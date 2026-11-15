import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;

import '../domain/maps_resolver.dart';
import '../domain/market.dart';
import '../domain/photo_scan.dart';
import '../domain/product_text.dart';
import '../domain/searcher.dart';
import '../domain/source_finder.dart';
import 'sources.dart';
import 'store.dart';

/// The network and storage half of هوش جستجوگر ۲ (see
/// `lib/domain/source_finder.dart` for the rules).
///
/// Only public pages are read: the answer page of a public search, the public
/// preview of a channel and the page of a website. No login, no API key, no
/// CAPTCHA is ever answered — a search page that refuses is left alone for
/// hours and the reason is written down.

/// The same identity every other request of the app uses on seller pages.
const finderAgent = 'IronPin/0.5 (public price reader)';

/// Standard mobile browser User-Agent used only when requesting public search
/// engine result pages so SSR HTML endpoints (such as DuckDuckGo HTML and
/// mobile Bing/Yahoo) return normal 200 HTML instead of bot-challenge 202s.
const finderSearchAgent =
    'Mozilla/5.0 (Linux; Android 13; IronPin) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

class FinderAnchor {
  final String url, text;
  const FinderAnchor(this.url, this.text);
}

class FinderPage {
  final String title, text;

  /// The name the site gives itself, when it states one.
  final String site;

  /// Whether a table on the page speaks of prices.
  final bool table;
  final List<FinderAnchor> links;
  const FinderPage(this.title, this.text, this.links,
      {this.site = '', this.table = false});
}

String _oneLine(String value, int max) {
  final s = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s.length <= max ? s : s.substring(0, max);
}

const _blocks = {
  'p', 'div', 'br', 'li', 'tr', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'section',
  'article', 'footer', 'header', 'address', 'table', 'ul', 'ol', 'td', 'th'
};
const _silent = {'script', 'style', 'noscript', 'svg', 'template', 'head'};

void _collect(dom.Node node, StringBuffer out, int limit) {
  if (out.length >= limit) return;
  if (node is dom.Text) {
    out.write(node.text);
    return;
  }
  if (node is dom.Element) {
    final tag = node.localName ?? '';
    if (_silent.contains(tag)) return;
    final block = _blocks.contains(tag);
    if (block) out.write('\n');
    for (final child in node.nodes) {
      _collect(child, out, limit);
    }
    if (block) out.write('\n');
    return;
  }
  for (final child in node.nodes) {
    _collect(child, out, limit);
  }
}

/// Addresses of channels written as plain text, without a link around them.
final _written = RegExp(
    r'(?:https?://)?((?:t\.me|telegram\.me|eitaa\.com|ble\.ir|rubika\.ir|splus\.ir)/[A-Za-z0-9_@/]{3,80})');

/// Reads one public page: its title, its visible text line by line and every
/// address it links to — web addresses and the app addresses of messengers
/// (`tg://resolve?domain=…`, `et://resolve?domain=…`) alike.
FinderPage readFinderPage(Map<String, String> input) {
  final base = Uri.parse(input['url']!);
  final doc = html.parse(input['body']!);
  String meta(String selector) =>
      doc.querySelector(selector)?.attributes['content']?.trim() ?? '';
  final og = meta('meta[property="og:title"]');
  final title =
      _oneLine(og.isNotEmpty ? og : doc.querySelector('title')?.text ?? '', 120);
  final description = [
    meta('meta[property="og:description"]'),
    meta('meta[name="description"]')
  ].where((x) => x.isNotEmpty).join('\n');
  final links = <FinderAnchor>[];
  final seen = <String>{};
  for (final a in doc.querySelectorAll('a[href]')) {
    final href = a.attributes['href']!.trim();
    if (href.isEmpty ||
        href.startsWith('#') ||
        href.startsWith('javascript:') ||
        href.startsWith('mailto:') ||
        href.startsWith('tel:')) {
      continue;
    }
    String url;
    try {
      url = webAddressOf(href) ?? base.resolve(href).toString();
    } catch (_) {
      continue;
    }
    if (seen.add(url)) links.add(FinderAnchor(url, _oneLine(a.text, 120)));
    if (links.length >= 500) break;
  }
  final table = doc
      .querySelectorAll('table')
      .take(40)
      .any((t) => t.text.contains('قیمت'));
  final buffer = StringBuffer();
  final body = doc.body;
  if (body != null) _collect(body, buffer, 60000);
  final text = buffer
      .toString()
      .replaceAll(RegExp(r'[ \t\u00a0]+'), ' ')
      .replaceAll(RegExp(r' ?\n[ \n]*'), '\n')
      .trim();
  for (final m in _written.allMatches(text).take(60)) {
    final url = 'https://${m[1]}';
    if (seen.add(url)) links.add(FinderAnchor(url, ''));
  }
  return FinderPage(title, '$description\n$text', links,
      site: _oneLine(meta('meta[property="og:site_name"]'), 40), table: table);
}

/// What the list builder needs to know about a page, decided where the page
/// was read. On a phone the reading, the word counting and the contact lines
/// of a large page cost tens of milliseconds, so the whole judgement runs on
/// a second isolate and only this small answer comes back.
class FinderJudged {
  final String title, site, contact;
  final bool table, sells;

  /// How much visible text the page had (a channel without a public preview
  /// has almost none).
  final int textLength;
  final List<FinderAnchor> links;
  const FinderJudged(
      {required this.title,
      required this.site,
      required this.contact,
      required this.table,
      required this.sells,
      required this.textLength,
      required this.links});
}

FinderJudged judgeFinderPage(Map<String, String> input) {
  final page = readFinderPage(input);
  return FinderJudged(
      title: page.title,
      site: page.site,
      table: page.table,
      sells: sellsGoods('${page.title}\n${page.text}'),
      contact: Searcher.contactLines(page.text),
      textLength: page.text.trim().length,
      links: page.links);
}

/// A public search page the app may ask. Only address formats that were
/// actually observed are listed; nothing here is a guessed API.
///
/// Multiple independent global and Iranian domestic engines are rotated in
/// round-robin order so rate-limiting, filtering, or downtime on any subset of
/// providers never stalls discovery:
/// * `ddg-lite` — DuckDuckGo Lite SSR table page (`lite.duckduckgo.com`).
/// * `yahoo` — Yahoo UK SSR web search (`uk.search.yahoo.com`), honours `site:`.
/// * `bing` — Bing RSS result feed (`format=rss`), honours `site:`.
/// * `ddg` — DuckDuckGo non-JS HTML (`html.duckduckgo.com`), honours `site:`.
/// * `naver` — Naver web search (`search.naver.com`), independent index.
/// * `bing-html` — Bing standard SSR HTML (`www.bing.com/search`).
/// * `yahoo-ca` — Yahoo Canada SSR web search (`ca.search.yahoo.com`).
/// * `gerdoo` — Iranian domestic meta-search (`gerdoo.me`), reachable on NIN.
/// * `zarebin` — Iranian domestic search API (`zarebin.ir`), reachable on NIN.
class FinderProvider {
  final String id, title;
  final Uri Function(String query) url;
  final bool siteOperator;
  final Duration timeout;
  const FinderProvider(this.id, this.title, this.url,
      {this.siteOperator = true, this.timeout = const Duration(seconds: 10)});
}

Uri _duckLiteUrl(String q) =>
    Uri.https('lite.duckduckgo.com', '/lite/', {'q': q});
Uri _yahooUkUrl(String q) =>
    Uri.https('uk.search.yahoo.com', '/search', {'p': q});
Uri _bingUrl(String q) =>
    Uri.https('www.bing.com', '/search', {'q': q, 'format': 'rss'});
Uri _duckUrl(String q) => Uri.https('html.duckduckgo.com', '/html/', {'q': q});
Uri _naverUrl(String q) =>
    Uri.https('search.naver.com', '/search.naver', {'where': 'web', 'query': q});
Uri _bingHtmlUrl(String q) => Uri.https('www.bing.com', '/search', {'q': q});
Uri _yahooCaUrl(String q) =>
    Uri.https('ca.search.yahoo.com', '/search', {'p': q});
Uri _gerdooUrl(String q) => Uri.https('gerdoo.me', '/search/', {'query': q});
Uri _zarebinUrl(String q) => Uri.https(
    'zarebin.ir', '/gse/api/search/', {'q': q, 'page': '1', 'query_source': 'user'});

const finderProviders = [
  FinderProvider('ddg-lite', 'داک‌داک‌گو سبک', _duckLiteUrl),
  FinderProvider('yahoo', 'یاهو', _yahooUkUrl,
      timeout: Duration(seconds: 12)),
  FinderProvider('bing', 'بینگ', _bingUrl),
  FinderProvider('ddg', 'داک‌داک‌گو', _duckUrl),
  FinderProvider('naver', 'نیور', _naverUrl,
      siteOperator: false, timeout: Duration(seconds: 12)),
  FinderProvider('bing-html', 'بینگ وب', _bingHtmlUrl,
      timeout: Duration(seconds: 12)),
  FinderProvider('yahoo-ca', 'یاهو ۲', _yahooCaUrl,
      timeout: Duration(seconds: 12)),
  FinderProvider('gerdoo', 'گردو', _gerdooUrl,
      siteOperator: false, timeout: Duration(seconds: 18)),
  FinderProvider('zarebin', 'ذره‌بین', _zarebinUrl,
      timeout: Duration(seconds: 14)),
];

final _yahooRu = RegExp(r'/RU=([^/]+)/R[KO]=');

/// The real address behind a result link of a search page.
String? unwrapResultLink(String href) {
  var h = href.trim();
  if (h.isEmpty) return null;
  if (h.startsWith('//')) h = 'https:$h';
  final u = Uri.tryParse(h);
  if (u == null || !(u.scheme == 'http' || u.scheme == 'https')) return null;
  final host = u.host.toLowerCase();
  if (host.endsWith('duckduckgo.com') && u.path.startsWith('/l/')) {
    final target = u.queryParameters['uddg'];
    return target == null || target.isEmpty ? null : target;
  }
  if (host.endsWith('yahoo.com')) {
    final m = _yahooRu.firstMatch(u.path);
    if (m != null) {
      try {
        final decoded = Uri.decodeComponent(m[1]!);
        return decoded.startsWith('http') ? decoded : null;
      } catch (_) {
        return null;
      }
    }
    return null;
  }
  if (host.endsWith('bing.com') && u.path.startsWith('/ck/')) {
    final raw = u.queryParameters['u'];
    if (raw == null || !raw.startsWith('a1')) return null;
    try {
      return utf8
          .decode(base64Url.decode(base64Url.normalize(raw.substring(2))));
    } catch (_) {
      return null;
    }
  }
  return h;
}

const _engineHosts = [
  'duckduckgo.com', 'bing.com', 'microsoft.com', 'msn.com', 'live.com',
  'gerdoo.me', 'zarebin.ir', 'yahoo.com', 'yimg.com', 'yahooapis.com',
  'naver.com', 'naver.net', 'pstatic.net', 'google.com', 'gstatic.com'
];

String _xml(String s) => s
    .replaceAll(RegExp(r'<!\[CDATA\[|\]\]>'), '')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

void _collectJsonAnchors(Object? node, void Function(String?, String) add,
    [int depth = 0]) {
  if (node == null || depth > 8) return;
  if (node is List) {
    for (final item in node.take(80)) {
      _collectJsonAnchors(item, add, depth + 1);
    }
    return;
  }
  if (node is Map) {
    String str(List<String> keys) {
      for (final k in keys) {
        final v = node[k];
        if (v is String && v.trim().isNotEmpty) return v.trim();
      }
      return '';
    }

    final link = str(const ['web_link', 'url', 'link', 'href']);
    final title = str(const ['title', 'name', 'heading']);
    final desc =
        str(const ['description', 'snippet', 'content', 'summary', 'text']);
    if (link.startsWith('http')) {
      add(link, '$title $desc');
    }
    for (final v in node.values) {
      if (v is Map || v is List) _collectJsonAnchors(v, add, depth + 1);
    }
  }
}

/// The result links of a search answer, each with its title and summary.
List<FinderAnchor> readSearchResults(Map<String, String> input) {
  final out = <FinderAnchor>[];
  final index = <String, int>{};
  void add(String? href, String text) {
    final url = unwrapResultLink(href ?? '');
    if (url == null) return;
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    if (host.isEmpty ||
        _engineHosts.any((e) => host == e || host.endsWith('.$e'))) {
      return;
    }
    final cleanText = _oneLine(text, 300);
    final known = index[url];
    if (known == null) {
      index[url] = out.length;
      out.add(FinderAnchor(url, cleanText));
    } else if (cleanText.isNotEmpty && !out[known].text.contains(cleanText)) {
      // The same result is linked twice (its address line and its title).
      out[known] = FinderAnchor(url, _oneLine('${out[known].text} $cleanText', 300));
    }
  }

  final body = input['body']!;
  final provider = input['provider'] ?? '';
  switch (provider) {
    case 'bing':
      // Bing's RSS form: one <item> per result with the plain address.
      for (final item
          in RegExp(r'<item>(.*?)</item>', dotAll: true).allMatches(body)) {
        String tag(String name) =>
            _xml(RegExp('<$name>(.*?)</$name>', dotAll: true)
                    .firstMatch(item[1]!)?[1] ??
                '');
        add(tag('link'), '${tag('title')} ${tag('description')}');
      }
    case 'bing-html':
      final doc = html.parse(body);
      final cards = doc.querySelectorAll('li.b_algo');
      if (cards.isNotEmpty) {
        for (final r in cards) {
          final a = r.querySelector('h2 a[href]') ?? r.querySelector('a[href]');
          if (a == null) continue;
          final caption = r.querySelector('.b_caption')?.text ?? r.text;
          add(a.attributes['href'], '${a.text} $caption');
        }
      } else {
        for (final a in doc.querySelectorAll('a[href]')) {
          add(a.attributes['href'], a.text);
        }
      }
    case 'ddg':
      final doc = html.parse(body);
      for (final r in doc.querySelectorAll('.result')) {
        final a = r.querySelector('a.result__a');
        if (a == null) continue;
        add(a.attributes['href'],
            '${a.text} ${r.querySelector('.result__snippet')?.text ?? ''}');
      }
    case 'ddg-lite':
      final doc = html.parse(body);
      for (final a in doc.querySelectorAll('a.result-link')) {
        dom.Element? tr = a.parent;
        while (tr != null && tr.localName != 'tr') {
          tr = tr.parent;
        }
        String snippet = '';
        if (tr != null && tr.parent != null) {
          final rows = tr.parent!.children;
          final idx = rows.indexOf(tr);
          if (idx >= 0 && idx + 1 < rows.length) {
            final next = rows[idx + 1];
            snippet = next.querySelector('.result-snippet')?.text ?? next.text;
          }
        }
        add(a.attributes['href'], '${a.text} $snippet');
      }
    case 'yahoo':
    case 'yahoo-ca':
      final doc = html.parse(body);
      for (final a in doc.querySelectorAll('a[href]')) {
        final href = a.attributes['href'] ?? '';
        if (!href.contains('/RU=') && !href.startsWith('http')) continue;
        dom.Element? block;
        var parent = a.parent;
        for (var i = 0; i < 6 && parent != null; i++, parent = parent.parent) {
          final cls = parent.className;
          if (cls.contains('algo') ||
              cls.contains('Sr') ||
              cls.contains('dd') ||
              parent.localName == 'li') {
            block = parent;
            break;
          }
        }
        add(href, '${a.text} ${block?.text ?? ''}');
      }
    case 'naver':
      final doc = html.parse(body);
      for (final a in doc.querySelectorAll('a[href]')) {
        final href = a.attributes['href']?.trim() ?? '';
        if (!href.startsWith('http')) continue;
        dom.Element? block;
        var parent = a.parent;
        for (var i = 0; i < 6 && parent != null; i++, parent = parent.parent) {
          final cls = parent.className;
          if (cls.contains('total_wrap') ||
              cls.contains('bx') ||
              parent.localName == 'li' ||
              (parent.localName == 'div' && parent.text.length <= 900)) {
            block = parent;
            if (cls.contains('total_wrap') || parent.localName == 'li') break;
          }
        }
        add(href, '${a.text} ${block?.text ?? ''}');
      }
    case 'zarebin':
      final trimmed = body.trimLeft();
      if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
        try {
          _collectJsonAnchors(jsonDecode(trimmed), add);
          break;
        } catch (_) {
          // Fall through to HTML parsing if response wasn't valid JSON.
        }
      }
      final doc = html.parse(body);
      for (final a in doc.querySelectorAll('a[href]')) {
        final href = a.attributes['href']!.trim();
        if (!href.startsWith('http')) continue;
        add(href, '${a.text} ${a.parent?.text ?? ''}');
      }
    default:
      // A page that links its results directly (Gerdoo): every link that
      // leaves the search page, with the text of the result block around it.
      final doc = html.parse(body);
      for (final a in doc.querySelectorAll('a[href]')) {
        final href = a.attributes['href']!.trim();
        if (!href.startsWith('http')) continue;
        dom.Element? block;
        var parent = a.parent;
        for (var i = 0; i < 6 && parent != null; i++, parent = parent.parent) {
          if (parent.className.contains('search-result')) {
            block = parent;
            break;
          }
        }
        add(href, '${a.text} ${block?.text ?? ''}');
      }
  }
  return out;
}

/// Whether a search page answered with a bot-challenge or rate-limit wall.
bool isSearchChallenge(String providerId, int status, String body) {
  if (status != 200) return true;
  if ((providerId == 'ddg' || providerId == 'ddg-lite') &&
      body.contains('anomaly')) {
    return true;
  }
  return body.contains("Making sure you're not a bot") ||
      body.contains('Making sure you&#x27;re not a bot') ||
      body.contains('smart-captcha') ||
      body.contains('CheckboxCaptcha') ||
      (body.contains('g-recaptcha') && body.length < 12000);
}

/// Whether an answer page honestly says the question has no results.
bool saysNoResults(String body) =>
    body.contains('no-results') ||
    body.contains('No results') ||
    body.contains('class="b_no"') ||
    body.contains('We did not find results for') ||
    body.contains('did not match any documents') ||
    body.contains('검색결과가 없습니다') ||
    body.contains('نتیجه‌ای یافت نشد') ||
    body.contains('نتیجه ای یافت نشد') ||
    body.contains('موردی یافت نشد');

/// Whether the results are about the question at all. A search page that
/// suspects a program sometimes answers with unrelated links; such an answer
/// is treated as no answer, never as findings.
bool answersQuestion(String query, List<FinderAnchor> results) {
  final tokens = FinderPlan.tokens(query);
  if (tokens.isEmpty) return true;
  for (final r in results) {
    var address = r.url;
    try {
      address = Uri.decodeFull(r.url);
    } catch (_) {
      // Keep the encoded form.
    }
    final text = ProductText.normalize('${r.text} $address');
    if (tokens.any(text.contains)) return true;
  }
  return false;
}

class FinderReport {
  final int steps;

  /// Three requests in a row could not leave the phone.
  final bool offline;

  /// Nothing is left to do right now.
  final bool idle;
  final bool skipped;
  const FinderReport(
      {this.steps = 0,
      this.offline = false,
      this.idle = false,
      this.skipped = false});
}

class FinderHandoff {
  final FinderEntry entry;
  final SourceEndpoint endpoint;
  const FinderHandoff(this.entry, this.endpoint);
}

class _Fetched {
  final int status;
  final String body;
  const _Fetched(this.status, this.body);
}

class _Outcome {
  /// The request never got an answer: the phone may be offline.
  final bool network;

  /// Takes the failure back when it turns out the phone was offline.
  final void Function()? undo;
  final String note;
  const _Outcome({this.network = false, this.undo, this.note = ''});
}

/// Canonical key of any [SourceEndpoint] for zero-duplicate checks across
/// built-in routes, discovered channels, and Smart Search 2 entries.
String endpointCanonicalKey(SourceEndpoint e) => canonicalUrlKey(e.url);

/// What the app already reads; such a place is never listed as new.
Set<String> finderKnownKeys([Iterable<SourceEndpoint> extra = const []]) {
  final known = <String>{};
  for (final e in endpoints) {
    final link = classifyLink(e.url);
    if (link == null) {
      known.add(canonicalUrlKey(e.url));
      continue;
    }
    known.add(link.key);
    if (link.kind == 'site') known.add('host:${link.host}');
  }
  for (final e in extra) {
    final link = classifyLink(e.url);
    known.add(link?.key ?? canonicalUrlKey(e.url));
  }
  return known;
}

class SourceFinder {
  final MarketStore store;
  final http.Client client;

  /// Pause between two page reads, and between two questions to search pages.
  final Duration pageGap, searchGap, timeout;

  /// Minimum pause before asking the *same* search provider a second question.
  final Duration providerGap;

  /// How long a candidate's own page may take. Shorter than [timeout]: a list
  /// waits for the first reading of every candidate, and a seller whose page
  /// does not answer in this time is simply read later.
  final Duration readTimeout;
  final int maxBytes;

  /// Maximum concurrent candidate/seed page reads across distinct hosts.
  final int maxParallelReads;
  final List<FinderProvider> providers;

  /// Pages on different networks, asked only to tell "this host is down"
  /// from "the phone is offline" after three requests in a row failed.
  final List<String> probes;
  final DateTime Function() clock;
  final int _writer = Random().nextInt(0x3fffffff) + 1;
  final Map<String, int> _emptyStreak = {};
  final Map<String, int> _lastProviderMs = {};
  final Map<String, int> _providerAskSeq = {};
  int _askCounter = 0;

  /// Whose turn it is among the three lists when a candidate is read.
  int _turn = 0;
  int _batches = 0;

  FinderState state = FinderState();
  final Set<String> known = finderKnownKeys();
  bool _loaded = false, _running = false;
  int _lastSearchMs = 0;
  final Map<String, String> _stored = {};

  SourceFinder(this.store,
      {required this.client,
      this.pageGap = const Duration(milliseconds: 300),
      this.searchGap = const Duration(milliseconds: 1200),
      Duration? providerGap,
      this.timeout = const Duration(seconds: 10),
      this.readTimeout = const Duration(seconds: 7),
      this.maxBytes = 1000000,
      this.maxParallelReads = 4,
      this.providers = finderProviders,
      this.probes = const [
        'https://www.bing.com/',
        'https://uk.search.yahoo.com/',
        'https://eitaa.com/',
        'https://ahanmelal.com/'
      ],
      DateTime Function()? clock})
      : providerGap = providerGap ??
            (searchGap == Duration.zero
                ? Duration.zero
                : const Duration(milliseconds: 3200)),
        clock = clock ?? DateTime.now;

  bool get running => _running;
  int _now() => clock().millisecondsSinceEpoch ~/ 1000;

  Future<void> load({bool force = false}) async {
    if (_loaded && !force) return;
    final found = await store.settingsMap(FinderState.settingKeys);
    final values = <String, String?>{
      for (final key in FinderState.settingKeys) key: found[key]
    };
    state = FinderState.fromSettings(values);
    state.deduplicate(known);
    _stored
      ..clear()
      ..addAll(found);
    _loaded = true;
  }

  /// Registers extra endpoints the app already reads (e.g. discovered channels)
  /// so Smart Search 2 never lists or hands over duplicates of them.
  Future<void> registerKnownEndpoints(Iterable<SourceEndpoint> extra) async {
    known
      ..clear()
      ..addAll(finderKnownKeys(extra));
    if (_loaded && state.deduplicate(known) > 0) {
      await save();
    }
  }

  /// Resets network-related provider/host cooldowns and restarts search if the
  /// `در نوبت` queue is empty when internet connectivity arrives.
  Future<void> onNetworkConnected() async {
    await sync();
    final now = _now();
    state.onNetworkConnected(now);
    _lastProviderMs.clear();
    _lastSearchMs = 0;
    state.startNextRoundIfQueueZero(now,
        askable: (t) => _providerFor(t, now) != null,
        resting: (e) => _resting(e, now),
        drainedJustNow: true);
    _complete(now);
    await save();
  }

  /// Starts a new search round immediately if `در نوبت` (`waiting`) is zero and
  /// no active work remains in the current round.
  Future<bool> ensureSearchingWhenQueueEmpty({bool drainedJustNow = false}) async {
    await sync();
    final now = _now();
    state.cooldown.removeWhere((_, until) => until <= now);
    final started = state.startNextRoundIfQueueZero(now,
        askable: (t) => _providerFor(t, now) != null,
        resting: (e) => _resting(e, now),
        drainedJustNow: drainedJustNow);
    if (started) {
      _complete(now);
      await save();
    }
    return started;
  }

  /// Picks up what another run (the background task) wrote meanwhile.
  Future<void> sync() async {
    if (!_loaded) return load();
    try {
      final raw = await store.setting('finder.meta');
      if (raw == null) return;
      final meta = jsonDecode(raw);
      if (meta is Map &&
          (meta['rev'] != state.rev || meta['writer'] != state.writer)) {
        await load(force: true);
      }
    } catch (_) {
      await load(force: true);
    }
  }

  Future<void> _saving = Future<void>.value();

  /// Waits for any queued persistence transaction to finish before backup/close.
  Future<void> flush() => _saving.catchError((Object _) {});

  /// Writes all changed keys atomically inside one SQLite transaction.
  /// Saves are queued one behind the other, so a verdict recorded by a
  /// refresh and a step finishing at the same moment cannot interleave.
  Future<void> save() {
    state.rev++;
    state.writer = _writer;
    final values = state.toSettings();
    return _saving = _saving.catchError((Object _) {}).then((_) async {
      final changed = <String, String>{};
      for (final key in FinderState.settingKeys.reversed) {
        final value = values[key]!;
        if (_stored[key] == value) continue;
        changed[key] = value;
      }
      if (changed.isEmpty) return;
      await store.setSettings(changed);
      _stored.addAll(changed);
    });
  }

  /// Puts a link on its list. A page of a public channel directory is not a
  /// seller: it is queued to be read once for the addresses it gives.
  bool _offer(FinderLink link,
      {required String from,
      required int depth,
      required bool hinted,
      required int now,
      String name = '',
      bool inner = false}) {
    if (link.kind == 'site' && isDirectoryHost(link.host)) {
      if (hinted &&
          state.queue.where((t) => t.type == 'P').length < 40 &&
          !state.knows(link.key)) {
        state.addSeedPages([link.url]);
      }
      return false;
    }
    return state.offer(link,
        from: from,
        depth: depth,
        hinted: hinted,
        now: now,
        name: name,
        inner: inner,
        known: known);
  }

  /// Gives the searcher its starting points once: the research lists shipped
  /// with the app (as candidates) and the pages of the sellers the app already
  /// reads (for the channels they link to).
  Future<void> seed(
      {Iterable<String> candidates = const [],
      Iterable<String> pages = const []}) async {
    await sync();
    if (state.seeded) return;
    final now = _now();
    for (final url in candidates) {
      final link = classifyLink(url);
      if (link != null) {
        _offer(link,
            from: 'فهرست پژوهش برنامه', depth: 0, hinted: true, now: now);
      }
    }
    state.addSeedPages(pages);
    state.seeded = true;
    await save();
  }

  /// Channel links the app saw in the posts it already reads.
  Future<int> offerLinks(Iterable<String> urls, {required String from}) async {
    if (!_loaded) await load();
    final now = _now();
    var added = 0;
    for (final url in urls) {
      final link = classifyLink(url);
      if (link != null &&
          _offer(link, from: from, depth: 1, hinted: true, now: now)) {
        added++;
      }
    }
    if (added > 0) {
      _complete(now);
      await save();
    }
    return added;
  }

  Future<_Fetched> _get(Uri url,
      {Duration? within, String userAgent = finderAgent}) async {
    final timeout = within ?? this.timeout;
    final request = http.Request('GET', url)
      ..followRedirects = true
      ..maxRedirects = 5
      ..headers.addAll({
        'User-Agent': userAgent,
        'Accept':
            'text/html,application/xhtml+xml,application/rss+xml,application/json;q=0.8',
        'Accept-Language': 'fa-IR,fa;q=0.9,en;q=0.5'
      });
    final response = await client.send(request).timeout(timeout);
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(timeout)) {
      bytes.add(chunk);
      if (bytes.length >= maxBytes) break;
    }
    return _Fetched(response.statusCode,
        utf8.decode(bytes.takeBytes(), allowMalformed: true));
  }

  /// Pages above this size are judged on a second isolate.
  static const inlineLimit = 16000;

  Future<FinderJudged> _read(String url, String body) async {
    final input = {'url': url, 'body': body};
    if (body.length < inlineLimit) return judgeFinderPage(input);
    try {
      return await compute(judgeFinderPage, input);
    } catch (_) {
      // No second isolate available (some embedders): same answer, in place.
      return judgeFinderPage(input);
    }
  }

  /// Round-robin provider ordering: healthy and untried providers rotate by
  /// least-recently-asked sequence so no single search engine is hammered.
  List<FinderProvider> _ordered() {
    int tier(FinderProvider p) {
      final note = state.providerNote[p.id] ?? '';
      if (note.startsWith('ok|') || note.isEmpty) return 0;
      return 1;
    }

    final list = [...providers];
    final rank = {for (var i = 0; i < list.length; i++) list[i].id: i};
    list.sort((a, b) {
      final byTier = tier(a).compareTo(tier(b));
      if (byTier != 0) return byTier;
      final seqA = _providerAskSeq[a.id] ?? 0;
      final seqB = _providerAskSeq[b.id] ?? 0;
      if (seqA != seqB) return seqA.compareTo(seqB);
      return rank[a.id]!.compareTo(rank[b.id]!);
    });
    return list;
  }

  /// The search page that will take this question now, if any.
  FinderProvider? _providerFor(FinderTask task, int now,
      {bool enforceGap = false}) {
    final site = FinderPlan.usesSiteOperator(task.value);
    final nowMs = clock().millisecondsSinceEpoch;
    FinderProvider? fallback;
    for (final p in _ordered()) {
      if ((state.cooldown[p.id] ?? 0) > now) continue;
      if (site && !p.siteOperator) continue;
      fallback ??= p;
      if (!enforceGap) return p;
      final lastMs = _lastProviderMs[p.id] ?? 0;
      if (lastMs == 0 ||
          Duration(milliseconds: nowMs - lastMs) >= providerGap) {
        return p;
      }
    }
    return fallback;
  }

  String _hostOf(FinderEntry e) => Uri.parse(previewUrl(e.kind, e.url)).host;
  bool _resting(FinderEntry e, int now) =>
      (state.cooldown['h:${_hostOf(e)}'] ?? 0) > now;

  /// Closes what can be closed now (see [FinderState.updateCompletion]).
  void _complete(int now) => state.updateCompletion(now,
      askable: (t) => _providerFor(t, now) != null,
      resting: (e) => _resting(e, now));

  void _rest(FinderProvider p, int now, int seconds, String code, String why) {
    state.cooldown[p.id] = now + seconds;
    state.providerNote[p.id] = '$code|$now';
    state.lastError = why;
  }

  /// Whether the phone reaches anything at all.
  Future<bool> _online() async {
    for (final url in probes) {
      try {
        final request = http.Request('GET', Uri.parse(url))
          ..headers['User-Agent'] = finderAgent;
        final response =
            await client.send(request).timeout(const Duration(seconds: 8));
        unawaited(response.stream.drain<void>().catchError((Object _) {}));
        return true;
      } catch (_) {
        // Try the next network.
      }
    }
    return false;
  }

  /// Runs a bounded piece of the work and saves after every step, so nothing
  /// is lost when the phone goes offline or the app is closed.
  Future<FinderReport> runSlice(
      {int maxSteps = 10,
      Duration budget = const Duration(seconds: 40),
      bool Function()? cancelled}) async {
    if (_running) return const FinderReport(skipped: true);
    _running = true;
    var steps = 0, netFails = 0, offline = false;
    final undo = <void Function()>[];
    final skip = <String>{};
    final watch = Stopwatch()..start();
    try {
      await sync();
      var now = _now();
      state.cooldown.removeWhere((_, until) => until <= now);
      if (state.startedAt == 0) state.beginRound(now);
      if (!state.maybeNextRound(now)) {
        state.startNextRoundIfQueueZero(now,
            askable: (t) => _providerFor(t, now) != null,
            resting: (e) => _resting(e, now));
      }
      _complete(now);
      while (steps < maxSteps &&
          watch.elapsed < budget &&
          !(cancelled?.call() ?? false)) {
        final batch = await _pickBatch(steps, skip, budget - watch.elapsed);
        if (batch.isEmpty) break;
        if (steps > 0) await Future<void>.delayed(pageGap);
        // Two readings at a time at most, never two on one host: the same
        // low concurrency as a refresh.
        final outcomes = await Future.wait([for (final job in batch) job()]);
        now = _now();
        state.lastStepAt = now;
        for (final outcome in outcomes) {
          steps++;
          if (outcome.network) {
            netFails++;
            if (outcome.undo != null) undo.add(outcome.undo!);
          } else {
            netFails = 0;
            undo.clear();
            state.lastOnlineAt = now;
            state.lastError = outcome.note;
          }
        }
        if (netFails >= 3) {
          if (await _online()) {
            // Those hosts are down or filtered; the phone is not offline,
            // so the failures stand and the work goes on elsewhere.
            netFails = 0;
            undo.clear();
            state.lastOnlineAt = now;
          } else {
            // Newest first, so every value returns to what it was before
            // the first of the failed requests.
            for (final u in undo.reversed) {
              u();
            }
            offline = true;
            state.lastError = 'اینترنت در دسترس نبود؛ ادامه در اتصال بعدی.';
          }
        }
        _complete(now);
        await save();
        if (offline) break;
      }
      if (!offline && netFails > 0 && undo.isNotEmpty && !await _online()) {
        // The slice ran out of work while its last requests were failing:
        // with nothing reachable at all, those were the phone being offline.
        for (final u in undo.reversed) {
          u();
        }
        offline = true;
        state.lastError = 'اینترنت در دسترس نبود؛ ادامه در اتصال بعدی.';
        _complete(_now());
        await save();
      }
      if (steps == 0) await save();
    } finally {
      _running = false;
    }
    return FinderReport(
        steps: steps, offline: offline, idle: steps == 0 && !offline);
  }

  Future<List<Future<_Outcome> Function()>> _pickBatch(
      int step, Set<String> skip, Duration left) async {
    final now = _now();
    FinderTask? search;
    FinderProvider? provider;
    for (final t in state.queue) {
      if (t.type != 'S' || skip.contains(t.value)) continue;
      final p = _providerFor(t, now, enforceGap: true);
      if (p == null) continue;
      search = t;
      provider = p;
      break;
    }
    final busyHosts = <String>{};
    FinderEntry? nextEntry() {
      final e = state.nextToVerify(skip,
          resting: (e) => _resting(e, now) || busyHosts.contains(_hostOf(e)),
          prefer: _turn % 3);
      if (e != null) {
        _turn++;
        skip.add(e.key);
        busyHosts.add(_hostOf(e));
      }
      return e;
    }

    FinderTask? nextPage() {
      for (final t in state.queue) {
        if (t.type != 'P' || skip.contains(t.value)) continue;
        final host = Uri.parse(t.value).host;
        if (busyHosts.contains(host)) continue;
        skip.add(t.value);
        busyHosts.add(host);
        return t;
      }
      return null;
    }

    final nowMs = clock().millisecondsSinceEpoch;
    final sinceGlobal = Duration(milliseconds: nowMs - _lastSearchMs);
    final sinceProvider = provider == null || (_lastProviderMs[provider.id] ?? 0) == 0
        ? providerGap
        : Duration(milliseconds: nowMs - _lastProviderMs[provider.id]!);
    final since = sinceGlobal < sinceProvider ? sinceGlobal : sinceProvider;
    final neededGap =
        sinceProvider < providerGap && (providerGap - sinceProvider) > (searchGap - sinceGlobal)
            ? providerGap
            : searchGap;
    final ready = search != null && provider != null;
    // Alternate briskly between search questions and parallel candidate reads.
    if (ready &&
        sinceGlobal >= searchGap &&
        sinceProvider >= providerGap &&
        step % 2 == 0) {
      return [() => _search(search!, provider!, skip)];
    }
    final readings = <Future<_Outcome> Function()>[];
    // Mostly candidates; every third turn a known seller's page first.
    if (_batches++ % 3 == 2) {
      final page = nextPage();
      if (page != null) readings.add(() => _seedPage(page));
    }
    while (readings.length < maxParallelReads) {
      final entry = nextEntry();
      if (entry == null) break;
      readings.add(() => _verify(entry));
    }
    while (readings.length < maxParallelReads) {
      final page = nextPage();
      if (page == null) break;
      readings.add(() => _seedPage(page));
    }
    if (readings.isNotEmpty) return readings;
    if (ready) {
      final wait = neededGap - since;
      if (wait < left) {
        if (wait > Duration.zero) await Future<void>.delayed(wait);
        return [() => _search(search!, provider!, skip)];
      }
    }
    return const [];
  }

  Future<_Outcome> _search(
      FinderTask task, FinderProvider p, Set<String> skip) async {
    final startMs = clock().millisecondsSinceEpoch;
    _lastSearchMs = startMs;
    _lastProviderMs[p.id] = startMs;
    _providerAskSeq[p.id] = ++_askCounter;
    final now = _now();
    _Fetched got;
    try {
      // Each page may take as long as it needs (see [FinderProvider.timeout]):
      // the question must not be declared unreachable because a slow — but
      // answering — page exceeded the short shared timeout.
      got = await _get(p.url(task.value),
          within: p.timeout, userAgent: finderSearchAgent);
    } catch (_) {
      // This page cannot be reached from this network right now. It is left
      // alone for a while and the question goes to the next page; nothing is
      // counted against the question.
      final before = state.cooldown[p.id], note = state.providerNote[p.id];
      _rest(p, now, 3 * 60, 'net',
          'صفحه جستجوی ${p.title} پاسخ نداد؛ سه دقیقه بعد دوباره پرسیده می‌شود و تا آن زمان صفحه بعدی امتحان می‌شود.');
      return _Outcome(
          network: true,
          undo: () {
            if (before == null) {
              state.cooldown.remove(p.id);
            } else {
              state.cooldown[p.id] = before;
            }
            if (note == null) {
              state.providerNote.remove(p.id);
            } else {
              state.providerNote[p.id] = note;
            }
          });
    }
    if (isSearchChallenge(p.id, got.status, got.body)) {
      // The page asked not to be read by a program. It is not argued with.
      _rest(p, now, 3 * 3600, 'refused',
          'صفحه جستجوی ${p.title} پاسخ نداد (${got.status})؛ چند ساعت کنار گذاشته شد.');
      return _Outcome(note: state.lastError);
    }
    final input = {'provider': p.id, 'body': got.body};
    List<FinderAnchor> results;
    if (got.body.length < inlineLimit) {
      results = readSearchResults(input);
    } else {
      try {
        results = await compute(readSearchResults, input);
      } catch (_) {
        results = readSearchResults(input);
      }
    }
    if (results.isEmpty) {
      final streak = (_emptyStreak[p.id] ?? 0) + 1;
      _emptyStreak[p.id] = streak;
      if (streak >= 3 && !saysNoResults(got.body)) {
        // Three empty answers in a row: the page changed or holds back.
        _emptyStreak[p.id] = 0;
        _rest(p, now, 3600, 'unreadable',
            'پاسخ صفحه جستجوی ${p.title} خوانده نشد؛ یک ساعت کنار گذاشته شد.');
        return _Outcome(note: state.lastError);
      }
      // An honest "nothing found": the question is answered.
      skip.add(task.value);
      state.providerNote[p.id] = 'ok|$now';
      state.finish(task);
      return const _Outcome();
    }
    if (!answersQuestion(task.value, results)) {
      _rest(p, now, 3600, 'unreadable',
          'پاسخ صفحه جستجوی ${p.title} به پرسش ربطی نداشت؛ یک ساعت کنار گذاشته شد.');
      return _Outcome(note: state.lastError);
    }
    _emptyStreak[p.id] = 0;
    state.providerNote[p.id] = 'ok|$now';
    for (final r in results) {
      final link = classifyLink(r.url);
      if (link == null) continue;
      final hinted = sellsGoods(r.text);
      // A website must already be described as selling goods in the answer;
      // a channel is read anyway, its own page decides.
      if (link.kind == 'site' && !hinted) continue;
      _offer(link,
          from: 'جستجو (${p.title}): ${task.value}',
          depth: 0,
          hinted: hinted,
          now: now);
    }
    state.searches++;
    skip.add(task.value);
    state.finish(task);
    return const _Outcome();
  }

  Future<_Outcome> _verify(FinderEntry entry) async {
    final now = _now();
    final url = previewUrl(entry.kind, entry.url);
    _Fetched got;
    final host = _hostOf(entry);
    try {
      got = await _get(Uri.parse(url), within: readTimeout);
    } catch (_) {
      const reason = 'در سه نوبت در دسترس نبود';
      final struck = <FinderEntry>[entry];
      state.failed(entry, reason);
      final fails = state.hostFails[host] ?? 0;
      final before = state.cooldown['h:$host'];
      state.hostFails[host] = fails + 1;
      if (fails + 1 >= 2) {
        // The host itself does not answer (down, or filtered on this
        // network). It is left alone for ten minutes and the attempt counts
        // for every candidate on it, so one dead host costs two requests, not
        // three for each of its channels.
        state.hostFails[host] = 0;
        state.cooldown['h:$host'] = now + 10 * 60;
        for (final other in state.entries.toList()) {
          if (other.state == 'new' &&
              !identical(other, entry) &&
              _hostOf(other) == host) {
            state.failed(other, reason);
            struck.add(other);
          }
        }
      } else {
        // Once is not yet a pattern; the host gets a few minutes.
        state.cooldown['h:$host'] = now + 3 * 60;
      }
      return _Outcome(
          network: true,
          undo: () {
            for (final e in struck) {
              state.refund(e);
            }
            state.hostFails[host] = fails;
            if (fails == 0) state.hostFails.remove(host);
            if (before == null) {
              state.cooldown.remove('h:$host');
            } else {
              state.cooldown['h:$host'] = before;
            }
          });
    }
    state.hostFails.remove(host);
    if (got.status == 404 || got.status == 410) {
      state.discard(entry);
      return const _Outcome();
    }
    if (got.status != 200) {
      state.failed(entry, 'پاسخ عمومی ${got.status}');
      return const _Outcome();
    }
    final page = await _read(url, got.body);
    if (!page.sells) {
      // A channel whose public page shows no posts cannot speak for itself;
      // it stays only if the place that named it spoke of selling goods.
      if (entry.kind != 'site' && entry.hinted && page.textLength < 200) {
        state.confirm(entry,
            name: page.title, note: 'پیش‌نمایش عمومی پیام نداشت');
      } else {
        state.discard(entry);
      }
      return const _Outcome();
    }
    state.confirm(entry,
        name: page.title,
        contact: page.contact,
        site: page.site,
        table: page.table);
    state.pages++;
    if (entry.depth >= FinderState.maxDepth) return const _Outcome();
    var sites = 0;
    for (final a in page.links) {
      final link = classifyLink(a.url);
      if (link == null) continue;
      if (link.kind != 'site') {
        _offer(link,
            from: entry.url, depth: entry.depth + 1, hinted: true, now: now);
      } else if (entry.kind == 'site') {
        // Of a website only its own price pages are followed.
        if (entry.inner || link.host != entry.host) continue;
        if (!a.text.contains('قیمت') || tradeEvidence(a.text).goods < 1) {
          continue;
        }
        _offer(link,
            from: entry.url,
            depth: entry.depth + 1,
            hinted: true,
            inner: true,
            name: a.text,
            now: now);
      } else if (sites < 5) {
        // A channel naming a website: most often the seller's own.
        if (_offer(link,
            from: entry.url, depth: entry.depth + 1, hinted: true, now: now)) {
          sites++;
        }
      }
    }
    return const _Outcome();
  }

  Future<_Outcome> _seedPage(FinderTask task) async {
    final now = _now();
    _Fetched got;
    try {
      got = await _get(Uri.parse(task.value));
    } catch (_) {
      task.tries++;
      final closed = task.tries >= 2;
      if (closed) state.finish(task);
      return _Outcome(
          network: true,
          undo: () {
            task.tries--;
            if (closed && !state.queue.contains(task)) state.queue.add(task);
          });
    }
    state.finish(task);
    final self = classifyLink(task.value);
    if (self != null) state.remember(self.key);
    if (got.status != 200) return const _Outcome();
    final page = await _read(task.value, got.body);
    // A directory page is trusted only as far as its own words go: the
    // channel it describes is followed when the description sells goods.
    final directory = isDirectoryHost(Uri.parse(task.value).host);
    if (directory && !page.sells) return const _Outcome();
    for (final a in page.links) {
      final link = classifyLink(a.url);
      if (link == null || link.kind == 'site') continue;
      _offer(link, from: task.value, depth: 1, hinted: true, now: now);
    }
    state.pages++;
    return const _Outcome();
  }

  // ----------------------------------------------------------------- hand-over

  /// The source the app reads for an entry: the app's own channel reader for
  /// a channel, the heading-owned table reader for a website page.
  SourceEndpoint? endpointOf(FinderEntry e) => finderEndpointOf(e);

  /// Sources هوش جستجوگر ۱ has already accepted, deduplicated by canonical URL
  /// and excluding any route already present in built-in [endpoints].
  List<SourceEndpoint> acceptedEndpoints({bool onlyUnapplied = false}) {
    final builtInKeys = {for (final e in endpoints) endpointCanonicalKey(e)};
    final builtInIds = {for (final e in endpoints) e.id};
    final seenIds = <String>{};
    final seenKeys = <String>{};
    final out = <SourceEndpoint>[];
    for (final e in state.entries) {
      if (e.handoff != 'accepted' || (onlyUnapplied && e.applied)) continue;
      final ep = endpointOf(e);
      if (ep == null) continue;
      final cKey = endpointCanonicalKey(ep);
      if (builtInIds.contains(ep.id) || builtInKeys.contains(cKey)) continue;
      if (seenIds.add(ep.id) && seenKeys.add(cKey)) {
        out.add(ep);
      }
    }
    return out;
  }

  /// The entries to give to هوش جستجوگر ۱ now. The place is decided by its
  /// rules from the contact lines the entry was found with.
  List<FinderHandoff> handoffBatch(
      {int limit = 12, bool Function(FinderEntry entry)? where}) {
    if (!_loaded) return const [];
    final builtInKeys = {for (final e in endpoints) endpointCanonicalKey(e)};
    final out = <FinderHandoff>[];
    final seenKeys = <String>{};
    for (final e in state.waiting(_now(), limit: where == null ? limit : 400)) {
      if (where != null && !where(e)) continue;
      if (out.length >= limit) break;
      if (e.city.isEmpty && e.contact.isNotEmpty) {
        final place = Searcher.placeOfText(e.contact);
        e.city = place.city;
        e.cityBasis = place.basis;
      }
      final endpoint = endpointOf(e);
      if (endpoint == null) {
        e.handoff = 'rejected';
        e.note = 'نشانی برای خواندن عمومی معتبر نبود';
        continue;
      }
      final cKey = endpointCanonicalKey(endpoint);
      if (builtInKeys.contains(cKey) || known.contains(e.key)) {
        state.discard(e);
        continue;
      }
      if (!seenKeys.add(cKey)) continue;
      out.add(FinderHandoff(e, endpoint));
    }
    return out;
  }

  /// Records a transient network failure during handoff without locking the
  /// entry out for 24 hours.
  Future<void> deferNetwork(String key, {required String note}) async {
    final e = state.entry(key);
    if (e == null) return;
    state.deferHandoffNetwork(e, note: note, now: _now());
    await save();
  }

  /// Records what هوش جستجوگر ۱ answered for one entry.
  Future<void> verdict(String key,
      {required int rows, required String note}) async {
    final e = state.entry(key);
    if (e == null) return;
    state.verdict(e, rows: rows, note: note, now: _now());
    await save();
  }

  /// Marks accepted sources as switched on by the app. Returns their ids.
  Future<List<String>> takeUnapplied() async {
    final builtInKeys = {for (final e in endpoints) endpointCanonicalKey(e)};
    final builtInIds = {for (final e in endpoints) e.id};
    final ids = <String>[];
    var touched = false;
    for (final e in state.entries) {
      if (e.handoff != 'accepted' || e.applied) continue;
      final endpoint = endpointOf(e);
      e.applied = true;
      touched = true;
      if (endpoint != null &&
          !builtInIds.contains(endpoint.id) &&
          !builtInKeys.contains(endpointCanonicalKey(endpoint))) {
        ids.add(endpoint.id);
      }
    }
    if (touched) await save();
    return ids;
  }

  /// A short plain-text account of where the list builder stands, for the
  /// user to copy when something does not work on their network. It holds
  /// addresses and counts only — never a key, a phone or a message.
  String report() {
    final s = state, now = _now(), b = StringBuffer();
    String ago(int at) => at == 0 ? '-' : '${(now - at) ~/ 60}m';
    b.writeln('IronPin 0.9.9 finder • round ${s.round + 1} • '
        'started ${ago(s.startedAt)} • online ${ago(s.lastOnlineAt)} • '
        'step ${ago(s.lastStepAt)}');
    b.writeln('questions answered ${s.searches} • pages read ${s.pages} • '
        'dropped ${s.dropped}');
    b.writeln('search pages: ${[
      for (final p in providers)
        '${p.id}=${s.providerNote[p.id]?.split('|').first ?? '-'}'
            '${(s.cooldown[p.id] ?? 0) > now ? ' rest ${((s.cooldown[p.id]! - now) / 60).ceil()}m' : ''}'
    ].join(' ; ')}');
    final resting = [
      for (final e in s.cooldown.entries)
        if (e.key.startsWith('h:') && e.value > now) e.key.substring(2)
    ];
    if (resting.isNotEmpty) {
      b.writeln('hosts resting (${resting.length}): '
          '${resting.take(12).join(', ')}');
    }
    for (final part in FinderPart.all) {
      b.writeln('list ${part + 1}: complete=${s.complete[part]} '
          'questions=${s.unanswered(part)} '
          'new=${s.count(part, 'new')} ok=${s.count(part, 'ok')} '
          'unreachable=${s.count(part, 'unreachable')} '
          'unreadable=${s.count(part, 'unreadable')} '
          'wait=${s.waitingInPart(part, now)} '
          'accepted=${s.handed(part, 'accepted')} '
          'rejected=${s.handed(part, 'rejected')}');
    }
    final reasons = <String, int>{};
    for (final e in s.entries) {
      if (e.handoffTries > 0 || e.handoff == 'rejected') {
        reasons.update('${e.kind}: ${e.note}', (n) => n + 1, ifAbsent: () => 1);
      }
    }
    final top = reasons.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final r in top.take(8)) {
      b.writeln('not accepted ×${r.value} — ${r.key}');
    }
    for (final e in s.entries.where((e) => e.handoff == 'accepted').take(6)) {
      b.writeln('accepted — ${e.url}');
    }
    if (s.lastError.isNotEmpty) b.writeln('last: ${s.lastError}');
    return b.toString().trimRight();
  }
}

/// Maps one verified [FinderEntry] to the [SourceEndpoint] the app reads.
SourceEndpoint? finderEndpointOf(FinderEntry e) {
  final city = e.city.isEmpty ? 'نامشخص' : e.city;
  if (e.kind == 'site') {
    return SourceEndpoint('finder-site-${finderHash(e.url)}',
        e.site.isEmpty ? e.host : e.site, e.url, 'عمومی', 'site-table', city,
        defaultEnabled: false);
  }
  if (!e.readable) return null;
  return publicChannel(e.url,
      name: e.name.isEmpty ? null : e.name, city: city);
}

/// Hands waiting entries to هوش جستجوگر ۱ in parallel waves across distinct
/// hosts, reading text prices first and running bounded OCR only when needed,
/// and holding the SQLite refresh lock only while writing snapshots when
/// [alreadyLocked] is `false`.
Future<int> deliverFinderBatch(
    MarketStore store, SourceClient client, SourceFinder finder,
    {required int windowDays,
    int limit = 6,
    PhotoScanner? photos,
    bool sitesOnly = false,
    bool alreadyLocked = true,
    bool Function()? cancelled}) async {
  var accepted = 0;
  final batch = finder.handoffBatch(
      limit: limit, where: sitesOnly ? (e) => e.kind == 'site' : null);
  if (batch.isEmpty) return 0;

  Future<void> writeSnapshot(String endpointId, List<Quote> quotes,
      {required bool replaceMissing}) async {
    if (alreadyLocked) {
      await store.saveSnapshot(endpointId, quotes,
          replaceMissing: replaceMissing);
      return;
    }
    String? lease;
    try {
      lease = await store.acquireRefreshLock();
      await store.saveSnapshot(endpointId, quotes,
          replaceMissing: replaceMissing);
    } finally {
      if (lease != null) {
        try {
          await store.releaseRefreshLock(lease);
        } catch (_) {}
      }
    }
  }

  Future<bool> inspectOne(FinderHandoff h) async {
    if (cancelled?.call() ?? false) return false;
    final e = h.endpoint;
    try {
      final fetched =
          await client.fetch(e, windowDays: windowDays, pageLimit: 1);
      var rows = fetched;
      var found = rows.isEmpty
          ? const SearcherResult([])
          : await Searcher.processAsync(rows,
              now: DateTime.now(),
              windowDays: windowDays,
              resolver: MapsResolver(client.client));
      final hasImages =
          fetched.any((r) => (r.details['پیوست تصویر'] ?? '').isNotEmpty);
      if (found.quotes.isEmpty &&
          hasImages &&
          photos != null &&
          !photos.blocked &&
          !(cancelled?.call() ?? false)) {
        rows = (await readPostPhotos(fetched, photos,
                defaultCurrency: e.defaultCurrency,
                cancelled: cancelled,
                maxPhotos: 2))
            .rows;
        found = await Searcher.processAsync(rows,
            now: DateTime.now(),
            windowDays: windowDays,
            resolver: MapsResolver(client.client));
      }
      if (found.quotes.isEmpty) {
        if (hasImages && (photos == null || photos.blocked)) {
          // Background run without OCR: leave photo-bearing channel for the
          // foreground OCR reader instead of refusing it for the wrong reason.
          await finder.deferNetwork(h.entry.key,
              note: 'دارای تصویر قیمت؛ در انتظار خوانش OCR');
          return false;
        }
        await finder.verdict(h.entry.key,
            rows: 0,
            note: rows.isEmpty
                ? 'ردیف قیمت در صفحه عمومی پیدا نشد'
                : 'ردیف قابل‌ثبت نبود (بیرون از بازه: ${found.outOfWindow} • بی‌قیمت/بی‌محصول: ${found.noise})');
        return false;
      }
      await writeSnapshot(e.id, found.quotes,
          replaceMissing: client.complete[e.id] ?? true);
      await finder.verdict(h.entry.key,
          rows: found.quotes.length,
          note: 'هوش جستجوگر ۱: ${found.quotes.length} ردیف معتبر');
      return true;
    } catch (error) {
      if (error is FormatException) {
        await finder.verdict(h.entry.key, rows: 0, note: error.message);
      } else {
        await finder.deferNetwork(h.entry.key,
            note: 'خطا در اتصال/مهلت دریافت؛ تلاش مجدد');
      }
      return false;
    }
  }

  final pending = [...batch];
  while (pending.isNotEmpty && !(cancelled?.call() ?? false)) {
    final wave = <FinderHandoff>[];
    final waveHosts = <String>{};
    for (var i = 0; i < pending.length && wave.length < 3;) {
      final host = Uri.tryParse(pending[i].endpoint.url)?.host ?? '';
      if (waveHosts.add(host)) {
        wave.add(pending.removeAt(i));
      } else {
        i++;
      }
    }
    if (wave.isEmpty) wave.add(pending.removeAt(0));
    final results = await Future.wait([for (final h in wave) inspectOne(h)]);
    accepted += results.where((ok) => ok).length;
    if (pending.isNotEmpty && !(cancelled?.call() ?? false)) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
  }
  return accepted;
}
