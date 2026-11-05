import 'package:flutter_test/flutter_test.dart';
import 'package:ironpin/domain/market.dart';

Quote quote(String id, double? amount,
        {String city = 'اصفهان',
        String loadingCity = 'تبریز',
        String unit = 'kg',
        String date = '۱۴۰۵/۸/۱۴',
        String tax = 'بدون ارزش افزوده',
        double? weight}) =>
    Quote(
        id: id,
        endpoint: 'test',
        seller: 'فروشنده',
        sellerCity: city,
        title: 'میلگرد 16 A3',
        category: 'میلگرد',
        unit: unit,
        amount: amount,
        fetchedAt: DateTime.utc(2026, 11, 5, 8),
        sourceDateRaw: date,
        sourceUrl: 'https://example.com',
        loadingCity: loadingCity,
        tax: tax,
        pieceKg: weight);
void main() {
  final now = DateTime.utc(2026, 11, 5, 9);
  test('normalizes Persian and Arabic digits', () {
    expect(number('۱۲۳٬۴۵۶٫۵'), 123456.5);
    expect(number('١٢٣,٤٥٦'), 123456);
    expect(latin('كالا ي'), 'کالا ی');
  });
  test('Jalali source date is not capture time', () {
    expect(sourceDate('۱۴۰۵/۸/۱۴')!.add(const Duration(hours: 3, minutes: 30)),
        DateTime.utc(2026, 11, 5));
  });
  test('unknown date not replaced with today', () {
    expect(sourceDate('تماس بگیرید'), null);
  });
  test('freshness uses announced date', () {
    expect(quote('a', 100, date: '۱۴۰۵/۸/۱۰').isFresh(now), false);
    expect(quote('b', 100).isFresh(now), true);
  });
  test('future date not trusted', () {
    expect(quote('a', 100, date: '۱۴۰۵/۹/۱۰').isFresh(now), false);
  });
  test('ascending order within unit group', () {
    final f = MarketFilter()..mashhadFirst = false;
    expect(f.apply([quote('a', 200), quote('b', 100)], now).map((x) => x.id),
        ['b', 'a']);
  });
  test('descending order within group', () {
    final f = MarketFilter()..sort = 'desc';
    expect(f.apply([quote('a', 200), quote('b', 100)], now).map((x) => x.id),
        ['a', 'b']);
  });
  test('Mashhad priority can override price but explicit toggle disables it',
      () {
    final list = [quote('a', 200, city: 'مشهد'), quote('b', 100)];
    final f = MarketFilter();
    expect(f.apply(list, now).first.id, 'a');
    f.mashhadFirst = false;
    expect(f.apply(list, now).first.id, 'b');
  });
  test('seller city never inferred from loading city', () {
    final f = MarketFilter()..city = 'تبریز';
    expect(f.apply([quote('a', 100)], now), isEmpty);
    f.cityKind = 'loading';
    expect(f.apply([quote('a', 100)], now).length, 1);
  });
  test('unit filter preserves original branch type', () {
    final f = MarketFilter()..unit = 'piece';
    expect(
        f
            .apply([quote('a', 100), quote('b', 1000, unit: 'piece')], now)
            .single
            .id,
        'b');
  });
  test('kg normalization needs real supplied mass', () {
    expect(quote('a', 2000, unit: 'piece').priceFor('kg'), null);
    expect(quote('a', 2000, unit: 'piece', weight: 20).priceFor('kg'), 100);
  });
  test('branch and kilogram stay separate without conversion', () {
    expect(quote('a', 100).comparisonGroup('original'),
        isNot(quote('b', 100, unit: 'piece').comparisonGroup('original')));
  });
  test('different tax basis remains separate', () {
    expect(quote('a', 100).comparisonGroup('kg'),
        isNot(quote('b', 100, tax: 'نامشخص').comparisonGroup('kg')));
  });
  test('price range applied to chosen comparison basis', () {
    final f = MarketFilter()
      ..basis = 'kg'
      ..minPrice = 90
      ..maxPrice = 110;
    expect(
        f
            .apply(
                [quote('a', 2000, unit: 'piece', weight: 20), quote('b', 120)],
                now)
            .single
            .id,
        'a');
  });
  test('no price is not zero and not ranked', () {
    final f = MarketFilter();
    expect(f.apply([quote('a', null)], now), isEmpty);
    f.includeUnpriced = true;
    expect(f.apply([quote('a', null)], now).length, 1);
  });
  test('category material search filters', () {
    final f = MarketFilter()
      ..query = '۱۶'
      ..material = 'فولاد کربنی'
      ..category = 'میلگرد';
    expect(f.apply([quote('a', 100)], now).length, 1);
    f.category = 'ورق';
    expect(f.apply([quote('a', 100)], now), isEmpty);
  });
  test('serialization preserves raw quote and history signature', () {
    final q = quote('a', 2000, weight: 20);
    final decoded = Quote.fromJson(q.toJson());
    expect(decoded.signature, q.signature);
    expect(decoded.amount, 2000);
  });
  test('material detection does not equate alloys to stainless', () {
    expect(materialOf('ورق استیل 304'), 'استنلس استیل');
    expect(materialOf('میلگرد CK45'), 'فولاد آلیاژی');
    expect(materialOf('ورق آلومینیوم'), 'آلومینیوم');
  });
}
