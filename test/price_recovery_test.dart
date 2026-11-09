import 'package:flutter_test/flutter_test.dart';
import 'package:ironpin/data/range_session.dart';
import 'package:ironpin/data/store.dart';
import 'package:ironpin/domain/market.dart';
import 'package:ironpin/domain/range_projection.dart';
import 'package:ironpin/domain/row_facts.dart';
import 'package:ironpin/domain/text_engine.dart';
import 'package:ironpin/ui/range_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 0.8.2 — announced prices reach the archive, and a card never says «بدون قیمت»
/// for an offer whose source published a number.
///
/// The two reported defects and their measured causes:
///
/// 1. The range/prices tabs showed products with no price, and whole products
///    were missing. `TextPriceEngine.analyze` cleared `pending` after the first
///    amount, so in a channel list («تیرآهن ذوب آهن» followed by «۱۴ : …»,
///    «۱۶ : …») every row after the first had no owner and was dropped — 8
///    announced prices produced 1 row.
/// 2. A row that also carried an incidental number (a Persian year, an order
///    code) was rejected by `numbers.length != 1` even though exactly one amount
///    bore the currency word, so the row lost its price entirely.
/// 3. A card rebuilt from the derived index had no `مبلغ استخراج‌شده`, so it
///    printed «بدون قیمت» and lost `hasTextAmount`, which made the prices tab's
///    fast path hide offers the classic filter shows.
final fetched = DateTime.utc(2026, 11, 6, 12);
final published = DateTime.utc(2026, 11, 6, 11, 30);

List<Quote> analyze(String text, {String defaultCurrency = 'نامشخص'}) =>
    TextPriceEngine.analyze(
        text: text,
        endpoint: 'recover',
        seller: 'فروشنده',
        sourceUrl: 'https://t.me/steel/1',
        fetchedAt: fetched,
        postId: '1',
        publishedAt: published,
        defaultCurrency: defaultCurrency);

Quote offer(int n,
    {double? amount = 42000,
    String currency = 'تومان',
    String unit = 'kg',
    Map<String, String> details = const {}}) =>
    Quote(
        id: 'o$n',
        endpoint: 'catalog',
        seller: 'فروشنده $n',
        sellerCity: 'تهران',
        title: 'ورق سیاه 3 مبارکه',
        category: 'ورق',
        thickness: '3',
        amount: amount,
        unit: unit,
        currency: currency,
        details: details,
        sourceDateRaw: fetched.subtract(const Duration(minutes: 40)).toIso8601String(),
        fetchedAt: fetched,
        sourceUrl: 'https://example.com/$n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  group('every announced price of a channel list is extracted', () {
    test('eight rows under one heading produce eight priced rows', () {
      final rows = analyze('''
تیرآهن ذوب آهن اصفهان 1405/08/14
14 : 20,181,000 تومان
16 : 25,818,000 تومان
18 : 31,818,000 تومان
20 : 41,181,000 تومان
22 : 41,818,000 تومان
24 : 48,181,000 تومان
27 : 60,181,000 تومان
30 : 95,454,000 تومان
''');
      expect(rows.where((q) => q.amount != null).length, 8,
          reason: 'the heading owns every row listed under it');
      expect(rows.map((q) => q.amount).toList(), [
        20181000, 25818000, 31818000, 41181000, 41818000, 48181000, 60181000,
        95454000
      ]);
      // Each row keeps the text the source wrote for it, not only the heading.
      expect(rows.last.title, contains('30'));
    });

    test('bare amounts under a currency the group states are all read', () {
      final rows = analyze('''
لیست قیمت میلگرد نیشابور 1405/08/14
قیمت‌ها به تومان و هر کیلوگرم
8 : 125,000
10 : 124,500
12 : 123,900
''');
      expect(rows.length, 3);
      expect(rows.every((q) => q.currency == 'تومان'), isTrue);
      expect(rows.every((q) => q.unit == 'kg'), isTrue);
      expect(rows.map((q) => q.amount).toList(), [125000, 124500, 123900]);
    });

    test('a source-declared currency prices a list of bare amounts', () {
      final rows = analyze('میلگرد نیشابور 1405/08/14\n8 : 125,000\n10 : 124,500',
          defaultCurrency: 'تومان');
      expect(rows.where((q) => q.amount != null).length, 2);
      expect(rows.every((q) => q.currency == 'تومان'), isTrue);
    });
  });

  group('an incidental number does not hide the labelled amount', () {
    test('a Persian year on the price line still yields the price', () {
      final r = analyze('ورق سیاه مبارکه 1405 ⬅ 42,000 تومان').single;
      expect(r.amount, 42000);
      expect(r.currency, 'تومان');
    });

    test('an order code on the price line still yields the price and size', () {
      final r = analyze('کد 1024 میلگرد 16 نیشابور ⬅ 125,000 تومان').single;
      expect(r.amount, 125000);
      expect(r.sizeLabel, '16');
    });

    test('two unlabelled amounts remain ambiguous and are never guessed', () {
      expect(analyze('میلگرد 16 : 120000 یا 125000').where((q) => q.amount != null),
          isEmpty);
    });

    test('an explicit range keeps its text and never becomes a single price', () {
      final r = analyze('ورق سیاه 3 میل مبارکه\n41,000 تا 43,000 تومان').single;
      expect(r.amount, isNull);
      expect(r.details['مبلغ استخراج‌شده'], '41,000 تا 43,000');
    });
  });

  group('a card rebuilt from the index keeps the source amount', () {
    test('the range card prints the announced amount, not «بدون قیمت»', () {
      final q = offer(1,
          amount: null,
          details: const {'مبلغ استخراج‌شده': '41,000 تا 43,000'});
      final wire = RowFacts.ofQuote(q).toWire();
      expect(wire['amountRaw'], '41,000 تا 43,000');
      final back = quoteFromWire(wire);
      expect(back.hasTextAmount, isTrue,
          reason: 'the classic filter reads this to keep the row');
      final text = candidatePriceText(CatalogueItem('k', wire, fetched));
      expect(text, isNot(contains('بدون قیمت')));
      expect(text, contains('۴۱,۰۰۰ تا ۴۳,۰۰۰'));
    });

    test('a stored row survives the index round trip with its amount text',
        () async {
      final store = await MarketStore.open(
          dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
      addTearDown(store.close);
      await store.saveSnapshot('catalog', [
        offer(1),
        offer(2,
            amount: null,
            currency: 'نامشخص',
            unit: 'unknown',
            details: const {'مبلغ استخراج‌شده': '125000'}),
      ]);
      final rows = await store.rangeIndexRows(fetched);
      // One row per receipt: the archive keeps a latest row and a history row
      // for each offer, and both are indexed.
      expect(rows.length, 4);
      expect(rows.every((r) => RowFacts.isCurrent(r)), isTrue,
          reason: 'the derivation wrote every column of this version');
      final rebuilt =
          rows.map(quoteFromStoredRow).where((q) => q.id == 'o2').toList();
      expect(rebuilt, isNotEmpty);
      for (final q in rebuilt) {
        expect(q.details['مبلغ استخراج‌شده'], '125000');
        expect(q.hasTextAmount, isTrue);
      }
    });
  });

  test('the prices fast path shows exactly what the classic filter shows',
      () async {
    final store = await MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
    addTearDown(store.close);
    final quotes = [
      offer(1), // comparable price
      offer(2, // a range offer: no single amount, but the source wrote one
          amount: null, details: const {'مبلغ استخراج‌شده': '41,000 تا 43,000'}),
      offer(3, amount: null, currency: 'نامشخص', unit: 'unknown'), // no number
    ];
    await store.saveSnapshot('catalog', quotes);
    final classic = (MarketFilter()..windowDays = 0)
        .apply(quotes, fetched)
        .map((q) => q.id)
        .toSet();
    expect(classic, {'o1', 'o2'},
        reason: 'the classic filter keeps a row that carries a text amount');

    final session = RangeSession(store);
    final set = await session.candidates(
        scope: const CandidateScope(
            basis: 'original', query: '', maxAgeDays: 36500),
        at: fetched);
    expect(set.quotes.map((q) => q.id).toSet(), classic,
        reason: 'the index path may only ever equal the classic answer');
    expect(set.unpriced, 1, reason: 'only the row with no number is withheld');
  });

  test('turning on unpriced announcements reveals them in the fast path',
      () async {
    final store = await MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
    addTearDown(store.close);
    await store.saveSnapshot('catalog',
        [offer(1), offer(3, amount: null, currency: 'نامشخص', unit: 'unknown')]);
    final session = RangeSession(store);
    Future<Set<String>> ids(bool includeUnpriced) async => (await session
            .candidates(
                scope: CandidateScope(
                    basis: 'original',
                    query: '',
                    maxAgeDays: 36500,
                    includeUnpriced: includeUnpriced),
                at: fetched))
        .quotes
        .map((q) => q.id)
        .toSet();
    expect(await ids(false), {'o1'});
    expect(await ids(true), {'o1', 'o3'},
        reason: 'the switch is honoured by the index path too');
  });
}
