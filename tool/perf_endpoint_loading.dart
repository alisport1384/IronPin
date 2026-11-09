// ignore_for_file: avoid_print
// Synthetic local benchmark, not a device FPS/ANR or network benchmark.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ironpin/data/store.dart';
import 'perf_archive.dart' as fixture;

Future<int> timed(Future<void> Function() action) async {
  final watch = Stopwatch()..start();
  await action();
  return watch.elapsedMicroseconds;
}

int median(List<int> values) => (values..sort())[values.length ~/ 2];

void main() {
  setUpAll(sqfliteFfiInit);
  test('measure endpoint SQL reads on the same 12000-row archive', () async {
    final dir = await Directory.systemTemp.createTemp('ironpin-endpoint-perf-');
    final store = await MarketStore.open(
        dbPath: '${dir.path}/market.db', factory: databaseFactoryFfi);
    try {
      await store.db.transaction((tx) async {
        for (var source = 0; source < 60; source++) {
          final batch = tx.batch();
          for (var n = 0; n < 200; n++) {
            final q = fixture.row('ep$source', n);
            batch.insert('latest', {
              'id': q.id,
              'endpoint': q.endpoint,
              'active': 1,
              'payload': jsonEncode(q.toJson())
            });
          }
          await batch.commit(noResult: true);
        }
      });
      Future<void> readEndpoints() async {
        for (var source = 0; source < 60; source++) {
          final rows = await store.db.query('latest',
              columns: ['payload'],
              where: 'endpoint=? AND active=1',
              whereArgs: ['ep$source']);
          expect(rows.length, 200);
        }
      }

      // Warm each configuration before five paired-size measurement rounds.
      await store.db.execute('DROP INDEX latest_endpoint_active');
      final scanPlan = await store.db.rawQuery(
          'EXPLAIN QUERY PLAN SELECT payload FROM latest WHERE endpoint=? AND active=1',
          ['ep1']);
      await readEndpoints();
      final scan = [for (var n = 0; n < 5; n++) await timed(readEndpoints)];
      await store.db.execute(
          'CREATE INDEX latest_endpoint_active ON latest(endpoint,active)');
      final indexPlan = await store.db.rawQuery(
          'EXPLAIN QUERY PLAN SELECT payload FROM latest WHERE endpoint=? AND active=1',
          ['ep1']);
      await readEndpoints();
      final indexed = [for (var n = 0; n < 5; n++) await timed(readEndpoints)];
      final decode = <int>[];
      for (var n = 0; n < 5; n++) {
        decode.add(await timed(() async {
          expect((await store.latest()).length, 12000);
        }));
      }
      final report = {
        'environment': 'Linux sqflite_common_ffi; synthetic, not Android',
        'rows': 12000,
        'sources': 60,
        'scanPlan': scanPlan,
        'indexPlan': indexPlan,
        'all60EndpointReadsScanUs': scan,
        'all60EndpointReadsIndexUs': indexed,
        'scanMedianUs': median(scan),
        'indexMedianUs': median(indexed),
        'fullArchiveDecodeUs': decode,
        'fullArchiveDecodeMedianUs': median(decode),
        'note': 'Normal refresh no longer needs the final full-archive decode. '
            'This measures that removed operation, not whole-refresh speedup.'
      };
      final output = Platform.environment['IRONPIN_PERF_OUTPUT'];
      if (output != null) {
        await File(output).writeAsString(
            '${const JsonEncoder.withIndent('  ').convert(report)}\n');
      }
      print(const JsonEncoder.withIndent('  ').convert(report));
    } finally {
      await store.close();
      await dir.delete(recursive: true);
    }
  });
}
