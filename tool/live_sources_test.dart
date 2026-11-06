import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironpin/data/sources.dart';
import 'package:ironpin/domain/market.dart';

// Explicit opt-in only; excluded from normal offline test/ directory.
void main() {
  test('live public source smoke', () async {
    final client = SourceClient();
    final report = <Map<String, dynamic>>[];
    try {
      const only = String.fromEnvironment('IRONPIN_ONLY_SOURCE');
      final selected =
          endpoints.where((e) => only.isEmpty || e.id == only).toList();
      Future<void> check(SourceEndpoint e) async {
        final started = DateTime.now().toUtc();
        try {
          final rows = await client.fetch(e);
          report.add({
            'endpoint': e.id,
            'url': e.url,
            'attemptedAt': started.toIso8601String(),
            'rows': rows.length,
            'automaticAnalysisRows': rows
                .where((q) => q.details['تحلیل خودکار'] == 'محلی v2')
                .length,
            'sheetRows': rows.where((q) => q.category == 'ورق').length,
            'sheetCandidates': rows
                .where((q) => q.category == 'ورق' && q.hasTextAmount)
                .length,
            'sheet3MashhadAllDates': (MarketFilter()..query = 'ورق3 مشهد')
                .apply(rows, DateTime.now())
                .length,
            'sheet3MashhadRecentWeek': (MarketFilter()
                  ..query = 'ورق3 مشهد'
                  ..recentWeek = true)
                .apply(rows, DateTime.now())
                .length,
            'sheetSamples': rows
                .where((q) => q.category == 'ورق' && q.hasTextAmount)
                .take(3)
                .map((q) => q.toJson())
                .toList(),
            'numericRows': rows.where((q) => q.amount != null).length,
            'comparableRows':
                rows.where((q) => q.priceFor('original') != null).length,
            'textCandidates': rows.where((q) => q.hasTextAmount).length,
            'recentWeekRows':
                rows.where((q) => q.isWithinWeek(DateTime.now())).length,
            'knownPublicationDates':
                rows.where((q) => q.publishedAt != null).length,
            'declaredRateDates':
                rows.where((q) => q.announcedAt != null).length,
            'publicPreviewComplete': client.complete[e.id],
            'discoveredUrls':
                (client.discoveries[e.id] ?? []).map((e) => e.url).toList(),
            'textSamples': rows
                .where((q) => q.hasTextAmount)
                .take(3)
                .map((q) => q.toJson())
                .toList(),
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

      for (var i = 0; i < selected.length; i += 2) {
        await Future.wait(selected.skip(i).take(2).map(check));
      }
      report.sort((a, b) => selected
          .indexWhere((e) => e.id == a['endpoint'])
          .compareTo(selected.indexWhere((e) => e.id == b['endpoint'])));
    } finally {
      client.close();
    }
    const output = String.fromEnvironment('IRONPIN_LIVE_REPORT',
        defaultValue: 'research/live-smoke.json');
    await File(output)
        .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    expect(report.any((r) => r['status'] == 'parsed'), isTrue,
        reason: 'All sources failed; see report');
  }, timeout: const Timeout(Duration(minutes: 20)));
}
