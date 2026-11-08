import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironpin/domain/range_worker.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ironpin/data/controller.dart';
import 'package:ironpin/data/range_session.dart';
import 'package:ironpin/data/store.dart';
import 'package:ironpin/domain/market.dart';
import 'package:ironpin/domain/price_range.dart';
import 'package:ironpin/domain/range_projection.dart';
import 'package:ironpin/domain/row_facts.dart';
import 'package:ironpin/ui/range_page.dart';

final now = DateTime.now().toUtc();
String fresh() => now.subtract(const Duration(hours: 1)).toIso8601String();

Quote row(int n,
        {double? amount = 100 + 0,
        String unit = 'kg',
        String city = 'مشهد',
        String? date,
        String brand = 'مبارکه',
        double? pieceKg,
        double? lengthM,
        String title = ''}) =>
    Quote(
        id: 'p$n',
        endpoint: 'catalog',
        seller: 'فروشنده$n',
        sellerCity: city,
        title: title.isEmpty ? 'ورق سیاه 3' : title,
        category: 'ورق',
        brand: brand,
        thickness: '3',
        amount: amount,
        unit: unit,
        pieceKg: pieceKg,
        lengthM: lengthM,
        currency: 'تومان',
        sourceDateRaw: date ?? fresh(),
        fetchedAt: now,
        sourceUrl: 'https://example.com/$n',
        details: const {'شاهد ردیف': 'ورق ۱۰۰ تومان'});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test('the stored index answers exactly like the live calculation', () async {
    final store = await MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
    try {
      final old = now.subtract(const Duration(days: 40)).toIso8601String();
      final quotes = [
        for (var i = 0; i < 240; i++) row(i, amount: 100.0 + i % 90),
        for (var i = 240; i < 280; i++)
          row(i, amount: 100.0 + i % 90, date: old),
        for (var i = 280; i < 320; i++) row(i, city: 'تهران'),
        for (var i = 320; i < 340; i++) row(i, brand: ''),
        row(400, unit: 'piece', amount: 4000000, pieceKg: 20),
        row(401, unit: 'piece', amount: 6000000, pieceKg: 20),
        row(402, amount: null),
      ];
      await store.saveSnapshot('catalog', quotes);
      final index = await store.rangeIndexRows(now);
      expect(index.length, greaterThanOrEqualTo(quotes.length));

      for (final probe in [
        (family: 'ورق', fields: <String, String>{}, city: ''),
        (family: 'ورق', fields: <String, String>{}, city: 'مشهد'),
        (family: 'ورق', fields: {'thickness': '3'}, city: ''),
        (family: 'ورق', fields: {'thickness': '9'}, city: 'مشهد'),
      ]) {
        final projected = project(index,
            family: probe.family,
            fields: probe.fields,
            basis: '',
            city: probe.city,
            nowMs: now.millisecondsSinceEpoch);
        final direct = calculateProductRange({
          'quotes': quotes,
          'query': ProductRangeQuery(probe.family,
              fields: probe.fields, city: probe.city),
          'now': now
        });
        expect(projected.rows.length, direct.announcements.length,
            reason: 'announcements of $probe');
        expect(projected.kept, direct.announcements.length);
        expect(projected.ranges.length, direct.ranges.length);
        final byBasis = {
          for (final r in direct.ranges)
            r.basis: (r.announcements.length, r.minimum, r.maximum, r.mean,
                r.sellers)
        };
        for (final range in projected.ranges) {
          final reference = byBasis[range['basis']]!;
          expect((range['indices'] as List).length, reference.$1);
          expect((range['min'] as num).toDouble(), reference.$2);
          expect((range['max'] as num).toDouble(), reference.$3);
          expect((range['mean'] as num).toDouble(), reference.$4);
          expect(range['sellers'], reference.$5);
        }
        // The selection stays the whole catalogue of the scope: the rows of the
        // confirmation window plus every older/unpriced row that matched.
        final catalogIds = {
          for (final wire in projected.catalog) '${wire['endpoint']}:${wire['id']}'
        };
        expect(catalogIds.length, projected.catalog.length,
            reason: 'one entry per stored offer: $probe');
        expect(catalogIds.containsAll(
                direct.announcements.map((q) => '${q.endpoint}:${q.id}')),
            true);
        expect(projected.catalog.length,
            greaterThanOrEqualTo(direct.announcements.length));
      }
    } finally {
      await store.close();
    }
  });

  test('an index row rebuilds the same facts and money as its payload', () async {
    final store = await MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
    try {
      final sample = [
        row(1, amount: 250.5),
        row(2, unit: 'piece', amount: 5000000, pieceKg: 25),
        row(3, unit: 'ton', amount: 90000000),
        row(4, amount: null),
        row(5, unit: 'sheet', amount: 12000000, pieceKg: 100),
      ];
      await store.saveSnapshot('catalog', sample);
      final indexed = await store.rangeIndexRows(now);
      for (final source in sample) {
        final facts = RowFacts.ofQuote(source);
        final row = indexed.firstWhere((r) => r['id'] == source.id);
        final restored = RowFacts.fromRow(row);
        expect(restored.family, facts.family);
        expect(restored.values, facts.values);
        expect(restored.prices, facts.prices);
        for (final unit in RowFacts.units) {
          expect(restored.priceIn(unit), source.tomanFor(unit));
        }
        expect(restored.marketAt, source.marketAt!.millisecondsSinceEpoch);
        expect(restored.announceKey, facts.announceKey);
        expect(restored.productKey, facts.productKey);
      }
    } finally {
      await store.close();
    }
  });

  test('a changed payload is re-derived, an untouched one is not', () async {
    final store = await MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
    try {
      final first = row(1, amount: 100);
      await store.saveSnapshot('catalog', [first]);
      // Same announcement received twice (a re-read) is one stored offer.
      final before = (await store.rangeIndexRows(now)).first;
      expect(RowFacts.fromRow(before).prices['kg'], 100);

      // Same payload received again: the indexed row is reused, not rewritten.
      await store.saveSnapshot('catalog', [first]);
      final again = (await store.rangeIndexRows(now)).first;
      expect(again['payload'], before['payload']);

      // A real price change produces a new payload and therefore a new row.
      await store.saveSnapshot('catalog', [row(1, amount: 175)]);
      final changed = await store.rangeIndexRows(now);
      final latest = changed.firstWhere((r) =>
          r['market_at'] == first.marketAt!.millisecondsSinceEpoch &&
          RowFacts.fromRow(r).prices['kg'] == 175);
      expect(RowFacts.fromRow(latest).prices['kg'], 175);
    } finally {
      await store.close();
    }
  });

  test('an index built only from payloads equals an index built at write time',
      () async {
    // `:memory:` is shared by the factory, so a real temporary file is needed
    // for two independent installations.
    final dir = await Directory.systemTemp.createTemp('ironpin-index');
    addTearDown(() => dir.delete(recursive: true));
    final store = await MarketStore.open(
        dbPath: '${dir.path}/a.db', factory: databaseFactoryFfi);
    final legacy = await MarketStore.open(
        dbPath: '${dir.path}/b.db', factory: databaseFactoryFfi);
    try {
      final sample = [for (var i = 0; i < 20; i++) row(i)];
      await store.saveSnapshot('catalog', sample);
      // Simulate an installation that predates the index: the payloads exist,
      // the derived rows do not.
      for (final quote in sample) {
        await legacy.db.insert('latest', {
          'id': quote.id,
          'endpoint': quote.endpoint,
          'payload': jsonEncode(quote.toJson()),
          'active': 1
        });
      }
      final rebuilt = await legacy.rangeIndexRows(now);
      final atWriteTime = await store.rangeIndexRows(now);
      expect(rebuilt.length, sample.length);
      final byId = {for (final r in atWriteTime) r['id']: r};
      for (final r in rebuilt) {
        final other = byId[r['id']]!;
        expect(r['family'], other['family']);
        expect(r['announce_key'], other['announce_key']);
        expect(r['prices'], other['prices']);
      }
      // And once derived, it is stored: the second read is served from SQLite.
      final count = await legacy.db.rawQuery('SELECT COUNT(*) c FROM range_index');
      expect(count.single['c'], sample.length);
    } finally {
      await store.close();
      await legacy.close();
    }
  });

  test('answers are reused only for the same scope and the same snapshot',
      () async {
    final store = await MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
    try {
      await store.saveSnapshot('catalog', [row(1), row(2, amount: 200)]);
      final session = RangeSession(store);
      final at = DateTime.now().toUtc();
      final first = await session.confirm(
          family: 'ورق', fields: const {}, basis: '', city: '', at: at);
      expect(first.result.announcements.length, 2);
      expect(first.keptRows, 2);

      // Same question: answered from memory, not recomputed.
      final again = await session.confirm(
          family: 'ورق', fields: const {}, basis: '', city: '', at: at);
      expect(again.fromMemory, true);
      expect(again.keptRows, first.keptRows);
      expect(again.result.announcements.length,
          first.result.announcements.length);
      expect(again.result.ranges.single.mean, first.result.ranges.single.mean);

      // A different unit, city, constraint or clock bucket is a new question.
      for (final other in [
        () => session.confirm(
            family: 'ورق', fields: const {}, basis: 'ton', city: '', at: at),
        () => session.confirm(
            family: 'ورق', fields: const {}, basis: '', city: 'تهران', at: at),
        () => session.confirm(
            family: 'ورق',
            fields: const {'thickness': '3'},
            basis: '',
            city: '',
            at: at),
      ]) {
        final answer = await other();
        expect(identical(answer, first), false);
        expect(answer.fromMemory, false);
      }

      // New data or a new city drops everything derived from the old snapshot.
      session.invalidate();
      expect(session.cached(
              session.scopeKey(
                  family: 'ورق', fields: const {}, basis: '', city: ''),
              at),
          isNull);
      final afterInvalidate = await session.confirm(
          family: 'ورق', fields: const {}, basis: '', city: '', at: at);
      expect(afterInvalidate.fromMemory, false);
      expect(afterInvalidate.result.announcements.length, 2);
    } finally {
      await store.close();
    }
  });

  testWidgets('a confirmed range is shown again without recalculating',
      (t) async {
    final store = await t.runAsync(() => MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi));
    await t.runAsync(
        () => store!.saveSnapshot('catalog', [row(1), row(2, amount: 200)]));
    final c = MarketController(store!);
    await t.pumpWidget(MaterialApp(home: Scaffold(body: RangePage(c: c))));
    await _settle(t);
    await t.tap(find.text('ورق / پلیت / صفحه فولادی'));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('تأیید و نمایش رنج'), 250,
        scrollable: find.byType(Scrollable).first);
    await t.tap(find.text('تأیید و نمایش رنج'));
    await t.pump();
    // The first confirmation of this snapshot really computes.
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await _settle(t);
    await _scrollTo(t, find.text('۱۵۰ تومان / کیلوگرم'));
    expect(find.text('۱۵۰ تومان / کیلوگرم'), findsOneWidget);
    expect(find.textContaining('تاریخ نامعلوم'), findsNothing);
    // The same scope again is served from memory: no spinner at any frame.
    await _scrollTo(t, find.text('تأیید و نمایش رنج'));
    await t.tap(find.text('تأیید و نمایش رنج'));
    await t.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await t.pumpAndSettle();
    await _scrollTo(t, find.text('۱۵۰ تومان / کیلوگرم'));
    expect(find.text('۱۵۰ تومان / کیلوگرم'), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox.shrink());
    c.dispose();
    await t.runAsync(store.close);
  });

  testWidgets('switching unit reuses no spinner but recalculates honestly',
      (t) async {
    final store = await t.runAsync(() => MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi));
    await t.runAsync(
        () => store!.saveSnapshot('catalog', [row(1), row(2, amount: 200)]));
    final c = MarketController(store!);
    await t.pumpWidget(MaterialApp(home: Scaffold(body: RangePage(c: c))));
    await _settle(t);
    await t.tap(find.text('ورق / پلیت / صفحه فولادی'));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('تأیید و نمایش رنج'), 250,
        scrollable: find.byType(Scrollable).first);
    await t.tap(find.text('تأیید و نمایش رنج'));
    await _settle(t);
    await _scrollTo(t, find.text('۱۵۰ تومان / کیلوگرم'));
    expect(find.text('۱۵۰ تومان / کیلوگرم'), findsOneWidget);
    // A different basis is a different question: it is recalculated, never
    // answered from the previous unit.
    await t.scrollUntilVisible(find.text('همه واحدها؛ جداگانه'), 250,
        scrollable: find.byType(Scrollable).first);
    await t.tap(find.text('همه واحدها؛ جداگانه'));
    await t.pumpAndSettle();
    await t.tap(find.text('تن').last);
    await t.pumpAndSettle();
    await t.tap(find.text('تأیید و نمایش رنج'));
    await _settle(t);
    await _scrollTo(t, find.textContaining('تومان / تن'));
    expect(find.textContaining('تومان / تن'), findsWidgets);
    expect(find.text('۱۵۰ تومان / کیلوگرم'), findsNothing);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox.shrink());
    c.dispose();
    await t.runAsync(store.close);
  });
  testWidgets('a second confirmation is answered by the standing worker',
      (t) async {
    final store = await t.runAsync(() => MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi));
    await t.runAsync(
        () => store!.saveSnapshot('catalog', [row(1), row(2, amount: 200)]));
    final c = MarketController(store!);
    await t.pumpWidget(MaterialApp(home: Scaffold(body: RangePage(c: c))));
    await _settle(t);
    await t.tap(find.text('ورق / پلیت / صفحه فولادی'));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('تأیید و نمایش رنج'), 250,
        scrollable: find.byType(Scrollable).first);
    await t.tap(find.text('تأیید و نمایش رنج'));
    await _settle(t);
    await _scrollTo(t, find.text('۱۵۰ تومان / کیلوگرم'));
    expect(find.text('۱۵۰ تومان / کیلوگرم'), findsOneWidget);
    // The same archive again asks nothing new of the index, and the worker that
    // answered the first question is the one still loaded.
    expect(RangeWorker.shared.isLoaded, isTrue);
    final before = c.rangeSession.computeRuns;
    await t.scrollUntilVisible(find.text('همه واحدها؛ جداگانه'), 250,
        scrollable: find.byType(Scrollable).first);
    await t.tap(find.text('همه واحدها؛ جداگانه'));
    await t.pumpAndSettle();
    await t.tap(find.text('تن').last);
    await t.pumpAndSettle();
    await t.tap(find.text('تأیید و نمایش رنج'));
    await _settle(t);
    // A different basis is computed in the worker, not through the fallback.
    expect(c.rangeSession.computeRuns, before);
    await _scrollTo(t, find.textContaining('تومان / تن'));
    expect(find.textContaining('تومان / تن'), findsWidgets);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox.shrink());
    c.dispose();
    await t.runAsync(store.close);
  });
}

/// Drags the page until [target] is rendered (the confirmed answer is below the
/// fold), without assuming a list extent that only exists after the answer.
Future<void> _scrollTo(WidgetTester t, Finder target) async {
  for (var i = 0; i < 25; i++) {
    if (target.evaluate().isNotEmpty) return;
    await t.drag(find.byType(Scrollable).first, const Offset(0, -220));
    await t.pumpAndSettle();
  }
}

/// Bounded real-time pumps: the confirmation is genuine async I/O + compute.
Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 200; i++) {
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)));
    await t.pump();
    if (find.byType(LinearProgressIndicator).evaluate().isEmpty &&
        i > 4) {
      break;
    }
  }
  await t.pumpAndSettle();
}
