import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../domain/market.dart';
import '../domain/range_projection.dart';
import '../domain/range_worker.dart';
import 'range_session.dart';
import 'sources.dart';
import 'store.dart';
import 'app_logger.dart';

class MarketController extends ChangeNotifier {
  final MarketStore store;
  final SourceClient client;
  final MarketFilter filter = MarketFilter()
    ..recentWeek = true
    ..sort = 'latest';
  List<Quote> quotes = [];
  final List<SourceEndpoint> discoveredSources = [];
  List<SourceEndpoint> get availableEndpoints =>
      [...endpoints, ...discoveredSources];
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
  Set<String> enabled = {
    for (final e in endpoints)
      if (e.defaultEnabled) e.id
  };
  bool busy = false, ready = false, autoRefresh = false, disposed = false;
  bool foreground = true;
  int finished = 0, historyRevision = 0;
  String get selectedCity => filter.city;
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
  MarketController(this.store, {SourceClient? client})
      : client = client ?? SourceClient();

  /// In-memory index of the archive and its confirmed answers. Purely additive:
  /// every answer is derived from the stored payloads, and any write drops it.
  late final RangeSession rangeSession = RangeSession(store);
  /// Hands the derived index to the standing range worker as soon as the
  /// archive is loaded, so the first confirmation has nothing left to prepare.
  /// It never blocks anything: a failure only means the confirm does it later.
  Future<void> warmRangeIndex() async {
    if (disposed) return;
    try {
      final at = DateTime.now().toUtc();
      final session = rangeSession;
      await session.ensureIndex(at);
      if (disposed) return;
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
    filter.city = await store.setting('selectedCity') ?? '';
    filter.cityKind = 'all';
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
    final setting = await store.setting('enabled');
    if (setting != null) {
      enabled = (jsonDecode(setting) as List)
          .cast<String>()
          .where((id) => availableEndpoints.any((e) => e.id == id))
          .toSet();
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
    // Explicit user request in 0.5.1: all curated sources ON, once on upgrade.
    // Unreviewed discovered links are candidates, not confirmed source adapters.
    if (await store.setting('allRegisteredSourcesEnabledVersion') != '3') {
      enabled.addAll(availableEndpoints.map((e) => e.id));
      await store.setSetting('enabled', jsonEncode(enabled.toList()));
      await store.setSetting('allRegisteredSourcesEnabledVersion', '3');
    }
    // Add only the eight newly requested routes once; preserve old OFF choices.
    if (await store.setting('mashhadSourcesVersion') != '072') {
      enabled.addAll(mashhadV072EndpointIds);
      await store.setSetting('enabled', jsonEncode(enabled.toList()));
      await store.setSetting('mashhadSourcesVersion', '072');
    }
    autoRefresh = false;
    await store.setSetting('autoRefresh', 'false');
    await reload();
    ready = true;
    unawaited(prepareCandidates());
    unawaited(AppLogger.instance.record('lifecycle', 'market_ready',
        {'cachedRows': quotes.length, 'enabled': enabled.length}));
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
    void add(Iterable<Quote> source) {
      for (final q in source) {
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
    final index = <Quote, int>{for (var i = 0; i < list.length; i++) list[i]: i};
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
        maxAgeDays: filter.recentWeek ? 7 : 3650,
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
    final key = _currentCandidateKey;
    if (key == _candidateKey && candidates != null) return;
    try {
      // An index already in memory is filtered synchronously: no await, so a
      // test clock (or the first frame) cannot observe a half-done state.
      // The scope is the whole filter, not a part of it: the fast path must
      // answer exactly what the classic path would, or it is not the same list.
      final scope = candidateScope();
      if (rangeSession.hasIndex) {
        candidates = rangeSession.candidatesNow(scope: scope, at: DateTime.now());
        _candidateKey = key;
        _notify();
        return;
      }
      final set = await rangeSession.candidates(scope: scope, at: DateTime.now());
      if (disposed) return;
      // A newer question may have been asked while this one was being answered.
      if (key != _currentCandidateKey) return;
      candidates = set;
      _candidateKey = key;
      _notify();
    } catch (e, stack) {
      // The classic filter still answers; a fast path is never a hard failure.
      AppLogger.instance.capture(e, stack, section: 'candidates');
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

  Future<void> reload() async {
    quotes = await store.latest();
    states = await store.syncStates();
    _notify();
    // Only after startup is complete: the index read must never sit in front of
    // the first prices on screen (both share one SQLite connection).
    if (ready) {
      unawaited(prepareCandidates());
      unawaited(warmRangeIndex());
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

  Future<void> setAuto(bool value) async {
    // Legacy method retained; background/network auto-refresh is disabled.
    autoRefresh = false;
    await store.setSetting('autoRefresh', 'false');
    _notify();
  }

  Future<void> refresh() async {
    if (busy || transferring || disposed) return;
    busy = true;
    historyRevision++;
    unawaited(AppLogger.instance
        .record('network', 'refresh_started', {'sources': enabled.length}));
    finished = 0;
    _notify();
    final queue =
        availableEndpoints.where((e) => enabled.contains(e.id)).toList();
    var index = 0;
    Future<void> worker() async {
      while (index < queue.length && !disposed) {
        final e = queue[index++];
        try {
          final data = await client.fetch(e);
          await store.saveSnapshot(e.id, data,
              replaceMissing: client.complete[e.id] ?? true);
          // Fresh rows are derived at write time; drop the previous answers.
          rangeSession.invalidate();
          await rememberSources(client.discoveries[e.id] ?? []);
          historyRevision++;
          endpointRevisions.update(e.id, (n) => n + 1, ifAbsent: () => 1);
          // Publish successful sources immediately; all-ON must not wait for
          // the slowest source before showing the first received prices.
          await reload();
        } catch (error, stack) {
          AppLogger.instance.capture(error, stack, section: 'source');
          await store.failure(
              e.id,
              error is FormatException
                  ? error.message
                  : 'خطا در اتصال/مهلت دریافت؛ داده قبلی حفظ شد.');
        }
        finished++;
        states = await store.syncStates();
        _notify();
        // Low concurrency, no login/CAPTCHA bypass or aggressive retries.
        await Future<void>.delayed(const Duration(milliseconds: 450));
      }
    }

    try {
      await Future.wait([worker(), worker()]);
      await store.setSetting(
          'lastRefresh', DateTime.now().toUtc().toIso8601String());
    } finally {
      busy = false;
      await reload();
      unawaited(AppLogger.instance.record('network', 'refresh_complete',
          {'completed': finished, 'cachedRows': quotes.length}));
    }
  }

  @override
  void dispose() {
    disposed = true;

    client.close();
    super.dispose();
  }
}

List<Quote> _filterInBackground(Map<String, Object> input) =>
    (input['filter'] as MarketFilter)
        .apply(input['quotes'] as List<Quote>, input['now'] as DateTime);
