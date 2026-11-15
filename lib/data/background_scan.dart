import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import '../domain/maps_resolver.dart';
import '../domain/ocr.dart';
import '../domain/photo_scan.dart';
import '../domain/searcher.dart';
import 'source_finder_io.dart';
import 'sources.dart';
import 'store.dart';

const _taskName = 'ironpin.periodic.public-scan';
const _uniqueName = 'ironpin-periodic-public-scan';
const _finderTask = 'ironpin.periodic.source-finder';
const _finderUnique = 'ironpin-periodic-source-finder';
const _connectTask = 'ironpin.oneoff.connect-finder';
const _connectUnique = 'ironpin-connect-finder';

class ScanBatch {
  final List<SourceEndpoint> sources;
  final int nextCursor;
  const ScanBatch(this.sources, this.nextCursor);
}

/// Selects a bounded, rotating slice without adding disabled routes.
ScanBatch selectScanBatch(List<SourceEndpoint> enabled, int cursor,
    {int size = 16}) {
  if (enabled.isEmpty || size <= 0) return const ScanBatch([], 0);
  final count = size < enabled.length ? size : enabled.length;
  final start = ((cursor % enabled.length) + enabled.length) % enabled.length;
  return ScanBatch(
      [for (var i = 0; i < count; i++) enabled[(start + i) % enabled.length]],
      (start + count) % enabled.length);
}

@pragma('vm:entry-point')
void callbackDispatcher() {
  WidgetsFlutterBinding.ensureInitialized();
  Workmanager().executeTask((task, inputData) async {
    if (task == _finderTask) return runFinderBackground();
    if (task == _connectTask) return runFinderBackground(onConnect: true);
    if (task != _taskName) return true;
    return runBackgroundScan();
  });
}

class BackgroundScanScheduler {
  static bool _initialized = false;
  static Future<void> Function(
      {required bool enabled, required int intervalMinutes})? configureOverride;

  static Future<void> initialize() async {
    if (_initialized || configureOverride != null) return;
    await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);
    _initialized = true;
  }

  static Future<void> configure(
      {required bool enabled, required int intervalMinutes}) async {
    final override = configureOverride;
    if (override != null) {
      await override(enabled: enabled, intervalMinutes: intervalMinutes);
      return;
    }
    await initialize();
    if (!enabled) {
      await Workmanager().cancelByUniqueName(_uniqueName);
      return;
    }
    final interval =
        [15, 30, 60].contains(intervalMinutes) ? intervalMinutes : 30;
    await Workmanager().registerPeriodicTask(
      _uniqueName,
      _taskName,
      existingWorkPolicy: ExistingWorkPolicy.replace,
      frequency: Duration(minutes: interval),
      constraints: Constraints(networkType: NetworkType.connected),
    );
  }

  /// The list builder's own task: every 15 minutes while connected, plus an
  /// immediate network-constrained one-off wakeup so connecting to the internet
  /// activates Smart Search 2 even when the app is in the background.
  static Future<void> configureFinder({required bool enabled}) async {
    if (configureOverride != null) return;
    await initialize();
    if (!enabled) {
      await Workmanager().cancelByUniqueName(_finderUnique);
      await Workmanager().cancelByUniqueName(_connectUnique);
      return;
    }
    await Workmanager().registerPeriodicTask(
      _finderUnique,
      _finderTask,
      existingWorkPolicy: ExistingWorkPolicy.keep,
      frequency: const Duration(minutes: 15),
      initialDelay: const Duration(seconds: 20),
      constraints: Constraints(networkType: NetworkType.connected),
    );
    await armConnectWakeup(enabled: true);
  }

  /// Registers a one-off task constrained to [NetworkType.connected] so Android
  /// JobScheduler / WorkManager triggers Smart Search 2 as soon as connectivity
  /// returns.
  static Future<void> armConnectWakeup({
    required bool enabled,
    Duration initialDelay = Duration.zero,
  }) async {
    if (configureOverride != null) return;
    await initialize();
    if (!enabled) {
      await Workmanager().cancelByUniqueName(_connectUnique);
      return;
    }
    await Workmanager().registerOneOffTask(
      _connectUnique,
      _connectTask,
      existingWorkPolicy: ExistingWorkPolicy.replace,
      initialDelay: initialDelay,
      constraints: Constraints(networkType: NetworkType.connected),
    );
  }
}

List<SourceEndpoint> _decodeDiscovered(String? rawJson) {
  if (rawJson == null || rawJson.isEmpty) return const [];
  final out = <SourceEndpoint>[];
  try {
    for (final item in (jsonDecode(rawJson) as List).cast<Map>()) {
      final source =
          publicChannel(item['url'] as String, name: item['name'] as String?);
      if (source != null) out.add(source);
    }
  } catch (_) {
    // Bad discovery metadata never adds a route or blocks registered work.
  }
  return out;
}

/// Continues the lists of هوش جستجوگر ۲ while the app is closed.
Future<bool> runFinderBackground({bool onConnect = false}) async {
  MarketStore? store;
  final client = SourceClient(maxChannelPages: 2);
  try {
    store = await MarketStore.open();
    if (await store.setting('finder.enabled') == 'false') return true;
    final finder = SourceFinder(store, client: client.client);
    await finder.load();
    final discovered = _decodeDiscovered(await store.setting('discoveredSources'));
    await finder.registerKnownEndpoints(discovered);
    if (onConnect) {
      await finder.onNetworkConnected();
    }
    final days = int.tryParse(await store.setting('windowDays') ?? '') ?? 30;
    // First hand over anything already waiting in `در نوبت`.
    var accepted = 0;
    if (finder.handoffBatch(limit: 1).isNotEmpty) {
      accepted += await deliverFinderBatch(store, client, finder,
          windowDays: days, limit: 6, alreadyLocked: false);
    }
    if (finder.handoffBatch(limit: 1).isEmpty) {
      await finder.ensureSearchingWhenQueueEmpty(drainedJustNow: accepted > 0);
    }
    final report = await finder.runSlice(
        maxSteps: 16, budget: const Duration(seconds: 35));
    if (!report.offline && finder.handoffBatch(limit: 1).isNotEmpty) {
      final more = await deliverFinderBatch(store, client, finder,
          windowDays: days, limit: 6, alreadyLocked: false);
      if (more > 0 && finder.handoffBatch(limit: 1).isEmpty) {
        await finder.ensureSearchingWhenQueueEmpty(drainedJustNow: true);
      }
    }
    // Re-arm for the next internet connection transition.
    try {
      await BackgroundScanScheduler.armConnectWakeup(
          enabled: true,
          initialDelay: report.offline
              ? const Duration(seconds: 15)
              : const Duration(minutes: 3));
    } catch (_) {}
    return true;
  } catch (_) {
    return false;
  } finally {
    client.close();
    // No store.close(): the UI isolate shares the same native handle.
  }
}

/// Executes one OS-scheduled batch. The same persisted lease protects against
/// overlap with a manual refresh or another worker invocation.
Future<bool> runBackgroundScan() async {
  MarketStore? store;
  final client = SourceClient(maxChannelPages: 2);
  // The same automatic picture reading as a manual refresh. Inside the
  // WorkManager isolate Flutter plugins are not registered, so the scanner marks
  // itself blocked and the posts keep their own rows until a foreground scan.
  final photos = PhotoScanner(
      client: client.client, engine: OcrEngine.platform());
  String? lease;
  Timer? heartbeat;
  try {
    store = await MarketStore.open();
    if (await store.setting('autoRefresh') != 'true') return true;
    final rawEnabled = await store.setting('enabled');
    final enabledIds = rawEnabled == null
        ? endpoints.map((e) => e.id).toSet()
        : (jsonDecode(rawEnabled) as List).cast<String>().toSet();
    final discovered =
        _decodeDiscovered(await store.setting('discoveredSources'));
    // Sources the list builder found and هوش جستجوگر ۱ accepted are routes
    // too; one accepted while the app was closed is read here even before
    // the app has switched it on.
    final finder = SourceFinder(store, client: client.client);
    var finderOn = false;
    final fresh = <String>{};
    final accepted = <SourceEndpoint>[];
    try {
      finderOn = await store.setting('finder.enabled') != 'false';
      await finder.load();
      await finder.registerKnownEndpoints(discovered);
      accepted.addAll(finder.acceptedEndpoints());
      fresh.addAll(
          finder.acceptedEndpoints(onlyUnapplied: true).map((e) => e.id));
    } catch (_) {
      // A damaged list never blocks the registered routes.
    }
    final ids = <String>{};
    final keys = <String>{};
    final all = [
      for (final e in [...endpoints, ...discovered, ...accepted])
        if (ids.add(e.id) && keys.add(endpointCanonicalKey(e))) e
    ];
    final enabled = all
        .where((e) => enabledIds.contains(e.id) || fresh.contains(e.id))
        .toList();
    final cursor =
        int.tryParse(await store.setting('backgroundScanCursor') ?? '') ?? 0;
    final batch = selectScanBatch(enabled, cursor, size: 16);
    if (batch.sources.isEmpty) return true;
    lease = await store.acquireRefreshLock();
    if (lease == null) return true;
    // Renew our own lease while this batch runs. Without it, a batch that the OS
    // killed mid-scan held the lock until the lease ran out, and every later
    // refresh (foreground or background) silently did nothing.
    heartbeat = Timer.periodic(MarketStore.refreshLockHeartbeat,
        (_) => unawaited(store!.renewRefreshLock(lease!)));

    var completed = 0;
    final days = int.tryParse(await store.setting('windowDays') ?? '') ?? 30;
    for (final endpoint in batch.sources) {
      try {
        final fetched =
            await client.fetch(endpoint, windowDays: days, pageLimit: 2);
        final batch = await readPostPhotos(fetched, photos,
            defaultCurrency: endpoint.defaultCurrency);
        if (batch.read > 0) {
          await store.setSetting('lastPhotoScanCount', '${batch.read}');
        }
        final quotes = batch.rows;
        // The same searcher rules apply in the background: only in-window,
        // product-bearing rows with a resolved place enter the archive, and an
        // empty result never wipes the rows already stored.
        final found = quotes.isEmpty
            ? const SearcherResult([])
            : await Searcher.processAsync(quotes,
                now: DateTime.now(),
                windowDays: days,
                resolver: MapsResolver(client.client));
        if (found.quotes.isEmpty) {
          await store.note(
              endpoint.id,
              quotes.isEmpty
                  ? 'اسکن پس‌زمینه ردیف قیمتی پیدا نکرد؛ داده قبلی حفظ شد.'
                  : 'ردیف قابل‌ثبت نبود (بیرون از بازه: ${found.outOfWindow} • '
                      'بی‌قیمت/بی‌محصول: ${found.noise})؛ داده قبلی حفظ شد.');
          continue;
        }
        await store.saveSnapshot(endpoint.id, found.quotes,
            replaceMissing: client.complete[endpoint.id] ?? true);
        completed++;
      } catch (error) {
        await store.failure(
            endpoint.id,
            error is FormatException
                ? error.message
                : 'خطا در اسکن پس‌زمینه؛ داده قبلی حفظ شد.');
      }
    }
    if (finderOn) {
      try {
        final more = await deliverFinderBatch(store, client, finder,
            windowDays: days, limit: 5, alreadyLocked: true);
        if (finder.handoffBatch(limit: 1).isEmpty) {
          await finder.ensureSearchingWhenQueueEmpty(drainedJustNow: more > 0);
        }
      } catch (_) {
        // Hand-over is retried by the next run.
      }
    }
    await store.setSetting('backgroundScanCursor', '${batch.nextCursor}');
    await store.setSetting(
        'lastBackgroundScan', DateTime.now().toUtc().toIso8601String());
    await store.setSetting('lastBackgroundScanCount', '$completed');
    return true;
  } catch (_) {
    return false;
  } finally {
    heartbeat?.cancel();
    client.close();
    if (lease != null && store != null) {
      try {
        await store.releaseRefreshLock(lease);
      } catch (_) {
        // Lease expiry recovers if the database was interrupted.
      }
    }
    // Deliberately no store.close() here. sqflite keeps one native handle per
    // database path per process, so closing it from this background isolate also
    // closed the handle the UI isolate was using: the next manual refresh then
    // failed with database_closed and looked like "refresh stopped working".
  }
}
