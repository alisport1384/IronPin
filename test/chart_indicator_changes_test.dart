import 'package:flutter_test/flutter_test.dart';
import 'package:ironpin/domain/market.dart';
import 'package:ironpin/ui/chart_page.dart';

/// 0.9.7 — نمودار تب «شاخص‌های رنج»: فقط تغییرات میانگین/بالاترین/پایین‌ترین
/// ثبت می‌شود، نه هر رسیدِ دریافتی. همان محاسبهٔ پنجرهٔ غلتان تب رنج.
Quote rec(int n, double amount, DateTime at) => Quote(
    id: 'q$n',
    endpoint: 'chart',
    seller: 'فروشنده',
    title: 'ورق سیاه 3',
    category: 'ورق',
    thickness: '3',
    grade: 'ST37',
    amount: amount,
    unit: 'kg',
    currency: 'تومان',
    sourceDateRaw: at.toIso8601String(),
    fetchedAt: at,
    sourceUrl: 'https://example.com/$n');

void main() {
  final t0 = DateTime.utc(2026, 11, 1, 8);

  test('تکرار بدون تغییر نقطه نمی‌سازد؛ هر شاخص لحظهٔ خودش را ثبت می‌کند', () {
    final records = [
      rec(1, 100, t0),
      rec(2, 200, t0.add(const Duration(hours: 1))),
      rec(3, 200, t0.add(const Duration(hours: 2))),
    ];
    final s = indicatorChanges(records, basis: 'kg');
    expect(s.records, 3);
    // میانگینِ تجمعی: ۱۰۰ → ۱۵۰ → ۱۶۶٫۶۷ (هر رکوردِ تازه عدد را می‌برد).
    final mean = s.changes['mean']!;
    expect(mean.length, 3);
    expect(mean[0].value, 100);
    expect(mean[0].changePct, 0);
    expect(mean[1].value, 150);
    expect(mean[1].changePct, closeTo(50, 1e-9));
    expect(mean[2].value, closeTo(500 / 3, 1e-9));
    // بالاترین: ۱۰۰ → ۲۰۰؛ رکوردِ تکراری بدون تغییر نقطه نمی‌سازد.
    final high = s.changes['high']!;
    expect(high.length, 2);
    expect(high.map((c) => c.value), [100, 200]);
    // پایین‌ترین: ۱۰۰ می‌ماند؛ فقط نقطهٔ اول.
    final low = s.changes['low']!;
    expect(low.length, 1);
    expect(low.single.value, 100);
    // همه نقاط مرتب زمانی‌اند.
    for (final list in s.changes.values) {
      for (var i = 1; i < list.length; i++) {
        expect(list[i].at.isAfter(list[i - 1].at), isTrue);
      }
    }
  });

  test('پنجرهٔ غلتان رکورد قدیمی را بیرون می‌ریزد و همان لحظه تغییر می‌سازد', () {
    final records = [
      rec(1, 1000, t0),
      rec(2, 10, t0.add(const Duration(hours: 5))),
    ];
    final s = indicatorChanges(records,
        basis: 'kg', window: const Duration(hours: 1));
    final high = s.changes['high']!;
    // با پنجرهٔ یک‌ساعته رکورد اول بیرون می‌افتد: بالاترین از ۱۰۰۰ به ۱۰
    // می‌جهد و همان لحظه ثبت می‌شود.
    expect(high.length, 2);
    expect(high.last.value, 10);
    expect(high.last.changePct, closeTo((10 - 1000) / 1000 * 100, 1e-9));
    // بدون پنجره رکورد اول همیشه در مجموعه است: بالاترین ۱۰۰۰ می‌ماند و
    // تغییری در آن ثبت نمی‌شود.
    final withoutWindow = indicatorChanges(records, basis: 'kg');
    expect(withoutWindow.changes['high']!.length, 1);
    expect(withoutWindow.changes['high']!.single.value, 1000);
  });

  test('بدون رکورد سری خالی است، نه خطابه', () {
    final s = indicatorChanges([], basis: 'kg');
    expect(s.isEmpty, isTrue);
    expect(s.records, 0);
    expect(s.changes['mean'], isEmpty);
  });

  test('قیمتِ بدون تومانِ معتبر در محاسبه نمی‌آید', () {
    final bad = Quote(
        id: 'x',
        endpoint: 'chart',
        seller: 'فروشنده',
        title: 'بدون قیمت',
        category: 'ورق',
        amount: null,
        unit: 'kg',
        currency: 'تومان',
        sourceDateRaw: t0.toIso8601String(),
        fetchedAt: t0,
        sourceUrl: 'https://example.com/x');
    final s = indicatorChanges([bad, rec(1, 50, t0)], basis: 'kg');
    // فقط ردیفِ قیمت‌دار اثر می‌گذارد: میانگینِ اول همان ۵۰ است.
    expect(s.changes['mean']!.single.value, 50);
  });
}
