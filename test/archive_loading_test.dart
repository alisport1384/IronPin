import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironpin/data/controller.dart';
import 'package:ironpin/data/sources.dart';
import 'package:ironpin/data/store.dart';
import 'package:ironpin/domain/market.dart';
import 'package:ironpin/domain/range_worker.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Quote offer(String endpoint, int n) => Quote(
      id: '$endpoint:$n',
      endpoint: endpoint,
      seller: 'test',
      title: 'میلگرد',
      category: 'میلگرد',
      unit: 'kg',
      amount: 100 + n.toDouble(),
      currency: 'تومان',
      sourceUrl: 'https://example.com/$n',
      sourceDateRaw: '2026-11-09T08:00:00Z',
      fetchedAt: DateTime.utc(2026, 11, 9, 9),
    );

class LocalClient extends SourceClient {
  @override
  Future<List<Quote>> fetch(SourceEndpoint endpoint,
          {int windowDays = 30}) async =>
      [offer(endpoint.id, 1)];
}

class ObservedStore extends MarketStore {
  ObservedStore(super.db);
  int fullReads = 0;
  bool failOnce = false;
  @override
  Future<List<Quote>> latest() {
    fullReads++;
    return super.latest();
  }

  @override
  Future<List<Quote>> latestFor(String endpoint) async {
    // Keep one publication pending while the other network worker finishes.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    if (failOnce) {
      failOnce = false;
      throw StateError('simulated publication failure');
    }
    return super.latestFor(endpoint);
  }
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
  });

  test('refresh publishes both workers without rereading unchanged archive',
      () async {
    final opened = await MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
    final store = ObservedStore(opened.db);
    await store.saveSnapshot('untouched', [offer('untouched', 1)]);
    final c = MarketController(store, client: LocalClient());
    c.enabled = {'melal-rebar', 'melal-sheet'};
    final seen = <String>{};
    c.addListener(() {
      if (c.busy) seen.addAll(c.quotes.map((q) => q.endpoint));
    });
    try {
      await c.reload();
      final original = c.quotes.single;
      await c.refresh();
      expect(store.fullReads, 1);
      expect(RangeWorker.shared.isLoaded, isFalse,
          reason: 'refresh must not eagerly copy the index to a range worker');
      expect(seen, containsAll(c.enabled));
      expect(c.quotes.map((q) => q.id).toSet(),
          (await opened.latest()).map((q) => q.id).toSet());
      expect(
          identical(
              c.quotes.firstWhere((q) => q.endpoint == 'untouched'), original),
          isTrue);
      // Drain background index work before closing its database.
      await c.rangeSession
          .ensureIndex(DateTime.now(), windowDays: c.rangeWindow);
    } finally {
      c.dispose();
      await store.close();
    }
  });

  test('publication failure reconciles disk and does not poison next refresh',
      () async {
    final opened = await MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
    final store = ObservedStore(opened.db)..failOnce = true;
    final c = MarketController(store, client: LocalClient());
    c.enabled = {'melal-rebar', 'melal-sheet'};
    try {
      await c.refresh();
      expect(store.fullReads, 2); // initial baseline + failure reconciliation
      expect(c.quotes.length, 2);
      await c.refresh();
      expect(store.fullReads, 2);
      expect(c.quotes.length, 2);
      await c.rangeSession
          .ensureIndex(DateTime.now(), windowDays: c.rangeWindow);
    } finally {
      c.dispose();
      await store.close();
    }
  });

  test('multiple index chunks persist all rows and roll back together on error',
      () async {
    final store = await MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
    try {
      await store.saveSnapshot(
          'large', [for (var i = 0; i < 850; i++) offer('large', i)]);
      expect((await store.latestFor('large')).length, 850);
      expect(await store.historyCount(), 850);
      expect((await store.db.query('range_index')).length, 850);
      await store.db.execute('''CREATE TRIGGER reject_later_chunk
        BEFORE INSERT ON range_index WHEN NEW.id='broken:500'
        BEGIN SELECT RAISE(ABORT, 'test rollback'); END''');
      await expectLater(
          store.saveSnapshot(
              'broken', [for (var i = 0; i < 850; i++) offer('broken', i)]),
          throwsA(isA<DatabaseException>()));
      expect(await store.latestFor('broken'), isEmpty);
      expect(await store.historyCount(), 850);
      expect((await store.db.query('range_index')).length, 850);
    } finally {
      await store.close();
    }
  });

  test('v6 upgrade adds endpoint index without rewriting prices or history',
      () async {
    final dir = await Directory.systemTemp.createTemp('ironpin-migration-');
    final path = '${dir.path}/market.db';
    var store =
        await MarketStore.open(dbPath: path, factory: databaseFactoryFfi);
    try {
      await store.saveSnapshot('e', [offer('e', 1)]);
      final payload = (await store.db.query('latest')).single['payload'];
      await store.db.execute('DROP INDEX latest_endpoint_active');
      await store.db.execute('PRAGMA user_version=6');
      await store.close();
      store = await MarketStore.open(dbPath: path, factory: databaseFactoryFfi);
      expect((await store.db.query('latest')).single['payload'], payload);
      expect(await store.historyCount(), 1);
      final plan = await store.db.rawQuery(
          'EXPLAIN QUERY PLAN SELECT payload FROM latest WHERE endpoint=? AND active=1',
          ['e']);
      expect(plan.toString(), contains('latest_endpoint_active'));
    } finally {
      await store.close();
      await dir.delete(recursive: true);
    }
  });
}
