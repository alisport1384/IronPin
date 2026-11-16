// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ironpin/data/range_session.dart';
import 'package:ironpin/data/store.dart';
import 'package:ironpin/domain/market.dart';
import 'package:ironpin/domain/range_projection.dart';
import 'package:ironpin/domain/range_worker.dart';

Quote mkRow(String endpoint, int n, DateTime now) {
  final day = 1 + (n % 25);
  final isRebar = n % 3 == 0;
  final isSheet = n % 3 == 1;
  final size = 10 + (n % 20);
  return Quote(
      id: '$endpoint/$n',
      endpoint: endpoint,
      seller: 'فولاد ایران ${n % 100}',
      sellerCity: n % 3 == 0 ? 'مشهد' : (n % 3 == 1 ? 'تهران' : 'اصفهان'),
      title: isRebar
          ? 'میلگرد $size A3 نیشابور'
          : isSheet
              ? 'ورق سیاه ${2 + (n % 10)} مبارکه'
              : 'تیرآهن $size ذوب آهن اصفهان',
      category: isRebar ? 'میلگرد' : (isSheet ? 'ورق' : 'تیرآهن'),
      material: 'فولاد کربنی',
      brand: isSheet ? 'مبارکه' : 'اصفهان',
      unit: 'kg',
      currency: 'تومان',
      amount: 24000 + (n % 900).toDouble(),
      sourceUrl: 'https://t.me/x/$n',
      sourceDateRaw: now.subtract(Duration(hours: day * 12)).toIso8601String(),
      fetchedAt: now.subtract(Duration(hours: day * 12)),
      details: {
        'مبلغ استخراج‌شده': '${24000 + n % 900}',
        'زمان انتشار پیام':
            now.subtract(Duration(hours: day * 12)).toIso8601String(),
        'تحلیل متن': 'محلی v2',
        'حالت': 'تحویل درب کارخانه',
      });
}

void main() {
  setUpAll(sqfliteFfiInit);

  test('perf 200k+ records benchmark', () async {
    const sources = 100;
    const perSource = 1000; // 100k latest + 100k history = 200k index rows!
    final now = DateTime.now().toUtc();
    final dir = await Directory('/var/tmp').createTemp('ironpin_200k_');
    final store = await MarketStore.open(
        dbPath: '${dir.path}/ironpin200k.db', factory: databaseFactoryFfi);

    var sw = Stopwatch()..start();
    for (var s = 0; s < sources; s++) {
      await store.saveSnapshot('ep$s',
          [for (var i = 0; i < perSource; i++) mkRow('ep$s', i, now)]);
    }
    print('200K write (100k latest + 100k history) = ${sw.elapsedMilliseconds}ms');
    print('200K db size = ${File('${dir.path}/ironpin200k.db').lengthSync() ~/ (1024 * 1024)} MB');

    {
      sw = Stopwatch()..start();
      final latest = await store.latest();
      print(
          '200K store.latest() cold (${latest.length} rows) = ${sw.elapsedMilliseconds}ms');
    }

    await store.close();
    final store2 = await MarketStore.open(
        dbPath: '${dir.path}/ironpin200k.db', factory: databaseFactoryFfi);
    {
      sw = Stopwatch()..start();
      final latestCached = await store2.latest();
      print(
          '200K store.latest() CACHED (${latestCached.length} rows) = ${sw.elapsedMilliseconds}ms');
    }

    {
      sw = Stopwatch()..start();
      final rawIndex = await store2.rangeIndexRows(now, windowDays: 30);
      print(
          '200K rangeIndexRows sql-warm (${rawIndex.length} rows) = ${sw.elapsedMilliseconds}ms');
    }

    await store2.close();
    final store3 = await MarketStore.open(
        dbPath: '${dir.path}/ironpin200k.db', factory: databaseFactoryFfi);
    {
      sw = Stopwatch()..start();
      final cachedIndex = await store3.rangeIndexRows(now, windowDays: 30);
      print(
          '200K rangeIndexRows CACHED (${cachedIndex.length} rows) = ${sw.elapsedMilliseconds}ms');
    }

    final session = RangeSession(store3);
    sw = Stopwatch()..start();
    await session.ensureIndex(now, windowDays: 30);
    print('200K RangeSession.ensureIndex CACHED (${session.indexRows} rows) = ${sw.elapsedMilliseconds}ms');

    sw = Stopwatch()..start();
    final allCand = await session.candidates(
        scope: const CandidateScope(basis: 'kg', query: '', maxAgeDays: 30),
        at: now,
        windowDays: 30);
    print('200K candidates (empty query, ${allCand.total} selected) = ${sw.elapsedMilliseconds}ms');

    sw = Stopwatch()..start();
    final numCand = await session.candidates(
        scope: const CandidateScope(basis: 'kg', query: '14', maxAgeDays: 30),
        at: now,
        windowDays: 30);
    print('200K candidates (query="14", ${numCand.total} selected) = ${sw.elapsedMilliseconds}ms');

    sw = Stopwatch()..start();
    final catCand = await session.candidates(
        scope: const CandidateScope(
            basis: 'kg', query: 'میلگرد 14', maxAgeDays: 30),
        at: now,
        windowDays: 30);
    print('200K candidates (query="میلگرد 14", ${catCand.total} selected) = ${sw.elapsedMilliseconds}ms');

    sw = Stopwatch()..start();
    await RangeWorker.shared.load(session.dataToken, session.indexRowsSnapshot);
    print('200K RangeWorker.load = ${sw.elapsedMilliseconds}ms');

    sw = Stopwatch()..start();
    final rMsg = await RangeWorker.shared.run(
        token: session.dataToken,
        family: 'میلگرد',
        fields: const {'سایز': '14'},
        basis: 'kg',
        city: '',
        nowMs: now.millisecondsSinceEpoch,
        windowMs: 30 * 24 * 3600 * 1000);
    final answer = rMsg['answer'] as RangeAnswer;
    print('200K RangeWorker.run (میلگرد 14, kept=${answer.keptRows}) = ${sw.elapsedMilliseconds}ms');

    print('200K peakRss = ${ProcessInfo.maxRss ~/ (1024 * 1024)} MB');
    RangeWorker.shared.dispose();
    await store3.close();
    await dir.delete(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
