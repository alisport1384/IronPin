import 'package:flutter_test/flutter_test.dart';
import 'package:ironpin/domain/market.dart';
import 'package:ironpin/domain/range_projection.dart';
import 'package:ironpin/domain/row_facts.dart';
import 'package:ironpin/ui/range_page.dart';

/// The range tab must offer exactly what it computes from: a candidate is a
/// dated announcement with a comparable price, and min, max and mean are taken
/// from every candidate the tab lists — never from a subset of it.
final at = DateTime.now().toUtc();

Quote row(int n,
        {double? amount = 20181000,
        String currency = 'تومان',
        String unit = 'kg',
        String date = 'hours',
        String category = 'تیرآهن'}) =>
    Quote(
        id: 'u$n',
        endpoint: 'probe',
        seller: 'فروشنده$n',
        title: 'تیرآهن 14 ذوب آهن اصفهان',
        category: category,
        size: '14',
        amount: amount,
        unit: unit,
        currency: currency,
        sourceDateRaw: date == 'hours'
            ? at.subtract(const Duration(hours: 2)).toIso8601String()
            : date,
        fetchedAt: at,
        sourceUrl: 'https://example.com/$n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('candidates are dated and priced, and the statistics cover them all',
      () {
    Map<String, Object?> idx(Quote q) => RowFacts.ofQuote(q)
        .toRow(payloadFingerprint('${q.id}:${q.fetchedAt}'));
    final rows = [
      idx(row(1)), // dated, kg, priced → candidate and counted
      idx(row(2, unit: 'unknown')), // priced amount, no unit → no comparable price
      idx(row(3, currency: 'نامشخص')), // no convertible currency
      idx(row(4, amount: null)), // no amount at all
      // Dated only by the publication time of the post — still a real date.
      idx(Quote(
          id: 'u5',
          endpoint: 'probe',
          seller: 'فروشنده5',
          title: 'تیرآهن 14 ذوب آهن اصفهان',
          category: 'تیرآهن',
          size: '14',
          amount: 20181000,
          unit: 'kg',
          currency: 'تومان',
          sourceDateRaw: '',
          details: {
            'زمان انتشار پیام':
                at.subtract(const Duration(hours: 1)).toIso8601String()
          },
          fetchedAt: at,
          sourceUrl: 'https://example.com/5')),
      idx(row(6, unit: 'piece', amount: 3000000)),
      // No date at all: no rate text and no publication time.
      idx(row(7, date: '', amount: 20181000)),
    ];
    final projected = project(rows,
        family: 'تیرآهن',
        fields: const {},
        basis: '',
        city: '',
        nowMs: at.millisecondsSinceEpoch,
        windowMs: 48 * 3600 * 1000);
    final answer = buildAnswer(projected,
        basis: '', at: at, inputRows: rows.length);

    // 1) No candidate without a date or without a price.
    expect(answer.candidates, isNotEmpty);
    for (final c in answer.candidates) {
      expect(c.wire['marketAt'], isNotNull,
          reason: 'candidate without a date: ${c.wire['id']}');
      final text = candidatePriceText(c);
      expect(text, isNot(contains('بدون قیمت')),
          reason: 'candidate without a price: ${c.wire['id']} ($text)');
    }
    // The undated row and the rows without a comparable price are not offered.
    final ids = answer.candidates.map((c) => c.wire['id']).toSet();
    expect(ids, {'u1', 'u5', 'u6'});

    // 2) min, max and mean are taken from all candidates: every listed
    // candidate is counted, and the ranges together cover exactly the list.
    for (final c in answer.candidates) {
      expect(c.counted, isTrue,
          reason: '${c.wire['id']} is listed but missing from the statistics');
    }
    final covered = answer.result.ranges
        .fold<int>(0, (n, r) => n + r.announcements.length);
    expect(covered, answer.candidates.length,
        reason: 'the statistics and the candidate list must be the same set');
    final kg = answer.result.ranges.singleWhere((r) => r.basis == 'kg');
    expect(kg.announcements.length, 2);
    expect(kg.minimum, 20181000);
    expect(kg.maximum, 20181000);
    expect(kg.mean, 20181000);
    final piece = answer.result.ranges.singleWhere((r) => r.basis == 'piece');
    expect(piece.announcements.single.amount, 3000000);
  });
}
