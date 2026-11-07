import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../domain/market.dart';
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
  void historyChanged() {
    historyRevision++;
    historyEpoch++;
    _notify();
  }

  String? startupError;
  bool transferring = false;
  final Map<String, int> endpointRevisions = {};
  int historyEpoch = 0;
  MarketController(this.store, {SourceClient? client})
      : client = client ?? SourceClient();
  Future<void> init() async {
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
    if (await store.setting('allRegisteredSourcesEnabledVersion') != '2') {
      enabled.addAll(availableEndpoints.map((e) => e.id));
      await store.setSetting('enabled', jsonEncode(enabled.toList()));
      await store.setSetting('allRegisteredSourcesEnabledVersion', '2');
    }
    autoRefresh = false;
    await store.setSetting('autoRefresh', 'false');
    await reload();
    ready = true;
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
    _notify();
  }

  List<Quote> _filtered = [];
  String _filterKey = '';
  bool filtering = false;
  String get _currentFilterKey =>
      '${identityHashCode(quotes)}:${filter.cacheKey}:${DateTime.now().millisecondsSinceEpoch ~/ 60000}';
  List<Quote> get filtered {
    final key = _currentFilterKey;
    if (key == _filterKey) return _filtered;
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
  }

  void transferState(bool value) {
    transferring = value;
    _notify();
  }

  Future<void> imported() async {
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
