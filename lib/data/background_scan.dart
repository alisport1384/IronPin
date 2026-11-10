import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import 'sources.dart';
import 'store.dart';

const _taskName = 'ironpin.periodic.public-scan';
const _uniqueName = 'ironpin-periodic-public-scan';

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
}

/// Executes one OS-scheduled batch. The same persisted lease protects against
/// overlap with a manual refresh or another worker invocation.
Future<bool> runBackgroundScan() async {
  MarketStore? store;
  final client = SourceClient(maxChannelPages: 2);
  String? lease;
  try {
    store = await MarketStore.open();
    if (await store.setting('autoRefresh') != 'true') return true;
    final rawEnabled = await store.setting('enabled');
    final enabledIds = rawEnabled == null
        ? endpoints.map((e) => e.id).toSet()
        : (jsonDecode(rawEnabled) as List).cast<String>().toSet();
    final discoveredJson = await store.setting('discoveredSources');
    final discovered = <SourceEndpoint>[];
    if (discoveredJson != null) {
      try {
        for (final item in (jsonDecode(discoveredJson) as List).cast<Map>()) {
          final source = publicChannel(item['url'] as String,
              name: item['name'] as String?);
          if (source != null) discovered.add(source);
        }
      } catch (_) {
        // Bad discovery metadata never adds a route or blocks registered work.
      }
    }
    final all = [...endpoints, ...discovered];
    final enabled = all.where((e) => enabledIds.contains(e.id)).toList();
    final cursor =
        int.tryParse(await store.setting('backgroundScanCursor') ?? '') ?? 0;
    final batch = selectScanBatch(enabled, cursor, size: 16);
    if (batch.sources.isEmpty) return true;
    lease = await store.acquireRefreshLock();
    if (lease == null) return true;

    var completed = 0;
    final days = int.tryParse(await store.setting('windowDays') ?? '') ?? 30;
    for (final endpoint in batch.sources) {
      try {
        final quotes =
            await client.fetch(endpoint, windowDays: days, pageLimit: 2);
        await store.saveSnapshot(endpoint.id, quotes,
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
    await store.setSetting('backgroundScanCursor', '${batch.nextCursor}');
    await store.setSetting(
        'lastBackgroundScan', DateTime.now().toUtc().toIso8601String());
    await store.setSetting('lastBackgroundScanCount', '$completed');
    return true;
  } catch (_) {
    return false;
  } finally {
    client.close();
    if (lease != null && store != null) {
      try {
        await store.releaseRefreshLock(lease);
      } catch (_) {
        // Lease expiry recovers if the database was interrupted.
      }
    }
    if (store != null) await store.close();
  }
}
