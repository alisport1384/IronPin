import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ironpin/domain/market.dart';
import 'package:ironpin/domain/range_projection.dart';
import 'package:ironpin/domain/row_facts.dart';
import 'package:ironpin/ui/range_page.dart';

/// 0.8.1 — a candidate is never shown without its price.
///
/// The reported defect: the range tab listed candidates with no number. Root
/// cause: the announced amount was only reachable through the row's own *unit*,
/// so a row whose source never named a unit (`unit = unknown`) had no price at
/// all, although `amount` and `currency` were stored for it. `priceFor('original')`
/// now returns the announced amount itself.
final at = DateTime.now().toUtc();

Quote row(int n,
        {double? amount = 20181000,
        String currency = 'تومان',
        String unit = 'unknown',
        String category = 'تیرآهن'}) =>
    Quote(
        id: 'u$n',
        endpoint: 'catalog',
        seller: 'فروشنده$n',
        title: 'تیرآهن 14 ذوب آهن اصفهان',
        category: category,
        size: '14',
        amount: amount,
        unit: unit,
        currency: currency,
        sourceDateRaw: at.subtract(const Duration(hours: 2)).toIso8601String(),
        fetchedAt: at,
        sourceUrl: 'https://example.com/$n');

Map<String, Object?> wire(Quote q) => RowFacts.ofQuote(q).toWire();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test('the announced amount is the original price even without a unit', () {
    final q = row(1);
    expect(q.priceFor('original'), 20181000,
        reason: 'the number the source announced is a real price');
    expect(q.tomanFor('original'), 20181000);
    expect(q.priceFor('kg'), isNull,
        reason: 'no conversion is invented from a row without a unit');
    // A row whose currency is unknown keeps its number, but no toman price is
    // invented for it.
    final noCurrency = row(2, currency: 'نامشخص');
    expect(noCurrency.priceFor('original'), 20181000);
    expect(noCurrency.tomanFor('original'), isNull);
  });

  test('every candidate card prints a price', () {
    // Unit stated: the comparable price with its unit.
    expect(
        candidatePriceText(
            CatalogueItem('k1', wire(row(1, unit: 'kg', amount: 125000)), at)),
        contains('تومان / کیلوگرم'));
    // Unit not stated, currency stated: the announced amount, and the fact that
    // the basis is missing — never a blank price.
    final unitless = candidatePriceText(CatalogueItem('k2', wire(row(2)), at));
    expect(unitless, contains('تومان'));
    expect(unitless, contains('واحد نامشخص'));
    expect(unitless, isNot(contains('بدون قیمت')));
    // Unit and currency both unknown: the announced number is still shown.
    final bare = CatalogueItem('k3', wire(row(3, currency: 'نامشخص')), at);
    expect(candidatePriceText(bare), contains('نامشخص'));
    expect(candidatePriceText(bare), isNot(contains('بدون قیمت')));
    // A row with no amount at all is the only case without a number.
    final unpriced = CatalogueItem('k4', wire(row(4, amount: null)), at);
    expect(candidatePriceText(unpriced), 'بدون قیمت');
  });
}
