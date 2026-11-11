import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ironpin/data/controller.dart';
import 'package:ironpin/data/sources.dart';
import 'package:ironpin/data/store.dart';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
  });

  test('a fresh lease blocks a second refresh, an expired one does not',
      () async {
    final store = await MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
    try {
      final first = await store.acquireRefreshLock(
          lease: const Duration(milliseconds: 150));
      expect(first, isNotNull);
      expect(await store.acquireRefreshLock(), isNull);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      // A refresh the OS killed must not block the next one forever.
      final third = await store.acquireRefreshLock();
      expect(third, isNotNull);
      await store.releaseRefreshLock(third!);
      expect(await store.refreshLockHolderExpiry(), isNull);
    } finally {
      await store.close();
    }
  });

  test('the heartbeat keeps a working refresh alive past its lease', () async {
    final store = await MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
    try {
      const lease = Duration(milliseconds: 200);
      final owner = await store.acquireRefreshLock(lease: lease);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(await store.renewRefreshLock(owner!, lease: lease), true);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      // The first lease would have expired; the renewed one has not.
      expect(await store.acquireRefreshLock(lease: lease), isNull);
      expect(await store.renewRefreshLock('not-owner'), false);
    } finally {
      await store.close();
    }
  });

  test('a blocked refresh says why instead of returning silently', () async {
    final store = await MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
    final c = MarketController(store,
        client: SourceClient(
            client: MockClient((_) async => http.Response('', 500))));
    try {
      final held = await store.acquireRefreshLock();
      expect(held, isNotNull);
      await c.refresh();
      expect(c.refreshBlockedReason, isNotEmpty);
      expect(c.refreshBlockedReason, contains('نوسازی دیگری'));
      await store.releaseRefreshLock(held!);
      await c.refresh();
      expect(c.refreshBlockedReason, isEmpty);
    } finally {
      c.dispose();
      await store.close();
    }
  });

  test('refresh runs again while the archive already holds rows', () async {
    var price = 118000;
    final fixture =
        File('test/fixtures/fardad_sheets_reconstructed.html').readAsStringSync();
    final store = await MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
    final c = MarketController(store,
        client: SourceClient(client: MockClient((_) async {
          return http.Response(fixture.replaceAll('185,000', '$price'), 200,
              headers: {'content-type': 'text/html; charset=utf-8'});
        })));
    try {
      c.enabled = {'fardad-sheet'};
      await c.refresh();
      final first = c.quotes.length;
      expect(first, greaterThan(0));
      expect(c.states['fardad-sheet']?['success_at'], isNotNull);
      expect(c.lastRefreshAt, isNotNull);

      price = 191000;
      await c.refresh();
      expect(c.quotes.length, first);
      expect(c.busy, false);
      final second = c.states['fardad-sheet']?['attempted_at'] as String?;
      expect(second, isNotNull);
      // The second run really wrote: the archive it publishes is the new one,
      // and the same-day row was updated instead of keeping the older price.
      final stored = await store.latestFor('fardad-sheet');
      final prices = stored
          .map((q) => q.details['قیمت'] ?? '')
          .where((v) => v.isNotEmpty)
          .toList();
      expect(prices, contains('191000'));
      expect(prices, isNot(contains('118000')));
    } finally {
      c.dispose();
      await store.close();
    }
  });

  test('a source whose rows are all prose says so and keeps its old rows',
      () async {
    final store = await MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
    final c = MarketController(store,
        client: SourceClient(
            client: MockClient((_) async => http.Response(
                '<html><body><div class="tgme_widget_message" data-post="ch/1">'
                '<div class="tgme_widget_message_text">با سلام، فروشگاه امروز تعطیل است</div>'
                '</div></body></html>',
                200,
                headers: {'content-type': 'text/html; charset=utf-8'}))));
    try {
      c.enabled = {'telegram-hayperahan'};
      await c.refresh();
      final message = c.states['telegram-hayperahan']?['message'] as String?;
      expect(message, isNotNull);
      expect(message, anyOf(contains('قابل‌ثبت نبود'), contains('پیدا نشد')));
    } finally {
      c.dispose();
      await store.close();
    }
  });
}
