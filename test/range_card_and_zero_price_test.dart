import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ironpin/data/store.dart';
import 'package:ironpin/data/controller.dart';
import 'package:ironpin/domain/market.dart';
import 'package:ironpin/domain/price_range.dart';
import 'package:ironpin/domain/range_projection.dart';
import 'package:ironpin/domain/row_facts.dart';
import 'package:ironpin/ui/range_page.dart';

/// 0.9.7 — دو اصلاح رفتاری تب رنج:
/// A) هر محصولی که کاندید دارد، کارتِ شاخص‌های خودش (میانگین/بالاترین/
///    پایین‌ترین) را هم دارد — کارت و کاندیدها از یک مجموعه ساخته می‌شوند.
/// B) قیمتِ صفر قیمت نیست: منابعی مثل قراضه «۰ تومان» می‌نویسند یعنی
///    «قیمتی ندارم»؛ ردیف در اعلام‌ها می‌ماند و شمرده می‌شود، اما در
///    فهرستِ قیمت‌دار و کاندیدها هرگز نمی‌آید.
final now = DateTime.now().toUtc();

Quote plate(int n,
        {required String thickness,
        required double amount,
        String brand = 'مبارکه'}) =>
    Quote(
        id: 'p$n',
        endpoint: 'catalog',
        seller: 'فروشنده$n',
        // The technical identity is read from the title, like every other
        // fixture in this suite: «ورق سیاه 3» and «ورق سیاه 4» are two
        // products with their own indicators.
        title: 'ورق سیاه $thickness',
        category: 'ورق',
        brand: brand,
        thickness: thickness,
        grade: 'A3',
        amount: amount,
        unit: 'kg',
        currency: 'تومان',
        sourceDateRaw:
            now.subtract(const Duration(hours: 1)).toIso8601String(),
        fetchedAt: now,
        sourceUrl: 'https://example.com/$n');

Future<void> _settle(WidgetTester t) async {
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

  testWidgets('هر کالای کاندیددار کارت شاخص‌های خودش را دارد (باگ A)',
      (t) async {
    final store = await t.runAsync(() => MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi));
    await t.runAsync(() => store!.saveSnapshot('catalog', [
          plate(1, thickness: '3', amount: 100),
          plate(2, thickness: '4', amount: 200),
          // یک ردیفِ بی‌قیمت از خانوادهٔ دیگر: کاندید نیست، کارت هم ندارد.
          plate(3, thickness: '5', amount: 0),
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
    await _settle(t);
    expect(find.textContaining('محاسبه کامل نشد'), findsNothing,
        reason: 'the confirmation must succeed even with a zero-price row');
    expect(find.textContaining('خطا'), findsNothing);
    expect(find.textContaining('اعلام یکتای مرتبط'), findsOneWidget,
        reason: 'the confirmation must produce a result at all');
    // The cards live below the fold: scroll them into the built tree
    // first — a SliverList only creates elements for what the viewport
    // (plus its cache) can reach.
    await t.scrollUntilVisible(
        find.textContaining('شاخص‌های همین کالا'), 250,
        scrollable: find.byType(Scrollable).first);
    await t.pumpAndSettle();
    // The cards sit below the fold of the test viewport; presence is
    // checked over the whole built tree, not only the onstage part.
    Finder built(String text) => find.textContaining(text, skipOffstage: false);
    expect(built('شاخص‌های همین کالا'), findsNWidgets(2));
    expect(built('میانگین: '), findsNWidgets(2));
    expect(built('بالاترین: '), findsNWidgets(2));
    expect(built('پایین‌ترین: '), findsNWidgets(2));
    // هر کارت عددِ همان کالا را نشان می‌دهد.
    expect(find.text('۱۰۰ تومان / کیلوگرم', skipOffstage: false),
        findsOneWidget,
        reason: 'the primary line of the 3-mil card — the indicator rows '
            'carry longer texts and do not match exactly');
    expect(find.text('۲۰۰ تومان / کیلوگرم', skipOffstage: false),
        findsOneWidget);
    // کالای بی‌قیمت کارت و کاندید ندارد، اما در اعلام‌ها شمرده می‌شود.
    expect(built('نمایش کاندیدها'), findsNWidgets(2));
    expect(built('۱ اعلام بدون قیمت نمایش داده نمی‌شود'), findsOneWidget);
    expect(t.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('قیمت صفر قیمت نیست: شمرده می‌شود اما هرگز قیمت نمی‌شود (باگ B)',
      () {
    final zero = plate(9, thickness: '3', amount: 0);
    final real = plate(10, thickness: '3', amount: 150);
    final r = calculateProductRange({
      'quotes': [zero, real],
      'query': const ProductRangeQuery('ورق'),
      'now': now,
    });
    // هر دو اعلام می‌مانند...
    expect(r.announcements.length, 2);
    // ...اما آمار فقط از ردیفِ واقعی ساخته می‌شود.
    expect(r.ranges.single.mean, 150);
    expect(r.ranges.single.announcements.single.id, 'p10');
    expect(
        r.excluded['نمایش در اعلام‌ها؛ مبلغ/ارز/واحد یا تبدیل معتبر برای آمار '
            'ندارد'],
        1);
    // متنِ قیمتِ کاندید برای صفر هم «بدون قیمت» است، نه «۰».
    final text = candidatePriceText(
        CatalogueItem('k', RowFacts.ofQuote(zero).toWire(), now,
            counted: false));
    expect(text, 'بدون قیمت');
  });
}
