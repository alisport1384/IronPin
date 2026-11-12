import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;

import '../domain/maps_resolver.dart';
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

/// The same identity every other request of the app uses.
const finderAgent = 'IronPin/0.5 (public price reader)';

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
/// * `gerdoo` — the Iranian search page, reachable on the domestic network.
///   It ignores the `site:` operator (observed), so such questions go to the
///   others.
/// * `ddg` — DuckDuckGo's page for browsers without scripts.
/// * `bing` — Bing's own RSS form of its result page (`format=rss`).
class FinderProvider {
  final String id, title;
  final Uri Function(String query) url;
  final bool siteOperator;
  const FinderProvider(this.id, this.title, this.url,
      {this.siteOperator = true});
}

Uri _gerdooUrl(String q) => Uri.https('gerdoo.me', '/search/', {'query': q});
Uri _duckUrl(String q) => Uri.https('html.duckduckgo.com', '/html/', {'q': q});
Uri _bingUrl(String q) =>
    Uri.https('www.bing.com', '/search', {'q': q, 'format': 'rss'});
const finderProviders = [
  FinderProvider('gerdoo', 'گردو', _gerdooUrl, siteOperator: false),
  FinderProvider('ddg', 'داک‌داک‌گو', _duckUrl),
  FinderProvider('bing', 'بینگ', _bingUrl)
];

/// The real address behind a result link of a search page.
String? unwrapResultLink(String href) {
  var h = href.trim();
  if (h.isEmpty) return null;
  if (h.startsWith('//')) h = 'https:$h';
  final u = Uri.tryParse(h);
  if (u == null || !u.hasScheme) return null;
  if (u.host.endsWith('duckduckgo.com') && u.path.startsWith('/l/')) {
    final target = u.queryParameters['uddg'];
    return target == null || target.isEmpty ? null : target;
  }
  if (u.host.endsWith('bing.com') && u.path.startsWith('/ck/')) {
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
  'duckduckgo.com', 'bing.com', 'microsoft.com', 'msn.com', 'gerdoo.me',
  'google.com', 'gstatic.com'
];

String _xml(String s) => s
    .replaceAll(RegExp(r'<!\[CDATA\[|\]\]>'), '')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

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
    final known = index[url];
    if (known == null) {
      index[url] = out.length;
      out.add(FinderAnchor(url, _oneLine(text, 300)));
    } else if (!out[known].text.contains(_oneLine(text, 300))) {
      // The same result is linked twice (its address line and its title).
      out[known] =
          FinderAnchor(url, _oneLine('${out[known].text} $text', 300));
    }
  }

  final body = input['body']!;
  switch (input['provider']) {
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
    case 'ddg':
      final doc = html.parse(body);
      for (final r in doc.querySelectorAll('.result')) {
        final a = r.querySelector('a.result__a');
        if (a == null) continue;
        add(a.attributes['href'],
            '${a.text} ${r.querySelector('.result__snippet')?.text ?? ''}');
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

/// Whether an answer page honestly says the question has no results.
bool saysNoResults(String body) =>
    body.contains('no-results') ||
    body.contains('No results') ||
    body.contains('class="b_no"') ||
    body.contains('نتیجه‌ای یافت نشد') ||
    body.contains('نتیجه ای یافت نشد');

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

/// What the app already reads; such a place is never listed as new.
Set<String> finderKnownKeys() {
  final known = <String>{};
  for (final e in endpoints) {
    final link = classifyLink(e.url);
    if (link == null) continue;
    known.add(link.key);
    if (link.kind == 'site') known.add('host:${link.host}');
  }
  return known;
}

class SourceFinder {
  final MarketStore store;
  final http.Client client;

  /// Pause between two page reads, and between two questions to a search page.
  final Duration pageGap, searchGap, timeout;

  /// How long a candidate's own page may take. Shorter than [timeout]: a list
  /// waits for the first reading of every candidate, and a seller whose page
  /// does not answer in this time is simply read later.
  final Duration readTimeout;
  final int maxBytes;
  final List<FinderProvider> providers;

  /// Pages on different networks, asked only to tell "this host is down"
  /// from "the phone is offline" after three requests in a row failed.
  final List<String> probes;
  final DateTime Function() clock;
  final int _writer = Random().nextInt(0x3fffffff) + 1;
  final Map<String, int> _emptyStreak = {};

  /// Whose turn it is among the three lists when a candidate is read.
  int _turn = 0;
  int _batches = 0;

  FinderState state = FinderState();
  late final Set<String> known = finderKnownKeys();
  bool _loaded = false, _running = false;
  int _lastSearchMs = 0;
  final Map<String, String> _stored = {};

  SourceFinder(this.store,
      {required this.client,
      this.pageGap = const Duration(milliseconds: 700),
      this.searchGap = const Duration(seconds: 9),
      this.timeout = const Duration(seconds: 10),
      this.readTimeout = const Duration(seconds: 8),
      this.maxBytes = 1000000,
      this.providers = finderProviders,
      this.probes = const [
        'https://www.bing.com/',
        'https://eitaa.com/',
        'https://ahanmelal.com/'
      ],
      DateTime Function()? clock})
      : clock = clock ?? DateTime.now;

  bool get running => _running;
  int _now() => clock().millisecondsSinceEpoch ~/ 1000;

  Future<void> load({bool force = false}) async {
    if (_loaded && !force) return;
    final values = <String, String?>{};
    for (final key in FinderState.settingKeys) {
      values[key] = await store.setting(key);
    }
    state = FinderState.fromSettings(values);
    _stored
      ..clear()
      ..addAll({
        for (final e in values.entries)
          if (e.value != null) e.key: e.value!
      });
    _loaded = true;
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

  /// Writes only what changed; the small record with the revision goes last.
  /// Saves are queued one behind the other, so a verdict recorded by a
  /// refresh and a step finishing at the same moment cannot interleave.
  Future<void> save() {
    state.rev++;
    state.writer = _writer;
    final values = state.toSettings();
    return _saving = _saving.catchError((Object _) {}).then((_) async {
      for (final key in FinderState.settingKeys.reversed) {
        final value = values[key]!;
        if (_stored[key] == value) continue;
        await store.setSetting(key, value);
        _stored[key] = value;
      }
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

  Future<_Fetched> _get(Uri url, {Duration? within}) async {
    final timeout = within ?? this.timeout;
    final request = http.Request('GET', url)
      ..followRedirects = true
      ..maxRedirects = 5
      ..headers.addAll({
        'User-Agent': finderAgent,
        'Accept': 'text/html,application/xhtml+xml,application/rss+xml',
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

  /// The search pages in the order to try them: the one that answered most
  /// recently first, then the declared order.
  List<FinderProvider> _ordered() {
    int answered(FinderProvider p) {
      final note = state.providerNote[p.id] ?? '';
      return note.startsWith('ok|') ? int.tryParse(note.substring(3)) ?? 0 : 0;
    }

    final list = [...providers];
    final rank = {for (var i = 0; i < list.length; i++) list[i].id: i};
    list.sort((a, b) {
      final byAnswer = answered(b).compareTo(answered(a));
      return byAnswer != 0 ? byAnswer : rank[a.id]!.compareTo(rank[b.id]!);
    });
    return list;
  }

  /// The search page that will take this question now, if any.
  FinderProvider? _providerFor(FinderTask task, int now) {
    final site = FinderPlan.usesSiteOperator(task.value);
    for (final p in _ordered()) {
      if ((state.cooldown[p.id] ?? 0) > now) continue;
      if (site && !p.siteOperator) continue;
      return p;
    }
    return null;
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
      state.maybeNextRound(now);
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
      final p = _providerFor(t, now);
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

    final since = Duration(
        milliseconds: clock().millisecondsSinceEpoch - _lastSearchMs);
    final ready = search != null && provider != null;
    // One question, then readings: questions are the scarce, rate-limited part.
    if (ready && since >= searchGap && step % 3 == 0) {
      return [() => _search(search!, provider!, skip)];
    }
    final readings = <Future<_Outcome> Function()>[];
    // Mostly candidates; every third turn a known seller's page first.
    if (_batches++ % 3 == 2) {
      final page = nextPage();
      if (page != null) readings.add(() => _seedPage(page));
    }
    while (readings.length < 2) {
      final entry = nextEntry();
      if (entry == null) break;
      readings.add(() => _verify(entry));
    }
    while (readings.length < 2) {
      final page = nextPage();
      if (page == null) break;
      readings.add(() => _seedPage(page));
    }
    if (readings.isNotEmpty) return readings;
    if (ready) {
      final wait = searchGap - since;
      if (wait < left) {
        if (wait > Duration.zero) await Future<void>.delayed(wait);
        return [() => _search(search!, provider!, skip)];
      }
    }
    return const [];
  }

  Future<_Outcome> _search(
      FinderTask task, FinderProvider p, Set<String> skip) async {
    _lastSearchMs = clock().millisecondsSinceEpoch;
    final now = _now();
    _Fetched got;
    try {
      got = await _get(p.url(task.value));
    } catch (_) {
      // This page cannot be reached from this network right now. It is left
      // alone for a while and the question goes to the next page; nothing is
      // counted against the question.
      final before = state.cooldown[p.id], note = state.providerNote[p.id];
      _rest(p, now, 20 * 60, 'net',
          'صفحه جستجوی ${p.title} از این اتصال در دسترس نبود؛ صفحه بعدی پرسیده می‌شود.');
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
    if (got.status != 200 ||
        (p.id == 'ddg' && got.body.contains('anomaly'))) {
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
  SourceEndpoint? endpointOf(FinderEntry e) {
    final city = e.city.isEmpty ? 'نامشخص' : e.city;
    if (e.kind == 'site') {
      // The seller is named by what the site calls itself, else by its host:
      // a page title is a sentence about one product, not a seller's name.
      return SourceEndpoint('finder-site-${finderHash(e.url)}',
          e.site.isEmpty ? e.host : e.site, e.url, 'عمومی', 'site-table', city,
          defaultEnabled: false);
    }
    if (!e.readable) return null;
    return publicChannel(e.url,
        name: e.name.isEmpty ? null : e.name, city: city);
  }

  /// Sources هوش جستجوگر ۱ has already accepted.
  List<SourceEndpoint> acceptedEndpoints({bool onlyUnapplied = false}) => [
        for (final e in state.entries)
          if (e.handoff == 'accepted' && (!onlyUnapplied || !e.applied))
            endpointOf(e)
      ].whereType<SourceEndpoint>().toList();

  /// The entries to give to هوش جستجوگر ۱ now. The place is decided by its
  /// rules from the contact lines the entry was found with.
  List<FinderHandoff> handoffBatch(
      {int limit = 12, bool Function(FinderEntry entry)? where}) {
    if (!_loaded) return const [];
    final out = <FinderHandoff>[];
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
      out.add(FinderHandoff(e, endpoint));
    }
    return out;
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
    final ids = <String>[];
    for (final e in state.entries) {
      if (e.handoff != 'accepted' || e.applied) continue;
      final endpoint = endpointOf(e);
      e.applied = true;
      if (endpoint != null) ids.add(endpoint.id);
    }
    if (ids.isNotEmpty) await save();
    return ids;
  }

  /// A short plain-text account of where the list builder stands, for the
  /// user to copy when something does not work on their network. It holds
  /// addresses and counts only — never a key, a phone or a message.
  String report() {
    final s = state, now = _now(), b = StringBuffer();
    String ago(int at) => at == 0 ? '-' : '${(now - at) ~/ 60}m';
    b.writeln('IronPin 0.9.4 finder • round ${s.round + 1} • '
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
          'wait=${s.handed(part, 'wait')} '
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

/// Hands waiting entries to هوش جستجوگر ۱: each is read with the app's own
/// reader, decided by [Searcher], and stored only when at least one valid row
/// came out. The caller holds the refresh lock.
///
/// With [photos] the price lists that channels publish as pictures are read
/// too (the foreground). Without it only [sitesOnly] entries should be given:
/// a channel judged without its pictures would be refused for the wrong
/// reason.
Future<int> deliverFinderBatch(
    MarketStore store, SourceClient client, SourceFinder finder,
    {required int windowDays,
    int limit = 3,
    PhotoScanner? photos,
    bool sitesOnly = false,
    bool Function()? cancelled}) async {
  var accepted = 0;
  final batch = finder.handoffBatch(
      limit: limit, where: sitesOnly ? (e) => e.kind == 'site' : null);
  for (final h in batch) {
    if (cancelled?.call() ?? false) break;
    final e = h.endpoint;
    try {
      final fetched =
          await client.fetch(e, windowDays: windowDays, pageLimit: 2);
      final rows = photos == null
          ? fetched
          : (await readPostPhotos(fetched, photos,
                  defaultCurrency: e.defaultCurrency, cancelled: cancelled))
              .rows;
      final found = rows.isEmpty
          ? const SearcherResult([])
          : await Searcher.processAsync(rows,
              now: DateTime.now(),
              windowDays: windowDays,
              resolver: MapsResolver(client.client));
      if (found.quotes.isEmpty) {
        await finder.verdict(h.entry.key,
            rows: 0,
            note: rows.isEmpty
                ? 'ردیف قیمت در صفحه عمومی پیدا نشد'
                : 'ردیف قابل‌ثبت نبود (بیرون از بازه: ${found.outOfWindow} • بی‌قیمت/بی‌محصول: ${found.noise})');
      } else {
        await store.saveSnapshot(e.id, found.quotes,
            replaceMissing: client.complete[e.id] ?? true);
        await finder.verdict(h.entry.key,
            rows: found.quotes.length,
            note: 'هوش جستجوگر ۱: ${found.quotes.length} ردیف معتبر');
        accepted++;
      }
    } catch (error) {
      await finder.verdict(h.entry.key,
          rows: 0,
          note: error is FormatException
              ? error.message
              : 'خطا در اتصال/مهلت دریافت');
    }
    await Future<void>.delayed(const Duration(milliseconds: 450));
  }
  return accepted;
}
