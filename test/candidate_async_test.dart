import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironpin/data/range_session.dart';
import 'package:ironpin/data/store.dart';
import 'package:ironpin/domain/market.dart';
import 'package:ironpin/domain/range_projection.dart';
import 'package:ironpin/domain/row_facts.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Map<String, Object?> _wire(int i, DateTime now) => {
      'payload': 'p$i',
      'family': i.isEven ? 'ورق' : 'میلگرد',
      'facts': '',
      'prices': 'kg\u000128000',
      'announce_key': 'a$i',
      'product_key': null,
      'seller_norm': 's',
      'id': 'id-$i',
      'endpoint': 'ep',
      'title': i.isEven ? 'ورق سیاه 3 مبارکه' : 'میلگرد 16 A3 نیشابور',
      'category': i.isEven ? 'ورق' : 'میلگرد',
      'seller': 'فروشنده',
      'seller_city': 'مشهد',
      'unit': 'kg',
      'brand': '',
      'material': 'فولاد کربنی',
      'tax': '',
      'terms': '',
      'status': '',
      'specification': '',
      'search': 'ورق میلگرد فولاد',
      'source_url': '',
      'haystack': 'مشهد ورق',
      'size_label': '',
      'thickness_label': i.isEven ? '3' : '',
      'dimensions_label': '',
      'grade_label': '',
      'size_num': null,
      'thickness_num': i.isEven ? 3.0 : null,
      'source_date_raw': '',
      'amount_raw': '',
      'derive': 'v6',
      'amount': 28000.0,
      'currency': 'تومان',
      'market_at': now.millisecondsSinceEpoch - i * 1000,
      'fetched_at': now.millisecondsSinceEpoch - i * 1000,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test('CandidateSelector decides exactly like selectCandidates', () {
    final now = DateTime.now().toUtc();
    final rows = [for (var i = 0; i < 500; i++) _wire(i, now)];
    for (final scope in [
      const CandidateScope(basis: 'kg', query: '', maxAgeDays: 30),
      const CandidateScope(basis: 'kg', query: 'ورق', maxAgeDays: 30),
      const CandidateScope(
          basis: 'original', query: '', maxAgeDays: 30, category: 'ورق'),
      const CandidateScope(basis: 'kg', query: 'قرص آهن یک ورق', maxAgeDays: 30),
    ]) {
      final sync = selectCandidates(rows, scope: scope, nowMs: now.millisecondsSinceEpoch);
      final selector = CandidateSelector(scope: scope, nowMs: now.millisecondsSinceEpoch);
      for (final row in rows) {
        selector.add(row);
      }
      final sliced = selector.finish();
      expect(sliced.wires.map((w) => w['id']).toList(),
          sync.wires.map((w) => w['id']).toList());
      expect(sliced.undated, sync.undated);
      expect(sliced.unpriced, sync.unpriced);
    }
  });

  test('packedPriceOf reads exactly what unpackPrices reads', () {
    const s1 = '\u0001', s2 = '\u0002';
    final cases = <String>[
      '',
      'kg${s1}28000',
      'kg${s1}28000${s2}ton${s1}28000000${s2}piece${s1}1500000',
      'piece${s1}42',
      'kg${s1}not-a-number${s2}ton${s1}7.5',
      'ton${s1}9${s2}kg${s1}0.001',
    ];
    for (final packed in cases) {
      final map = unpackPrices(packed);
      for (final unit in ['kg', 'ton', 'piece', 'm', 'sheet', '']) {
        expect(packedPriceOf(packed, unit), map[unit],
            reason: 'packed=$packed unit=$unit');
      }
    }
  });

  test('sliced candidates over a >4000-row index equal the synchronous set',
      () async {
    final dir = await Directory.systemTemp.createTemp('ironpin-sliced');
    addTearDown(() => dir.delete(recursive: true));
    final store = await MarketStore.open(
        dbPath: '${dir.path}/s.db', factory: databaseFactoryFfi);
    final now = DateTime.now().toUtc();
    try {
      // 2600 latest offers -> 5200 index rows (latest + history), above the
      // synchronous limit, so `candidates` must take the sliced path.
      for (var s = 0; s < 2; s++) {
        final ep = 'ep-$s';
        await store.saveSnapshot(ep, [
          for (var i = 0; i < 1300; i++)
            Quote(
              id: '$ep/$i',
              endpoint: ep,
              seller: 'فولاد $ep',
              sellerCity: 'مشهد',
              title: i.isEven ? 'ورق سیاه 3 مبارکه' : 'میلگرد 16 A3 نیشابور',
              category: i.isEven ? 'ورق' : 'میلگرد',
              material: 'فولاد کربنی',
              brand: 'مبارکه',
              unit: 'kg',
              currency: 'تومان',
              amount: 28000.0 + i,
              sourceDateRaw: now.toIso8601String(),
              fetchedAt: now,
              sourceUrl: 'https://example.com/$ep/$i',
            )
        ]);
      }
      // The new SQLite indexes exist on an archive opened by this version.
      final indexNames = (await store.db
              .rawQuery("SELECT name FROM sqlite_master WHERE type='index'"))
          .map((r) => r['name'])
          .toSet();
      expect(indexNames,
          containsAll(['range_index_market', 'range_index_offer']));

      final session = RangeSession(store);
      const scope = CandidateScope(basis: 'kg', query: 'ورق', maxAgeDays: 30);
      final sliced =
          await session.candidates(scope: scope, at: now, windowDays: 30);
      final sync = session.candidatesNow(scope: scope, at: now);
      expect(session.indexRows, greaterThan(RangeSession.candidateSyncLimit));
      expect(sliced.total, sync.total);
      expect(sliced.total, greaterThan(0));
      expect(sliced.quotes.map((q) => q.id).toList(),
          sync.quotes.map((q) => q.id).toList());
      // Newest-first order is preserved without a per-query sort.
      final ats = [
        for (final w in sliced.wires) (w['market_at'] as int?) ?? 0
      ];
      final sorted = ats.toList()..sort((a, b) => b.compareTo(a));
      expect(ats, sorted);
      // The sliced scan yields to the event loop: after one zero-delay turn
      // it is still running, where the old synchronous scan would already
      // have returned (having blocked the UI isolate for the whole pass).
      var done = false;
      final pending = session
          .candidatesSliced(scope: scope, at: now)
          .whenComplete(() => done = true);
      await Future<void>.delayed(Duration.zero);
      expect(done, isFalse,
          reason: 'sliced selection must not finish in one synchronous block');
      await pending;
      expect(done, isTrue);
    } finally {
      await store.close();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
