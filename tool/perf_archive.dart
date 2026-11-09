// ignore_for_file: avoid_print
// A measurement tool, not app code: its whole output is the printed numbers.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ironpin/data/store.dart';
import 'package:ironpin/domain/market.dart';
import 'package:ironpin/domain/range_projection.dart';
import 'package:ironpin/domain/row_facts.dart';

/// Measures the archive paths a large installation exercises, so a performance
/// claim about this app is a number and not an impression.
///
/// Not part of the pass/fail suite: it prints, and the numbers move with the
/// machine. Run it against a change and against its parent commit and compare:
///
///   flutter test tool/perf_archive.dart --concurrency=1
///   git stash push -- lib/ && flutter test tool/perf_archive.dart --concurrency=1
///
/// Baseline on this sandbox (12,000 rows, 82 sources x 60), commit 0b71771:
///   write 60 x 200 rows        29,324 ms
///   rangeIndexRows cold        25,525 ms
///   saveSnapshot 400 rows       1,170 ms
///   refresh() 82 endpoints     28,906 ms
///   rss after writing 12k         310 MB
Quote row(String endpoint, int n) {
  final day = 1 + (n % 28);
  return Quote(
      id: '$endpoint/$n',
      endpoint: endpoint,
      seller: 'فولاد ایران $n',
      sellerCity: n % 3 == 0 ? 'مشهد' : 'اصفهان',
      title: 'تیرآهن ${10 + n % 20} ذوب آهن اصفهان',
      category: 'تیرآهن',
      material: 'فولاد کربنی',
      brand: 'ذوب آهن اصفهان',
      unit: 'kg',
      currency: 'تومان',
      amount: 24000 + (n % 900).toDouble(),
      sourceUrl: 'https://t.me/x/$n',
      sourceDateRaw: '2026-11-${day.toString().padLeft(2, '0')}T08:00:00Z',
      fetchedAt: DateTime.utc(2026, 11, day, 9),
      details: {
        'مبلغ استخراج‌شده': '${24000 + n % 900}',
        'زمان انتشار پیام': '2026-11-${day.toString().padLeft(2, '0')}T07:30:00Z',
        'تحلیل متن': 'محلی v2',
        'حالت': 'تحویل درب کارخانه',
        'استاندارد': 'IPE',
        'سایز': '${10 + n % 20}',
        'طول': '12',
      });
}

void main() {
  setUpAll(sqfliteFfiInit);

  test('perf: derive, index write, index read', () async {
    const rows = 12000;
    final payloads = [for (var i = 0; i < rows; i++) jsonEncode(row('e', i).toJson())];
    var sink = 0;

    var sw = Stopwatch()..start();
    for (final p in payloads) {
      sink += RowFacts.ofPayload(p).toRow(payloadFingerprint(p)).length;
    }
    print('PERF RowFacts.ofPayload + toRow x$rows = ${sw.elapsedMilliseconds}ms '
        '(${(sw.elapsedMilliseconds * 1000 / rows).toStringAsFixed(0)}us/row) [$sink]');

    final dir = await Directory.systemTemp.createTemp('ironpin_perf');
    final store = await MarketStore.open(
        dbPath: '${dir.path}/ironpin.db', factory: databaseFactoryFfi);

    sw = Stopwatch()..start();
    for (var s = 0; s < 60; s++) {
      await store.saveSnapshot(
          'ep$s', [for (var i = 0; i < 200; i++) row('ep$s', i)]);
    }
    print('PERF write 60 sources x 200 rows = ${sw.elapsedMilliseconds}ms');
    print('PERF rss after writing = ${ProcessInfo.currentRss ~/ (1024 * 1024)} MB');

    sw = Stopwatch()..start();
    final one = [for (var i = 0; i < 400; i++) row('solo', i)];
    await store.saveSnapshot('solo', one);
    print('PERF saveSnapshot 400 new rows = ${sw.elapsedMilliseconds}ms');

    await store.db.delete('range_index');
    sw = Stopwatch()..start();
    final cold = await store.rangeIndexRows(DateTime.now(), windowDays: 30);
    print('PERF rangeIndexRows cold = ${sw.elapsedMilliseconds}ms -> ${cold.length} rows');
    sw = Stopwatch()..start();
    final warm = await store.rangeIndexRows(DateTime.now(), windowDays: 30);
    print('PERF rangeIndexRows warm = ${sw.elapsedMilliseconds}ms -> ${warm.length} rows');

    sw = Stopwatch()..start();
    final picked = selectCandidates(warm,
        scope: const CandidateScope(basis: 'kg', query: '', maxAgeDays: 30),
        nowMs: DateTime.now().millisecondsSinceEpoch);
    print('PERF selectCandidates = ${sw.elapsedMilliseconds}ms '
        '-> ${picked.wires.length} selected');

    sw = Stopwatch()..start();
    final built = [for (final w in picked.wires) quoteFromStoredRow(w)];
    print('PERF quoteFromStoredRow x${picked.wires.length} = '
        '${sw.elapsedMilliseconds}ms '
        '(${(sw.elapsedMilliseconds * 1000 / built.length).toStringAsFixed(1)}us/row)');

    sw = Stopwatch()..start();
    final decoded = await store.latest();
    print('PERF store.latest() ${decoded.length} rows = ${sw.elapsedMilliseconds}ms');

    print('PERF peakRss = ${ProcessInfo.maxRss ~/ (1024 * 1024)} MB');
    await store.close();
    await dir.delete(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 25)));
}
