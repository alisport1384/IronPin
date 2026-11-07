import 'dart:math' as math;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ironpin/data/controller.dart';
import 'package:ironpin/data/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironpin/domain/calculator.dart';
import 'package:ironpin/domain/market.dart';
import 'package:ironpin/domain/product_text.dart';
import 'package:ironpin/domain/product_schema.dart';
import 'package:ironpin/domain/price_range.dart';
import 'package:ironpin/domain/text_engine.dart';
import 'package:ironpin/data/sources.dart';
import 'package:ironpin/ui/calculator_page.dart';
import 'package:ironpin/ui/prices_page.dart';

final now = DateTime.utc(2026, 11, 7, 12);
WeightResult calc(String shape, Map<String, double> values,
        {String unit = 'piece',
        double q = 1,
        double length = .5,
        double rho = 7850}) =>
    SteelCalculator.calculate(
        shape: shape,
        values: values,
        density: rho,
        inputUnit: unit,
        quantity: q,
        lengthPerPiece: length);
Quote bolt(String id,
        {String kind = 'L',
        String diameter = '20',
        Map<String, String> change = const {},
        bool complete = true,
        double? mass}) =>
    Quote(
        id: id,
        endpoint: 'test',
        seller: 'seller$id',
        title: 'انکر بولت M$diameter',
        category: 'بولت',
        unit: 'piece',
        currency: 'تومان',
        amount: 100000,
        sourceDateRaw: '2026-11-07T08:00:00Z',
        fetchedAt: now,
        sourceUrl: 'https://example.com/$id',
        pieceKg: mass,
        details: complete
            ? {
                'نوع': kind,
                'سایز': diameter,
                'طول': '500 mm',
                'طول رزوه': '100 mm',
                'گام رزوه': '2.5 mm',
                'گرید': '8.8',
                'پوشش': 'بدون پوشش',
                'شمول': 'میله تنها',
                'واحد ابعاد': 'mm',
                'جنس': 'فولاد کربنی',
                ...change
              }
            : {});
ProductRangeResult ranges(List<Quote> rows) => calculateProductRange(
    {'quotes': rows, 'query': const ProductRangeQuery('بولت'), 'now': now});
SourceEndpoint endpoint(String id) => endpoints.firstWhere((e) => e.id == id);
// Semantic fixture reconstructed from fetch_page's public table, NOT a raw HTML capture.
String semanticTable(
        {String price = '۱٬۵۸۵٬۰۰۰ ریال هر کیلوگرم',
        String date = 'بروزرسانی تاریخ ۱۶ آبان ۱۴۰۵',
        String title = 'مفتول سیاه پخته 1/5',
        String extra = ''}) =>
    '<h2>لیست قیمت مفتول سیاه</h2><p>$date</p><button>نمایش به تومان</button><h3>مفتول سیاه پخته</h3><table><tr><th>محصول</th><th>قطر مفتول</th><th>قیمت ↕(ریال / واحد مبنا)</th></tr><tr><td><h3>$title</h3>کد کالا: 111015020000000015 برند: راه ساخت</td><td>1.5 mm</td><td>$price</td></tr></table>$extra';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  test('new source migration preserves old OFF choices and only runs once',
      () async {
    final store = await MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
    for (final e in {
      'enabled': '["melal-rebar"]',
      'sourcesVersion': '2',
      'analysisSourcesVersion': '1',
      'sheetSourcesVersion': '1',
      'allRegisteredSourcesEnabledVersion': '3',
      'selectedCity': 'مشهد',
      'loggingEnabled': 'false'
    }.entries) {
      await store.setSetting(e.key, e.value);
    }
    final c = MarketController(store);
    await c.init();
    expect(c.enabled, {'melal-rebar', ...mashhadV072EndpointIds});
    expect(c.selectedCity, 'مشهد');
    expect(c.loggingEnabled, false);
    await c.setEnabled('rahsakht-wire', false);
    c.dispose();
    final c2 = MarketController(store);
    await c2.init();
    expect(c2.enabled.contains('rahsakht-wire'), false);
    expect(c2.enabled.contains('melal-sheet'), false);
    c2.dispose();
    await store.close();
  });

  for (final text in [
    'بولت M20',
    'انکر بولت M20',
    'انکربولت M20',
    'رول بولت M20',
    'Anchor bolt M20'
  ]) {
    test('bolt canonical vocabulary: $text', () {
      expect(ProductText.category(text), 'بولت');
      expect(ProductText.spec(text).size, '20');
    });
  }
  test('billet is not mistaken for bolt', () {
    expect(ProductText.category('بیلت شمش فولادی'), 'شمش');
  });
  test('flat and bolt schemas expose dedicated technical fields', () {
    expect(
        productFields['بولت']!.keys,
        containsAll([
          'pitch',
          'threadLength',
          'coating',
          'accessories',
          'model',
          'embedment'
        ]));
    expect(productFields['تسمه']!.keys, contains('form'));
  });
  test('flat 50x5mm x6m gives 11.775kg', () {
    expect(
        calc('flat', {'b': 50, 't': 5}, length: 6).kg, closeTo(11.775, 1e-9));
  });
  test('flat mass-to-length round trip and count', () {
    final r = calc('flat', {'b': 50, 't': 5}, length: 6, q: 2);
    expect(r.kg, closeTo(23.55, 1e-9));
    final inv = calc('flat', {'b': 50, 't': 5}, length: 6, unit: 'kg', q: r.kg);
    expect(inv.metres, closeTo(12, 1e-9));
    expect(inv.pieces, closeTo(2, 1e-9));
  });
  test('bolt M20 500mm uses developed length, not chart guesses', () {
    expect(calc('anchor', {'d': 20, 'extraKg': 0}).kg,
        closeTo(math.pi / 4 * 400 * .5 * .00785, 1e-9));
  });
  test('bolt measured accessories added once per piece', () {
    final r = calc('anchor', {'d': 20, 'extraKg': .1}, q: 4);
    expect(r.kg, closeTo(4 * (math.pi / 4 * 400 * .5 * .00785 + .1), 1e-9));
    expect(r.pieces, 4);
  });
  test('custom density applies to body, not already weighed accessories', () {
    expect(calc('anchor', {'d': 20, 'extraKg': .1}, rho: 2700).kg,
        closeTo(math.pi / 4 * 400 * .5 * .0027 + .1, 1e-9));
  });
  test('measured complete anchor set never gets cylindrical weight', () {
    expect(
        calc('anchorMeasured', {'kgpiece': .4}, q: 3).kg, closeTo(1.2, 1e-9));
  });
  test('measured anchor kg converts to equivalent pieces', () {
    expect(calc('anchorMeasured', {'kgpiece': .4}, unit: 'kg', q: 2).pieces, 5);
  });
  for (final unit in ['m', 'm2']) {
    test('measured set rejects unsupported $unit', () {
      expect(() => calc('anchorMeasured', {'kgpiece': .4}, unit: unit),
          throwsFormatException);
    });
  }
  test('bolt rejects fractional quantity and negative accessories', () {
    expect(() => calc('anchor', {'d': 20, 'extraKg': 0}, q: 1.5),
        throwsFormatException);
    expect(
        () => calc('anchor', {'d': 20, 'extraKg': -.1}), throwsFormatException);
  });
  test('flat rejects zero/negative/nonfinite dimensions', () {
    for (final b in [0.0, -1.0, double.nan, double.infinity]) {
      expect(() => calc('flat', {'b': b, 't': 5}), throwsFormatException);
    }
  });
  test('set count and kg/ton price reconcile without double conversion', () {
    final r = calc('anchorMeasured', {'kgpiece': .4}, q: 3);
    expect(SteelCalculator.cost(r, 'piece', 100), 300);
    expect(SteelCalculator.cost(r, 'kg', 250), closeTo(300, 1e-9));
    expect(SteelCalculator.cost(r, 'ton', 250000), closeTo(300, 1e-9));
  });
  test('quote unit number is explicit and has no theoretical kg conversion',
      () {
    expect(parseUnit('عدد'), 'piece');
    expect(TextPriceEngine.priceUnit('هر عدد'), 'piece');
    final q = bolt('a');
    expect(q.unitName('piece'), 'عدد / ست');
    expect(q.priceFor('kg'), isNull);
    expect(bolt('b', mass: .4).priceFor('kg'), 250000);
  });
  test('explicit bolt text extracts diameter, grade and count unit', () {
    final q = TextPriceEngine.analyze(
            text:
                'بولت خام M20 طول 500 mm طول رزوه 100 mm گام رزوه 2.5 mm 8.8 بدون پوشش میله تنها\nقیمت هر عدد 100000 تومان',
            endpoint: 'x',
            seller: 'x',
            sourceUrl: 'https://example.com',
            fetchedAt: now,
            postId: '1',
            publishedAt: now)
        .first;
    expect(q.category, 'بولت');
    expect(q.unit, 'piece');
    expect(q.sizeLabel, '20');
    expect(ProductFacts.of(q).values['grade'], '8.8');
  });
  test('unknown technical bolt specs remain listed, not numerically pooled',
      () {
    final r = ranges([bolt('a', complete: false)]);
    expect(r.announcements.length, 1);
    expect(r.ranges, isEmpty);
    expect(exactProductKey(bolt('a', complete: false)), isNull);
  });
  test('complete technically identical rods compare across sellers', () {
    expect(
        ranges([bolt('a'), bolt('b')]).ranges.single.announcements.length, 2);
  });
  for (final field in [
    'نوع',
    'سایز',
    'طول',
    'طول رزوه',
    'گام رزوه',
    'گرید',
    'پوشش',
    'شمول',
    'واحد ابعاد'
  ]) {
    test('technical change separates bolt ranges: $field', () {
      expect(
          ranges([
            bolt('a'),
            bolt('b', change: {field: field == 'نوع' ? 'J' : 'DIFFERENT'})
          ]).ranges.length,
          2);
    });
  }
  test('mechanical/chemical anchors require exact model and embedment', () {
    expect(ranges([bolt('a', kind: 'مکانیکی')]).ranges, isEmpty);
    expect(
        ranges([
          bolt('a',
              kind: 'مکانیکی', change: {'مدل': 'HST3', 'عمق کاشت': '100 mm'}),
          bolt('b',
              kind: 'مکانیکی', change: {'مدل': 'OTHER', 'عمق کاشت': '100 mm'})
        ]).ranges.length,
        2);
  });
  test('8 endpoints added without reordering or duplicate URLs', () {
    expect(endpoints.length, 82);
    expect(endpoints.first.id, 'melal-rebar');
    expect(endpoints.map((e) => e.id).toSet().length, 82);
  });
  test(
      'inline price unit/currency wins over toggle label; nominal package weight not injected',
      () {
    final q =
        SourceParser.parse(endpoint('rahsakht-wire'), semanticTable(), now)
            .single;
    expect(q.title, 'مفتول سیاه پخته 1/5');
    expect(q.amount, 1585000);
    expect(q.currency, 'ریال');
    expect(q.unit, 'kg');
    expect(q.marketAt, sourceDate('1405/08/16'));
    expect(q.pieceKg, isNull);
  });
  test(
      'rahsakht subsection h3 preserves declared price date only within section',
      () {
    final q =
        SourceParser.parse(endpoint('rahsakht-wire'), semanticTable(), now)
            .single;
    expect(q.details['مبنای تاریخ'], 'تاریخ صریح پیش از جدول');
  });
  test('missing currency is not inferred from site or amount', () {
    final body = semanticTable(price: '1585000 هر کیلوگرم')
        .replaceAll('(ریال / واحد مبنا)', '');
    final q = SourceParser.parse(endpoint('rahsakht-wire'), body, now).single;
    expect(q.amount, isNull);
    expect(q.currency, 'نامشخص');
    expect(q.details['مبلغ استخراج‌شده'], '1585000');
  });
  test(
      'missing inline unit remains unknown; header unit-mabna is not a real unit',
      () {
    final q = SourceParser.parse(endpoint('rahsakht-wire'),
            semanticTable(price: '1585000 ریال'), now)
        .single;
    expect(q.unit, 'unknown');
    expect(q.priceFor('kg'), isNull);
  });
  test('yearless or absent date never gets fetchedAt as marketAt', () {
    for (final d in ['', 'بروزرسانی ۶ دی']) {
      final q = SourceParser.parse(
              endpoint('rahsakht-wire'), semanticTable(date: d), now)
          .single;
      expect(q.marketAt, isNull);
    }
  });
  test('inquiry and conflicting currencies are not numeric rates', () {
    for (final p in ['تماس بگیرید', '1585000 ریال 158500 تومان']) {
      final q = SourceParser.parse(
              endpoint('rahsakht-wire'), semanticTable(price: p), now)
          .single;
      expect(q.amount, isNull);
    }
  });
  test('unit and preceding date never leak across a new main product section',
      () {
    final body = semanticTable(
        extra: semanticTable(date: '').replaceFirst(
            '<h2>لیست قیمت مفتول سیاه</h2>', '<h2>مفتول گالوانیزه</h2>'));
    final rows = SourceParser.parse(endpoint('rahsakht-wire'), body, now);
    expect(rows.length, 2);
    expect(rows.last.marketAt, isNull);
  });
  test('generic public parser does not inherit rahsakht inline-unit policy',
      () {
    final q = SourceParser.parse(
            const SourceEndpoint('x', 'x', 'https://example.com', 'مفتول',
                'public-table', 'نامشخص'),
            semanticTable(),
            now)
        .single;
    expect(q.unit, 'unknown');
  });
  testWidgets(
      'beginner selector exposes independent flat and both bolt methods',
      (t) async {
    await t
        .pumpWidget(const MaterialApp(home: Scaffold(body: CalculatorPage())));
    await t.tap(find.byType(DropdownButtonFormField<String>).first);
    await t.pumpAndSettle();
    expect(find.text('تسمه فولادی').last, findsOneWidget);
    expect(find.text('بولت / انکربولت خام — نظری').last, findsOneWidget);
    expect(find.text('انکر / ست کامل — وزن واقعی').last, findsOneWidget);
    await t.tap(find.text('تسمه فولادی').last);
    await t.pumpAndSettle();
    expect(
        find.widgetWithText(TextField, 'عرض تسمه (میلی‌متر)'), findsOneWidget);
    await t.scrollUntilVisible(find.text('محاسبه'), 250,
        scrollable: find.byType(Scrollable).first);
    await t.tap(find.text('محاسبه'));
    await t.pumpAndSettle();
    expect(find.text('۱۱٫۷۷۵ کیلوگرم'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  for (final spec in [
    ['بولت / انکربولت خام — نظری', '۱٫۲۳۳ کیلوگرم'],
    ['انکر / ست کامل — وزن واقعی', '۰٫۵۰۰ کیلوگرم']
  ]) {
    testWidgets(
        'beginner bolt method computes without hidden area inputs: ${spec.first}',
        (t) async {
      await t.pumpWidget(
          const MaterialApp(home: Scaffold(body: CalculatorPage())));
      await t.tap(find.byType(DropdownButtonFormField<String>).first);
      await t.pumpAndSettle();
      await t.tap(find.text(spec.first).last);
      await t.pumpAndSettle();
      await t.scrollUntilVisible(find.text('محاسبه'), 250,
          scrollable: find.byType(Scrollable).first);
      await t.tap(find.text('محاسبه'));
      await t.pumpAndSettle();
      expect(find.text(spec.last), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }
  test(
      'flat source branch and bolt evidence keep product-specific count labels',
      () {
    final q = Quote.fromJson(
        {...bolt('flat').toJson(), 'category': 'تسمه', 'title': 'تسمه فولادی'});
    expect(q.unitName('piece'), 'شاخه');
    final parsed = TextPriceEngine.analyze(
            text: 'بولت M20 قیمت هر عدد 100000 تومان',
            endpoint: 'x',
            seller: 'x',
            sourceUrl: 'https://example.com',
            fetchedAt: now,
            postId: '1')
        .first;
    expect(parsed.details['مبنای واحد'], 'عدد / ست');
  });
  testWidgets('bolt price card shows number or set, never branch label',
      (t) async {
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: QuoteCard(
                q: bolt('display'), basis: 'original', onChart: () {}))));
    await t.pumpAndSettle();
    expect(find.text('تومان / عدد / ست'), findsOneWidget);
    expect(find.text('تومان / شاخه'), findsNothing);
    expect(t.takeException(), isNull);
  });
}
