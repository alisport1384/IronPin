import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironpin/domain/market.dart';
import 'package:ironpin/domain/product_text.dart';
import 'package:ironpin/domain/product_schema.dart';
import 'package:ironpin/domain/price_range.dart';
import 'package:ironpin/domain/text_engine.dart';
import 'package:ironpin/data/app_logger.dart';
import 'package:ironpin/data/sources.dart';

final now = DateTime.utc(2026, 11, 7, 12);
Quote row(String id, double? amount,
        {String title = 'ورق سیاه 3',
        String category = 'ورق',
        String brand = '',
        String unit = 'kg',
        String currency = 'تومان',
        String date = '2026-11-07T08:00:00Z',
        String thickness = '3',
        String grade = 'ST37',
        String? post,
        Map<String, String> details = const {}}) =>
    Quote(
        id: id,
        endpoint: 'test',
        seller: 'فروشنده$id',
        sellerCity: id,
        brand: brand,
        title: title,
        category: category,
        amount: amount,
        unit: unit,
        currency: currency,
        sourceDateRaw: date,
        fetchedAt: now,
        sourceUrl: post ?? 'https://example.com',
        thickness: thickness,
        grade: grade,
        details: details);
Quote alter(Quote q, Map<String, dynamic> values) =>
    Quote.fromJson({...q.toJson(), ...values});
ProductRangeResult run(List<Quote> rows,
        {String family = 'ورق',
        Map<String, String> fields = const {},
        String basis = ''}) =>
    calculateProductRange({
      'quotes': rows,
      'query': ProductRangeQuery(family, fields: fields, basis: basis),
      'now': now
    });
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('plate synonyms are canonical and website page alone is not a product',
      () {
    for (final title in [
      'ورق سیاه 3',
      'پلیت سیاه 3',
      'صفحه فولادی 3',
      'شیت سیاه 3',
      'steel plate 3',
      'Steel Sheet 3'
    ]) {
      expect(ProductText.category(title), 'ورق');
      expect(ProductText.spec(title).thickness, '3');
    }
    expect(ProductText.category('صفحه اصلی تماس با ما'), '');
    expect(ProductText.category('آهن'), '');
  });
  test(
      'all technical families have independent fields and minimal blank filters',
      () {
    expect(
        productFields.keys,
        containsAll([
          'ورق',
          'نبشی',
          'میلگرد',
          'پروفیل',
          'لوله',
          'تیرآهن',
          'تسمه',
          'چهارپهلو',
          'توری',
          'مش جوشی',
          'شمش',
          'قراضه'
        ]));
    expect(productFields['نبشی']!.containsKey('dimensions'), true);
    expect(productFields['لوله']!.containsKey('schedule'), true);
    expect(productFields['ورق']!.containsKey('width'), true);
    expect(
        productFields.values.every((m) =>
            !m.containsKey('brand') &&
            !m.containsKey('city') &&
            !m.containsKey('seller')),
        true);
  });
  test(
      'selected physical fields, not source/brand/title/geography/tax, define market range',
      () {
    final a = row('a', 100, brand: 'مبارکه');
    final b = alter(row('b', 200, brand: 'اکسین', title: 'پلیت سیاه 3'),
        {'tax': 'با مالیات', 'loadingCity': 'تهران', 'terms': 'نقد'});
    final c = row('c', 300, brand: '');
    final r = run([a, b, c, row('d', 900, thickness: '30')],
        fields: {'thickness': '۳', 'grade': 'st37'});
    expect(r.announcements.map((q) => q.id).toSet(), {'a', 'b', 'c'});
    expect(r.ranges.single.mean, 200);
  });
  test(
      'minimal category default includes unspecified sizes but strict user-selected field excludes unknown',
      () {
    final rows = [
      row('a', 100),
      row('b', 900, thickness: '30'),
      row('c', 200, thickness: '', title: 'ورق سیاه')
    ];
    expect(run(rows).announcements.length, 3);
    expect(run(rows, fields: {'thickness': '3'}).announcements.single.id, 'a');
  });
  test(
      'time is publication/rate date, never fetched time; exact 48-hour endpoints',
      () {
    final r = run([
      row('a', 100,
          date: now.subtract(const Duration(hours: 48)).toIso8601String()),
      row('b', 200, date: now.toIso8601String()),
      row('old', 900,
          date: now
              .subtract(const Duration(hours: 48, seconds: 1))
              .toIso8601String()),
      row('future', 900,
          date: now.add(const Duration(seconds: 1)).toIso8601String()),
      row('unknown', 900, date: '')
    ]);
    expect(r.announcements.map((q) => q.id).toSet(), {'a', 'b'});
    expect(r.ranges.single.mean, 150);
  });
  test('all announcements weigh equally, not one vote per seller', () {
    final a = row('a', 100),
        b = alter(row('b', 200), {'seller': a.seller}),
        c = row('c', 900);
    expect(run([a, b, c]).ranges.single.mean, 400);
  });
  test(
      'different price units remain separate; unknown unit/currency/unpriced remain visible',
      () {
    final r = run([
      row('kg', 100),
      row('sheet', 900, unit: 'sheet'),
      row('unknownUnit', 300, unit: 'unknown'),
      row('unknownCurrency', 400, currency: 'نامشخص'),
      row('contact', null)
    ]);
    expect(r.announcements.length, 5);
    expect(r.ranges.map((r) => r.basis).toSet(), {'kg', 'sheet'});
    expect(r.ranges.singleWhere((r) => r.basis == 'kg').mean, 100);
    expect(r.excluded.values.reduce((a, b) => a + b), 3);
  });
  test(
      'explicit unit choice needs proven source conversion, not estimated density',
      () {
    final r = run([row('a', 100), row('b', 900, unit: 'sheet')], basis: 'kg');
    expect(r.announcements.length, 2);
    expect(r.ranges.single.mean, 100);
  });
  test('explicit rials convert once and three modes use actual points', () {
    final r = run([row('rial', 1000, currency: 'ریال'), row('toman', 200)])
        .ranges
        .single;
    expect(r.rate('min'), 100);
    expect(r.rate('max'), 200);
    expect(r.rate('mean'), 150);
  });
  test(
      'post edits deduplicate but different products in one post do not vanish',
      () {
    final a = row('a', 100, post: 'https://t.me/market/1');
    final edit = alter(a, {
      'amount': 200,
      'fetchedAt': now.add(const Duration(minutes: 1)).toIso8601String()
    });
    final other = row('b', 400, thickness: '4', post: 'https://t.me/market/1');
    final r = run([a, edit, other, a]);
    expect(r.announcements.length, 2);
    expect(r.ranges.single.mean, 300);
  });
  test(
      'legacy specs normalize numeric syntax without inferring missing dimension units',
      () {
    final q = row('a', 100,
        details: {'عرض': '1000', 'طول': '2', 'ابعاد': '1000×2000'});
    final f = ProductFacts.of(q);
    expect(f.matches({'width': '۱۰۰۰', 'dimensions': '2000x1000'}), true);
    expect(f.values['dimUnit'], '');
    expect(f.matches({'dimUnit': 'mm'}), false);
  });
  test(
      'automatic ingestion recognizes plate aliases and persists structured evidence',
      () {
    final q = TextPriceEngine.enrich(
        row('a', 100, title: 'پلیت سیاه 3', category: 'عمومی', thickness: ''));
    expect(q.category, 'ورق');
    expect(q.thicknessLabel, '3');
    expect(q.details['مشخصات.kind'], 'سیاه');
    expect(q.details['نسخه مشخصات'], '1');
    expect(q.id, 'a');
    expect(q.sourceDateRaw, '2026-11-07T08:00:00Z');
  });
  test('more than a hundred recent offers remain in results', () {
    final r =
        run([for (var i = 0; i < 125; i++) row('$i', 100 + i.toDouble())]);
    expect(r.announcements.length, 125);
    expect(r.ranges.single.announcements.length, 125);
  });
  test(
      'unknown general iron is visible under other, but not pooled as a known product',
      () {
    final r =
        run([row('a', 100, title: 'آهن', category: 'عمومی')], family: 'سایر');
    expect(r.announcements.length, 1);
    expect(r.ranges, isEmpty);
  });
  test(
      'new Samen adapter reads transcribed observed columns, units and per-section dates',
      () {
    // Research-transcribed contract fixture; NOT represented as downloaded raw HTML.
    const html = '''<h2>نبشی کارخانه سپهر</h2><p>شنبه 16 آبان 1405</p><table>
  <tr><th>سایز</th><th>ضخامت</th><th>برند</th><th>حالت</th><th>واحد فروش</th><th>اسم</th><th>قیمت (تومان)</th></tr>
  <tr><td>40*40</td><td>3</td><td>سپهر</td><td>6متری</td><td>کیلوگرم</td><td>نبشی 4 سپهر ضخامت 3میل</td><td>71,000</td></tr>
  <tr><td>30*30</td><td>2.5</td><td>سپهر</td><td>6متری</td><td>کیلوگرم</td><td>نبشی 3 ضخامت 2.5میل</td><td>تماس بگیرید</td></tr></table>''';
    final rows = SourceParser.parse(
        endpoints.singleWhere((e) => e.id == 'samen-angle'), html, now);
    expect(rows.length, 2);
    expect(rows.first.amount, 71000);
    expect(rows.first.unit, 'kg');
    expect(rows.first.category, 'نبشی');
    expect(rows.first.thicknessLabel, '3.0');
    expect(rows.first.dimensionsLabel, '40*40');
    expect(rows.last.amount, isNull);
    expect(rows.first.marketAt, isNotNull);
  });
  test(
      'multi-family Shahr table identifies each row and never concatenates VAT dual prices',
      () {
    const html =
        '''<h2>پروفیل صنعتی</h2><p>آخرین بروزرسانی قیمت: 1405/08/16</p><table>
  <tr><th>محصول</th><th>سایز</th><th>ضخامت</th><th>واحد فروش</th><th>قیمت (تومان)</th></tr>
  <tr><td><a href="/p/1">پروفیل 2×40×40</a><br>ضخامت:2</td><td>40x40</td><td>2</td><td>کیلوگرم</td><td>178,200 162,000 ثابت</td></tr></table>
  <h2>ورق سیاه</h2><table><tr><th>محصول</th><th>ضخامت</th><th>واحد فروش</th><th>قیمت (تومان)</th></tr>
  <tr><td>ورق سیاه 2 عرض 1000</td><td>2</td><td>کیلوگرم</td><td>تماس بگیرید</td></tr></table>''';
    final rows = SourceParser.parse(
        endpoints.singleWhere((e) => e.id == 'shahr-mashhad'), html, now);
    expect(rows.length, 2);
    expect(rows.first.category, 'پروفیل');
    expect(rows.first.amount, isNull);
    expect(rows.first.details['مبلغ چندگانه'], 'بله');
    expect(rows.last.category, 'ورق');
    expect(rows.last.marketAt, isNull,
        reason:
            'a new undated section must not inherit another product table date');
  });
  test(
      'legacy carbon material default cannot establish a selected material match',
      () {
    final q = row('unknown-material', 100);
    expect(run([q]).announcements.length, 1);
    expect(
        run([q], fields: {'material': 'فولاد کربنی'}).announcements, isEmpty);
    expect(
        run([
          row('declared', 100, details: {'جنس': 'فولاد کربنی'})
        ], fields: {
          'material': 'فولاد کربنی'
        }).announcements.length,
        1);
  });
  test(
      'three-number dimensions are not arbitrarily reversed and grades retain supplier spelling',
      () {
    final f = ProductFacts.of(alter(row('a', 100), {'dimensions': '2x40x60'}));
    expect(f.matches({'dimensions': '60x40x2'}), false);
    expect(ProductText.spec('پروفیل S355J2H 40x40 ضخامت 2').grade, 'S355J2H');
    expect(ProductText.spec('مفتول 2').size, '2');
    expect(
        ProductFacts.of(
                row('r', 100, title: 'رابیتس 13 ستون', category: 'رابیتس'))
            .values['columns'],
        '13');
  });
  group('bounded source/product logs', () {
    late Directory dir;
    late AppLogger log;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('ironpin-070-');
      log = AppLogger(enabled: true, maxBytes: 4096, fileBytes: 1024);
      await log.initialize(directory: dir);
    });
    tearDown(() async {
      await log.flush();
      await dir.delete(recursive: true);
    });
    test('UI/lifecycle/filter/stack/raw content are not persisted', () async {
      for (final name in [
        'lifecycle',
        'filter',
        'calculation',
        'flutter',
        'storage'
      ]) {
        await log.record(name, 'event', {'rows': 1});
      }
      expect(await log.files(), isEmpty);
      await log.record('source', 'fetch', {
        'endpoint': 'samen-angle',
        'rows': 3,
        'stack': 'not allowed',
        'html': 'not allowed',
        'phone': 'not allowed'
      });
      final text = await (await log.files()).single.readAsString();
      expect(text, contains('samen-angle'));
      expect(text, contains('"rows":3'));
      expect(text, isNot(contains('not allowed')));
    });
    test(
        'only ten product summaries are logged; identical snapshots do not grow log',
        () async {
      final fields = {
        'endpoint': 'a',
        'products': [
          for (var i = 0; i < 30; i++)
            {'id': 'p$i', 'category': 'ورق', 'amount': 100}
        ]
      };
      await log.record('product', 'changed', fields);
      final before = await (await log.files()).single.length();
      await log.record('product', 'changed', fields);
      expect(await (await log.files()).single.length(), before);
      final text = await (await log.files()).single.readAsString();
      expect(text, contains('p9'));
      expect(text, isNot(contains('p10')));
    });
    test('minimum 512-byte file cap also bounds Persian oversized fallback',
        () async {
      final tiny = AppLogger(enabled: true, maxBytes: 1024, fileBytes: 512);
      await tiny.initialize(directory: dir);
      await tiny.record('source', 'fetch', {
        'endpoint': 'آ' * 200,
        'products': List.filled(10, {'id': 'آ' * 200})
      });
      for (final file in await tiny.files()) {
        expect(await file.length(), lessThanOrEqualTo(512));
      }
    });
    test('UTF8 total and per-file cap hold under rotation and parallel calls',
        () async {
      await Future.wait([
        for (var i = 0; i < 100; i++)
          log.record('source', 'fetch', {
            'endpoint': 'منبع$i',
            'rows': i,
            'coverage': 'ورق با مشخصات دقیق ${'آهن ' * 70}'
          })
      ]);
      final files = await log.files();
      var total = 0;
      for (final file in files) {
        final b = await file.readAsBytes();
        expect(b.length, lessThanOrEqualTo(1024));
        utf8.decode(b);
        total += b.length;
      }
      expect(total, lessThanOrEqualTo(4096));
      expect(total, greaterThan(0));
    });
    test(
        'legacy diagnostic log is retired, unrelated files/database are preserved',
        () async {
      final old = File('${dir.path}/IronPin-2026-01-01.md');
      await old.writeAsString('old lifecycle stack');
      final db = File('${dir.path}/prices.db');
      await db.writeAsString('precious product history');
      final unrelated = File('${dir.path}/notes.md');
      await unrelated.writeAsString('user note');
      await log.initialize(directory: dir);
      expect(await old.exists(), false);
      expect(await db.readAsString(), 'precious product history');
      expect(await unrelated.exists(), true);
    });
  });
}
