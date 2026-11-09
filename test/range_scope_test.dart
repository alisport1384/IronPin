import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironpin/data/controller.dart';
import 'package:ironpin/data/range_session.dart';
import 'package:ironpin/data/store.dart';
import 'package:ironpin/domain/market.dart';
import 'package:ironpin/domain/range_projection.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The prices tab has two ways to answer the same question: the derived index
/// (fast, used when it is loaded) and the classic filter over `latest`. They are
/// one feature, so they must be one answer — field by field, including the
/// fields a fast path is tempted to leave out.
late MarketStore store;
late Directory dir;

final now = DateTime.now().toUtc();

Quote offer(int n,
        {String category = 'ورق',
        String material = 'فولاد کربنی',
        String city = 'تهران',
        String thickness = '3',
        String size = '16',
        String grade = 'A3',
        String unit = 'kg',
        double? amount = 42000,
        String? date,
        Map<String, String> details = const {}}) =>
    Quote(
        id: 'p$n',
        endpoint: 'catalog',
        seller: 'فروشنده $n',
        sellerCity: city,
        title: 'محصول آزمایشی $n',
        category: category,
        material: material,
        size: size,
        thickness: thickness,
        grade: grade,
        amount: amount,
        unit: unit,
        currency: 'تومان',
        details: details,
        sourceDateRaw:
            date ?? now.subtract(Duration(minutes: 30 + n)).toIso8601String(),
        fetchedAt: now,
        sourceUrl: 'https://example.com/$n');

Future<MarketController> prepared(List<Quote> quotes) async {
  await store.saveSnapshot('catalog', quotes);
  final c = MarketController(store);
  await c.init();
  // Wait for the prepared set instead of guessing a delay: the assertion is
  // about the answer, not about timing.
  for (var i = 0; i < 300 && c.candidates == null; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return c;
}

String ids(Iterable<Quote> rows) =>
    (rows.map((q) => q.id).toList()..sort()).join(',');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('scope');
    store = await MarketStore.open(
        dbPath: '${dir.path}/s.db', factory: databaseFactoryFfi);
  });
  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });

  /// The archive holds one offer of another category, another material, another
  /// city, another thickness, another size, another grade, another unit, one
  /// without a price and one outside the week, so every filter below has
  /// something to exclude.
  final archive = [
    offer(1),
    offer(2, city: 'مشهد'),
    offer(3, category: 'میلگرد'),
    offer(4, material: 'استیل'),
    offer(5, thickness: '8'),
    offer(6, size: '20'),
    offer(7, grade: 'A2'),
    offer(8, unit: 'ton', amount: 42000000),
    offer(9, amount: null),
    offer(10, date: now.subtract(const Duration(days: 40)).toIso8601String()),
    offer(11, details: const {'حالت': 'رول'}),
  ];

  Future<void> same(String what, void Function(MarketFilter) configure) async {
    final c = await prepared(archive);
    addTearDown(c.dispose);
    configure(c.filter);
    c.changed();
    await c.prepareCandidates();
    final fast = c.candidateRows;
    // The classic answer over the same archive, asked directly.
    final classic = c.filter.apply(c.quotes, DateTime.now());
    expect(ids(fast), ids(classic), reason: what);
    // And the fast path really was used, not silently skipped.
    expect(c.candidates, isNotNull, reason: '$what: the index answered');
  }

  test('the index answers exactly what the classic filter answers', () async {
    await same('no filter', (f) {});
    await same('category', (f) => f.category = 'ورق');
    await same('material', (f) => f.material = 'فولاد کربنی');
    await same('city', (f) => f.city = 'تهران');
    await same('city, seller only', (f) {
      f.city = 'تهران';
      f.cityKind = 'seller';
    });
    await same('thickness', (f) => f.thickness = '8');
    await same('size', (f) => f.size = '16');
    await same('grade', (f) => f.grade = 'A2');
    await same('unit', (f) => f.unit = 'ton');
    await same('price bound', (f) => f.minPrice = 41000);
    await same('price ceiling', (f) => f.maxPrice = 41000);
    await same('search word', (f) => f.query = 'محصول آزمای');
    await same('search by number', (f) => f.query = '۸');
    await same('recent week', (f) => f.recentWeek = true);
    await same('fresh only', (f) => f.onlyFresh = true);
    await same('everything at once', (f) {
      f.category = 'ورق';
      f.city = 'تهران';
      f.thickness = '3';
      f.query = 'آزمایشی';
      f.recentWeek = true;
    });
  });

  test('the window is the user filter, not a hidden one', () async {
    final c = await prepared(archive);
    addTearDown(c.dispose);
    // The tab opens on the primary window (one month), so an offer older than it
    // is out — but it is out because that window is selected, and it returns the
    // moment the window is widened to «همه زمان‌ها».
    expect(c.candidateRows.map((q) => q.id), isNot(contains('p10')));
    expect(c.candidates!.undated, greaterThan(0),
        reason: 'the rows held back are counted, never hidden without a number');
    await c.setDiscoveryDays(0);
    for (var i = 0; i < 200 && c.candidates == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await c.prepareCandidates();
    expect(c.candidateRows.map((q) => q.id), contains('p10'),
        reason: 'with the window widened the old offer is a candidate again');
  });

  test('an offer stored twice is one card, never two', () async {
    // The archive keeps a latest row per receipt; the same offer written twice is
    // still one offer, and the newest receipt is the one shown.
    await store.saveSnapshot('catalog', [offer(21)]);
    await store.saveSnapshot('catalog', [
      Quote.fromJson({
        ...offer(21).toJson(),
        'amount': 42500.0,
      })
    ]);
    final session = RangeSession(store);
    final set = await session.candidates(
        scope: const CandidateScope(basis: '', query: '', maxAgeDays: 7),
        at: DateTime.now());
    expect(set.quotes.map((q) => q.id).toList(), ['p21'],
        reason: 'one offer, one card');
    expect(set.total, 1);
    // The card carries what the archive kept as the current receipt — the index
    // never invents a newer price than the archive holds.
    final latest = await store.latest();
    expect(set.quotes.single.amount, latest.single.amount);
  });

  test('a priced row of an unknown unit is still not a candidate', () async {
    await store.saveSnapshot('catalog', [
      offer(31, unit: 'parcel', amount: 5000),
      offer(32),
    ]);
    final session = RangeSession(store);
    final set = await session.candidates(
        scope: const CandidateScope(basis: 'kg', query: '', maxAgeDays: 7),
        at: DateTime.now());
    expect(set.quotes.map((q) => q.id).toList(), ['p32'],
        reason: 'no comparable price in the chosen basis, so no candidate');
    expect(set.unpriced, greaterThan(0));
  });

  test('the count is the whole scope, the list grows as it is asked to', () async {
    await store.saveSnapshot('catalog', [for (var i = 0; i < 150; i++) offer(100 + i)]);
    final c = await prepared([for (var i = 0; i < 150; i++) offer(100 + i)]);
    addTearDown(c.dispose);
    // Ready rows are bounded, but what the user is told is the truth.
    expect(c.candidateRows.length, 60);
    expect(c.candidateCount, 150);
    expect(c.moreCandidates, isTrue);
    c.showMoreCandidates();
    expect(c.candidateRows.length, 120);
    expect(c.candidateCount, 150);
    c.showMoreCandidates();
    expect(c.candidateRows.length, 150);
    expect(c.moreCandidates, isFalse,
        reason: 'no «more» button once the scope is fully built');
    // Every row is a real, distinct offer: growing the list never duplicates one.
    expect(c.candidateRows.map((q) => q.id).toSet().length, 150);
    // Newest first, still: a page appended later never breaks the order.
    final dates = [
      for (final q in c.candidateRows) q.marketAt?.millisecondsSinceEpoch ?? 0
    ];
    expect(dates, [...dates]..sort((a, b) => b.compareTo(a)),
        reason: 'the whole list stays newest-first after paging');
  });

  test('a price order covers the whole scope, not the first page', () async {
    final prices = {
      for (var i = 0; i < 150; i++) 100 + i: 50000.0 + i * 100,
    };
    await store.saveSnapshot('catalog', [
      for (final e in prices.entries) offer(e.key, amount: e.value),
    ]);
    final c = MarketController(store);
    await c.init();
    for (var i = 0; i < 300 && c.candidates == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    addTearDown(c.dispose);
    c.filter.sort = 'asc';
    c.changed();
    await c.prepareCandidates();
    final rows = c.candidateRows;
    expect(rows.length, 150, reason: 'a price order builds the whole scope');
    final amounts = [for (final q in rows) q.amount!];
    expect(amounts.first, 50000.0,
        reason: 'the cheapest offer of the archive is first, not the cheapest of '
            'the first sixty rows');
    expect(amounts, [...amounts]..sort());
  });

  test('a filter never turns a priced row into an unpriced one', () async {
    await store.saveSnapshot('catalog', [offer(41), offer(42, amount: null)]);
    final session = RangeSession(store);
    final set = await session.candidates(
        scope: const CandidateScope(
            basis: '', query: '', maxAgeDays: 7, minPrice: 100000),
        at: DateTime.now());
    expect(set.quotes, isEmpty, reason: 'the price bound excludes both');
    expect(set.unpriced, 1, reason: 'only the row without a number is unpriced');
  });
}
