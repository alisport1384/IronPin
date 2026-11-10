import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ironpin/data/store.dart';
import 'package:ironpin/domain/market.dart';

Quote q(double price, {String id = 'a', int day = 5}) => Quote(
    id: id,
    endpoint: 'e',
    seller: 'test',
    title: 'میلگرد',
    category: 'میلگرد',
    unit: 'kg',
    amount: price,
    sourceUrl: 'https://example.com',
    sourceDateRaw: '2026-11-0${day}T08:00:00Z',
    fetchedAt: DateTime.utc(2026, 11, day, 9));
void main() {
  late MarketStore store;
  setUpAll(sqfliteFfiInit);
  setUp(() async {
    store = await MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
  });
  tearDown(() async => store.close());
  test('empty installation has no fake seed data', () async {
    expect(await store.latest(), isEmpty);
    expect(await store.history('a'), isEmpty);
  });
  test('snapshot writes latest and a history point atomically', () async {
    await store.saveSnapshot('e', [q(100)]);
    expect((await store.latest()).single.amount, 100);
    expect((await store.history('a')).length, 1);
  });
  test('unchanged refresh updates seen time but not historical price point',
      () async {
    await store.saveSnapshot('e', [q(100)]);
    await store.saveSnapshot('e', [q(100)]);
    expect((await store.history('a')).length, 1);
  });
  test('price change appends rather than replaces history', () async {
    await store.saveSnapshot('e', [q(100)]);
    await store.saveSnapshot('e', [q(110, day: 6)]);
    expect((await store.history('a')).map((q) => q.amount), [100, 110]);
    expect((await store.latest()).single.amount, 110);
  });
  test('network failure preserves data and last success', () async {
    await store.saveSnapshot('e', [q(100)]);
    await store.failure('e', 'timeout');
    expect((await store.latest()).single.amount, 100);
    expect((await store.syncStates())['e']!['success_at'], isNotNull);
    expect((await store.syncStates())['e']!['message'], 'timeout');
  });
  test('missing current product removed from latest but history retained',
      () async {
    await store.saveSnapshot('e', [q(100), q(200, id: 'b')]);
    await store.saveSnapshot('e', [q(105)]);
    expect((await store.latest()).length, 1);
    expect((await store.history('b')).single.amount, 200);
  });
  test('empty or wrong endpoint snapshot rejected before mutation', () async {
    await store.saveSnapshot('e', [q(100)]);
    await expectLater(store.saveSnapshot('e', []), throwsArgumentError);
    await expectLater(
        store.saveSnapshot('other', [q(100)]), throwsArgumentError);
    expect((await store.latest()).single.amount, 100);
  });
  test('older cached source date never downgrades a newer quote', () async {
    await store.saveSnapshot('e', [q(120, day: 6)]);
    await store.saveSnapshot('e', [q(100, day: 5)]);
    expect((await store.latest()).single.amount, 120);
    expect((await store.history('a')).length, 1);
  });
  test(
      'refresh lease excludes overlapping work and recovers after release/expiry',
      () async {
    final first = await store.acquireRefreshLock();
    expect(first, isNotNull);
    expect(await store.acquireRefreshLock(), isNull);
    await store.releaseRefreshLock(first!);
    final second = await store.acquireRefreshLock();
    expect(second, isNotNull);
    await store.db.rawUpdate('UPDATE refresh_lock SET expires_at=0 WHERE id=1');
    final recovered = await store.acquireRefreshLock();
    expect(recovered, isNotNull);
    expect(recovered, isNot(second));
    await store.releaseRefreshLock(recovered!);
  });
  test('source settings persist', () async {
    await store.setSetting('autoRefresh', 'false');
    expect(await store.setting('autoRefresh'), 'false');
  });
  test('history date range isolates observations', () async {
    await store.saveSnapshot('e', [q(100)]);
    await store.saveSnapshot('e', [q(110, day: 6)]);
    expect(
        (await store.history('a', since: DateTime.utc(2026, 11, 6))).length, 1);
  });
  test(
      'bounded channel pagination and manual imports preserve prior active rows',
      () async {
    await store.saveSnapshot('e', [q(100), q(200, id: 'b')]);
    await store.saveSnapshot('e', [q(110)], replaceMissing: false);
    expect((await store.latest()).length, 2);
    expect((await store.latest()).firstWhere((r) => r.id == 'b').amount, 200);
    expect((await store.syncStates())['e']!['message'], contains('پوشش محدود'));
  });
  test(
      'v2 reparsing retires old v1 model ids only in reread posts; history and unread data survive',
      () async {
    Quote versioned(String id, double price, int version) => Quote.fromJson({
          ...q(price, id: id).toJson(),
          'details': {'تحلیل متن': 'محلی v$version'}
        });
    final legacy = versioned('e:channel/123:old-model', 16125000, 1);
    final unread = versioned('e:channel/1230:unread', 130000, 1);
    final otherV2 = versioned('e:channel/123:existing-v2-product', 140000, 2);
    await store.saveSnapshot('e', [legacy, unread, otherV2]);
    final corrected = versioned('e:channel/123:corrected-model', 125000, 2);
    await store.saveSnapshot('e', [corrected], replaceMissing: false);
    expect((await store.latest()).map((r) => r.id).toSet(),
        {unread.id, otherV2.id, corrected.id});
    expect((await store.history(legacy.id)).single.amount, 16125000);
    expect(await store.historyCount(), 4);
    expect(
        (await store.db.query('latest', where: 'id=?', whereArgs: [legacy.id]))
            .single['active'],
        0);
  });
}
