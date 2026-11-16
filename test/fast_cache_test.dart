import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironpin/data/fast_cache.dart';
import 'package:ironpin/data/store.dart';
import 'package:ironpin/domain/market.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Quote _makeQuote(String ep, int i, DateTime now) => Quote(
      id: '$ep/$i',
      endpoint: ep,
      seller: 'فروشنده $i',
      sellerCity: i.isEven ? 'تهران' : 'اصفهان',
      title: 'میلگرد ${12 + (i % 10)} ذوب آهن',
      category: 'میلگرد',
      material: 'فولاد کربنی',
      brand: 'ذوب آهن',
      loading: 'انبار تهران',
      loadingCity: 'تهران',
      unit: 'kg',
      tax: 'با ارزش افزوده',
      currency: 'تومان',
      terms: 'نقدی',
      sourceUrl: 'https://t.me/s/$i',
      sourceDateRaw: now.subtract(Duration(hours: i % 40)).toIso8601String(),
      fetchedAt: now.subtract(Duration(minutes: i)),
      amount: 25000.0 + i,
      pieceKg: 10.5,
      size: '${12 + (i % 10)}',
      grade: 'A3',
      details: i % 3 == 0
          ? const {}
          : {
              'مبلغ استخراج‌شده': '${25000 + i}',
              'زمان انتشار پیام':
                  now.subtract(Duration(hours: i % 40)).toIso8601String(),
            },
    );

void main() {
  setUpAll(sqfliteFfiInit);

  test('FastArchiveCache round-trips latest & rangeIndexRows and invalidates cleanly',
      () async {
    final dir = await Directory.systemTemp.createTemp('ironpin_fast_cache_');
    final dbPath = '${dir.path}/cache_test.db';
    final now = DateTime.now().toUtc();
    try {
      final store1 =
          await MarketStore.open(dbPath: dbPath, factory: databaseFactoryFfi);
      // >= FastArchiveCache.minRowsToCache (200) so binary caches are written.
      await store1.saveSnapshot(
          'ep1', [for (var i = 0; i < 250; i++) _makeQuote('ep1', i, now)]);

      final coldLatest = await store1.latest();
      final coldRange = await store1.rangeIndexRows(now, windowDays: 30);
      await store1.close();

      expect(File(FastArchiveCache.latestPathFor(dbPath)).existsSync(), isTrue);
      expect(File(FastArchiveCache.rangePathFor(dbPath)).existsSync(), isTrue);

      // Reopen: reads from binary cache and must match SQLite output exactly.
      final store2 =
          await MarketStore.open(dbPath: dbPath, factory: databaseFactoryFfi);
      final cachedLatest = await store2.latest();
      final cachedRange = await store2.rangeIndexRows(now, windowDays: 30);

      expect(cachedLatest.length, coldLatest.length);
      for (var i = 0; i < coldLatest.length; i++) {
        expect(cachedLatest[i].id, coldLatest[i].id);
        expect(cachedLatest[i].title, coldLatest[i].title);
        expect(cachedLatest[i].amount, coldLatest[i].amount);
        expect(cachedLatest[i].pieceKg, coldLatest[i].pieceKg);
        expect(cachedLatest[i].details, coldLatest[i].details);
        expect(cachedLatest[i].fetchedAt, coldLatest[i].fetchedAt);
      }

      expect(cachedRange.length, coldRange.length);
      for (var i = 0; i < coldRange.length; i++) {
        expect(cachedRange[i], equals(coldRange[i]));
      }

      // Direct SQL UPDATE must invalidate cache_state.rev.
      await store2.db.update(
        'latest',
        {'active': 0},
        where: 'id=?',
        whereArgs: ['ep1/0'],
      );
      final afterDelete = await store2.latest();
      expect(afterDelete.length, 249);
      expect(afterDelete.any((q) => q.id == 'ep1/0'), isFalse);

      // New snapshot invalidates both caches cleanly.
      await store2.saveSnapshot('ep1', [
        for (var i = 0; i < 251; i++) _makeQuote('ep1', i, now),
      ]);
      final afterSaveLatest = await store2.latest();
      final afterSaveRange = await store2.rangeIndexRows(now, windowDays: 30);
      expect(afterSaveLatest.length, 251);
      expect(afterSaveRange.length, greaterThanOrEqualTo(251));

      // Future history row entering (oldNow, newNow] invalidates range cache.
      final futureTime = now.add(const Duration(minutes: 10));
      await store2.db.insert('history', {
        'id': 'ep1/999',
        'captured_at': futureTime.toIso8601String(),
        'signature': 'sig999',
        'payload': '{"id":"ep1/999","endpoint":"ep1","seller":"s","title":"میلگرد 14","category":"میلگرد","unit":"kg","fetchedAt":"${futureTime.toIso8601String()}","sourceUrl":"u"}',
        'market_at': futureTime.toIso8601String(),
      });
      final withFuture = await store2.rangeIndexRows(
          futureTime.add(const Duration(minutes: 1)),
          windowDays: 30);
      expect(withFuture.any((r) => r['id'] == 'ep1/999'), isTrue);

      await store2.close();
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
