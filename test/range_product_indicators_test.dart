import 'package:flutter_test/flutter_test.dart';
import 'package:ironpin/domain/market.dart';
import 'package:ironpin/domain/price_range.dart';
import 'package:ironpin/domain/range_projection.dart';
import 'package:ironpin/domain/row_facts.dart';

/// 0.9.7 — تب رنج: هر کالا سه شاخص منحصر به فرد خودش (میانگین، بالاترین،
/// پایین‌ترین) دارد؛ میانگین ورق فولادی ۴ میل با ورق آلیاژی ۶ میل قاطی
/// نمی‌شود. هر کاندید بر اساس سه شاخصِ کالای خودش تعریف می‌شود و فهرست
/// کاندیدها فقط با درخواست کاربر نمایش داده می‌شود.
final at = DateTime.now().toUtc();

Quote sheet(int n,
        {required String thickness,
        String material = '',
        String grade = 'ST37',
        double amount = 100}) =>
    Quote(
        id: 's$n',
        endpoint: 'probe',
        seller: 'فروشنده$n',
        title: 'ورق $thickness میل',
        category: 'ورق',
        thickness: thickness,
        grade: grade,
        material: material,
        amount: amount,
        unit: 'kg',
        currency: 'تومان',
        sourceDateRaw: at.subtract(const Duration(hours: 1)).toIso8601String(),
        fetchedAt: at,
        sourceUrl: 'https://example.com/$n');

/// Same answer as the range tab's worker path (index → projection → answer).
RangeAnswer viaIndex(List<Quote> rows) {
  final index = [
    for (final q in rows)
      RowFacts.ofQuote(q).toRow(payloadFingerprint('${q.id}:${q.fetchedAt}'))
  ];
  final projected = project(index,
      family: 'ورق',
      fields: const {},
      basis: '',
      city: '',
      nowMs: at.millisecondsSinceEpoch,
      windowMs: 48 * 3600 * 1000);
  return buildAnswer(projected, basis: '', at: at, inputRows: index.length);
}

ProductRangeResult direct(List<Quote> rows) => calculateProductRange({
      'quotes': rows,
      'query': const ProductRangeQuery('ورق'),
      'now': at,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final carbon4 = [
    sheet(1, thickness: '4', amount: 100),
    sheet(2, thickness: '4', amount: 120),
  ];
  final alloy6 = [
    sheet(3, thickness: '6', material: 'فولاد آلیاژی', amount: 500),
    sheet(4, thickness: '6', material: 'فولاد آلیاژی', amount: 600),
  ];

  test('هر کالا سه شاخص منحصر به فرد خودش را دارد؛ میانگین‌ها قاطی نمی‌شوند',
      () {
    final r = direct([...carbon4, ...alloy6]);
    expect(r.ranges.length, 2, reason: 'یک کارت رنج برای هر کالا');
    final thin = r.ranges.singleWhere((x) => x.example.thicknessLabel == '4');
    expect(thin.minimum, 100);
    expect(thin.maximum, 120);
    expect(thin.mean, 110);
    final thick = r.ranges.singleWhere((x) => x.example.thicknessLabel == '6');
    expect(thick.minimum, 500);
    expect(thick.maximum, 600);
    expect(thick.mean, 550);
    // اعلام‌های هر دو کالا بدون تغییر در فهرست بالا باقی می‌مانند.
    expect(r.announcements.length, 4);
  });

  test('مسیر ایندکس (تب واقعی) همان جواب را می‌دهد و کاندیدها را می‌پوشاند',
      () {
    final answer = viaIndex([...carbon4, ...alloy6]);
    expect(answer.result.ranges.length, 2);
    final thin = answer.result.ranges
        .singleWhere((x) => x.example.thicknessLabel == '4');
    expect(thin.mean, 110);
    expect(answer.candidates.length, 4);
    for (final c in answer.candidates) {
      expect(c.counted, isTrue,
          reason: 'هر کاندید فهرست، در آمار همین رنج حساب شده است');
    }
    final covered = answer.result.ranges
        .fold<int>(0, (n, r) => n + r.announcements.length);
    expect(covered, answer.candidates.length,
        reason: 'آمار و فهرست کاندیدها یک مجموعه‌اند');
  });

  test('هر کاندید بر اساس سه شاخص کالای خودش تعریف می‌شود', () {
    final answer = viaIndex([
      sheet(1, thickness: '4', amount: 100),
      sheet(2, thickness: '4', amount: 120),
      sheet(3, thickness: '4', amount: 140),
      sheet(4, thickness: '6', material: 'فولاد آلیاژی', amount: 500),
    ]);
    expect(answer.candidates.length, 4);
    final byId = {
      for (final c in answer.candidates) c.wire['id'] as String: c
    };

    // کالای ۴ میل: میانگین ۱۲۰، بازه ۱۰۰ تا ۱۴۰.
    final m1 = byId['s1']!.mark!;
    expect(m1.minimum, 100);
    expect(m1.maximum, 140);
    expect(m1.mean, closeTo(120, 1e-9));
    expect(m1.roles, ['پایین‌ترین']);
    expect(m1.deviationPct, closeTo((100 - 120) / 120 * 100, 1e-9));

    final m2 = byId['s2']!.mark!;
    expect(m2.roles, ['نزدیک‌ترین به میانگین']);
    expect(m2.deviationPct, closeTo(0, 1e-9));

    final m3 = byId['s3']!.mark!;
    expect(m3.roles, ['بالاترین']);
    expect(m3.deviationPct, closeTo((140 - 120) / 120 * 100, 1e-9));

    // کاندید کالای ۶ میل با اعداد کالای خودش تعریف می‌شود، نه کالای ۴ میل.
    final m4 = byId['s4']!.mark!;
    expect(m4.minimum, 500);
    expect(m4.maximum, 500);
    expect(m4.mean, 500);
    expect(
        m4.roles,
        containsAll(
            ['پایین‌ترین', 'بالاترین', 'نزدیک‌ترین به میانگین']));
    expect(m4.deviationPct, closeTo(0, 1e-9));
    expect(m4.basis, 'kg');
  });

  test('نشان هر کاندید با کارت رنج کالای همان کاندید یکی است', () {
    final answer = viaIndex([...carbon4, ...alloy6]);
    for (final c in answer.candidates) {
      final mark = c.mark;
      expect(mark, isNotNull);
      final range = answer.result.ranges.singleWhere(
          (r) => r.announcements.any((q) => q.id == c.wire['id']));
      expect(mark!.minimum, range.minimum);
      expect(mark.maximum, range.maximum);
      expect(mark.mean, closeTo(range.mean, 1e-9));
      expect(mark.price,
          inInclusiveRange(range.minimum, range.maximum),
          reason: 'قیمت کاندید داخل بازهٔ همان کالا است');
    }
  });

  test('تغییر گرید هم کالای جدا می‌سازد؛ شاخص‌ها با هم قاطی نمی‌شوند', () {
    final r = direct([
      sheet(1, thickness: '4', grade: 'ST37', amount: 100),
      sheet(2, thickness: '4', grade: 'ST52', amount: 300),
    ]);
    expect(r.announcements.length, 2);
    expect(r.ranges.length, 2, reason: 'گرید بخشی از هویت کالا است');
    expect(r.ranges.map((x) => x.mean).toSet(), {100.0, 300.0});
  });
}
