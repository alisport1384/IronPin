import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironpin/data/app_logger.dart';
import 'package:ironpin/data/range_session.dart';
import 'package:ironpin/data/store.dart';
import 'package:ironpin/domain/range_worker.dart';
import 'package:ironpin/domain/row_facts.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'archive_loading_test.dart' as fixture;

class GatedIndexStore extends MarketStore {
  GatedIndexStore(super.db);
  final started = Completer<void>();
  final release = Completer<void>();
  final requests = <int>[];
  @override
  Future<List<Map<String, Object?>>> rangeIndexRows(DateTime now,
      {int windowDays = 0}) async {
    requests.add(windowDays);
    if (requests.length == 1) {
      started.complete();
      await release.future;
    }
    return [
      {'id': 'window$windowDays'}
    ];
  }
}

class NoBulkPayloadStore extends MarketStore {
  NoBulkPayloadStore(super.db);
  @override
  Future<List<String>> rangePayloads(DateTime now, {int windowDays = 0}) =>
      throw StateError('The index reader must not bulk-load archive payloads');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test('overlapping 48-hour and 30-day requests cannot mislabel one snapshot',
      () async {
    final opened = await MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
    final store = GatedIndexStore(opened.db);
    final session = RangeSession(store);
    try {
      final first = session.ensureIndex(DateTime.now());
      await store.started.future;
      final second = session.ensureIndex(DateTime.now(), windowDays: 30);
      store.release.complete();
      await Future.wait([first, second]);
      expect(store.requests, [0, 30]);
      expect(session.hasIndexFor(30), isTrue);
      expect(session.indexRowsSnapshot.single['id'], 'window30');
    } finally {
      await store.close();
    }
  });

  test('invalidation discards old in-flight rows and permits a new generation',
      () async {
    final opened = await MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
    final store = GatedIndexStore(opened.db);
    final session = RangeSession(store);
    try {
      final first = session.ensureIndex(DateTime.now());
      final rejected = expectLater(first, throwsStateError);
      await store.started.future;
      session.invalidate();
      final second = session.ensureIndex(DateTime.now(), windowDays: 30);
      store.release.complete();
      await rejected;
      await second;
      expect(store.requests, [0, 30]);
      expect(session.indexRowsSnapshot.single['id'], 'window30');
    } finally {
      await store.close();
    }
  });

  test('same-window concurrent index callers share one read', () async {
    final opened = await MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
    final store = GatedIndexStore(opened.db);
    final session = RangeSession(store);
    try {
      final first = session.ensureIndex(DateTime.now(), windowDays: 30);
      await store.started.future;
      final second = session.ensureIndex(DateTime.now(), windowDays: 30);
      store.release.complete();
      await Future.wait([first, second]);
      expect(store.requests, [30]);
    } finally {
      await store.close();
    }
  });

  test('paged index matches full selection including duplicates and orphans',
      () async {
    final opened = await MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
    final store = NoBulkPayloadStore(opened.db);
    try {
      await opened.saveSnapshot(
          'large', [for (var n = 0; n < 1250; n++) fixture.offer('large', n)]);
      await opened.saveSnapshot('orphan', [fixture.offer('orphan', 1)]);
      await opened.db
          .delete('latest', where: 'endpoint=?', whereArgs: ['orphan']);
      final at = DateTime.utc(2026, 11, 9, 12);
      final expected = (await opened.rangePayloads(at, windowDays: 30))
          .map(payloadFingerprint)
          .toList();
      await opened.db
          .delete('range_index'); // exercise chunked cold rebuild too
      final cold = await store.rangeIndexRows(at, windowDays: 30);
      expect(cold.map((r) => r['payload']).toList(), expected);
      final warm = await store.rangeIndexRows(at, windowDays: 30);
      expect(warm.map((r) => r['payload']).toList(), expected);
      expect((await opened.latest()).length, 1250);
      expect(await opened.historyCount(), 1251);
      expect(
          await opened.db.rawQuery(
              "SELECT name FROM sqlite_temp_master WHERE name='ironpin_range_read'"),
          isEmpty);
      expect(RangeWorker.shared.isLoaded, isFalse);
    } finally {
      await store.close();
    }
  });

  test(
      'runtime checkpoint survives reopening and contains bounded RSS metadata',
      () async {
    final dir = await Directory.systemTemp.createTemp('ironpin-checkpoint-');
    final logger = AppLogger();
    final next = AppLogger();
    try {
      await logger.initialize(directory: dir);
      await logger.checkpoint('refresh_sources_saved', rows: 12000);
      final path = File('${dir.path}/IronPin-runtime.md');
      final before = await path.readAsString();
      final data = jsonDecode(before.split('\n')[1]) as Map;
      expect(data['rows'], 12000);
      expect(data['rssBytes'], greaterThan(0));
      expect(await path.length(), lessThan(4096));
      await next.initialize(directory: dir);
      expect(await path.exists(), isTrue);
      await next.checkpoint('startup');
      String summary = '';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AppLogger.platform, (call) async {
        for (final p in call.arguments['paths'] as List) {
          final text = await File(p as String).readAsString();
          if (text.contains('session summary')) summary = text;
        }
        return null;
      });
      await next.export();
      expect(summary, contains('refresh_sources_saved'));
      expect(summary, contains('checkpoint from previous process'));
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AppLogger.platform, null);
      await logger.flush();
      await next.flush();
      await dir.delete(recursive: true);
    }
  });

  test('export includes error stack even when product logs already exist',
      () async {
    final dir = await Directory.systemTemp.createTemp('ironpin-stack-');
    final logger = AppLogger(enabled: true);
    try {
      await logger.initialize(directory: dir);
      await logger.record('source', 'example', {'rows': 3});
      logger.capture(StateError('test failure'),
          StackTrace.fromString('frame_one\nframe_two'));
      String report = '';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AppLogger.platform, (call) async {
        for (final p in call.arguments['paths'] as List) {
          report += await File(p as String).readAsString();
        }
        return null;
      });
      await logger.export();
      expect(report, contains('test failure'));
      expect(report, contains('frame_one'));
      expect(report, contains('frame_two'));
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AppLogger.platform, null);
      await logger.flush();
      await dir.delete(recursive: true);
    }
  });
}
