import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironpin/data/sources.dart';

// Explicit opt-in only; excluded from normal offline test/ directory.
void main() {
  test('live public source smoke', () async {
    final client = SourceClient();
    final report = <Map<String, dynamic>>[];
    try {
      for (final e in endpoints.where((e) =>
          e.defaultEnabled ||
          (const bool.fromEnvironment('IRONPIN_EXTRA_PUBLIC') &&
              const [
                'telegram-novinpars',
                'telegram-hayperahan',
                'telegram-radmanahan',
                'telegram-fiahan',
                'telegram-ahan100'
              ].contains(e.id)))) {
        final started = DateTime.now().toUtc();
        try {
          final rows = await client.fetch(e);
          report.add({
            'endpoint': e.id,
            'url': e.url,
            'attemptedAt': started.toIso8601String(),
            'rows': rows.length,
            'numericRows': rows.where((q) => q.amount != null).length,
            'convertibleMetreRows':
                rows.where((q) => q.priceFor('m') != null).length,
            'convertibleDiscreteRows':
                rows.where((q) => q.priceFor(q.discreteUnit) != null).length,
            'conversionSamples': rows
                .where((q) => q.priceFor('m') != null)
                .take(2)
                .map((q) => {
                      'id': q.id,
                      'nativeUnit': q.unit,
                      'amount': q.amount,
                      'pieceKg': q.pieceKg,
                      'lengthM': q.lengthM,
                      'metrePrice': q.priceFor('m'),
                      'discretePrice': q.priceFor(q.discreteUnit),
                      'currency': q.currency
                    })
                .toList(),
            'categories': rows.map((q) => q.category).toSet().toList(),
            'sellerCities': rows.map((q) => q.sellerCity).toSet().toList(),
            'sourceDates':
                rows.map((q) => q.sourceDateRaw).toSet().take(12).toList(),
            'status': 'parsed'
          });
        } catch (error) {
          report.add({
            'endpoint': e.id,
            'url': e.url,
            'attemptedAt': started.toIso8601String(),
            'status': 'failed',
            'error': '$error'
          });
        }
      }
    } finally {
      client.close();
    }
    const output = String.fromEnvironment('IRONPIN_LIVE_REPORT',
        defaultValue: 'research/live-smoke.json');
    await File(output)
        .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    expect(report.any((r) => r['status'] == 'parsed'), isTrue,
        reason: 'All sources failed; see report');
  }, timeout: const Timeout(Duration(minutes: 7)));
}
