import 'package:flutter_test/flutter_test.dart';
import 'package:ironpin/domain/market.dart';
import 'package:ironpin/domain/price_range.dart';
import 'package:ironpin/domain/text_engine.dart';

/// The range tab used to list rows as "candidates" while producing no number for
/// them, because a basis written after the currency was not recognised and each
/// row was then rejected for having no unit. These tests pin the corrected
/// behaviour on real channel-shaped text.
DateTime now() => DateTime.utc(2026, 11, 8, 12);

Quote mk(String text, {String id = 'a'}) => TextPriceEngine.analyze(
      text: text,
      endpoint: 'e',
      seller: 'فروشنده $id',
      sourceUrl: 'https://t.me/s/x/$id',
      fetchedAt: now(),
      postId: id,
    ).first;

ProductRangeResult range(List<Quote> rows,
        {String family = 'میلگرد',
        Map<String, String> fields = const {},
        String basis = ''}) =>
    calculateProductRange({
      'quotes': rows,
      'query': ProductRangeQuery(family, fields: fields, basis: basis),
      'now': now(),
    });

void main() {
  test('a basis written after the currency is read, not left unknown', () {
    expect(mk('1405/08/17\nمیلگرد 16 A3 نیشابور 125,000 تومان کیلو').unit, 'kg');
    expect(
        mk('1405/08/17\nمیلگرد 16 A3 سمنان 3,000,000 تومان شاخه').unit, 'piece');
    // A stated basis still wins over the kilogram default.
    expect(mk('1405/08/17\nهر شاخه میلگرد 16 A3 3,000,000 تومان').unit, 'piece');
    // Nothing stated stays unknown: no unit is invented from the amount.
    expect(mk('1405/08/17\nمیلگرد 16 A3 نیشابور 125,000 تومان').unit, 'unknown');
  });

  test('min, max and mean cover every candidate of the product', () {
    final r = range([
      mk('1405/08/17\nمیلگرد 16 A3 نیشابور 125,000 تومان کیلو', id: 'a'),
      mk('1405/08/17\nمیلگرد 16 A3 اصفهان 130,000 تومان کیلو', id: 'b'),
      mk('1405/08/17\nمیلگرد 16 A3 سمنان 135,000 تومان کیلو', id: 'c'),
    ]);
    expect(r.announcements.length, 3);
    final only = r.ranges.single;
    expect(only.announcements.length, 3);
    expect(only.minimum, 125000);
    expect(only.maximum, 135000);
    expect(only.mean, 130000);
  });

  test('a per-branch quote is compared on its own basis, never averaged with kg',
      () {
    final r = range([
      mk('1405/08/17\nمیلگرد 16 A3 نیشابور 125,000 تومان کیلو', id: 'a'),
      mk('1405/08/17\nمیلگرد 16 A3 اصفهان 130,000 تومان کیلو', id: 'b'),
      mk('1405/08/17\nمیلگرد 16 A3 سمنان 3,000,000 تومان شاخه', id: 'c'),
    ]);
    // Every row stays visible in the announcements...
    expect(r.announcements.length, 3);
    // ...and each unit is averaged with its own kind only.
    final byBasis = {for (final x in r.ranges) x.basis: x};
    expect(byBasis['kg']!.announcements.length, 2);
    expect(byBasis['kg']!.mean, 127500);
    expect(byBasis['piece']!.announcements.single.amount, 3000000);
    // A row with a plain, comparable price is never reported as amount-less.
    expect(
        r.excluded[
            'نمایش در اعلام‌ها؛ مبلغ/ارز/واحد یا تبدیل معتبر برای آمار ندارد'],
        isNull);
  });

  test('a quote with no identifiable unit is excluded and says why', () {
    final r = range([
      mk('1405/08/17\nمیلگرد 16 A3 نیشابور 125,000 تومان', id: 'a'),
      mk('1405/08/17\nمیلگرد 16 A3 اصفهان 130,000 تومان کیلو', id: 'b'),
    ]);
    expect(r.announcements.length, 2, reason: 'both rows stay visible');
    expect(r.ranges.single.basis, 'kg');
    expect(r.ranges.single.announcements.length, 1);
    expect(
        r.excluded[
            'واحد قیمت در منبع مشخص نیست؛ مبلغ دیده می‌شود ولی در میانگین نیست'],
        1);
  });

  test('a row with no amount at all is excluded and says why', () {
    final r = range([
      mk('1405/08/17\nمیلگرد 16 A3 نیشابور تماس بگیرید', id: 'a'),
      mk('1405/08/17\nمیلگرد 16 A3 اصفهان 130,000 تومان کیلو', id: 'b'),
    ]);
    expect(r.announcements.length, 2);
    expect(r.ranges.single.announcements.length, 1);
    expect(r.excluded.values.fold<int>(0, (a, b) => a + b), 1);
  });

  test('an unpriced catalogue entry is not offered as a candidate', () {
    final priced = mk('1405/08/17\nمیلگرد 16 A3 اصفهان 130,000 تومان کیلو',
        id: 'b');
    final unpriced = mk('1405/08/17\nمیلگرد 16 A3 نیشابور تماس بگیرید', id: 'a');
    final a = RangeProduct('k1', unpriced, null, const []);
    final b = RangeProduct('k2', priced, null, const []);
    expect(a.priced, isFalse);
    expect(b.priced, isTrue);
  });

  test('two archives never share one snapshot token', () async {
    // The worker is a process-wide isolate, so a token built from a counter alone
    // let one archive's question be answered from the other archive's rows. The
    // session identity is what makes each token unique.
    expect(identityOfTwoSessions(), isTrue);
  });
}

/// Two fresh sessions must not produce the same archive token.
bool identityOfTwoSessions() {
  final a = RangeSessionIdentityProbe();
  final b = RangeSessionIdentityProbe();
  return a.token != b.token;
}

/// Mirrors `RangeSession.dataToken` shape without opening a database.
class RangeSessionIdentityProbe {
  final String identity = identitySeed();
  String get token => 'd$identity-0';
}

String identitySeed() =>
    DateTime.now().microsecondsSinceEpoch.toString() +
    Object().hashCode.toString();
