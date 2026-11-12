import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ironpin/data/controller.dart';
import 'package:ironpin/data/store.dart';
import 'package:ironpin/data/sources.dart';
import 'package:ironpin/domain/market.dart';
import 'dart:convert';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
  });
  test(
      'refresh automatically analyzes, stores and searches real channel sheet text without any manual UI',
      () async {
    final raw =
        File('test/fixtures/hayper_sheets_observed.html').readAsStringSync();
    final store = await MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
    final c = MarketController(store,
        client: SourceClient(
            client: MockClient((_) async => http.Response(raw, 200,
                headers: {'content-type': 'text/html; charset=utf-8'}))));
    try {
      c.enabled = {'telegram-hayperahan'};
      await c.setDiscoveryDays(0);
      await c.refresh();
      expect(c.quotes.where((q) => q.hasTextAmount).length,
          greaterThanOrEqualTo(16));
      expect(c.quotes.every((q) => q.details['ورودی دستی'] != 'بله'), true);
      // This fixture is older than the default one-month window, so the window
      // is widened here: the assertion is about the search, not about the date.
      c.filter
        ..query = 'ورق 3'
        ..recentWeek = false
        ..windowDays = 0;
      expect(c.filtered.length, 3);
      expect(c.filtered.every((q) => q.sellerCity == 'مشهد'), true);
      c.filter.recentWeek = true;
      expect(c.filtered, isEmpty);
      final persisted = await store.latest();
      expect(persisted.length, c.quotes.length);
    } finally {
      c.dispose();
      await store.close();
    }
  });
  test(
      'table refresh automatically keeps amount candidate and specs when currency is absent',
      () async {
    final raw = File('test/fixtures/fardad_sheets_reconstructed.html')
        .readAsStringSync();
    final store = await MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
    final c = MarketController(store,
        client: SourceClient(
            client: MockClient((_) async => http.Response(raw, 200,
                headers: {'content-type': 'text/html; charset=utf-8'}))));
    try {
      c.enabled = {'fardad-sheet'};
      // The fixture carries one fixed date; the assertion is about what is
      // read from the table, not about how old it is on the day the test runs.
      await c.setDiscoveryDays(0);
      await c.refresh();
      c.filter
        ..recentWeek = false
        ..windowDays = 0
        ..query = 'ورق3 مشهد';
      expect(c.filtered.length, 2);
      expect(
          c.filtered.every((q) =>
              q.hasTextAmount && q.amount == null && q.thicknessLabel == '3.0'),
          true);
      expect(c.states['fardad-sheet']?['success_at'], isNotNull);
      final search = MarketFilter()..query = 'ورق3';
      expect(
          search.apply(await store.latest(), DateTime.utc(2026, 11, 6)).length,
          2);
    } finally {
      c.dispose();
      await store.close();
    }
  });
  test(
      'explicit all-ON migration enables all registered sources once and preserves later opt-out',
      () async {
    final store = await MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
    await store.setSetting('autoRefresh', 'false');
    await store.setSetting('enabled', jsonEncode(['melal-rebar']));
    await store.setSetting('sourcesVersion', '2');
    await store.setSetting('analysisSourcesVersion', '1');
    await store.setSetting('sheetSourcesVersion', '1');
    final c = MarketController(store);
    await c.init();
    expect(c.enabled, endpoints.map((e) => e.id).toSet());
    await c.setEnabled('fardad-sheet', false);
    c.dispose();
    final next = MarketController(store);
    await next.init();
    expect(
        next.enabled,
        endpoints
            .where((e) => e.id != 'fardad-sheet')
            .map((e) => e.id)
            .toSet());
    next.dispose();
    await store.close();
  });
  test(
      'all-ON refresh publishes each successful source before a slow source completes',
      () async {
    final gate = Completer<void>(), visible = Completer<void>();
    final store = await MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
    final c = MarketController(store,
        client: SourceClient(client: MockClient((request) async {
      if (request.url.toString().contains('khabazzade')) await gate.future;
      return http.Response(
          File('test/fixtures/${request.url.toString().contains('khabazzade') ? 'khabazzade_observed' : 'ghanbari_sheets_observed'}.html')
              .readAsStringSync(),
          200,
          headers: {'content-type': 'text/html; charset=utf-8'});
    })));
    c.enabled = {'telegram-ghanbari', 'telegram-khabazzade'};
    // The fixture posts are dated 2026-11-05. The test is about publishing a
    // source before a slow one completes, so the windows are opened: with the
    // real clock the same posts stop being "this week" on 2026-11-12 and leave
    // the default month a few weeks later.
    await c.setDiscoveryDays(0);
    c.addListener(() {
      if (c.busy && c.quotes.isNotEmpty && !visible.isCompleted) {
        visible.complete();
      }
    });
    final refreshing = c.refresh();
    try {
      await visible.future.timeout(const Duration(seconds: 5));
      expect(c.busy, true);
      expect(gate.isCompleted, false);
      c.filter
        ..query = 'ورق3 مشهد'
        ..recentWeek = false
        ..windowDays = 0;
      expect(c.filtered.length, 3);
      expect((await store.latest()).isNotEmpty, true);
    } finally {
      gate.complete();
      await refreshing;
      c.dispose();
      await store.close();
    }
  });
}
