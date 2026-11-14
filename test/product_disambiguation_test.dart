import 'package:flutter_test/flutter_test.dart';
import 'package:ironpin/data/public_tables.dart';
import 'package:ironpin/data/range_session.dart';
import 'package:ironpin/data/store.dart';
import 'package:ironpin/domain/market.dart';
import 'package:ironpin/domain/product_schema.dart';
import 'package:ironpin/domain/product_text.dart';
import 'package:ironpin/domain/range_projection.dart';
import 'package:ironpin/domain/searcher.dart';
import 'package:ironpin/domain/source_finder.dart';
import 'package:ironpin/domain/text_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  final now = DateTime.utc(2026, 11, 13, 9);

  group('قرص آهن یک ورق vs یک ورق آهن فولادی', () {
    test('ProductText distinguishes iron supplement blister packs from steel sheets', () {
      for (final nonMetal in [
        'قرص آهن یک ورق',
        'قرص آهن ففول یک ورق ۱۰ عددی',
        'کپسول آهن فروس سولفات ۳۰ عددی',
        'شربت آهن کودکان',
        'قطره آهن نوزاد',
        'ورق ام دی اف ۱۶ میل سفید',
        'ورق کاغذ A4 هشتاد گرم',
        'ورق گچبرگ کناف ۱۲ میل',
        'ورق پلکسی شفاف ۳ میل',
      ]) {
        expect(ProductText.isNonMetal(nonMetal), isTrue, reason: nonMetal);
        expect(ProductText.category(nonMetal), isEmpty, reason: nonMetal);
        expect(ProductText.spec(nonMetal, categoryHint: 'ورق').category, isEmpty,
            reason: nonMetal);
      }

      for (final steel in [
        'یک ورق آهن فولادی',
        'یک ورق آهن فولادی 3 میل',
        'یک برگ ورق سیاه فولادی مبارکه',
        'ورق آهن فولادی ST37',
        'ورق گالوانیزه 0.5 تاراز',
      ]) {
        expect(ProductText.isNonMetal(steel), isFalse, reason: steel);
        expect(ProductText.category(steel), 'ورق', reason: steel);
      }

      expect(ProductText.spec('یک ورق آهن فولادی 3').thickness, '3');
      expect(ProductText.spec('یک ورق آهن فولادی 4,500,000 تومان').thickness, isEmpty);
      expect(ProductText.spec('ورق استیل 304').thickness, isEmpty);
      expect(ProductText.spec('ورق استیل 304').grade, '304');
    });

    test('TextPriceEngine & Searcher reject قرص آهن یک ورق and extract یک ورق آهن فولادی', () {
      final pillRows = TextPriceEngine.analyze(
        text: '1405/08/22\nقرص آهن یک ورق : 230,500 تومان\nکپسول آهن ففول : 424,800 تومان',
        endpoint: 'test',
        seller: 'داروخانه آنلاین',
        sourceUrl: 'https://example.com/pharma',
        fetchedAt: now,
        postId: '1',
        publishedAt: now,
      );
      expect(pillRows.where((q) => q.amount != null), isEmpty);
      expect(Searcher.process(pillRows, now: now, windowDays: 30).quotes, isEmpty);

      final steelRows = TextPriceEngine.analyze(
        text: '1405/08/22\nیک ورق آهن فولادی 2 میل مبارکه : 4,500,000 تومان',
        endpoint: 'test',
        seller: 'بازرگانی فولاد',
        sourceUrl: 'https://example.com/steel',
        fetchedAt: now,
        postId: '2',
        publishedAt: now,
      );
      expect(steelRows.length, 1);
      final sheet = steelRows.single;
      expect(sheet.category, 'ورق');
      expect(sheet.unit, 'sheet');
      expect(sheet.amount, 4500000);
      expect(sheet.thicknessLabel, '2');
      expect(ProductFacts.of(sheet).values['material'], 'فولاد کربنی');
      expect(Searcher.process(steelRows, now: now, windowDays: 30).quotes.length, 1);
    });

    test('PublicTables & SourceFinder reject pharmacies/MDF and accept steel sheet sellers', () {
      const mixedHtml = '''
        <h2>لیست قیمت روز</h2>
        <p>1405/08/22</p>
        <table>
          <tr><th>محصول</th><th>واحد</th><th>قیمت (تومان)</th></tr>
          <tr><td>قرص آهن یک ورق ۱۰ عددی</td><td>ورق</td><td>230,500</td></tr>
          <tr><td>ورق ام دی اف ۱۶ میل</td><td>ورق</td><td>10,800,000</td></tr>
          <tr><td>یک ورق آهن فولادی 2 میل مبارکه</td><td>ورق</td><td>4,500,000</td></tr>
        </table>
      ''';
      final parsed = PublicTables.read(
        body: mixedHtml,
        url: 'https://example.com/prices',
        endpoint: 'tbl',
        seller: 'فروشنده آزمایشی',
        city: 'مشهد',
        category: 'عمومی',
        fetchedAt: now,
      );
      expect(parsed.length, 1);
      expect(parsed.single.title, contains('یک ورق آهن فولادی'));
      expect(parsed.single.amount, 4500000);

      expect(
        sellsGoods('خرید قرص آهن یک ورق ۱۰ عددی قیمت 230,500 تومان ارسال فوری از داروخانه'),
        isFalse,
      );
      expect(
        sellsGoods('قیمت ورق ام دی اف 16 میل 10,800,000 تومان فروش عمده ورق MDF'),
        isFalse,
      );
      expect(
        sellsGoods('فروش یک ورق آهن فولادی 2 میل مبارکه قیمت 4,500,000 تومان تحویل انبار'),
        isTrue,
      );
    });

    test('Search query matches steel sheets for یک ورق آهن فولادی and returns empty for قرص آهن یک ورق', () async {
      final store = await MarketStore.open(
          dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
      addTearDown(store.close);

      final steelSheet = Quote(
        id: 's1',
        endpoint: 'cat',
        seller: 'آهن ملل',
        sellerCity: 'مشهد',
        title: 'ورق سیاه 3 مبارکه',
        category: 'ورق',
        material: 'فولاد کربنی',
        brand: 'مبارکه',
        thickness: '3',
        amount: 42000,
        unit: 'kg',
        currency: 'تومان',
        sourceDateRaw: now.subtract(const Duration(hours: 2)).toIso8601String(),
        fetchedAt: now,
        sourceUrl: 'https://example.com/s1',
      );
      final aluminumSheet = Quote(
        id: 'a1',
        endpoint: 'cat',
        seller: 'فلزات رنگین',
        sellerCity: 'تهران',
        title: 'ورق آلومینیوم 3',
        category: 'ورق',
        material: 'آلومینیوم',
        thickness: '3',
        amount: 210000,
        unit: 'kg',
        currency: 'تومان',
        sourceDateRaw: now.subtract(const Duration(hours: 2)).toIso8601String(),
        fetchedAt: now,
        sourceUrl: 'https://example.com/a1',
      );
      final rebar = Quote(
        id: 'r1',
        endpoint: 'cat',
        seller: 'نیشابور',
        sellerCity: 'مشهد',
        title: 'میلگرد 16 A3',
        category: 'میلگرد',
        material: 'فولاد کربنی',
        size: '16',
        grade: 'A3',
        amount: 31000,
        unit: 'kg',
        currency: 'تومان',
        sourceDateRaw: now.subtract(const Duration(hours: 2)).toIso8601String(),
        fetchedAt: now,
        sourceUrl: 'https://example.com/r1',
      );

      await store.saveSnapshot('cat', [steelSheet, aluminumSheet, rebar]);
      final session = RangeSession(store);

      // Classic filter & fast index path on «یک ورق آهن فولادی»
      final classicSteel = (MarketFilter()
            ..windowDays = 0
            ..query = 'یک ورق آهن فولادی')
          .apply([steelSheet, aluminumSheet, rebar], now);
      expect(classicSteel.map((q) => q.id).toList(), ['s1']);

      final fastSteel = await session.candidates(
        scope: const CandidateScope(
            basis: 'original', query: 'یک ورق آهن فولادی', maxAgeDays: 30),
        at: now,
      );
      expect(fastSteel.quotes.map((q) => q.id).toList(), ['s1']);

      // Classic filter & fast index path on «قرص آهن یک ورق»
      final classicPill = (MarketFilter()
            ..windowDays = 0
            ..query = 'قرص آهن یک ورق')
          .apply([steelSheet, aluminumSheet, rebar], now);
      expect(classicPill, isEmpty);

      final fastPill = await session.candidates(
        scope: const CandidateScope(
            basis: 'original', query: 'قرص آهن یک ورق', maxAgeDays: 30),
        at: now,
      );
      expect(fastPill.quotes, isEmpty);
    });
  });
}
