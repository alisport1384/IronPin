// Explicit manual live check; not part of the offline test/ suite.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironpin/data/sources.dart';
import 'package:ironpin/domain/price_range.dart';

void main() {
  test(
      'actual SourceClient transport for the newly researched Bonyan endpoints',
      () async {
    final client = SourceClient(maxChannelPages: 1);
    final reports = <Map<String, Object?>>[];
    try {
      for (final e in endpoints.where((e) =>
          ['telegram-bonyan-ghavam', 'eitaa-bonyan-ghavam'].contains(e.id))) {
        final started = DateTime.now().toUtc(), watch = Stopwatch()..start();
        try {
          final rows = await client.fetch(e);
          final ranged = calculateRanges(rows, DateTime.now().toUtc());
          reports.add({
            'endpoint': e.id,
            'url': e.url,
            'attemptedAt': started.toIso8601String(),
            'status': 'parsed',
            'elapsedMs': watch.elapsedMilliseconds,
            'rows': rows.length,
            'numericRows': rows.where((q) => q.amount != null).length,
            'textAmountRows': rows.where((q) => q.hasTextAmount).length,
            'freshComparableRanges': ranged.ranges.length,
            'excluded': ranged.excluded,
            'samples': rows.take(2).map((q) => q.toJson()).toList()
          });
        } catch (e2) {
          reports.add({
            'endpoint': e.id,
            'url': e.url,
            'attemptedAt': started.toIso8601String(),
            'status': 'failed',
            'elapsedMs': watch.elapsedMilliseconds,
            'error': '$e2'
          });
        }
      }
    } finally {
      client.close();
    }
    await File('production/verification/v0.7.1/live-bonyan.json').writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(reports)}\n');
    expect(
        reports.length, 2); // This checks complete reporting, not live success.
  }, timeout: const Timeout(Duration(minutes: 2)));
}
