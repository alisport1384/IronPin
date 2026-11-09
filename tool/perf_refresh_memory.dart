// ignore_for_file: avoid_print
// Same synthetic archive in separate processes for before/after measurements.
// Not a device test, not a proof of the cause of an Android process death.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironpin/data/controller.dart';
import 'package:ironpin/data/store.dart';
import 'package:ironpin/domain/range_worker.dart';
import 'package:ironpin/domain/market.dart';
import 'package:ironpin/domain/row_facts.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
  });
  test('memory at refresh finalization with 6000 retained offers', () async {
    final dir = await Directory.systemTemp.createTemp('ironpin-memory-');
    final existing = Platform.environment['IRONPIN_MEMORY_DB'];
    final store = await MarketStore.open(
        dbPath: existing ?? '${dir.path}/market.db',
        factory: databaseFactoryFfi);
    final at = DateTime.now().toUtc().subtract(const Duration(hours: 1));
    final controller = MarketController(store)..enabled = {};
    Timer? sample;
    try {
      // Bounded seed writes; never construct all payloads/derived rows at once.
      if (existing == null ||
          Platform.environment['IRONPIN_MEMORY_MODE'] == 'seed') {
        await store.db.transaction((tx) async {
          for (var start = 0; start < 6000; start += 200) {
            final batch = tx.batch();
            for (var n = start; n < start + 200; n++) {
              final q = Quote(
                  id: 'p$n',
                  endpoint: 'source${n ~/ 200}',
                  seller: 'seller$n',
                  title: 'ورق سیاه 3',
                  category: 'ورق',
                  thickness: '3',
                  unit: 'kg',
                  currency: 'تومان',
                  amount: 40000 + n.toDouble(),
                  sourceDateRaw: at.toIso8601String(),
                  fetchedAt: at,
                  sourceUrl: 'https://example.com/$n',
                  details: {'شاهد ردیف': '${List.filled(2048, 'x').join()}$n'});
              final payload = jsonEncode(q.toJson());
              batch.insert('latest', {
                'id': q.id,
                'endpoint': q.endpoint,
                'payload': payload,
                'active': 1
              });
              batch.insert('history', {
                'id': q.id,
                'captured_at': at.toIso8601String(),
                'signature': q.signature,
                'payload': payload,
                'market_at': at.toIso8601String()
              });
              batch.insert('range_index',
                  RowFacts.ofQuote(q).toRow(payloadFingerprint(payload)));
            }
            await batch.commit(noResult: true);
          }
        });
      }
      final before = ProcessInfo.currentRss;
      var peak = before;
      sample = Timer.periodic(const Duration(milliseconds: 5), (_) {
        final rss = ProcessInfo.currentRss;
        if (rss > peak) peak = rss;
      });
      final watch = Stopwatch()..start();
      await controller.reload();
      final coldReadMs = watch.elapsedMilliseconds;
      final afterColdRead = ProcessInfo.currentRss;
      controller.ready = true;
      await controller.refresh();
      final expectWorker = Platform.environment['IRONPIN_EXPECT_WORKER'] == '1';
      while (controller.candidates == null ||
          (expectWorker &&
              !RangeWorker.shared
                  .holdsToken(controller.rangeSession.dataToken))) {
        if (watch.elapsed > const Duration(seconds: 60)) {
          throw TimeoutException('finalization failed to finish');
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final readyMs = watch.elapsedMilliseconds;
      // Include delayed finalization work in both measurements equally.
      await Future<void>.delayed(const Duration(seconds: 1));
      sample.cancel();
      final report = {
        'environment': 'Linux sqflite_common_ffi; synthetic, no network',
        'rows': controller.quotes.length,
        'indexRows': controller.rangeSession.indexRows,
        'candidateCount': controller.candidateCount,
        'beforeColdReadMiB': before / 1048576,
        'afterColdReadMiB': afterColdRead / 1048576,
        'coldReadMs': coldReadMs,
        'sampledColdReadAndFinalizationPeakMiB': peak / 1048576,
        'processMaxRssMiB': ProcessInfo.maxRss / 1048576,
        'workerLoaded': RangeWorker.shared.isLoaded,
        'finalizationReadyMs': readyMs,
        'note':
            'One run; RSS sampling can miss short peaks. Not Android heap/FPS.'
      };
      print(const JsonEncoder.withIndent('  ').convert(report));
      final output = Platform.environment['IRONPIN_PERF_OUTPUT'];
      if (output != null) {
        await File(output).writeAsString(
            '${const JsonEncoder.withIndent('  ').convert(report)}\n');
      }
    } finally {
      sample?.cancel();
      controller.dispose();
      RangeWorker.shared.dispose();
      await store.close();
      await dir.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
