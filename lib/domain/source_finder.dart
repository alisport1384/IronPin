import 'dart:convert';

import 'product_text.dart';

/// هوش جستجوگر ۲ — the list builder.
///
/// It only answers one question: *where* do people publish the sale and
/// distribution of the goods this app knows? It builds three lists and nothing
/// else — it never reads a price, a city or a product detail. When a list is
/// complete its entries are handed to the app, and from there هوش جستجوگر ۱
/// ([Searcher]) decides product, city and details exactly as it does for every
/// other source.
///
/// This file is pure: no network, no storage. `lib/data/source_finder_io.dart`
/// does the reading; every decision is made here so it can be tested offline.
class FinderPart {
  /// Websites that sell and distribute goods.
  static const sites = 0;

  /// Channels and pages on social networks.
  static const social = 1;

  /// Channels and pages on the domestic (Iranian) networks.
  static const domestic = 2;
  static const all = [sites, social, domestic];
  static const titles = [
    'وب‌سایت‌های فروش و پخش کالا',
    'کانال‌ها و صفحه‌های شبکه‌های اجتماعی',
    'کانال‌ها و صفحه‌های شبکه‌های داخلی'
  ];
}

/// A link that belongs to one of the three lists.
class FinderLink {
  /// Canonical address: the same place always gives the same text.
  final String url;

  /// `site`, `telegram`, `instagram`, `whatsapp`, `eitaa`, `bale`, `rubika`,
  /// `soroush`, `igap` or `gap`.
  final String kind;

  /// Identity used for de-duplication.
  final String key;
  final int part;

  /// Whether the app owns a public reader for this kind. A page that needs a
  /// login (Instagram, WhatsApp, …) is listed but can never be handed over.
  final bool readable;
  const FinderLink(this.url, this.kind, this.key, this.part, this.readable);

  /// Host of a website link; empty for a channel.
  String get host => kind == 'site' ? Uri.parse(url).host : '';
}

const _messengers = <String, (String, int, bool)>{
  't.me': ('telegram', FinderPart.social, true),
  'telegram.me': ('telegram', FinderPart.social, true),
  'instagram.com': ('instagram', FinderPart.social, false),
  'whatsapp.com': ('whatsapp', FinderPart.social, false),
  'eitaa.com': ('eitaa', FinderPart.domestic, true),
  'ble.ir': ('bale', FinderPart.domestic, true),
  'rubika.ir': ('rubika', FinderPart.domestic, true),
  'splus.ir': ('soroush', FinderPart.domestic, false),
  'igap.net': ('igap', FinderPart.domestic, false),
  'gap.im': ('gap', FinderPart.domestic, false),
};

const _canonicalHost = {
  'telegram': 't.me',
  'instagram': 'www.instagram.com',
  'eitaa': 'eitaa.com',
  'bale': 'ble.ir',
  'rubika': 'rubika.ir',
  'soroush': 'splus.ir',
  'igap': 'igap.net',
  'gap': 'gap.im',
};

/// Path words of the messengers that are functions, not channels.
const _reserved = {
  'share', 'join', 'joinchat', 'joing', 'joinc', 's', 'search', 'proxy',
  'socks', 'addstickers', 'addemoji', 'addlist', 'iv', 'c', 'login', 'contact',
  'setlanguage', 'boost', 'giftcode', 'invoice', 'confirmphone', 'k', 'a', 'z',
  'web', 'download', 'apps', 'faq', 'privacy', 'blog', 'dl', 'about', 'app',
  'home', 'index', 'channel', 'channels', 'terms', 'support', 'help', 'tos',
  'static', 'assets', 'api', 'auth', 'p', 'reel', 'reels', 'explore',
  'accounts', 'stories', 'tv', 'direct', 'developer', 'legal', 'tags',
  'locations', 'challenge', 'landing', 'rules', 'features', 'security'
};

/// Hosts that are never a seller: search engines, large platforms, trust
/// seals, payment and map services. Matched as a suffix.
const _notSites = [
  'google.com', 'google.ir', 'bing.com', 'duckduckgo.com', 'yahoo.com',
  'yandex.com', 'yandex.ru', 'microsoft.com', 'msn.com', 'live.com',
  'apple.com', 'facebook.com', 'fb.com', 'twitter.com', 'x.com', 'youtube.com',
  'youtu.be', 'linkedin.com', 'pinterest.com', 'aparat.com', 'wikipedia.org',
  'wikimedia.org', 'github.com', 'cafebazaar.ir', 'myket.ir', 'enamad.ir',
  'samandehi.ir', 'zarinpal.com', 'shaparak.ir', 'neshan.org', 'balad.ir',
  'waze.com', 'wa.me', 'telegram.org', 'w3.org', 'schema.org', 'gravatar.com',
  'wordpress.org', 'wordpress.com', 'cloudflare.com', 'googleapis.com',
  'gstatic.com', 'googletagmanager.com', 'bale.ai', 'eitaa.ir', 'rubika.app',
  'archive.org', 'zarebin.ir', 'gerdoo.me', 'tgstat.com', 'telegram.dog'
];

final _fileLike = RegExp(
    r'\.(?:jpe?g|png|gif|svg|webp|ico|pdf|zip|rar|apk|mp4|mp3|css|js|xml|json|xlsx?|docx?)$',
    caseSensitive: false);
final _handle = RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{2,63}$');
final _instagramHandle = RegExp(r'^[a-zA-Z0-9._]{2,30}$');

/// Decides which list a public address belongs to, or `null` when it is not a
/// place this searcher lists (an invite, a phone contact, a bot, a file, a
/// search engine…). Nothing is guessed: only the written address is read.
FinderLink? classifyLink(String raw) {
  final text = raw.trim();
  if (text.isEmpty || text.length > 400) return null;
  final u = Uri.tryParse(text);
  if (u == null ||
      !(u.scheme == 'http' || u.scheme == 'https') ||
      u.userInfo.isNotEmpty ||
      u.host.isEmpty ||
      u.hasPort) {
    return null;
  }
  var host = u.host.toLowerCase();
  // The web apps of the messengers need a login; they are not public pages.
  if (host.startsWith('web.')) return null;
  if (host.startsWith('www.')) host = host.substring(4);
  if (!host.contains('.') || RegExp(r'^[\d.]+$').hasMatch(host)) return null;
  // A host name is letters, digits, dots and hyphens. An address a messenger
  // linked together with the emoji in front of it («🌐www.example.com») is not
  // a place anything can be read from.
  if (!RegExp(r'^[a-z0-9.-]+$').hasMatch(host)) return null;
  final seg = u.pathSegments.where((x) => x.isNotEmpty).toList();
  final messenger = _messengers[host];
  if (messenger != null) {
    final (kind, part, readable) = messenger;
    if (kind == 'whatsapp') {
      if (seg.length < 2 || seg.first != 'channel') return null;
      final id = seg[1];
      if (!RegExp(r'^[A-Za-z0-9]{10,40}$').hasMatch(id)) return null;
      return FinderLink(
          'https://whatsapp.com/channel/$id', kind, 'whatsapp:$id', part, false);
    }
    if (seg.isNotEmpty && seg.first == 's') seg.removeAt(0);
    if (seg.isEmpty) return null;
    var h = seg.first;
    if (h.startsWith('@')) h = h.substring(1);
    final low = h.toLowerCase();
    if (_reserved.contains(low)) return null;
    if (kind == 'instagram') {
      if (!_instagramHandle.hasMatch(h) || h.startsWith('.')) return null;
      return FinderLink(
          'https://www.instagram.com/$low/', kind, 'instagram:$low', part, false);
    }
    // A second segment is only ever the number of one post.
    if (seg.length > 2 ||
        (seg.length == 2 && !RegExp(r'^\d+$').hasMatch(seg[1]))) {
      return null;
    }
    // Same rule as the app's own channel factory: bots and sales contacts are
    // people to call, not channels to read.
    if (!_handle.hasMatch(h) ||
        low.endsWith('bot') ||
        low.contains('admin') ||
        low.contains('marketing')) {
      return null;
    }
    return FinderLink(
        'https://${_canonicalHost[kind]}/$h', kind, '$kind:$low', part, readable);
  }
  if (_notSites.any((x) => host == x || host.endsWith('.$x'))) return null;
  if (_fileLike.hasMatch(u.path)) return null;
  final query = {
    for (final e in u.queryParameters.entries)
      if (!e.key.startsWith('utm_') &&
          !const {'fbclid', 'gclid', 'srsltid', 'ref', 'share'}.contains(e.key))
        e.key: e.value
  };
  var path = u.path.isEmpty ? '/' : u.path;
  if (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  final clean = Uri(
      scheme: u.scheme,
      host: host,
      path: path,
      queryParameters: query.isEmpty ? null : query);
  final url = clean.toString();
  if (url.length > 220) return null;
  return FinderLink(
      url,
      'site',
      'site:$host${path.toLowerCase()}'
          '${query.isEmpty ? '' : '?${clean.query.toLowerCase()}'}',
      FinderPart.sites,
      true);
}

/// The address the public reader opens for an entry: Telegram and Bale show
/// their posts without a login under `/s/`, the others on the channel address.
String previewUrl(String kind, String url) {
  if (kind != 'telegram' && kind != 'bale') return url;
  final u = Uri.parse(url);
  return 'https://${u.host}/s/${u.pathSegments.last}';
}

/// What a text says about selling goods. Only words that are written count.
class TradeEvidence {
  /// How many times a product of the app's vocabulary is named.
  final int goods;

  /// How many times a word of selling, buying or distributing is written.
  final int trade;

  /// The first product family named, or empty.
  final String product;
  const TradeEvidence(this.goods, this.trade, this.product);

  /// A short text (a title, a channel introduction) needs one of each; a whole
  /// page needs the subject to recur, so one stray word proves nothing.
  bool okFor(int length) =>
      length < 600 ? goods >= 1 && trade >= 1 : goods >= 3 && trade >= 2;
}

final _wholesale = RegExp(r'آهن\s?آلات|آهن\s?فروش|مقاطع\s+فولادی|بنگاه\s+آهن');
final _trade = RegExp(
    r'قیمت|فروش|خرید|پخش|توزیع|عمده|استعلام|سفارش|تومان|ریال|موجودی|تحویل|بنگاه|نمایندگی|بارگیری');

TradeEvidence tradeEvidence(String text) {
  final s = ProductText.normalize(text);
  String sliceAround(Match m) {
    final from = m.start > 48 ? m.start - 48 : 0;
    final to = m.end + 48 < s.length ? m.end + 48 : s.length;
    return s.substring(from, to);
  }

  final products = ProductText.product
      .allMatches(s)
      .where((m) => !ProductText.isNonMetal(sliceAround(m)))
      .take(20)
      .toList();
  final wholesale = _wholesale
      .allMatches(s)
      .where((m) => !ProductText.isNonMetal(sliceAround(m)))
      .take(20)
      .length;
  final product = products.isNotEmpty
      ? ProductText.category(products.first[0]!)
      : (wholesale > 0 ? 'آهن‌آلات' : '');
  return TradeEvidence(
      products.length + wholesale, _trade.allMatches(s).take(20).length, product);
}

/// Whether a text is evidence that goods are sold there.
bool sellsGoods(String text) => tradeEvidence(text).okFor(text.length);

/// The questions asked of a public search page.
///
/// Every list has an ordered bank of questions — the most telling first — and a
/// round takes only the next few of each. Rounds are small on purpose: a list
/// can only be called complete if the work behind it ends soon, and the sooner
/// a round ends, the sooner what it found is handed to the app. The next round
/// continues the bank where the last one stopped, so the lists keep growing
/// every time the phone is online.
class FinderPlan {
  static const perRound = 5;
  static const products = [
    'میلگرد', 'تیرآهن', 'ورق', 'پروفیل', 'لوله', 'نبشی', 'ناودانی', 'آهن'
  ];
  static const cities = [
    'مشهد', 'تهران', 'اصفهان', 'تبریز', 'شیراز', 'اهواز', 'کرج', 'قم',
    'کرمانشاه', 'ارومیه', 'رشت', 'زاهدان', 'کرمان', 'همدان', 'یزد', 'اردبیل',
    'بندرعباس', 'اراک', 'زنجان', 'قزوین', 'سنندج', 'خرم‌آباد', 'گرگان', 'ساری',
    'بوشهر', 'بیرجند', 'ایلام', 'شهرکرد', 'سمنان', 'یاسوج', 'بجنورد'
  ];

  /// Three general questions, then two about a city, and so on.
  static List<String> _weave(List<String> general, List<String> local) {
    final out = <String>[];
    var g = 0, l = 0;
    while (g < general.length || l < local.length) {
      for (var i = 0; i < 3 && g < general.length; i++) {
        out.add(general[g++]);
      }
      for (var i = 0; i < 2 && l < local.length; i++) {
        out.add(local[l++]);
      }
    }
    return out;
  }

  static final List<List<String>> _banks = [
    _weave([
      for (final p in products) 'قیمت $p امروز',
      'فروش آهن آلات', 'پخش آهن آلات', 'لیست قیمت آهن آلات',
      for (final p in products) 'خرید $p',
      for (final p in products) 'فروش $p',
      for (final p in products) 'پخش $p',
    ], [
      for (final c in cities) ...['قیمت آهن $c', 'آهن فروشی $c']
    ]),
    _weave([
      'کانال تلگرام قیمت آهن', 'کانال تلگرام قیمت میلگرد',
      'site:t.me قیمت آهن', 'site:t.me قیمت میلگرد', 'site:t.me آهن آلات',
      'پیج اینستاگرام آهن آلات', 'site:instagram.com آهن آلات',
      for (final p in products.skip(1).take(6)) 'کانال تلگرام قیمت $p',
      'کانال تلگرام آهن آلات',
    ], [
      for (final c in cities) 'کانال تلگرام آهن $c'
    ]),
    _weave([
      for (final m in const ['ایتا', 'بله', 'روبیکا']) 'کانال $m قیمت آهن',
      for (final m in const ['ایتا', 'بله', 'روبیکا']) 'کانال $m قیمت میلگرد',
      for (final m in const ['ایتا', 'بله', 'روبیکا']) 'کانال $m آهن آلات',
      'site:eitaa.com قیمت میلگرد', 'site:eitaa.com آهن آلات',
      'site:ble.ir قیمت آهن', 'site:ble.ir آهن آلات',
      'site:rubika.ir آهن آلات',
      for (final p in products.skip(1).take(6)) 'کانال ایتا قیمت $p',
    ], [
      for (final c in cities) 'کانال ایتا آهن $c'
    ]),
  ];

  static List<String> bank(int part) => _banks[part];

  /// How many rounds it takes to ask every question of the longest bank once.
  static final int cycleRounds = _banks
      .map((b) => (b.length / perRound).ceil())
      .reduce((a, b) => a > b ? a : b);

  /// The questions of one round: the next [perRound] of the bank, wrapping.
  static List<String> queries(int part, int round) {
    final all = _banks[part];
    final start = (round * perRound) % all.length;
    return [for (var i = 0; i < perRound; i++) all[(start + i) % all.length]];
  }

  /// Whether a question uses the `site:` operator, which not every search
  /// page honours.
  static bool usesSiteOperator(String query) => query.startsWith('site:');

  /// The words of a question an honest answer must be about.
  static List<String> tokens(String query) => [
        for (final w in ProductText.normalize(query).split(' '))
          if (w.length >= 3 && !w.startsWith('site:')) w
      ];
}

/// Addresses written for a messenger app rather than a browser. They name a
/// public channel just as plainly as a web address does.
String? webAddressOf(String href) {
  final u = Uri.tryParse(href.trim());
  if (u == null || u.host != 'resolve') return null;
  final domain = u.queryParameters['domain'] ?? '';
  if (domain.isEmpty) return null;
  return switch (u.scheme) {
    'tg' => 'https://t.me/$domain',
    'et' => 'https://eitaa.com/$domain',
    _ => null
  };
}

/// Public directories of channels. Their pages describe other people's
/// channels, so they are read for the addresses they give and never listed as
/// a seller themselves.
const finderDirectories = ['mychannels.ir'];
bool isDirectoryHost(String host) =>
    finderDirectories.any((d) => host == d || host.endsWith('.$d'));


String _clip(String value, int max) {
  final s = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s.length <= max ? s : s.substring(0, max);
}

/// FNV-1a, 32 bit: a short, stable name for an address.
String finderHash(String value) {
  var h = 0x811c9dc5;
  for (final b in utf8.encode(value)) {
    h ^= b;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(36);
}

/// One line of a list.
class FinderEntry {
  String url, kind, key, name, from, contact, note, city, cityBasis;

  /// The name a website gives itself (`og:site_name`), when it states one.
  String site;
  int part, depth, tries, at;

  /// `new` (seen, not read yet), `ok` (read: it sells goods), `unreachable`
  /// (three attempts failed) or `unreadable` (the network needs a login).
  String state;

  /// Whether the place it was found already spoke of selling goods.
  bool hinted;

  /// Found as an inner page of a site that is itself on the list.
  bool inner;

  /// The page showed a table that speaks of prices.
  bool table;

  /// Empty until the list is complete; then `wait`, `accepted` or `rejected`.
  String handoff;
  int handoffTries, handoffAt;

  /// Whether the app has already switched the accepted source on.
  bool applied;

  FinderEntry(
      {required this.url,
      required this.kind,
      required this.key,
      required this.part,
      this.name = '',
      this.from = '',
      this.contact = '',
      this.note = '',
      this.city = '',
      this.cityBasis = '',
      this.site = '',
      this.table = false,
      this.depth = 0,
      this.tries = 0,
      this.at = 0,
      this.state = 'new',
      this.hinted = false,
      this.inner = false,
      this.handoff = '',
      this.handoffTries = 0,
      this.handoffAt = 0,
      this.applied = false});

  bool get readable => !const {'instagram', 'whatsapp', 'soroush', 'igap', 'gap'}
      .contains(kind);
  String get host => kind == 'site' ? Uri.parse(url).host : '';
  String get title => name.isEmpty ? url : name;

  Map<String, Object?> toJson() => {
        'u': url,
        'k': kind,
        if (name.isNotEmpty) 'n': name,
        if (from.isNotEmpty) 'f': from,
        if (contact.isNotEmpty) 'c': contact,
        if (note.isNotEmpty) 'o': note,
        if (city.isNotEmpty) 'ci': city,
        if (cityBasis.isNotEmpty) 'cb': cityBasis,
        if (site.isNotEmpty) 'sn': site,
        if (table) 'tb': 1,
        if (depth != 0) 'd': depth,
        if (tries != 0) 't': tries,
        'a': at,
        if (state != 'ok') 's': state,
        if (hinted) 'h': 1,
        if (inner) 'i': 1,
        if (handoff.isNotEmpty) 'ho': handoff,
        if (handoffTries != 0) 'ht': handoffTries,
        if (handoffAt != 0) 'ha': handoffAt,
        if (applied) 'ap': 1,
      };

  /// Rebuilds an entry; an address that no longer classifies is refused, so a
  /// damaged or hand-edited record can never become a source.
  static FinderEntry? fromJson(Object? raw) {
    if (raw is! Map || raw['u'] is! String) return null;
    final link = classifyLink(raw['u'] as String);
    if (link == null || link.kind != raw['k']) return null;
    String s(String k, int max) =>
        raw[k] is String ? _clip(raw[k] as String, max) : '';
    int n(String k) => raw[k] is int ? raw[k] as int : 0;
    final state = raw['s'] is String ? raw['s'] as String : 'ok';
    final handoff = s('ho', 10);
    if (!const {'new', 'ok', 'unreachable', 'unreadable'}.contains(state) ||
        !const {'', 'wait', 'accepted', 'rejected'}.contains(handoff)) {
      return null;
    }
    return FinderEntry(
        url: link.url,
        kind: link.kind,
        key: link.key,
        part: link.part,
        name: s('n', 60),
        from: s('f', 120),
        contact: s('c', 200),
        note: s('o', 100),
        city: s('ci', 30),
        cityBasis: s('cb', 40),
        site: s('sn', 40),
        table: raw['tb'] == 1,
        depth: n('d'),
        tries: n('t'),
        at: n('a'),
        state: state,
        hinted: raw['h'] == 1,
        inner: raw['i'] == 1,
        handoff: handoff,
        handoffTries: n('ht'),
        handoffAt: n('ha'),
        applied: raw['ap'] == 1);
  }
}

/// A piece of work that is not tied to one entry: a question for a search
/// page (`S`) or a known seller's page whose links are read once (`P`).
class FinderTask {
  final String type, value;
  final int part;
  int tries;
  FinderTask(this.type, this.value, this.part, [this.tries = 0]);
  Map<String, Object?> toJson() =>
      {'t': type, 'v': value, 'p': part, if (tries != 0) 'n': tries};
  static FinderTask? fromJson(Object? raw) {
    if (raw is! Map ||
        !(raw['t'] == 'S' || raw['t'] == 'P') ||
        raw['v'] is! String ||
        raw['p'] is! int ||
        !FinderPart.all.contains(raw['p'])) {
      return null;
    }
    return FinderTask(raw['t'] as String, raw['v'] as String, raw['p'] as int,
        raw['n'] is int ? raw['n'] as int : 0);
  }
}

/// Everything the searcher remembers between two online sessions.
class FinderState {
  static const maxPerPart = 250;
  static const maxDepth = 2;
  static const maxTries = 3;
  static const maxQueue = 400;
  static const maxSeen = 5000;
  static const maxInnerPerHost = 8;
  static const maxPerHost = 10;
  static const maxAccepted = 150;
  static const maxHandoffTries = 3;
  static const handoffRetrySeconds = 24 * 3600;

  /// Rest between two rounds while the question banks are still being asked
  /// for the first time, and afterwards.
  static const roundRestSeconds = 20 * 60;
  static const settledRestSeconds = 24 * 3600;

  /// Places that could not be reached are tried again at most this often.
  static const reviveSeconds = 24 * 3600;
  static const settingKeys = [
    'finder.meta', 'finder.queue', 'finder.seen',
    'finder.list.0', 'finder.list.1', 'finder.list.2'
  ];
  static const backupKeys = [...settingKeys, 'finder.enabled'];

  int rev = 0, round = 0;
  int startedAt = 0, lastOnlineAt = 0, lastStepAt = 0, roundCompletedAt = 0;
  int searches = 0, pages = 0, dropped = 0;

  /// How many times in a row a public search page could not be used.
  int strikes = 0;

  /// Which run wrote the state last; lets two isolates notice each other.
  int writer = 0;
  bool seeded = false;
  String lastError = '';
  final List<List<FinderEntry>> lists = [[], [], []];
  final List<FinderTask> queue = [];
  final Set<String> seen = <String>{};
  final List<bool> complete = [false, false, false];
  final List<int> completedAt = [0, 0, 0];

  /// Until when a search page or a host is left alone (seconds since epoch).
  final Map<String, int> cooldown = {};

  /// What each search page answered last: `ok`, `net`, `refused` or
  /// `unreadable`, and when (`ok|1731300000`).
  final Map<String, String> providerNote = {};

  /// How many times in a row a host did not answer.
  final Map<String, int> hostFails = {};
  int revivedAt = 0;

  Iterable<FinderEntry> get entries => lists.expand((l) => l);
  FinderEntry? entry(String key) {
    for (final e in entries) {
      if (e.key == key) return e;
    }
    return null;
  }

  bool get allComplete => complete.every((c) => c);
  int count(int part, String state) =>
      lists[part].where((e) => e.state == state).length;
  int handed(int part, String handoff) =>
      lists[part].where((e) => e.handoff == handoff).length;

  /// Remembers a place as decided, so it is not asked about again.
  void remember(String key) {
    seen.add(finderHash(key));
    while (seen.length > maxSeen) {
      seen.remove(seen.first);
    }
  }

  bool knows(String key) =>
      seen.contains(finderHash(key)) || entry(key) != null;

  /// Starts the questions of the current round. A list that still has two
  /// rounds of questions nobody could answer gets no more for now.
  void beginRound(int now) {
    if (startedAt == 0) {
      startedAt = now;
      revivedAt = now;
    }
    for (final part in FinderPart.all) {
      final waiting =
          queue.where((t) => t.type == 'S' && t.part == part).length;
      if (waiting >= 2 * FinderPlan.perRound) continue;
      for (final q in FinderPlan.queries(part, round)) {
        if (queue.length >= maxQueue) break;
        if (!queue.any((t) => t.type == 'S' && t.value == q)) {
          queue.add(FinderTask('S', q, part));
        }
      }
    }
  }

  /// Adds the known sellers' own pages, whose links are read once.
  void addSeedPages(Iterable<String> urls) {
    for (final url in urls) {
      if (queue.length >= maxQueue) break;
      if (!queue.any((t) => t.type == 'P' && t.value == url)) {
        queue.add(FinderTask('P', url, FinderPart.sites));
      }
    }
  }

  /// Puts a link on its list as a candidate. Returns whether it was new.
  ///
  /// [known] holds what the app already reads: such a place is never listed
  /// again. A network without a public reader is listed only when the place it
  /// was found already spoke of selling goods, because its own page cannot be
  /// read to check.
  bool offer(FinderLink link,
      {required String from,
      required int depth,
      required bool hinted,
      required int now,
      String name = '',
      bool inner = false,
      Set<String> known = const {}}) {
    if (depth > maxDepth) return false;
    if (known.contains(link.key) ||
        (link.kind == 'site' && known.contains('host:${link.host}'))) {
      return false;
    }
    if (knows(link.key)) return false;
    if (!link.readable && !hinted) return false;
    final list = lists[link.part];
    if (list.length >= maxPerPart) {
      dropped++;
      return false;
    }
    if (link.kind == 'site') {
      // One seller's many pages must not crowd the other sellers out.
      final same = list.where((e) => e.host == link.host).toList();
      if (same.length >= maxPerHost ||
          (inner && same.where((e) => e.inner).length >= maxInnerPerHost)) {
        return false;
      }
    }
    list.add(FinderEntry(
        url: link.url,
        kind: link.kind,
        key: link.key,
        part: link.part,
        name: _clip(name, 60),
        from: _clip(from, 120),
        depth: depth,
        at: now,
        hinted: hinted,
        inner: inner,
        state: link.readable ? 'new' : 'unreadable',
        note: link.readable ? '' : 'خواندن این شبکه بدون ورود ممکن نیست'));
    return true;
  }

  /// The next candidate to read: nearest to a search answer first.
  ///
  /// [prefer] names the list whose turn it is, so a long list of websites
  /// cannot keep the two channel lists waiting.
  FinderEntry? nextToVerify(Set<String> skip,
      {bool Function(FinderEntry entry)? resting, int? prefer}) {
    FinderEntry? pick(Iterable<FinderEntry> from, {required bool fresh}) {
      FinderEntry? best;
      for (final e in from) {
        if (e.state != 'new' || skip.contains(e.key)) continue;
        if (fresh != (e.tries == 0)) continue;
        if (resting != null && resting(e)) continue;
        // Fewest failed attempts; then nearest to a search answer; then
        // oldest.
        if (best == null ||
            e.tries < best.tries ||
            (e.tries == best.tries &&
                (e.depth < best.depth ||
                    (e.depth == best.depth && e.at < best.at)))) {
          best = e;
        }
      }
      return best;
    }

    // Every candidate gets its first reading before any gets a second.
    final mine = prefer == null ? const <FinderEntry>[] : lists[prefer];
    return pick(mine, fresh: true) ??
        pick(entries, fresh: true) ??
        pick(mine, fresh: false) ??
        pick(entries, fresh: false);
  }

  FinderTask? nextTask(String type, [Set<String> skip = const {}]) {
    for (final t in queue) {
      if (t.type == type && !skip.contains(t.value)) return t;
    }
    return null;
  }

  /// The page was read and it sells goods.
  void confirm(FinderEntry e,
      {String name = '',
      String contact = '',
      String note = '',
      String site = '',
      bool table = false}) {
    e.state = 'ok';
    if (name.isNotEmpty) e.name = _clip(name, 60);
    e.contact = _clip(contact, 200);
    e.note = _clip(note, 100);
    e.site = _clip(site, 40);
    e.table = table;
  }

  /// The page was read and says nothing about selling goods: it leaves the
  /// list for good and is not asked again.
  void discard(FinderEntry e) {
    lists[e.part].remove(e);
    remember(e.key);
  }

  /// One failed attempt to read a candidate.
  void failed(FinderEntry e, String reason) {
    e.tries++;
    if (e.tries >= maxTries) {
      e.state = 'unreachable';
      e.note = _clip(reason, 100);
    }
  }

  /// Takes back a failure that was only the phone being offline.
  void refund(FinderEntry e) {
    if (e.tries > 0) e.tries--;
    if (e.state == 'unreachable') {
      e.state = 'new';
      e.note = '';
    }
  }

  void finish(FinderTask t) => queue.remove(t);

  /// Closes the lists whose work has ended and opens them for hand-over.
  ///
  /// A list is complete when no seller page is still to be read, none of its
  /// candidates is untried and no question is waiting for it. Work that
  /// cannot be done *now* does not hold a list open: a question no search page
  /// will take at the moment ([askable]), a candidate on a host that is being
  /// left alone ([resting]) and a page that was tried and did not answer are
  /// continued later, and whatever they bring is handed over then. From
  /// completion on, every readable, confirmed entry waits for هوش جستجوگر ۱ —
  /// including the ones found later.
  void updateCompletion(int now,
      {bool Function(FinderTask task)? askable,
      bool Function(FinderEntry entry)? resting}) {
    bool open(FinderTask t) => askable == null || askable(t);
    bool unread(FinderEntry e) =>
        e.state == 'new' && e.tries == 0 && (resting == null || !resting(e));
    final pages = queue.any((t) => t.type == 'P' && t.tries == 0);
    for (final part in FinderPart.all) {
      if (complete[part]) continue;
      final busy = pages ||
          queue.any((t) => t.type == 'S' && t.part == part && open(t)) ||
          lists[part].any(unread);
      if (!busy && startedAt != 0) {
        complete[part] = true;
        completedAt[part] = now;
      }
    }
    for (final part in FinderPart.all) {
      if (!complete[part]) continue;
      for (final e in lists[part]) {
        if (e.state == 'ok' && e.handoff.isEmpty && deliverable(e)) {
          e.handoff = 'wait';
        }
      }
    }
    final idle = allComplete &&
        !pages &&
        !queue.any((t) => t.type == 'S' && open(t)) &&
        !entries.any(unread);
    if (idle && roundCompletedAt == 0) roundCompletedAt = now;
    if (!idle) roundCompletedAt = 0;
  }

  /// Whether an entry is something the app can read prices from. A channel on
  /// a network with a public reader is; a website page is only when a table
  /// on it spoke of prices — a front page without one stays on the list as a
  /// seller, and its own price pages are handed over instead.
  static bool deliverable(FinderEntry e) =>
      e.readable && (e.kind != 'site' || e.table);

  /// Questions still waiting for a search page that will take them.
  int unanswered(int part) =>
      queue.where((t) => t.type == 'S' && t.part == part).length;

  /// After a short rest, asks the next questions of the banks. Places that
  /// could not be reached get another chance once a day.
  bool maybeNextRound(int now) {
    final rest = round + 1 < FinderPlan.cycleRounds
        ? roundRestSeconds
        : settledRestSeconds;
    if (roundCompletedAt == 0 || now - roundCompletedAt < rest) return false;
    round++;
    roundCompletedAt = 0;
    if (now - revivedAt >= reviveSeconds) {
      revivedAt = now;
      for (final e in entries) {
        if (e.state == 'unreachable') {
          e.state = 'new';
          e.tries = 0;
          e.note = '';
        }
      }
    }
    beginRound(now);
    return true;
  }

  int get acceptedCount => entries.where((e) => e.handoff == 'accepted').length;

  /// Entries هوش جستجوگر ۱ should look at now, shared fairly between lists.
  List<FinderEntry> waiting(int now, {int limit = 12}) {
    final room = maxAccepted - acceptedCount;
    if (room <= 0 || limit <= 0) return const [];
    final perPart = [
      for (final part in FinderPart.all)
        lists[part]
            .where((e) =>
                e.handoff == 'wait' &&
                (e.handoffTries == 0 ||
                    now - e.handoffAt >= handoffRetrySeconds))
            .toList()
          // Untried first; among websites, a page that showed a price table
          // before one that did not, and a seller's price page before its
          // front page.
          ..sort((a, b) => a.handoffTries != b.handoffTries
              ? a.handoffTries.compareTo(b.handoffTries)
              : a.table != b.table
                  ? (a.table ? -1 : 1)
                  : a.inner != b.inner
                      ? (a.inner ? -1 : 1)
                      : a.at.compareTo(b.at))
    ];
    final out = <FinderEntry>[];
    final max = limit < room ? limit : room;
    for (var i = 0; out.length < max; i++) {
      var any = false;
      for (final list in perPart) {
        if (i < list.length && out.length < max) {
          out.add(list[i]);
          any = true;
        }
      }
      if (!any) break;
    }
    return out;
  }

  /// What هوش جستجوگر ۱ answered for one entry: [rows] valid rows, or none.
  void verdict(FinderEntry e, {required int rows, required String note, required int now}) {
    e.handoffAt = now;
    e.note = _clip(note, 100);
    if (rows > 0) {
      e.handoff = 'accepted';
      return;
    }
    e.handoffTries++;
    if (e.handoffTries >= maxHandoffTries) e.handoff = 'rejected';
  }

  // ------------------------------------------------------------ persistence

  Map<String, String> toSettings() {
    String list(int part) {
      var rows = lists[part].map((e) => e.toJson()).toList();
      var text = jsonEncode(rows);
      // A stored setting may not exceed the archive's own limit. What is
      // dropped first is what is no longer needed, never an address.
      if (text.length > 180000) {
        for (final e in lists[part]) {
          if (e.handoff == 'accepted' || e.handoff == 'rejected') e.contact = '';
          if (e.from.length > 40) e.from = e.from.substring(0, 40);
        }
        rows = lists[part].map((e) => e.toJson()).toList();
        text = jsonEncode(rows);
      }
      while (text.length > 180000 && rows.isNotEmpty) {
        rows.removeLast();
        text = jsonEncode(rows);
      }
      return text;
    }

    return {
      'finder.meta': jsonEncode({
        'v': 2,
        'rev': rev,
        'round': round,
        'started': startedAt,
        'online': lastOnlineAt,
        'step': lastStepAt,
        'roundDone': roundCompletedAt,
        'searches': searches,
        'pages': pages,
        'dropped': dropped,
        'strikes': strikes,
        'writer': writer,
        'seeded': seeded,
        'error': _clip(lastError, 160),
        'complete': complete,
        'completedAt': completedAt,
        'cooldown': cooldown,
        'providers': providerNote,
        'hostFails': {
          for (final e in hostFails.entries.take(200)) e.key: e.value
        },
        'revived': revivedAt,
      }),
      'finder.queue': jsonEncode(queue.map((t) => t.toJson()).toList()),
      'finder.seen': jsonEncode(seen.toList()),
      for (final part in FinderPart.all) 'finder.list.$part': list(part),
    };
  }

  /// Reads the stored state. Anything unreadable starts that piece empty: a
  /// damaged record costs progress, never a crash and never a wrong source.
  static FinderState fromSettings(Map<String, String?> values) {
    final s = FinderState();
    Object? decode(String key) {
      final raw = values[key];
      if (raw == null || raw.isEmpty) return null;
      try {
        return jsonDecode(raw);
      } catch (_) {
        return null;
      }
    }

    final meta = decode('finder.meta');
    if (meta is Map) {
      int n(String k) => meta[k] is int ? meta[k] as int : 0;
      s.rev = n('rev');
      s.round = n('round');
      s.startedAt = n('started');
      s.lastOnlineAt = n('online');
      s.lastStepAt = n('step');
      s.roundCompletedAt = n('roundDone');
      s.searches = n('searches');
      s.pages = n('pages');
      s.dropped = n('dropped');
      s.strikes = n('strikes');
      s.revivedAt = n('revived');
      s.writer = n('writer');
      s.seeded = meta['seeded'] == true;
      s.lastError = meta['error'] is String ? meta['error'] as String : '';
      final done = meta['complete'], at = meta['completedAt'];
      for (final part in FinderPart.all) {
        if (done is List && done.length == 3) s.complete[part] = done[part] == true;
        if (at is List && at.length == 3 && at[part] is int) {
          s.completedAt[part] = at[part] as int;
        }
      }
      final notes = meta['providers'];
      if (notes is Map) {
        for (final e in notes.entries) {
          if (e.key is String && e.value is String) {
            s.providerNote[e.key as String] = _clip(e.value as String, 40);
          }
        }
      }
      final fails = meta['hostFails'];
      if (fails is Map) {
        for (final e in fails.entries.take(200)) {
          if (e.key is String && e.value is int) {
            s.hostFails[e.key as String] = e.value as int;
          }
        }
      }
      final cool = meta['cooldown'];
      if (cool is Map) {
        for (final e in cool.entries) {
          if (e.key is String && e.value is int) {
            s.cooldown[e.key as String] = e.value as int;
          }
        }
      }
    }
    final queue = decode('finder.queue');
    if (queue is List) {
      for (final raw in queue.take(maxQueue)) {
        final t = FinderTask.fromJson(raw);
        if (t != null) s.queue.add(t);
      }
    }
    final seen = decode('finder.seen');
    if (seen is List) {
      for (final x in seen.take(maxSeen)) {
        if (x is String && x.length <= 8) s.seen.add(x);
      }
    }
    final keys = <String>{};
    for (final part in FinderPart.all) {
      final list = decode('finder.list.$part');
      if (list is! List) continue;
      for (final raw in list.take(maxPerPart)) {
        final e = FinderEntry.fromJson(raw);
        if (e != null && e.part == part && keys.add(e.key)) s.lists[part].add(e);
      }
    }
    // State written by 0.9.3 holds one long round of questions and may hold
    // a rest for search pages that were unreachable. The lists and everything
    // already decided are kept; the questions start again as small rounds.
    final version = meta is Map && meta['v'] is int ? meta['v'] as int : 0;
    if (meta is Map && version < 2) {
      s.queue.removeWhere((t) => t.type == 'S');
      s.cooldown.clear();
      s.providerNote.clear();
      s.strikes = 0;
      s.round = 0;
      s.startedAt = 0;
      s.roundCompletedAt = 0;
    }
    return s;
  }
}
