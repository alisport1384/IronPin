import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironpin/data/sources.dart';
import 'package:ironpin/domain/market.dart';
import 'package:ironpin/domain/text_engine.dart';

void main() {
  final now = DateTime.utc(2026, 11, 6, 10);
  List<Quote> parse(String id, String fixture) => SourceParser.parse(
      endpoints.firstWhere((e) => e.id == id),
      File('test/fixtures/$fixture.html').readAsStringSync(),
      now);
  test(
      'all curated endpoints are enabled on fresh installation; candidates remain unapproved',
      () {
    expect(endpoints.length, 70);
    expect(endpoints.every((e) => e.defaultEnabled), true);
    expect(
        endpoints
            .map((e) => e.url.toLowerCase().replaceFirst(RegExp(r'/$'), ''))
            .toSet()
            .length,
        endpoints.length);
    expect(publicChannel('https://t.me/unreviewed_channel')!.defaultEnabled,
        false);
  });
  test(
      'actual newly found Ghanbari sheets include three recent exact thickness 3 rows',
      () {
    final rows = parse('telegram-ghanbari', 'ghanbari_sheets_observed');
    final found = (MarketFilter()
          ..query = 'ورق3 مشهد'
          ..recentWeek = true)
        .apply(rows, now);
    expect(found.length, 3);
    expect(
        found
            .map((q) =>
                TextPriceEngine.money(q.details['مبلغ استخراج‌شده'] ?? ''))
            .toSet(),
        {1850000, 1870000});
    expect(found.every((q) => q.priceFor('kg') == null), true);
    expect(found.every((q) => q.details['تحلیل خودکار'] == 'محلی v2'), true);
  });
  test(
      'real Khabazzade grouped sizes remain grouped and searchable without invented currency',
      () {
    final rows = parse('telegram-khabazzade', 'khabazzade_observed');
    final found = (MarketFilter()
          ..query = 'میلگرد16 مشهد'
          ..recentWeek = true)
        .apply(rows, now);
    expect(found.length, 1);
    expect(
        TextPriceEngine.money(found.single.details['مبلغ استخراج‌شده'] ?? ''),
        123500);
    expect(found.single.currency, 'نامشخص');
    expect(found.single.priceFor('kg'), isNull);
  });
  test(
      'new product-price-date table works without unit column and preserves individual old dates',
      () {
    final rows = parse('khabazzade-sheet', 'khabazzade_table_reconstructed');
    expect(rows.length, 3);
    expect(rows.every((q) => q.unit == 'unknown'), true);
    expect(rows.every((q) => q.priceFor('original') == null), true);
    expect(rows.map((q) => q.amount).toSet(), {184000, 177000, 120000});
    expect(rows.where((q) => q.isWithinWeek(now)).length, 2);
  });
}
