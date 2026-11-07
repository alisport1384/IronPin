import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ironpin/data/store.dart';
import 'package:ironpin/data/controller.dart';
import 'package:ironpin/domain/market.dart';
import 'package:ironpin/domain/price_range.dart';
import 'package:ironpin/ui/range_page.dart';

final at = DateTime.utc(2026, 11, 6, 12);
Quote item(int n,
        {String brand = 'مبارکه',
        String date = '2026-11-06T08:00:00Z',
        double? amount = 100,
        String currency = 'تومان',
        String unit = 'kg',
        String category = 'ورق'}) =>
    Quote(
        id: 'p$n',
        endpoint: 'catalog',
        seller: 'فروشنده$n',
        title: 'محصول${n.toString().padLeft(3, '0')}',
        brand: brand,
        category: category,
        size: '16',
        thickness: '3',
        dimensions: '1000x2000',
        grade: 'A3',
        amount: amount,
        unit: unit,
        currency: currency,
        sourceDateRaw: date,
        fetchedAt: at,
        sourceUrl: 'https://example.com');
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  test(
      'catalogue keeps old, undated, unknown currency/unit, unpriced and incomplete products',
      () {
    final report = calculateRanges([
      item(0),
      item(1, date: '2026-10-01'),
      item(2, date: ''),
      item(3, currency: 'نامشخص'),
      item(4, unit: 'unknown'),
      item(5, amount: null),
      item(6, brand: '')
    ], at);
    expect(report.products.length, 7);
    expect(report.ranges.length, 1);
    for (final p in report.products.where((p) => p.range == null)) {
      expect(p.unavailableReasons, isNotEmpty);
    }
    expect(
        report.quotes
            .singleWhere((p) => p.id == 'p1')
            .marketAt!
            .isBefore(at.subtract(const Duration(hours: 48))),
        true);
    expect(report.ranges.single.announcements.map((q) => q.id).toSet(),
        {'p0', 'p6'});
  });
  test(
      'all categories stay selectable independently of statistical eligibility',
      () {
    final categories = [
      'ورق',
      'میلگرد',
      'پروفیل',
      'لوله',
      'تیرآهن',
      'ناودانی',
      'نبشی',
      'توری',
      'رابیتس',
      'قراضه'
    ];
    final report = calculateRanges([
      for (var i = 0; i < categories.length; i++)
        item(i, category: categories[i], brand: '', amount: null)
    ], at);
    expect(report.products.map((p) => p.example.category).toSet(),
        categories.toSet());
    expect(report.ranges, isEmpty);
  });
  test(
      'offer catalogue retains entries while missing brands no longer excludes matching rates',
      () {
    final a = item(1, brand: '');
    final b =
        Quote.fromJson({...item(2, brand: '').toJson(), 'title': a.title});
    final report = calculateRanges([a, b], at);
    expect(report.products.length, 2);
    expect(report.ranges.single.announcements.length, 2);
    expect(report.ranges.single.mean, 100);
  });
  test('catalogue has no 40-item cap and search covers every product', () {
    final report = calculateRanges(
        [for (var i = 0; i < 125; i++) item(i, brand: '', amount: null)], at);
    expect(report.products.length, 125);
    expect(
        report.products
            .singleWhere((p) => p.searchText.contains('محصول124'))
            .example
            .id,
        'p124');
  });
  test(
      'adding invalid catalogue products never changes valid announcement mean/count',
      () {
    final a = item(0);
    final b = Quote.fromJson(
        {...a.toJson(), 'id': 'other', 'seller': 'ب', 'amount': 200});
    final report = calculateRanges([
      a,
      b,
      item(1, amount: null),
      item(2, currency: 'R'),
      item(3, date: '')
    ], at);
    expect(report.ranges.single.mean, 150);
    expect(report.ranges.single.announcements.length, 2);
    expect(report.products.length, 5);
  });
  test('repeated fetch of an unavailable product gives one selectable entry',
      () {
    final q = item(1, brand: '');
    final next = Quote.fromJson({
      ...q.toJson(),
      'fetchedAt': at.add(const Duration(minutes: 1)).toIso8601String()
    });
    final report = calculateRanges([q, next, q], at);
    expect(report.products.length, 1);
    expect(report.products.single.example.fetchedAt, next.fetchedAt);
  });
  test(
      'store selection includes inactive historical latest while feed stays active-only',
      () async {
    final store = await MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
    try {
      await store.saveSnapshot('catalog', [item(0, date: '2026-10-01')]);
      await store.saveSnapshot('catalog', [item(1)]);
      expect((await store.latest()).single.id, 'p1');
      final report = await store.rangeReport(at);
      expect(report.products.map((p) => p.example.id).toSet(), {'p0', 'p1'});
      expect(report.ranges.single.example.id, 'p1');
      expect(report.quotes.any((q) => q.id == 'p0'), true);
      expect(report.ranges.single.announcements.length, 1);
    } finally {
      await store.close();
    }
  });
  test(
      'history-only old product remains selectable after a history-only restore',
      () async {
    final store = await MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
    try {
      await store.saveSnapshot('catalog', [item(0, date: '2026-10-01')]);
      await store.db.delete('latest');
      final report = await store.rangeReport(at);
      expect(report.products.single.example.id, 'p0');
      expect(report.products.single.range, isNull);
      expect(report.ranges, isEmpty);
    } finally {
      await store.close();
    }
  });
  testWidgets(
      'an unavailable product is visible and selectable with reasons, not a fabricated range',
      (t) async {
    final store = await t.runAsync(() => MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi));
    await t.runAsync(() => store!.saveSnapshot('catalog', [
          Quote.fromJson({
            ...item(8, brand: '', amount: null).toJson(),
            'sourceDateRaw': DateTime.now()
                .toUtc()
                .subtract(const Duration(hours: 1))
                .toIso8601String()
          })
        ]));
    final c = MarketController(store!);
    addTearDown(() async {
      c.dispose();
      await store.close();
    });
    await t.pumpWidget(MaterialApp(home: Scaffold(body: RangePage(c: c))));
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)));
    await t.pumpAndSettle();
    await t.tap(find.text('ورق / پلیت / صفحه فولادی'));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('تأیید و نمایش رنج'), 250,
        scrollable: find.byType(Scrollable).first);
    await t.tap(find.text('تأیید و نمایش رنج'));
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('رنج عددی قابل مقایسه نداریم'), 300,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('رنج عددی قابل مقایسه نداریم'), findsOneWidget);
    await t.scrollUntilVisible(find.textContaining('محصول۰۰۸'), 300,
        scrollable: find.byType(Scrollable).first);
    expect(find.textContaining('محصول۰۰۸'), findsOneWidget);
    expect(find.byType(RangeCost), findsNothing);
    expect(find.text('میانگین گرد‌شده'), findsNothing);

    expect(t.takeException(), isNull);
  });
  testWidgets(
      'old and undated products remain selectable in the local archive without numeric ranges',
      (t) async {
    final store = await t.runAsync(() => MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi));
    await t.runAsync(() =>
        store!.saveSnapshot('catalog', [item(908, amount: null, date: '')]));
    final c = MarketController(store!);
    addTearDown(() async {
      c.dispose();
      await store.close();
    });
    await t.pumpWidget(MaterialApp(home: Scaffold(body: RangePage(c: c))));
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)));
    await t.pumpAndSettle();
    await t.tap(find.text('ورق / پلیت / صفحه فولادی'));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('تأیید و نمایش رنج'), 250,
        scrollable: find.byType(Scrollable).first);
    await t.tap(find.text('تأیید و نمایش رنج'));
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)));
    await t.pumpAndSettle();
    final archive = find.text('فهرست کامل محلی • ۱ کالا');
    await t.scrollUntilVisible(archive, 250,
        scrollable: find.byType(Scrollable).first);
    await t.tap(archive);
    await t.pumpAndSettle();
    final product = find.textContaining('محصول۹۰۸');
    await t.scrollUntilVisible(product, 250,
        scrollable: find.byType(Scrollable).first);
    await t.tap(product);
    await t.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('این نمایش از آرشیو محلی است'), findsOneWidget);
    expect(find.byType(RangeCost), findsNothing);
    expect(t.takeException(), isNull);
  });
  testWidgets(
      'UI exposes all pages and can search beyond the first 40 products',
      (t) async {
    t.view.physicalSize = const Size(390, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final store = await t.runAsync(() => MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi));
    await t.runAsync(() => store!.saveSnapshot('catalog', [
          for (var i = 0; i < 85; i++)
            Quote.fromJson({
              ...item(i, brand: '', amount: null).toJson(),
              'sourceDateRaw': DateTime.now()
                  .toUtc()
                  .subtract(const Duration(hours: 1))
                  .toIso8601String()
            })
        ]));
    final c = MarketController(store!);
    addTearDown(() async {
      c.dispose();
      await store.close();
    });
    await t.pumpWidget(MaterialApp(home: Scaffold(body: RangePage(c: c))));
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 160)));
    await t.pumpAndSettle();
    await t.tap(find.text('ورق / پلیت / صفحه فولادی'));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('تأیید و نمایش رنج'), 250,
        scrollable: find.byType(Scrollable).first);
    await t.tap(find.text('تأیید و نمایش رنج'));
    await t.pump();
    // Real isolate/I/O time does not advance with fake-clock pumpAndSettle.
    // Bounded wait checks completion rather than assuming a fixed 160ms host speed.
    for (var i = 0; i < 100; i++) {
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await t.pump();
      if (find.byType(LinearProgressIndicator).evaluate().isEmpty) break;
    }
    await t.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    final search =
        find.widgetWithText(TextField, 'جستجو در تمام اعلام‌های نتیجه');
    await t.scrollUntilVisible(search, 250,
        scrollable: find.byType(Scrollable).first);
    await t.enterText(search, 'محصول084');
    await t.pumpAndSettle();
    expect(find.textContaining('محصول۰۸۴'), findsOneWidget);
    await t.enterText(search, '');
    await t.pumpAndSettle();
    for (var i = 0; i < 2; i++) {
      await t.scrollUntilVisible(find.text('نمایش ۴۰ اعلام بعدی'), 700,
          scrollable: find.byType(Scrollable).first, maxScrolls: 80);
      await t.tap(find.text('نمایش ۴۰ اعلام بعدی'));
      await t.pumpAndSettle();
    }
    await t.scrollUntilVisible(find.text('نمایش ۸۵ از ۸۵ اعلام'), 700,
        scrollable: find.byType(Scrollable).first, maxScrolls: 80);
    expect(find.text('نمایش ۴۰ اعلام بعدی'), findsNothing);
    expect(find.text('نمایش ۸۵ از ۸۵ اعلام'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
