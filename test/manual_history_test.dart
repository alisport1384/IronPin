import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ironpin/data/controller.dart';
import 'package:ironpin/data/sources.dart';
import 'package:ironpin/data/store.dart';
import 'package:ironpin/domain/market.dart';
import 'package:ironpin/main.dart';

Quote point(int n) => Quote(
    id: 'series',
    endpoint: 'e',
    seller: 'فروشنده',
    title: 'میلگرد ۱۶',
    category: 'میلگرد',
    brand: 'نیشابور',
    size: '16',
    grade: 'A3',
    unit: 'kg',
    amount: 100 + n.toDouble(),
    sourceDateRaw: '2026-11-06T08:00:00Z',
    sourceUrl: 'https://example.com',
    fetchedAt: DateTime.utc(2026, 11, 1).add(Duration(minutes: n)));
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  test(
      'legacy automatic setting, init, re-init, setAuto and transfer never fetch',
      () async {
    var requests = 0;
    final raw =
        File('test/fixtures/hayper_sheets_observed.html').readAsStringSync();
    final store = await MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
    await store.setSetting('autoRefresh', 'true');
    final c = MarketController(store,
        client: SourceClient(client: MockClient((_) async {
      requests++;
      return http.Response(raw, 200,
          headers: {'content-type': 'text/html; charset=utf-8'});
    })));
    try {
      await c.init();
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(c.autoRefresh, false);
      expect(requests, 0);
      expect(await store.setting('autoRefresh'), 'false');
      await c.setAuto(true);
      expect(c.autoRefresh, false);
      expect(requests, 0);
      c.enabled = {'telegram-hayperahan'};
      c.transferState(true);
      await c.refresh();
      expect(requests, 0);
      c.transferState(false);
      await c.refresh();
      expect(requests, greaterThan(0));
      final manualCount = requests;
      await c.imported();
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(requests, manualCount);
    } finally {
      c.dispose();
      await store.close();
    }
  });
  testWidgets(
      'no pull-to-refresh or resume network; only toolbar button fetches',
      (t) async {
    var requests = 0;
    final store = await t.runAsync(() => MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi));
    final c = MarketController(store!,
        client: SourceClient(client: MockClient((_) async {
      requests++;
      return http.Response('offline test: no rates', 200);
    })));
    c.enabled = {'telegram-hayperahan'};
    addTearDown(() async {
      c.dispose();
      await store.close();
    });
    await t.pumpWidget(IronPinApp(controller: c));
    await t.pumpAndSettle();
    expect(find.byType(RefreshIndicator), findsNothing);
    await t.drag(find.byType(ListView).first, const Offset(0, 300));
    await t.pumpAndSettle();
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpAndSettle();
    expect(requests, 0);
    await t.runAsync(() async {
      await t.tap(find.byTooltip('نوسازی قیمت‌ها'));
      await Future<void>.delayed(const Duration(milliseconds: 900));
    });
    await t.pumpAndSettle();
    expect(requests, 1);
    expect(t.takeException(), isNull);
  });
  test(
      'indexed 12000-point history returns only latest 1000, preserving full data',
      () async {
    final store = await MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
    try {
      final batch = store.db.batch();
      for (var i = 0; i < 12000; i++) {
        final q = point(i);
        batch.insert('history', {
          'id': q.id,
          'captured_at': q.fetchedAt.toUtc().toIso8601String(),
          'signature': q.signature,
          'payload': jsonEncode(q.toJson()),
          'market_at': q.marketAt!.toIso8601String()
        });
      }
      await batch.commit(noResult: true);
      var ticks = 0;
      final timer =
          Timer.periodic(const Duration(milliseconds: 1), (_) => ticks++);
      final watch = Stopwatch()..start();
      final tail = await store.history('series', limit: 1000);
      final tailMs = watch.elapsedMilliseconds;
      expect(tail.length, 1000);
      expect(tail.first.amount, 11100);
      expect(tail.last.amount, 12099);
      watch.reset();
      final all = await store.history('series');
      final fullMs = watch.elapsedMilliseconds;
      timer.cancel();
      expect(all.length, 12000);
      expect(ticks, greaterThan(0));
      final plan = await store.db.rawQuery(
          'EXPLAIN QUERY PLAN SELECT payload FROM history WHERE id=? ORDER BY captured_at DESC,seq DESC LIMIT 1000',
          ['series']);
      expect(plan.toString(), contains('history_id_time'));
      final rangePlan = await store.db.rawQuery(
          'EXPLAIN QUERY PLAN SELECT payload FROM history WHERE market_at>=? AND market_at<=?',
          ['2026-11-04', '2026-11-07']);
      expect(rangePlan.toString(), contains('history_market_time'));
      // Host timing is diagnostic, never a fabricated phone FPS claim.
      // ignore: avoid_print
      print(
          'HISTORY_METRIC total=12000 initial=1000 tailMs=$tailMs fullMs=$fullMs timerTicks=$ticks');
    } finally {
      await store.close();
    }
  });
  test(
      'real schema-2 upgrade backfills indexed dates without touching payload/history/settings',
      () async {
    final dir = await Directory.systemTemp.createTemp('ironpin-upgrade-');
    final path = '${dir.path}/old.db';
    final q = point(1);
    final payload = jsonEncode(q.toJson());
    final db = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(
            version: 2,
            onCreate: (db, _) async {
              await db.execute(
                  'CREATE TABLE latest(id TEXT PRIMARY KEY,endpoint TEXT NOT NULL,payload TEXT NOT NULL,active INTEGER NOT NULL DEFAULT 1)');
              await db.execute(
                  'CREATE TABLE history(seq INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT NOT NULL,captured_at TEXT NOT NULL,signature TEXT NOT NULL,payload TEXT NOT NULL)');
              await db.execute(
                  'CREATE INDEX history_id_time ON history(id,captured_at)');
              await db
                  .execute('CREATE INDEX history_id_seq ON history(id,seq)');
              await db.execute(
                  'CREATE TABLE settings(key TEXT PRIMARY KEY,value TEXT NOT NULL)');
              await db.execute(
                  'CREATE TABLE sync(endpoint TEXT PRIMARY KEY,attempted_at TEXT NOT NULL,success_at TEXT,message TEXT NOT NULL)');
              await db.insert('latest', {
                'id': q.id,
                'endpoint': q.endpoint,
                'payload': payload,
                'active': 1
              });
              await db.insert('history', {
                'id': q.id,
                'captured_at': q.fetchedAt.toUtc().toIso8601String(),
                'signature': q.signature,
                'payload': payload
              });
              await db.insert('settings', {'key': 'enabled', 'value': '[]'});
            }));
    await db.close();
    final store =
        await MarketStore.open(dbPath: path, factory: databaseFactoryFfi);
    try {
      // Schema 5 adds the derived range index on top of the schema-3 backfill,
      // and the derivation columns the prices tab filters on.
      expect(await store.db.getVersion(), 5);
      expect(await store.historyCount(), 1);
      final row = (await store.db.query('history')).single;
      expect(row['payload'], payload);
      expect(row['market_at'], q.marketAt!.toIso8601String());
      expect((await store.db.query('latest')).single['payload'], payload);
      expect(await store.setting('enabled'), '[]');
    } finally {
      await store.close();
      await dir.delete(recursive: true);
    }
  });
}
