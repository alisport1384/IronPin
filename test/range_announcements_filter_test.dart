import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ironpin/data/controller.dart';
import 'package:ironpin/data/store.dart';
import 'package:ironpin/domain/market.dart';
import 'package:ironpin/ui/range_page.dart';

/// «اعلام‌های نتیجه» shows offers the user can act on. A row without a number
/// is not among them — it is counted and named under «علت نبودن در آمار»
/// instead, so the list never shows an entry whose price column would read
/// «تماس / مبلغ نامعلوم».
Quote priced() => Quote(
    id: 'p7',
    endpoint: 'catalog',
    seller: 'فروشنده۷',
    title: 'محصول۰۰۸',
    brand: 'مبارکه',
    category: 'ورق',
    size: '16',
    thickness: '3',
    dimensions: '1000x2000',
    grade: 'A3',
    amount: 130.0,
    unit: 'kg',
    currency: 'تومان',
    sourceDateRaw: DateTime.now()
        .toUtc()
        .subtract(const Duration(hours: 1))
        .toIso8601String(),
    fetchedAt: DateTime.now().toUtc(),
    sourceUrl: 'https://example.com/7');

Quote unpriced() => Quote(
    id: 'p8',
    endpoint: 'catalog',
    seller: 'فروشنده۸',
    title: 'محصول۰۰۸',
    brand: 'مبارکه',
    category: 'ورق',
    size: '16',
    thickness: '3',
    dimensions: '1000x2000',
    grade: 'A3',
    amount: null,
    unit: 'kg',
    currency: 'تومان',
    sourceDateRaw: DateTime.now()
        .toUtc()
        .subtract(const Duration(hours: 2))
        .toIso8601String(),
    fetchedAt: DateTime.now().toUtc(),
    sourceUrl: 'https://example.com/8');

Future<void> _settleRange(WidgetTester t) async {
  for (var i = 0; i < 120; i++) {
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)));
    await t.pump();
    if (find.byType(LinearProgressIndicator).evaluate().isEmpty) break;
  }
  await t.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  testWidgets('a row without a price is counted, not listed', (t) async {
    final store = await t.runAsync(() => MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi));
    await t.runAsync(() => store!.saveSnapshot('catalog', [priced(), unpriced()]));
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
    await _settleRange(t);

    // The list sits below the scope card and the range: bring it into view.
    await t.scrollUntilVisible(
        find.textContaining('اعلام بدون قیمت نمایش داده نمی‌شود'), 300,
        scrollable: find.byType(Scrollable).first);
    // In the announcements list the product appears once — for its priced
    // row; the price-less sibling has no entry.
    expect(find.text('محصول۰۰۸'), findsOneWidget,
        reason: 'only the priced row is listed in «اعلام‌های نتیجه»');
    expect(find.textContaining('مبلغ نامعلوم'), findsNothing,
        reason: 'no price-less row may be rendered in the list');
    expect(find.textContaining('اعلام بدون قیمت نمایش داده نمی‌شود'),
        findsOneWidget,
        reason: 'the shorter list says how many rows were withheld');
    // Expanding the candidates of the same product adds exactly one more
    // entry: the priced row again. A leaked price-less sibling would make it
    // three.
    await t.tap(find.textContaining('کاندیدهای همان کالا'));
    await t.pumpAndSettle();
    expect(find.text('محصول۰۰۸'), findsNWidgets(2),
        reason: 'announcements + candidates carry the priced row once each');

    // The statistics are from the priced row only: the range card prints the
    // priced number, and nothing was fabricated for the price-less sibling.
    expect(find.textContaining('تومان /'), findsWidgets,
        reason: 'a range card with the priced number must be shown');
    expect(t.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
