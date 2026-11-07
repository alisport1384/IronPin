// Explicit live check, separate from offline tests. Failure is evidence, not success.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironpin/data/sources.dart';
import 'package:ironpin/domain/price_range.dart';

void main() {
  test('actual SourceClient for eight newly registered Mashhad-related routes',
      () async {
    final oldIds = {
      'rahsakht-wire',
      'rahsakht-galv',
      'rahsakht-rabits',
      'rahsakht-bastar',
      'telegram-rahsakht',
      'telegram-profilonline',
      'khoshkam-rebar',
      'maham-beam12'
    };
    final selected = endpoints.where((e) => oldIds.contains(e.id)).toList();
    final records = <Map<String, Object?>>[];
    final client = SourceClient(maxChannelPages: 1);
    Future<void> check(SourceEndpoint e) async {
      final watch = Stopwatch()..start();
      try {
        final rows = await client.fetch(e);
        final ranged = calculateRanges(rows, DateTime.now().toUtc());
        records.add({
          'id': e.id,
          'url': e.url,
          'transportStatus': 'parsed',
          'elapsedMs': watch.elapsedMilliseconds,
          'rows': rows.length,
          'numericRows': rows.where((q) => q.amount != null).length,
          'freshRanges': ranged.ranges.length,
          'excluded': ranged.excluded,
          'samples': rows.take(1).map((q) => q.toJson()).toList()
        });
      } catch (error) {
        records.add({
          'id': e.id,
          'url': e.url,
          'transportStatus': 'failed',
          'elapsedMs': watch.elapsedMilliseconds,
          'error': '$error'
        });
      }
    }

    try {
      for (var i = 0; i < selected.length; i += 4) {
        await Future.wait(selected.skip(i).take(4).map(check));
      }
    } finally {
      client.close();
    }
    records.sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
    await File('production/verification/v0.7.2/live-sources.json')
        .writeAsString('${const JsonEncoder.withIndent('  ').convert({
          'attemptedAt': DateTime.now().toUtc().toIso8601String(),
          'records': records,
          'note':
              'Eight complete attempts; this assertion is not a claim that all transports or prices succeeded.'
        })}\n');
    expect(records.length, 8);
    stdout.writeln('LIVE_RESULTS ${jsonEncode(records.map((r) => {
          'id': r['id'],
          'status': r['transportStatus'],
          'rows': r['rows'],
          'fresh': r['freshRanges']
        }).toList())}');
  }, timeout: const Timeout(Duration(minutes: 4)));
}
