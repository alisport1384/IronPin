import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../domain/market.dart';
import '../domain/maps_resolver.dart';
import '../domain/ocr.dart';
import '../domain/photo_scan.dart';
import '../domain/range_projection.dart';
import '../domain/searcher.dart';
import '../domain/range_worker.dart';
import 'range_session.dart';
import 'background_scan.dart';
import 'source_finder_io.dart';
import 'sources.dart';
import 'store.dart';
import 'app_logger.dart';

class MarketController extends ChangeNotifier {
  final MarketStore store;
  final SourceClient client;

  /// Reads the pictures a source publishes; no manual pick anywhere.
  final PhotoScanner photoScanner;
  final MarketFilter filter = MarketFilter()
    ..sort = 'latest'
    // A fresh controller already answers with the primary window; `init` only
    // restores what the user saved.
    ..windowDays = defaultWindowDays;
  List<Quote> quotes = [];

  /// How many pictures the scanner read during the last scan, and what it saw.
  /// The user never picks a picture: the scan reads the ones the sources publish.
  int photosScanned = 0;
  String photoReport = '';
  final List<SourceEndpoint> discoveredSources = [];

  /// هوش جستجوگر ۲: builds the three lists of places that sell goods and
  /// hands each completed list to the app (see `domain/source_finder.dart`).
  late final SourceFinder finder = SourceFinder(store, client: client.client);

  /// Sources of those lists that هوش جستجوگر ۱ accepted (at least one valid
  /// row). They are ordinary routes from then on: listed, refreshed, and
  /// switched off by the user like any other.
  List<SourceEndpoint> finderSources = [];
  bool finderEnabled = true;
  FinderReport? finderReport;
  Timer? _finderTimer;

  List<SourceEndpoint> get availableEndpoints {
    if (finderSources.isEmpty) return [...endpoints, ...discoveredSources];
    final ids = <String>{};
    return [
      for (final e in [...endpoints, ...discoveredSources, ...finderSources])
        if (ids.add(e.id)) e
    ];
  }

  /// Switches on what هوش جستجوگر ۱ accepted since the last look — in this
  /// run or in a background one.
  Future<void> applyFinderAccepted() async {
    finderSources = finder.acceptedEndpoints();
    final ids = await finder.takeUnapplied();
    if (ids.isEmpty) return;
    enabled.addAll(ids);
    await store.setSetting('enabled', jsonEncode(enabled.toList()));
    unawaited(AppLogger.instance
        .record('discovery', 'finder_sources_enabled', {'added': ids.length}));
  }

  Future<void> setFinderEnabled(bool value) async {
    finderEnabled = value;
    await store.setSetting('finder.enabled', '$value');
    try {
      await BackgroundScanScheduler.configureFinder(enabled: value);
    } catch (error, stack) {
      AppLogger.instance.capture(error, stack, section: 'finder');
    }
    if (value) {
      startFinder(first: const Duration(seconds: 1));
    } else {
      _finderTimer?.cancel();
      _finderTimer = null;
    }
    _notify();
  }

  /// Registers the background task that continues the lists whenever the
  /// phone is online, also while the app is closed.
  Future<void> scheduleFinder() async {
    try {
      await BackgroundScanScheduler.configureFinder(enabled: finderEnabled);
    } catch (error, stack) {
      AppLogger.instance.capture(error, stack, section: 'finder');
    }
  }

  /// Keeps the list builder working while the app is open. Every tick is a
  /// short, bounded slice; a tick that finds the phone offline simply waits
  /// for the next one, so the work resumes by itself whenever it is online.
  void startFinder({Duration first = const Duration(seconds: 6)}) {
    _finderTimer?.cancel();
    _finderTimer = null;
    if (!finderEnabled || disposed) return;
    _finderTimer = Timer(first, () => unawaited(_finderTick()));
  }

  Future<void> _finderTick() async {
    _finderTimer = null;
    if (disposed || !finderEnabled) return;
    var wait = const Duration(seconds: 30);
    if (!busy && !transferring && foreground) {
      final report = await runFinderNow(maxSteps: 8);
      if (report != null) {
        wait = report.offline
            ? const Duration(seconds: 90)
            : report.idle
                ? const Duration(minutes: 5)
                : const Duration(seconds: 6);
      }
      // A completed list is handed over without waiting for a refresh.
      if (report != null && !report.offline) {
        final given = await deliverFinderNow(limit: 4);
        if (given >= 0 && finder.handoffBatch(limit: 1).isNotEmpty) {
          wait = const Duration(seconds: 6);
        }
      }
    }
    if (!disposed && finderEnabled) {
      _finderTimer = Timer(wait, () => unawaited(_finderTick()));
    }
  }

  /// One slice of the list builder, now. Never runs on top of a refresh.
  Future<FinderReport?> runFinderNow({int maxSteps = 8}) async {
    if (disposed || busy || transferring || finder.running) return null;
    try {
      // Long enough that a slow page can be tried and the next provider still
      // gets its turn inside the same slice (گردو alone may need 30 s).
      final report = await finder.runSlice(
          maxSteps: maxSteps,
          budget: const Duration(seconds: 60),
          cancelled: () => disposed || busy);
      finderReport = report;
      if (report.steps > 0) {
        unawaited(AppLogger.instance.record('discovery', 'finder_slice', {
          'steps': report.steps,
          'offline': report.offline,
          'found': finder.state.entries.length
        }));
      }
      return report;
    } catch (error, stack) {
      AppLogger.instance.capture(error, stack, section: 'finder');
      return null;
    } finally {
      _notify();
    }
  }

  Future<void>? _delivery;
  bool _stopDelivery = false;

  /// Gives a few waiting entries of the completed lists to هوش جستجوگر ۱ now,
  /// outside a refresh: the same reader, the same picture reading, the same
  /// searcher. An accepted source appears among the routes at once. Returns
  /// how many were accepted, or -1 when it could not run.
  Future<int> deliverFinderNow({int limit = 4}) async {
    if (disposed ||
        busy ||
        transferring ||
        !finderEnabled ||
        _delivery != null ||
        finder.running) {
      return -1;
    }
    final done = Completer<void>();
    _delivery = done.future;
    _stopDelivery = false;
    String? lock;
    var accepted = -1;
    try {
      await finder.sync();
      if (finder.handoffBatch(limit: 1).isEmpty) return 0;
      lock = await store.acquireRefreshLock();
      if (lock == null) return -1;
      accepted = await deliverFinderBatch(store, client, finder,
          windowDays: discoveryDays,
          limit: limit,
          photos: photoScanner,
          cancelled: () => disposed || _stopDelivery);
      if (accepted > 0) {
        await applyFinderAccepted();
        rangeSession.invalidate();
        historyRevision++;
        await reload();
        unawaited(AppLogger.instance
            .record('discovery', 'finder_accepted', {'sources': accepted}));
      }
      return accepted;
    } catch (error, stack) {
      AppLogger.instance.capture(error, stack, section: 'finder');
      return accepted;
    } finally {
      if (lock != null) {
        try {
          await store.releaseRefreshLock(lock);
        } catch (_) {
          // The lease expires by itself.
        }
      }
      _delivery = null;
      done.complete();
      _notify();
    }
  }

  /// Starting points for the list builder: the research lists shipped with
  /// the app and the home pages of the sellers the app already reads.
  Future<void> _seedFinder() async {
    if (finder.state.seeded) return;
    final candidates = <String>[
      for (final key in const ['telegram_channels', 'other_channels', 'sources'])
        for (final row in (registry[key] as List? ?? const []))
          if (row is Map && row['url'] is String) row['url'] as String
    ];
    final pages = <String>{
      for (final e in endpoints)
        if (!const {'telegram', 'eitaa', 'bale', 'rubika'}.contains(e.parser))
          Uri(scheme: 'https', host: Uri.parse(e.url).host, path: '/').toString()
    };
    await finder.seed(candidates: candidates, pages: pages);
  }
  Future<void> rememberSources(Iterable<SourceEndpoint> found) async {
    final ids = availableEndpoints.map((e) => publicChannel(e.url)?.id).toSet();
    var changed = false;
    for (final e in found) {
      if (!ids.add(e.id) || discoveredSources.length >= 60) continue;
      discoveredSources.add(e);
      changed = true;
    }
    if (changed) {
      await store.setSetting(
          'discoveredSources',
          jsonEncode(discoveredSources
              .map((e) => {'url': e.url, 'name': e.name})
              .toList()));
      await AppLogger.instance.record('discovery', 'public_links_found',
          {'total': discoveredSources.length});
    }
  }

  Future<void> addPublicSource(String raw) async {
    final candidate = publicChannel(raw);
    if (candidate == null) {
      throw const FormatException(
          'پیوند عمومی کانال ایتا/بله/روبیکا/تلگرام معتبر نیست؛ دعوت، تلفن و ربات پذیرفته نمی‌شود.');
    }
    final existing = availableEndpoints
        .where((e) => publicChannel(e.url)?.id == candidate.id)
        .firstOrNull;
    if (existing == null) {
      await rememberSources([candidate]);
      if (!discoveredSources.any((e) => e.id == candidate.id)) {
        throw const FormatException('ظرفیت فهرست کشف منابع پر است.');
      }
    }
    await setEnabled(existing?.id ?? candidate.id, true);
  }

  Map<String, Map<String, Object?>> states = {};
  Map<String, dynamic> registry = {};
  List<String> cities = [];
  // Every registered route is enabled from the first run. Only a route the user
  // turns off later stays off (and a channel discovered from a public post is
  // still opt-in, because it is a candidate, not a registered source).
  Set<String> enabled = {for (final e in endpoints) e.id};
  bool busy = false, ready = false, autoRefresh = false, disposed = false;

  /// Why the last refresh attempt did nothing (empty when it ran or was not
  /// attempted). The button shows it, so a blocked refresh is never silent.
  String refreshBlockedReason = '';

  /// When the archive last finished a refresh, read from the archive itself so
  /// it survives restarts and is the same in the foreground and background.
  DateTime? lastRefreshAt;

  Timer? _refreshHeartbeat;
  bool foreground = true;
  int scanIntervalMinutes = 30;
  String? lastBackgroundScan;

  /// Last foreground scan of the continuous watch (see [startForegroundWatch]).
  DateTime? lastWatchScan;
  Timer? _watchTimer;
  int lastBackgroundScanCount = 0;
  int finished = 0, historyRevision = 0;
  String get selectedCity => filter.city;

  /// The primary window of the whole app: what a refresh registers and what
  /// every tab shows by default. One month, as chosen by the user.
  int discoveryDays = defaultWindowDays;

  /// A tab may narrow the primary window, or widen it; `-1` means "inherit".
  /// The calculation tab has no time filter at all.
  int pricesDays = -1, rangeDays = -1, chartDays = -1;

  static const defaultWindowDays = 30;
  int get pricesWindow => pricesDays >= 0 ? pricesDays : discoveryDays;
  int get rangeWindow => rangeDays >= 0 ? rangeDays : discoveryDays;
  int get chartWindow => chartDays >= 0 ? chartDays : discoveryDays;

  bool loggingEnabled = false;
  Future<void> setCity(String city) async {
    // A different city is a different query; derived answers never cross it.
    rangeSession.invalidate();
    filter.city = city.trim();
    filter.cityKind = 'all';
    _filtered = [];
    _filteredCity = selectedCity;
    _filterKey = '';
    candidates = null;
    _candidateKey = '';
    await store.setSetting('selectedCity', selectedCity);
    _notify();
    unawaited(prepareCandidates());
  }

  Future<void> setLogging(bool value) async {
    loggingEnabled = value;
    await AppLogger.instance.setEnabled(value);
    await store.setSetting('loggingEnabled', '$value');
    _notify();
  }

  /// Sets the primary capture window and re-derives everything that depended
  /// on the previous one.
  Future<void> setDiscoveryDays(int days) async {
    if (days == discoveryDays) return;
    discoveryDays = days;
    await store.setSetting('windowDays', '$days');
    await _windowChanged();
  }

  /// Sets one tab's own time filter; `-1` restores "same as the primary window".
  Future<void> setTabDays(String tab, int days) async {
    switch (tab) {
      case 'prices':
        if (pricesDays == days) return;
        pricesDays = days;
      case 'range':
        if (rangeDays == days) return;
        rangeDays = days;
      case 'chart':
        if (chartDays == days) return;
        chartDays = days;
      default:
        return;
    }
    await store.setSetting('windowDays:$tab', '$days');
    await _windowChanged();
  }

  Future<void> _windowChanged() async {
    filter.windowDays = pricesWindow;
    // Every derived answer of the old window is void.
    rangeSession.invalidate();
    _filtered = [];
    _filterKey = '';
    _filteredCity = '';
    candidates = null;
    _candidateKey = '';
    _rowCache = null;
    _rowCacheKey = '';
    _notify();
    if (ready) {
      unawaited(prepareCandidates());
    }
  }

  void historyChanged() {
    historyRevision++;
    historyEpoch++;
    // The archive changed: nothing derived from the old one may be served.
    rangeSession.invalidate();
    candidates = null;
    _candidateKey = '';
    _notify();
    unawaited(prepareCandidates());
  }

  String? startupError;
  bool transferring = false;
  final Map<String, int> endpointRevisions = {};
  int historyEpoch = 0;
  MarketController(this.store, {SourceClient? client, PhotoScanner? photoScanner})
      : client = client ?? SourceClient(),
        photoScanner = photoScanner ?? PhotoScanner(
            client: (client ?? SourceClient()).client,
            engine: OcrEngine.platform());

  /// In-memory index of the archive and its confirmed answers. Purely additive:
  /// every answer is derived from the stored payloads, and any write drops it.
  late final RangeSession rangeSession = RangeSession(store);

  /// Hands the derived index to the standing range worker as soon as the
  /// archive is loaded. This is now explicit opt-in only: automatically warming
  /// it alongside prices duplicates the full index at the refresh memory peak.
  Future<void> warmRangeIndex() async {
    if (disposed || busy) return;
    try {
      final at = DateTime.now().toUtc();
      final session = rangeSession;
      await session.ensureIndex(at, windowDays: rangeWindow);
      if (disposed || busy) return;
      // The worker holds rows, so a token it no longer matches must start from a
      // clean worker: a stale token would answer with another archive's rows.
      final worker = RangeWorker.shared;
      if (worker.isLoaded && !worker.holdsToken(session.dataToken)) {
        worker.dispose();
      }
      await worker.load(session.dataToken, session.indexRowsSnapshot);
    } catch (e, stack) {
      AppLogger.instance.capture(e, stack, section: 'range_worker');
    }
  }

  Future<void> init() async {
    await AppLogger.instance.checkpoint('startup');
    filter.city = await store.setting('selectedCity') ?? '';
    filter.cityKind = 'all';
    discoveryDays = int.tryParse(await store.setting('windowDays') ?? '') ??
        defaultWindowDays;
    if (discoveryDays < 0) discoveryDays = defaultWindowDays;
    pricesDays =
        int.tryParse(await store.setting('windowDays:prices') ?? '') ?? -1;
    rangeDays =
        int.tryParse(await store.setting('windowDays:range') ?? '') ?? -1;
    chartDays =
        int.tryParse(await store.setting('windowDays:chart') ?? '') ?? -1;
    filter.windowDays = pricesWindow;
    loggingEnabled = await store.setting('loggingEnabled') == 'true';
    await AppLogger.instance.setEnabled(loggingEnabled);
    registry = jsonDecode(await rootBundle.loadString('assets/registry.json'));
    final cityData =
        jsonDecode(await rootBundle.loadString('assets/cities.json')) as List;
    cities = cityData.map((x) => x['name'] as String).toSet().toList()..sort();
    cities.remove('مشهد');
    cities.insert(0, 'مشهد');
    client.cityNames = cities;
    filter.queryCities = cities;
    final savedLinks = await store.setting('discoveredSources');
    if (savedLinks != null) {
      try {
        await rememberSources((jsonDecode(savedLinks) as List)
            .map((x) =>
                publicChannel(x['url'] as String, name: x['name'] as String?))
            .whereType<SourceEndpoint>());
      } catch (error, stack) {
        AppLogger.instance.capture(error, stack, section: 'discovery');
      }
    }
    finderEnabled = await store.setting('finder.enabled') != 'false';
    try {
      await finder.load(force: true);
      finderSources = finder.acceptedEndpoints();
    } catch (error, stack) {
      AppLogger.instance.capture(error, stack, section: 'finder');
    }
    final setting = await store.setting('enabled');
    if (setting != null) {
      enabled = (jsonDecode(setting) as List)
          .cast<String>()
          .where((id) => availableEndpoints.any((e) => e.id == id))
          .toSet();
    }
    try {
      await applyFinderAccepted();
      await _seedFinder();
    } catch (error, stack) {
      AppLogger.instance.capture(error, stack, section: 'finder');
    }
    if (await store.setting('sourcesVersion') != '2') {
      enabled.addAll(
          ['telegram-mashhad', 'telegram-ahanresan', 'telegram-ahanemashhad']);
      await store.setSetting('enabled', jsonEncode(enabled.toList()));
      await store.setSetting('sourcesVersion', '2');
    }
    if (await store.setting('analysisSourcesVersion') != '1') {
      enabled
          .addAll(['public-eitaa-modiranahan', 'public-bale-novinparsgroup']);
      await store.setSetting('enabled', jsonEncode(enabled.toList()));
      await store.setSetting('analysisSourcesVersion', '1');
    }
    if (await store.setting('sheetSourcesVersion') != '1') {
      enabled.addAll(['fardad-sheet', 'mashhad-sheet']);
      await store.setSetting('enabled', jsonEncode(enabled.toList()));
      await store.setSetting('sheetSourcesVersion', '1');
    }
    // Explicit user request: all curated sources ON, once on upgrade.
    // Unreviewed discovered links are candidates, not confirmed source adapters.
    if (await store.setting('allRegisteredSourcesEnabledVersion') != '4') {
      enabled.addAll(endpoints.map((e) => e.id));
      await store.setSetting('enabled', jsonEncode(enabled.toList()));
      await store.setSetting('allRegisteredSourcesEnabledVersion', '4');
    }
    // Add only the eight newly requested routes once; preserve old OFF choices.
    if (await store.setting('mashhadSourcesVersion') != '072') {
      enabled.addAll(mashhadV072EndpointIds);
      await store.setSetting('enabled', jsonEncode(enabled.toList()));
      await store.setSetting('mashhadSourcesVersion', '072');
    }
    autoRefresh = await store.setting('autoRefresh') == 'true';
    scanIntervalMinutes =
        int.tryParse(await store.setting('scanIntervalMinutes') ?? '') ?? 30;
    if (![15, 30, 60].contains(scanIntervalMinutes)) scanIntervalMinutes = 30;
    lastRefreshAt = DateTime.tryParse(await store.setting('lastRefresh') ?? '')
        ?.toLocal();
    lastBackgroundScan = await store.setting('lastBackgroundScan');
    lastBackgroundScanCount =
        int.tryParse(await store.setting('lastBackgroundScanCount') ?? '') ?? 0;
    try {
      await BackgroundScanScheduler.configure(
          enabled: autoRefresh, intervalMinutes: scanIntervalMinutes);
    } catch (error, stack) {
      autoRefresh = false;
      await store.setSetting('autoRefresh', 'false');
      AppLogger.instance.capture(error, stack, section: 'background_scan');
    }
    await reload();
    ready = true;
    await AppLogger.instance
        .checkpoint('startup_prices_ready', rows: quotes.length);
    unawaited(prepareCandidates());
    unawaited(AppLogger.instance.record('lifecycle', 'market_ready',
        {'cachedRows': quotes.length, 'enabled': enabled.length}));
    startForegroundWatch();
    _notify();
  }

  void _notify() {
    if (!disposed) notifyListeners();
  }

  void changed() {
    unawaited(AppLogger.instance.record('filter', 'changed', {
      'category': filter.category,
      'city': filter.city,
      'size': filter.size,
      'thickness': filter.thickness,
      'queryLength': filter.query.length
    }));
    // A changed scope is a changed candidate list; a changed sort or a price
    // bound is only a re-sort and needs no new selection.
    if (_candidateKey != _currentCandidateKey && !disposed) {
      unawaited(prepareCandidates());
    }
    _notify();
  }

  /// Every stored offer that has a real price in the chart basis, deduplicated
  /// by id, with the current feed rows first. Selecting one never invents a
  /// price: a row without a comparable amount stays out.
  List<Quote> get chartOptions {
    final basis = filter.basis;
    final seen = <String>{};
    final options = <Quote>[];
    final now = DateTime.now().toUtc();
    void add(Iterable<Quote> source) {
      for (final q in source) {
        // Only rows inside the chart's own window: the tab shows what was stored
        // in the selected window, exactly like the other tabs.
        if (!insideWindow(q, now, chartWindow)) continue;
        if (q.tomanFor(basis) == null) continue;
        if (seen.add(q.id)) options.add(q);
      }
    }

    add(filtered);
    add(quotes);
    return options;
  }

  /// Candidate rows of the prices tab, prepared from the stored archive as soon
  /// as it is loaded, so nothing has to be "prepared" when the tab is opened.
  CandidateSet? candidates;
  String _candidateKey = '';
  String _preparingCandidateKey = '';

  /// The rows the prices tab shows: the prepared candidate set when it is ready
  /// and still matches the current basis/search, otherwise the classic filter
  /// (used for selections, price bounds and sorting, which the index path does
  /// not replace). If the index path fails, this is the same answer the app has
  /// always given — it is the fallback, not a different result.
  List<Quote>? _rowCache;
  String _rowCacheKey = '';

  /// True while the prepared list has rows that were not built yet.
  bool get moreCandidates => (candidates?.total ?? 0) > candidateRows.length;

  /// Builds one more page and tells the tab to draw it.
  void showMoreCandidates() {
    final c = candidates;
    if (c == null || !moreCandidates) return;
    c.extend();
    _rowCacheKey = '';
    _notify();
  }

  List<Quote> get candidateRows {
    final c = candidates;
    if (c == null || _candidateKey != _currentCandidateKey) return filtered;
    // Building and sorting thousands of rows is done once per scope and sort,
    // never once per frame.
    final key = '$_candidateKey\u0001${c.total}\u0001${c.quotes.length}'
        '\u0001${filter.sort}'
        '\u0001${filter.mashhadFirst}\u0001${filter.minPrice}'
        '\u0001${filter.maxPrice}\u0001${filter.onlyFresh}';
    final cached = _rowCache;
    if (cached != null && key == _rowCacheKey) return cached;
    // A newest-first order is a date order, and the selection is already in that
    // order, so a page is enough. A price order is not: the cheapest offer of the
    // scope may be the last row of it, so the whole selection is built once before
    // it is sorted — the only case where the tab builds every row.
    if (filter.sort != 'latest') c.extend(c.total);
    final now = DateTime.now();
    final list = _sortCandidates(c.quotes, now);
    final f = filter;
    // The classic filter has already been applied to the selection, so only the
    // fields it owns alone (the bounds and the freshness switch) are re-run here.
    final rows = f.minPrice == null && f.maxPrice == null && !f.onlyFresh
        ? list
        : f.apply(list, now);
    _rowCache = rows;
    _rowCacheKey = key;
    return rows;
  }

  /// The number of offers the scope really has, ready ones or not.
  int get candidateCount => candidates?.total ?? filtered.length;

  String get _currentCandidateKey => [
        filter.basis,
        filter.query,
        filter.city,
        filter.cityKind,
        filter.category,
        filter.material,
        filter.size,
        filter.thickness,
        filter.grade,
        filter.unit,
        filter.recentWeek,
        filter.includeUnpriced,
        filter.windowDays,
        quotes.length,
        identityHashCode(quotes),
        historyRevision,
      ].join('\u0001');

  List<Quote> _sortCandidates(List<Quote> rows, DateTime now) {
    final list = rows.toList();
    final f = filter;
    if (f.sort == 'latest') {
      list.sort((a, b) {
        final byDate = (b.marketAt?.millisecondsSinceEpoch ?? 0)
            .compareTo(a.marketAt?.millisecondsSinceEpoch ?? 0);
        if (byDate != 0) return byDate;
        if (f.mashhadFirst) {
          final city = (a.sellerCity == 'مشهد' ? 0 : 1)
              .compareTo(b.sellerCity == 'مشهد' ? 0 : 1);
          if (city != 0) return city;
        }
        return a.id.compareTo(b.id);
      });
      return list;
    }
    final keys = [for (final q in list) q.comparisonGroup(f.basis)];
    final index = <Quote, int>{
      for (var i = 0; i < list.length; i++) list[i]: i
    };
    list.sort((a, b) {
      final group = keys[index[a]!].compareTo(keys[index[b]!]);
      if (group != 0) return group;
      if (f.mashhadFirst) {
        final p = (a.sellerCity == 'مشهد' ? 0 : 1)
            .compareTo(b.sellerCity == 'مشهد' ? 0 : 1);
        if (p != 0) return p;
      }
      final pa = a.tomanFor(f.basis), pb = b.tomanFor(f.basis);
      if (pa == null && pb == null) return a.title.compareTo(b.title);
      if (pa == null) return 1;
      if (pb == null) return -1;
      final c = pa.compareTo(pb);
      return (f.sort == 'desc' ? -c : c) != 0
          ? (f.sort == 'desc' ? -c : c)
          : a.id.compareTo(b.id);
    });
    return list;
  }

  /// The current scope, expressed so the stored index can decide it.
  CandidateScope candidateScope() => CandidateScope(
        basis: filter.basis,
        query: filter.query,
        // The tab's own window is the selection window; the "only this week"
        // switch narrows it further when it is turned on.
        maxAgeDays: filter.recentWeek && pricesWindow > 7
            ? 7
            : (pricesWindow <= 0 ? 36500 : pricesWindow),
        category: filter.category,
        material: filter.material,
        city: filter.city,
        unit: filter.unit,
        size: filter.size,
        thickness: filter.thickness,
        grade: filter.grade,
        cityKind: filter.cityKind,
        onlyFresh: filter.onlyFresh,
        includeUnpriced: filter.includeUnpriced,
        minPrice: filter.minPrice,
        maxPrice: filter.maxPrice,
      );

  /// Prepares the candidate set from the index. Called after the archive is
  /// loaded and whenever the basis/search/city changes — never from `build`.
  Future<void> prepareCandidates() async {
    if (disposed) return;
    // During a refresh the archive is being rewritten source by source, so an
    // index built now would describe a half-written archive — and holding it
    // means two full representations of the archive in memory at once (the
    // decoded rows *and* the wide index rows) for the whole refresh, which is
    // a possible source of peak memory pressure. The classic
    // filter over the rows already in memory answers meanwhile; the index is
    // built once, when the refresh finishes.
    if (busy) {
      candidates = null;
      _candidateKey = '';
      return;
    }
    final key = _currentCandidateKey;
    if (key == _candidateKey && candidates != null) return;
    if (_preparingCandidateKey == key) return;
    _preparingCandidateKey = key;
    try {
      // An index already in memory is filtered synchronously: no await, so a
      // test clock (or the first frame) cannot observe a half-done state.
      // The scope is the whole filter, not a part of it: the fast path must
      // answer exactly what the classic path would, or it is not the same list.
      final scope = candidateScope();
      if (rangeSession.hasIndexFor(pricesWindow)) {
        candidates =
            rangeSession.candidatesNow(scope: scope, at: DateTime.now());
        _candidateKey = key;
        _notify();
        return;
      }
      await AppLogger.instance
          .checkpoint('candidate_index_start', rows: quotes.length);
      if (disposed || busy || key != _currentCandidateKey) return;
      final set = await rangeSession.candidates(
          scope: scope, at: DateTime.now(), windowDays: pricesWindow);
      if (disposed || busy) return;
      // A newer question may have been asked while this one was being answered.
      if (key != _currentCandidateKey) return;
      candidates = set;
      _candidateKey = key;
      await AppLogger.instance
          .checkpoint('candidate_index_ready', rows: set.total);
      _notify();
    } catch (e, stack) {
      // The classic filter still answers; a fast path is never a hard failure.
      AppLogger.instance.capture(e, stack, section: 'candidates');
    } finally {
      if (_preparingCandidateKey == key) _preparingCandidateKey = '';
    }
  }

  List<Quote> _filtered = [];
  String _filterKey = '', _filteredCity = '';
  bool filtering = false;
  String get _currentFilterKey =>
      '${identityHashCode(quotes)}:${filter.cacheKey}:${DateTime.now().millisecondsSinceEpoch ~/ 60000}';
  List<Quote> get filtered {
    if (_filteredCity != selectedCity) {
      _filtered = [];
      _filteredCity = selectedCity;
    }
    final key = _currentFilterKey;
    if (key == _filterKey) {
      return _filtered;
    }
    if (quotes.length <= 200) {
      _filtered = filter.apply(quotes, DateTime.now());
      _filterKey = key;
    } else if (!filtering) {
      filtering = true;
      unawaited(_updateFiltered());
    }
    return _filtered;
  }

  Future<void> _updateFiltered() async {
    await Future<void>.delayed(Duration.zero);
    _notify();
    try {
      while (!disposed) {
        final key = _currentFilterKey;
        final watch = Stopwatch()..start();
        final result = await compute(_filterInBackground,
            {'quotes': quotes, 'filter': filter, 'now': DateTime.now()});
        if (disposed) return;
        if (key != _currentFilterKey) continue;
        _filtered = result;
        _filterKey = key;
        await AppLogger.instance.record('filter', 'completed', {
          'rows': quotes.length,
          'matches': result.length,
          'elapsedMs': watch.elapsedMilliseconds
        });
        break;
      }
    } catch (e, stack) {
      AppLogger.instance.capture(e, stack, section: 'filter');
    } finally {
      filtering = false;
      _notify();
    }
  }

  bool _quotesLoaded = false;

  Future<void> reload() async {
    quotes = await store.latest();
    _quotesLoaded = true;
    states = await store.syncStates();
    _notify();
    // Only after startup is complete: the index read must never sit in front of
    // the first prices on screen (both share one SQLite connection). A refresh
    // in progress defers both — see `prepareCandidates`.
    if (ready && !busy) {
      unawaited(prepareCandidates());
    }
  }

  void transferState(bool value) {
    transferring = value;
    _notify();
  }

  Future<void> imported() async {
    rangeSession.invalidate();
    discoveredSources.clear();
    await init();
    historyChanged();
  }

  Future<void> setEnabled(String id, bool value) async {
    if (value) {
      enabled.add(id);
    } else {
      enabled.remove(id);
    }
    await store.setSetting('enabled', jsonEncode(enabled.toList()));
    _notify();
  }

  /// One step for every source the list shows: the registered routes, the
  /// channels added by hand or seen in posts, and the ones هوش جستجوگر ۲ got
  /// accepted. «همه روشن» and «همه خاموش» act on all of them together, and
  /// the choice is stored like any other, so a later run keeps it.
  Future<void> setAllEnabled(bool value) async {
    final ids = [for (final e in availableEndpoints) e.id];
    if (value) {
      enabled.addAll(ids);
    } else {
      enabled.removeAll(ids);
    }
    await store.setSetting('enabled', jsonEncode(enabled.toList()));
    unawaited(AppLogger.instance.record(
        'filter', value ? 'all_sources_on' : 'all_sources_off',
        {'sources': ids.length}));
    _notify();
  }

  /// Keeps the searcher scanning while the app is open.
  ///
  /// WorkManager cannot run more often than 15 minutes and Android does not
  /// promise the exact time, so the only way to keep scanning continuously is a
  /// foreground timer. It uses the same refresh (same lease, same rules), never
  /// starts on top of a running refresh, and stops as soon as periodic scanning
  /// is turned off.
  void startForegroundWatch() {
    _watchTimer?.cancel();
    _watchTimer = null;
    if (!autoRefresh || disposed) return;
    _watchTimer =
        Timer.periodic(Duration(minutes: scanIntervalMinutes), (_) {
      if (disposed || busy || transferring || !autoRefresh || !foreground) {
        return;
      }
      lastWatchScan = DateTime.now();
      unawaited(refresh());
    });
  }

  Future<void> setAuto(bool value) async {
    final previous = autoRefresh;
    autoRefresh = value;
    try {
      await BackgroundScanScheduler.configure(
          enabled: value, intervalMinutes: scanIntervalMinutes);
      await store.setSetting('autoRefresh', '$value');
    } catch (error, stack) {
      autoRefresh = previous;
      AppLogger.instance.capture(error, stack, section: 'background_scan');
      rethrow;
    }
    startForegroundWatch();
    _notify();
  }

  Future<void> setScanInterval(int minutes) async {
    if (![15, 30, 60].contains(minutes)) {
      throw ArgumentError.value(minutes, 'minutes', 'Expected 15, 30, or 60');
    }
    final previous = scanIntervalMinutes;
    scanIntervalMinutes = minutes;
    try {
      if (autoRefresh) {
        await BackgroundScanScheduler.configure(
            enabled: true, intervalMinutes: minutes);
      }
      await store.setSetting('scanIntervalMinutes', '$minutes');
    } catch (error, stack) {
      scanIntervalMinutes = previous;
      AppLogger.instance.capture(error, stack, section: 'background_scan');
      rethrow;
    }
    startForegroundWatch();
    _notify();
  }

  Future<void> refreshBackgroundState() async {
    lastBackgroundScan = await store.setting('lastBackgroundScan');
    lastBackgroundScanCount =
        int.tryParse(await store.setting('lastBackgroundScanCount') ?? '') ?? 0;
    // A background run may have extended the lists or accepted a source.
    if (!finder.running && !busy) {
      try {
        await finder.sync();
        await applyFinderAccepted();
      } catch (error, stack) {
        AppLogger.instance.capture(error, stack, section: 'finder');
      }
    }
    _notify();
  }

  Future<void> _publishTail = Future<void>.value();
  bool _publishFailed = false;
  bool _indexStale = false;

  /// Publishes one received source without re-decoding the archive.
  ///
  /// The rows of the source that just arrived replace that source's rows in
  /// memory; every other row is already decoded and is left alone. This is what
  /// keeps a refresh of many sources against a large archive from allocating a
  /// fresh copy of every stored row once per publish.
  Future<void> _publishEndpoint(String endpoint) {
    _publishPending.add(endpoint);
    return _publishFlush ??= _schedulePublish();
  }

  final Set<String> _publishPending = {};
  Future<void>? _publishFlush;
  Completer<void>? _publishHurry;

  /// False once the last source of a refresh is in: nothing more to wait for.
  bool _gather = true;

  /// How long arrivals are gathered before the list is rebuilt once.
  ///
  /// Publishing after every single source rebuilt the whole in-memory list,
  /// invalidated the filter and repainted the screen once per source; with many
  /// sources and a large archive those rebuilds ran back to back and the
  /// interface stopped answering. A small archive still publishes at once.
  Duration get _publishWindow => quotes.length >= 1500
      ? const Duration(milliseconds: 2500)
      : quotes.length >= 300
          ? const Duration(milliseconds: 900)
          : Duration.zero;

  Future<void> _schedulePublish() {
    // Serialize publications, not downloads. Never drop a completed source
    // just because the other network worker is publishing at the same time.
    final next = _publishTail.then((_) async {
      final wait = _publishWindow;
      if (wait > Duration.zero && busy && _gather && !disposed) {
        final hurry = _publishHurry = Completer<void>();
        await Future.any([Future<void>.delayed(wait), hurry.future]);
        _publishHurry = null;
      }
      final batch = _publishPending.toSet();
      _publishPending.clear();
      _publishFlush = null;
      if (disposed || batch.isEmpty) return;
      final fresh = <Quote>[];
      for (final endpoint in batch) {
        fresh.addAll(await store.latestFor(endpoint));
      }
      if (disposed) return;
      quotes = [
        for (final q in quotes)
          if (!batch.contains(q.endpoint)) q,
        ...fresh,
      ];
      states = await store.syncStates();
      _notify();
    });
    // A failed publication must not poison the queue. Reconcile from disk at
    // the end instead; callers still receive the original error.
    _publishTail = next.then<void>((_) {}, onError: (Object e, StackTrace s) {
      _publishFlush = null;
      _publishFailed = true;
    });
    return next;
  }

  DateTime _lastProgress = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _progressTimer;

  /// Progress of a running refresh, announced at most a few times a second.
  /// Every announcement rebuilds the visible page, so one per finished source
  /// is too many when sources finish in bursts.
  void _progress() {
    const gap = Duration(milliseconds: 350);
    final now = DateTime.now();
    if (now.difference(_lastProgress) >= gap) {
      _lastProgress = now;
      _notify();
      return;
    }
    _progressTimer ??= Timer(gap, () {
      _progressTimer = null;
      _lastProgress = DateTime.now();
      _notify();
    });
  }

  Future<void> refresh() async {
    refreshBlockedReason = '';
    if (busy || transferring || disposed) {
      refreshBlockedReason = busy ? 'نوسازی همین حالا در حال اجراست.' : '';
      _notify();
      return;
    }
    // A hand-over of the list builder holds the same lock for a moment; the
    // refresh asks it to stop and waits, rather than telling the user that
    // "another refresh is running".
    final handing = _delivery;
    if (handing != null) {
      _stopDelivery = true;
      await handing;
      if (busy || disposed) return;
    }
    String? refreshLock;
    try {
      refreshLock = await store.acquireRefreshLock();
    } catch (error, stack) {
      AppLogger.instance.capture(error, stack, section: 'refresh_lock');
      refreshBlockedReason = 'قفل نوسازی در آرشیو خوانده نشد؛ بعداً دوباره تلاش کنید.';
      _notify();
      return;
    }
    if (refreshLock == null || busy || transferring || disposed) {
      if (refreshLock != null) await store.releaseRefreshLock(refreshLock);
      if (refreshLock == null && !busy) {
        // Another run holds the lock. Say how long it lasts instead of doing
        // nothing: a 30-minute silent wait was read by the user as "the button
        // stopped working".
        final until = await store.refreshLockHolderExpiry();
        final minutes = until == null
            ? 0
            : until.difference(DateTime.now()).inMinutes +
                (until.difference(DateTime.now()).inSeconds % 60 > 0 ? 1 : 0);
        refreshBlockedReason = minutes <= 0
            ? 'نوسازی دیگری در حال اجراست؛ یک دقیقه دیگر دوباره تلاش کنید.'
            : 'نوسازی دیگری در حال اجراست؛ $minutes دقیقه تا آزادشدن قفل.';
      }
      _notify();
      return;
    }
    busy = true;
    // Keep our own lease alive while the scan runs; a refresh that dies leaves
    // the lock to expire instead of blocking the next one for half an hour.
    _refreshHeartbeat?.cancel();
    _refreshHeartbeat = Timer.periodic(MarketStore.refreshLockHeartbeat,
        (_) => unawaited(store.renewRefreshLock(refreshLock!)));
    // Drop retained answers and worker copies BEFORE allocating the next
    // archive. A refresh must not hold the old and new indices concurrently.
    rangeSession.invalidate();
    RangeWorker.shared.dispose();
    candidates = null;
    _candidateKey = '';
    _rowCache = null;
    _rowCacheKey = '';
    _filtered = [];
    _filterKey = '';
    _publishFailed = false;
    historyRevision++;
    unawaited(AppLogger.instance
        .record('network', 'refresh_started', {'sources': enabled.length}));
    finished = 0;
    _notify();
    final queue =
        availableEndpoints.where((e) => enabled.contains(e.id)).toList();
    // The completed lists of هوش جستجوگر ۲ are handed over here, a few entries
    // per refresh: each is read by the same reader and judged by the same
    // searcher as every other source, and only one that yields a valid row
    // becomes a route of the app.
    final handoff = <String, String>{};
    if (finderEnabled) {
      try {
        await finder.sync();
        final queued = {for (final e in queue) e.id};
        var front = 0;
        for (final h in finder.handoffBatch(limit: 12)) {
          if (queued.add(h.endpoint.id)) {
            // First in the queue: the user sees what the lists brought before
            // the long tail of ordinary sources.
            queue.insert(front++, h.endpoint);
            handoff[h.endpoint.id] = h.entry.key;
          } else {
            // Already a route of the app (added by hand or found in a post).
            await finder.verdict(h.entry.key,
                rows: 1, note: 'از پیش در اتصال‌های برنامه بود');
          }
        }
      } catch (error, stack) {
        AppLogger.instance.capture(error, stack, section: 'finder');
      }
    }
    Future<void> answer(SourceEndpoint e, int rows, String note) async {
      final key = handoff[e.id];
      if (key == null) return;
      try {
        await finder.verdict(key, rows: rows, note: note);
        if (rows > 0) await applyFinderAccepted();
      } catch (error, stack) {
        AppLogger.instance.capture(error, stack, section: 'finder');
      }
    }

    var index = 0;
    Future<void> worker() async {
      while (index < queue.length && !disposed) {
        final e = queue[index++];
        try {
          final fetched = await client.fetch(e, windowDays: discoveryDays);
          // A price list published only as a picture is read here, automatically.
          final data = await readPhotos(fetched,
              defaultCurrency: e.defaultCurrency);
          // One searcher decides what may enter the archive: inside the parent
          // window, about a product, with its place resolved and one copy of
          // each offer. A source that yields nothing usable keeps its previous
          // rows instead of being wiped by prose.
          final found = data.isEmpty
              ? const SearcherResult([])
              : await Searcher.processAsync(data,
                  now: DateTime.now(),
                  windowDays: discoveryDays,
                  resolver: MapsResolver(client.client));
          if (found.quotes.isEmpty) {
            await AppLogger.instance.record('search', 'no_rows', {
              'endpoint': e.id,
              'noise': found.noise,
              'outOfWindow': found.outOfWindow,
            });
            if (handoff.containsKey(e.id)) {
              // A list entry that gave no valid row is not a route yet: the
              // reason stays on the entry and nothing is written for it.
              await answer(
                  e,
                  0,
                  data.isEmpty
                      ? 'ردیف قیمت در صفحه عمومی پیدا نشد'
                      : 'ردیف قابل‌ثبت نبود (بیرون از بازه: ${found.outOfWindow} • '
                          'بی‌قیمت/بی‌محصول: ${found.noise})');
              finished++;
              _progress();
              continue;
            }
            // Rows are kept, but the source says why nothing new appeared.
            await store.note(
                e.id,
                data.isEmpty
                    ? 'متن پیام/ردیف قیمت در پاسخ عمومی پیدا نشد؛ داده قبلی حفظ شد.'
                    : 'ردیف قابل‌ثبت نبود (بیرون از بازه: ${found.outOfWindow} • '
                        'بی‌قیمت/بی‌محصول: ${found.noise})؛ داده قبلی حفظ شد.');
            finished++;
            _progress();
            continue;
          }
          await store.saveSnapshot(e.id, found.quotes,
              replaceMissing: client.complete[e.id] ?? true);
          // Fresh rows are derived at write time; drop the previous answers.
          // The index itself is rebuilt once, when the refresh finishes.
          _indexStale = true;
          await answer(e, found.quotes.length,
              'هوش جستجوگر ۱: ${found.quotes.length} ردیف معتبر');
          final seen = client.discoveries[e.id] ?? const <SourceEndpoint>[];
          await rememberSources(seen);
          // The channels a source names in its own posts are candidates for
          // the lists as well; they are read and judged like any other.
          if (finderEnabled && seen.isNotEmpty) {
            try {
              await finder.offerLinks(seen.map((x) => x.url), from: e.url);
            } catch (error, stack) {
              AppLogger.instance.capture(error, stack, section: 'finder');
            }
          }
          historyRevision++;
          endpointRevisions.update(e.id, (n) => n + 1, ifAbsent: () => 1);
          // Publish this source's own rows immediately; all-ON must not wait for
          // the slowest source before showing the first received prices, and the
          // rest of the archive is not re-read to do it.
          // The worker does not wait for the screen: arrivals are gathered and
          // shown together, and a failed publication is reconciled from disk
          // when the refresh ends.
          unawaited(_publishEndpoint(e.id).catchError((Object _) {}));
        } catch (error, stack) {
          AppLogger.instance.capture(error, stack, section: 'source');
          if (handoff.containsKey(e.id)) {
            await answer(
                e,
                0,
                error is FormatException
                    ? error.message
                    : 'خطا در اتصال/مهلت دریافت');
          } else {
            await store.failure(
                e.id,
                error is FormatException
                    ? error.message
                    : 'خطا در اتصال/مهلت دریافت؛ داده قبلی حفظ شد.');
          }
        }
        finished++;
        _progress();
        // Low concurrency, no login/CAPTCHA bypass or aggressive retries.
        await Future<void>.delayed(const Duration(milliseconds: 450));
      }
    }

    try {
      // A direct refresh before init must preserve untouched cached sources too.
      if (!_quotesLoaded) await reload();
      await AppLogger.instance.checkpoint('refresh_fetch', rows: quotes.length);
      await Future.wait([worker(), worker()]);
      await AppLogger.instance
          .checkpoint('refresh_sources_saved', rows: quotes.length);
      await store.setSetting(
          'lastRefresh', DateTime.now().toUtc().toIso8601String());
    } finally {
      try {
        if (_indexStale) {
          rangeSession.invalidate();
          _indexStale = false;
        }
        _progressTimer?.cancel();
        _progressTimer = null;
        // Nothing is left to gather: publish what has arrived now.
        _gather = false;
        if (!(_publishHurry?.isCompleted ?? true)) _publishHurry!.complete();
        await _publishTail;
        if (_publishFlush != null) await _publishTail;
        _gather = true;
        if (_publishFailed || !_quotesLoaded) {
          await reload();
        } else {
          // Every successful source is already decoded; do not allocate another
          // full archive just to publish the final status (including failures).
          states = await store.syncStates();
          _notify();
        }
        await AppLogger.instance
            .checkpoint('refresh_publish_complete', rows: quotes.length);
        unawaited(AppLogger.instance.record('network', 'refresh_complete',
            {'completed': finished, 'cachedRows': quotes.length}));
      } finally {
        _refreshHeartbeat?.cancel();
        _refreshHeartbeat = null;
        try {
          await store.releaseRefreshLock(refreshLock);
        } finally {
          lastRefreshAt =
              DateTime.tryParse(await store.setting('lastRefresh') ?? '')
                  ?.toLocal();
          busy = false;
          _notify();
          unawaited(prepareCandidates());
        }
      }
    }
  }

  /// Reads the pictures the fetched posts carry (delegates to the one shared
  /// pipeline, so the background scan behaves identically).
  Future<List<Quote>> readPhotos(List<Quote> rows,
      {String defaultCurrency = 'نامشخص'}) async {
    final batch = await readPostPhotos(rows, photoScanner,
        defaultCurrency: defaultCurrency, cancelled: () => disposed);
    photosScanned += batch.read;
    if (batch.read > 0 || batch.failed > 0) {
      photoReport = 'تصویر خوانده‌شده: ${batch.read}'
          '${batch.failed == 0 ? '' : ' • خوانده‌نشده: ${batch.failed}'}';
    }
    return batch.rows;
  }

  @override
  void dispose() {
    disposed = true;
    _watchTimer?.cancel();
    _watchTimer = null;
    _finderTimer?.cancel();
    _finderTimer = null;
    _refreshHeartbeat?.cancel();
    _refreshHeartbeat = null;
    _progressTimer?.cancel();
    _progressTimer = null;
    if (!(_publishHurry?.isCompleted ?? true)) _publishHurry!.complete();

    rangeSession.invalidate();
    RangeWorker.shared.dispose();
    client.close();
    super.dispose();
  }
}

List<Quote> _filterInBackground(Map<String, Object> input) =>
    (input['filter'] as MarketFilter)
        .apply(input['quotes'] as List<Quote>, input['now'] as DateTime);
