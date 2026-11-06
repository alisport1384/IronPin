import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironpin/domain/market.dart';
import 'package:ironpin/domain/product_text.dart';
import 'package:ironpin/data/sources.dart';

Quote row(String id, String title,
        {String category = 'ورق',
        String city = 'مشهد',
        String brand = '',
        String loadingCity = 'نامشخص',
        String? thickness,
        Map<String, String> details = const {}}) =>
    Quote(
        id: id,
        endpoint: 'e',
        seller: 'فروشنده',
        sellerCity: city,
        title: title,
        category: category,
        brand: brand,
        loadingCity: loadingCity,
        thickness: thickness,
        unit: 'kg',
        currency: 'تومان',
        amount: 133000,
        sourceUrl: 'https://example.com',
        fetchedAt: DateTime.utc(2026, 11, 6),
        details: details);
void main() {
  final now = DateTime.utc(2026, 11, 6);
  test('sheet 3 means exact thickness, never price, year, 30, 13 or rebar size',
      () {
    final rows = [
      row('a', 'ورق سیاه 3 میل'),
      row('b', 'ورق سیاه 30 میل'),
      row('c', 'ورق 13 میل'),
      row('d', 'میلگرد 3', category: 'میلگرد'),
      row('e', 'ورق 2 میل', details: {'متن پیام': 'ورق 3 میل قیمت 133000'}),
      row('f', 'ورق سیاه ۳', thickness: '')
    ];
    for (final query in [
      'ورق ۳',
      'ورق3',
      'قیمت ورق ٣ میل',
      'ورق ضخامت 3 میلیمتر'
    ]) {
      final f = MarketFilter()..query = query;
      expect(f.apply(rows, now).map((q) => q.id).toSet(), {'a', 'f'},
          reason: query);
    }
  });
  test('search and ingestion share the same spec vocabulary and aliases', () {
    expect(ProductText.spec('ورق سیاه 3').thickness, '3');
    expect(
        ProductText.spec('3میل 600*150', categoryHint: 'ورق').thickness, '3');
    expect(ProductText.spec('قوطی 40×40 ضخامت 2').category, 'پروفیل');
    final q = row('a', 'پروفیل 40×40 ضخامت 2 ST37', category: 'پروفیل');
    final f = MarketFilter()..query = 'قوطی 40*40 ضخامت ۲ st۳۷';
    expect(f.matches(q, now), true);
    f.query = 'قوطی 40*40 ضخامت ۲ st52';
    expect(f.matches(q, now), false);
  });
  test('factory names are not silently treated as seller office cities', () {
    final f = MarketFilter()..query = 'میلگرد ۱۶ نیشابور';
    expect(
        f.matches(
            row('a', 'میلگرد 16 نیشابور', category: 'میلگرد', city: 'تهران'),
            now),
        true);
    f.query = 'ورق ۳ مشهد';
    expect(
        f.matches(
            row('b', 'ورق 3 میل', city: 'تهران', loadingCity: 'مشهد'), now),
        false);
    expect(f.matches(row('c', 'ورق 3 میل'), now), true);
    f.query = 'ورق 3 در مشهد ST37';
    expect(f.matches(row('z', 'ورق سیاه 3 میل ST37'), now), true);
    f.query = 'ورق 3 در تهران';
    expect(f.matches(row('d', 'ورق 3 میل', city: 'تهران'), now), true);
  });
  test('decimal and Persian/Arabic digits normalize without substring matches',
      () {
    final f = MarketFilter()..query = 'ورق ۱٫۵';
    expect(f.matches(row('a', 'ورق سیاه 1.5 میل'), now), true);
    expect(f.matches(row('b', 'ورق 15 میل'), now), false);
    f.query = 'ورق 3';
    f.matches(row('c', 'ورق3'), now);
    f.query = 'ورق 4';
    expect(f.matches(row('d', 'ورق3'), now), false);
  });
  test(
      'brand tokens need not be contiguous and caption of another product cannot satisfy them',
      () {
    final f = MarketFilter()..query = 'ورق 3 مبارکه سیاه';
    expect(f.matches(row('a', 'ورق سیاه 3 میل', brand: 'فولاد مبارکه'), now),
        true);
    expect(
        f.matches(
            row('b', 'ورق سیاه 3 میل',
                brand: 'کاویان',
                details: {'متن پیام': 'ورق سیاه 3 میل فولاد مبارکه'}),
            now),
        false);
  });
  test(
      'real observed Hayper sheet rows are analyzed automatically, every numbered line keeps its model',
      () {
    final e = endpoints.firstWhere((e) => e.id == 'telegram-hayperahan');
    final rows = SourceParser.parse(
        e,
        File('test/fixtures/hayper_sheets_observed.html').readAsStringSync(),
        now);
    expect(rows.where((q) => q.hasTextAmount).length, greaterThanOrEqualTo(16));
    final found = (MarketFilter()..query = 'ورق 3').apply(rows, now);
    expect(found.length, 3);
    expect(
        found.every((q) => q.currency == 'ریال' && q.unit == 'unknown'), true);
    expect(found.map((q) => q.amount).toSet(), {470000, 465000});
    expect(found.every((q) => q.details['تحلیل خودکار'] == 'محلی v2'), true);
    expect(
        (MarketFilter()
              ..recentWeek = true
              ..query = 'ورق 3')
            .apply(rows, now),
        isEmpty);
    expect(found.every((q) => q.publishedAt!.year == 2025), true);
  });
  test(
      'observed Fardad table content: date and all specs, but no invented currency',
      () {
    final e = endpoints.firstWhere((e) => e.id == 'fardad-sheet');
    final rows = SourceParser.parse(
        e,
        File('test/fixtures/fardad_sheets_reconstructed.html')
            .readAsStringSync(),
        now);
    expect(rows.length, 3);
    final q = rows.first;
    expect(q.title, contains('سیاه'));
    expect(q.thicknessLabel, '3.0');
    expect(q.gradeLabel.toUpperCase(), 'ST37');
    expect(q.dimensionsLabel, '2 × 1');
    expect(q.lengthM, 2);
    expect(q.unit, 'kg');
    expect(q.currency, 'نامشخص');
    expect(q.amount, isNull);
    expect(q.hasTextAmount, true);
    expect(q.isWithinWeek(now), true);
    expect(q.publishedAt, isNull);
    expect((MarketFilter()..query = 'ورق 3 مشهد').apply(rows, now).length, 2);
    expect(rows.last.hasTextAmount, false);
    expect(rows.last.amount, isNull);
  });
  test(
      'explicit table currency and row date win; changed price does not change identity',
      () {
    final e = endpoints.firstWhere((e) => e.id == 'fardad-sheet');
    final raw = File('test/fixtures/fardad_sheets_reconstructed.html')
        .readAsStringSync()
        .replaceAll('<th>قیمت</th>', '<th>قیمت (تومان)</th>');
    final a = SourceParser.parse(e, raw, now),
        b = SourceParser.parse(e, raw.replaceAll('185,000', '186,000'), now);
    expect(a.first.amount, 185000);
    expect(a.first.priceFor('kg'), 185000);
    expect(a.first.id, b.first.id);
    final nodate = SourceParser.parse(e, raw.replaceAll('۱۴۰۵/۰۸/۱۵', ''), now);
    expect(nodate.first.marketAt, isNull);
    expect(nodate.first.isWithinWeek(now), false);
  });
  test(
      'invalid explicit row date must not fall back to a valid date before table',
      () {
    final e = endpoints.firstWhere((e) => e.id == 'fardad-sheet');
    const raw =
        '<p>1405/08/15</p><table><tr><th>نام کالا</th><th>ضخامت</th><th>واحد</th><th>قیمت (تومان)</th><th>تاریخ</th></tr><tr><td>ورق 3 میل</td><td>3</td><td>کیلوگرم</td><td>185000</td><td>1405/13/99</td></tr></table>';
    final q = SourceParser.parse(e, raw, now).single;
    expect(q.marketAt, isNull);
    expect(q.isWithinWeek(now), false);
  });
  test(
      'explicit multi-thickness and descending range stay grouped but can be found by a member',
      () {
    final q = row('group', 'ورق 3 و 4 و 5 میل مبارکه');
    expect(q.thicknessLabel, '3 و 4 و 5');
    expect((MarketFilter()..query = 'ورق 3').matches(q, now), true);
    expect((MarketFilter()..query = 'ورق 30').matches(q, now), false);
    final r = row('range', 'ورق 15-6 میل مبارکه');
    expect(r.thicknessLabel, '15-6');
    expect((MarketFilter()..query = 'ورق 10').matches(r, now), true);
    expect((MarketFilter()..query = 'ورق 3').matches(r, now), false);
  });
}
