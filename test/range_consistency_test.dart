import 'package:flutter_test/flutter_test.dart';
import 'package:ironpin/domain/market.dart';
import 'package:ironpin/domain/price_range.dart';
import 'package:ironpin/domain/range_projection.dart';
import 'package:ironpin/domain/row_facts.dart';
import 'package:ironpin/domain/text_engine.dart';

/// «هر کیلو ۱۰۰ هزار تومان، هر تن ۱۰ هزار تومان» — one product whose claims
/// cannot all be true. The tab must not print either number as «میانگین»:
/// the claims are kept visible in the announcements, withheld from every
/// statistic and from the candidates, and the reason is counted.
DateTime now() => DateTime.utc(2026, 11, 8, 12);

List<Quote> read(String text, {String id = '1'}) =>
    TextPriceEngine.analyze(
      text: text,
      endpoint: 'e',
      seller: 'فروشنده',
      sourceUrl: 'https://t.me/s/x/$id',
      fetchedAt: now(),
      postId: id,
    );

ProductRangeResult viaTask(List<Quote> rows) => calculateProductRange({
      'quotes': rows,
      'query': const ProductRangeQuery('میلگرد', basis: ''),
      'now': now(),
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final claims = read('1405/08/17\nمیلگرد ۱۶ ذوب آهن\n'
      'کیلویی ۱۰۰ هزار تومان\nهر تن ۱۰ هزار تومان');

  test('one post claiming a kilo and a ton at once yields two rows', () {
    expect(claims.length, 2, reason: 'both lines are real announcements');
    final byUnit = {for (final q in claims) q.unit: q};
    expect(byUnit.keys, {'kg', 'ton'});
    expect(byUnit['kg']!.amount, 100000);
    expect(byUnit['ton']!.amount, 10000);
  });

  test(
      'claims that cannot both be true are withheld from statistics and candidates',
      () {
    // The synchronous path (RangeTask / legacy answer).
    final r = viaTask(claims);
    expect(r.announcements.length, 2,
        reason: 'both stay visible in «اعلام‌های نتیجه»');
    expect(r.ranges, isEmpty,
        reason: 'no honest mean can be printed for these two claims');
    expect(r.excluded[kgDisagreementReason], 2);

    // The worker path the app's tab actually runs.
    final idx = [
      for (final q in claims)
        RowFacts.ofQuote(q).toRow(payloadFingerprint('${q.id}:${q.fetchedAt}'))
    ];
    final projected = project(idx,
        family: 'میلگرد',
        fields: const {},
        basis: '',
        city: '',
        nowMs: now().millisecondsSinceEpoch,
        windowMs: 48 * 3600 * 1000);
    final answer = buildAnswer(projected,
        basis: '', at: now(), inputRows: idx.length);
    expect(answer.result.announcements.length, 2);
    expect(answer.result.ranges, isEmpty);
    expect(answer.result.excluded[kgDisagreementReason], 2);
    expect(answer.candidates, isEmpty,
        reason: 'a contradicted claim is not a candidate either');
  });

  test('one wrong digit leaves, the market around it stays', () {
    final rows = [
      ...read('1405/08/17\nمیلگرد ۱۶ ذوب آهن\nکیلویی ۱۲۵ هزار تومان', id: 'a'),
      ...read('1405/08/17\nمیلگرد ۱۶ ذوب آهن\nکیلویی ۱۳۰ هزار تومان', id: 'b'),
      ...read('1405/08/17\nمیلگرد ۱۶ ذوب آهن\nهر تن ۱۰ هزار تومان', id: 'c'),
    ];
    expect(rows.length, 3);
    final r = viaTask(rows);
    final kg = r.ranges.singleWhere((x) => x.basis == 'kg');
    expect(kg.announcements.length, 2,
        reason: 'the two agreeing claims keep their average');
    expect(kg.mean, 127500);
    expect(r.excluded[kgDisagreementReason], 1,
        reason: 'the ton claim (۱۰ کیلویی) is the wrong digit');
    expect(r.announcements.length, 3,
        reason: 'the wrong claim is still an announcement, just not a rate');
  });

  test('per-ton and per-kilo claims that agree are all counted', () {
    final rows = [
      ...read('1405/08/17\nمیلگرد ۱۶ ذوب آهن\nکیلویی ۱۲۵ هزار تومان', id: 'a'),
      ...read('1405/08/17\nمیلگرد ۱۶ ذوب آهن\nهر تن ۱۲۸ میلیون تومان', id: 'b'),
    ];
    expect(rows.length, 2);
    final r = viaTask(rows);
    expect(r.excluded[kgDisagreementReason], isNull,
        reason: '۱۲۸ میلیون در تن = ۱۲۸ هزار در کیلو، کنار ۱۲۵ هزار قابل قبول است');
    expect(r.ranges.length, 2, reason: 'each unit keeps its own average');
    expect(r.announcements.length, 2);
  });
}
