import 'package:flutter_test/flutter_test.dart';
import 'package:ironpin/data/controller.dart';
import 'package:ironpin/data/range_session.dart';
import 'package:ironpin/data/store.dart';
import 'package:ironpin/domain/market.dart';
import 'package:ironpin/domain/range_projection.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 0.8.0 — the time window is one setting of the whole app: it is chosen in the
/// information tab, it is the default of every other tab, and a row is shown
/// only inside it. These tests pin the parts a UI could otherwise fake.
final now = DateTime.now().toUtc();

Quote offer(int n,
        {String category = 'ورق',
        String unit = 'kg',
        double? amount = 42000,
        String currency = 'تومان',
        Duration age = const Duration(hours: 2)}) =>
    Quote(
        id: 'w$n',
        endpoint: 'catalog',
        seller: 'فروشنده $n',
        sellerCity: 'تهران',
        title: 'ورق آزمایشی $n',
        category: category,
        material: 'فولاد کربنی',
        size: '16',
        thickness: '3',
        grade: 'A3',
        amount: amount,
        unit: unit,
        currency: currency,
        sourceDateRaw: now.subtract(age).toIso8601String(),
        fetchedAt: now,
        sourceUrl: 'https://example.com/$n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test('the primary window is one month and every tab inherits it', () async {
    final store = await MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
    final c = MarketController(store);
    addTearDown(() async {
      c.dispose();
      await store.close();
    });
    expect(c.discoveryDays, MarketController.defaultWindowDays);
    expect(c.discoveryDays, 30);
    expect(c.pricesDays, -1, reason: 'a tab with no choice of its own');
    expect(c.pricesWindow, 30);
    expect(c.rangeWindow, 30);
    expect(c.chartWindow, 30);
    // The tab's own choice is remembered and does not change the parent.
    await c.setTabDays('prices', 7);
    expect(c.pricesWindow, 7);
    expect(c.discoveryDays, 30);
    expect(c.rangeWindow, 30);
    // The parent window moves every tab that only inherits it.
    await c.setDiscoveryDays(7);
    expect(c.rangeWindow, 7);
    expect(c.chartWindow, 7);
    expect(c.pricesWindow, 7);
    // «همه زمان‌ها» is a real choice: it removes the date filter, it is not a
    // hidden 48-hour rule.
    await c.setTabDays('prices', -1);
    await c.setDiscoveryDays(0);
    expect(c.pricesWindow, 0);
  });

  test('a row is judged by its own announcement date, then by storage time',
      () {
    final fresh = offer(1, age: const Duration(days: 2));
    final old = offer(2, age: const Duration(days: 45));
    expect(insideWindow(fresh, now, 30), true);
    expect(insideWindow(old, now, 30), false);
    expect(insideWindow(old, now, 0), true, reason: 'no window means all time');
    expect(insideWindow(old, now, 90), true);
  });

  test('prices of the window only: an older stored row is not in the tab',
      () async {
    final store = await MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
    addTearDown(store.close);
    await store.saveSnapshot('catalog', [
      offer(1, age: const Duration(days: 2)),
      offer(2, age: const Duration(days: 45)),
    ]);
    final c = MarketController(store);
    addTearDown(c.dispose);
    await c.init();
    await c.prepareCandidates();
    expect(c.candidateRows.map((q) => q.id), ['w1']);
    await c.setDiscoveryDays(0);
    await c.prepareCandidates();
    expect(c.candidateRows.map((q) => q.id).toSet(), {'w1', 'w2'});
  });

  test('the range answer uses the tab window, not a hidden 48 hours', () async {
    final store = await MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
    addTearDown(store.close);
    await store.saveSnapshot('catalog', [
      offer(1, age: const Duration(days: 2)),
      offer(2, age: const Duration(days: 12)),
    ]);
    final session = RangeSession(store);
    final narrow = await session.confirm(
        family: 'ورق',
        fields: const {},
        basis: '',
        city: '',
        at: now);
    expect(narrow.result.announcements.map((q) => q.id), ['w1']);
    final wide = await session.confirm(
        family: 'ورق',
        fields: const {},
        basis: '',
        city: '',
        at: now,
        windowDays: 30);
    expect(wide.result.announcements.map((q) => q.id).toSet(), {'w1', 'w2'});
  });

  test('a priced row without a stated unit is offered with its amount', () {
    final wire = {
      'endpoint': 'catalog',
      'id': 'u1',
      'seller': 'فروشنده',
      'sellerCity': 'تهران',
      'title': 'تیرآهن ۱۴ اصفهان',
      'category': 'تیرآهن',
      'family': 'تیرآهن',
      'unit': 'unknown',
      'currency': 'تومان',
      'amount': 20181000.0,
      'prices': '{}',
      'market_at': now.millisecondsSinceEpoch,
      'fetched_at': now.millisecondsSinceEpoch,
    };
    final found = selectCandidates([wire],
        scope: const CandidateScope(basis: '', query: '', maxAgeDays: 30),
        nowMs: now.millisecondsSinceEpoch);
    expect(found.wires.length, 1,
        reason: 'a real amount is a real price, even without a unit');
    expect(found.unpriced, 0,
        reason: 'it is not counted as a row without a price');
  });
}
