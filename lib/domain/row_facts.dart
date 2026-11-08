import 'dart:convert';

import 'market.dart';
import 'price_range.dart';
import 'product_schema.dart';
import 'product_text.dart';

/// Derived facts of one stored price row: everything the range workflow needs,
/// computed once and stored, instead of being recomputed on every read.
///
/// The derivation uses the domain's own functions (`ProductFacts.of`,
/// `announcementKey`, `exactProductKey`) on the payload the application already
/// holds in memory. That is what makes the fast path exact rather than a second
/// implementation of the rules: a stored row and a fresh calculation cannot
/// disagree, and `test/range_index_v074_test.dart` asserts it for every path.
///
/// `latest`/`history` remain the only source of truth for money and history; this
/// table is reproducible state, so it is not part of the backup and is rebuilt
/// whenever a payload is seen for the first time.
class RowFacts {
  /// Product family; `''` is stored as `سایر`, exactly as the domain decides.
  final String family;

  /// Technical facts: the only input of constraint matching.
  final Map<String, String> values;

  /// Comparable price in Toman, for the units the source really supports.
  final Map<String, double> prices;

  final String id, endpoint, title, category, seller, sellerCity, unit;
  final String brand, material, tax, terms, status, specification, searchText;
  /// Real source link of the offer, so a rendered row still opens its origin.
  final String sourceUrl;

  /// Pre-normalised city haystack (seller city + title + search text), so the
  /// city scope is one regular-expression test per row instead of a rebuild.
  final String haystack;

  /// Domain identities, computed once and reused verbatim.
  final String announceKey;
  final String? productKey;

  final double? amount;
  final String currency;
  final int? marketAt;
  final int fetchedAt;

  const RowFacts({
    required this.family,
    required this.values,
    required this.prices,
    required this.id,
    required this.endpoint,
    required this.title,
    required this.category,
    required this.seller,
    required this.sellerCity,
    required this.unit,
    required this.brand,
    required this.material,
    required this.tax,
    required this.terms,
    required this.status,
    required this.specification,
    required this.searchText,
    required this.sourceUrl,
    required this.haystack,
    required this.announceKey,
    required this.productKey,
    required this.amount,
    required this.currency,
    required this.marketAt,
    required this.fetchedAt,
  });

  /// Every technical key the extraction can emit for [family]: the declared
  /// fields plus the ones it always returns (`schedule`, `mesh`, `columns`,
  /// `mass`). Padding with them keeps a restored row identical to a fresh one.
  static List<String> keysOf(String family) => [
        ...?productFields[family]?.keys,
        'size',
        'schedule',
        'mesh',
        'columns',
        'mass'
      ];

  /// Units the domain accepts as a comparable basis.
  static const units = ['kg', 'ton', 'sheet', 'piece', 'roll', 'm', 'm2'];

  static RowFacts ofQuote(Quote q) {
    final facts = ProductFacts.of(q);
    return RowFacts(
      family: facts.family.isEmpty ? 'سایر' : facts.family,
      values: facts.values,
      prices: {
        for (final unit in units)
          if (q.tomanFor(unit) != null) unit: q.tomanFor(unit)!
      },
      id: q.id,
      endpoint: q.endpoint,
      title: q.title,
      category: q.category,
      seller: q.seller,
      sellerCity: q.sellerCity,
      unit: q.unit,
      brand: q.brand,
      material: q.material,
      tax: q.tax,
      terms: q.terms,
      status: q.status,
      specification: q.specificationLabel,
      searchText: specNorm('${q.title} ${q.specificationLabel} ${q.seller}'),
      sourceUrl: q.sourceUrl,
      haystack: ProductText.normalize('${q.sellerCity} ${q.title} '
          '${q.specificationLabel} ${q.seller}'),
      announceKey: announcementKey(q),
      productKey: exactProductKey(q),
      amount: q.amount,
      currency: q.currency,
      marketAt: q.marketAt?.toUtc().millisecondsSinceEpoch,
      fetchedAt: q.fetchedAt.toUtc().millisecondsSinceEpoch,
    );
  }

  static RowFacts ofPayload(String payload) =>
      ofQuote(Quote.fromJson(jsonDecode(payload) as Map<String, dynamic>));

  Map<String, Object?> toRow(String payloadHash) => {
        'payload': payloadHash,
        'family': family,
        'facts': _packFacts(values),
        'prices': _packPrices(prices),
        'announce_key': announceKey,
        'seller_norm': sellerKey,
        'product_key': productKey,
        'id': id,
        'endpoint': endpoint,
        'title': title,
        'category': category,
        'seller': seller,
        'seller_city': sellerCity,
        'unit': unit,
        'brand': brand,
        'material': material,
        'tax': tax,
        'terms': terms,
        'status': status,
        'specification': specification,
        'search': searchText,
        'source_url': sourceUrl,
        'haystack': haystack,
        'amount': amount,
        'currency': currency,
        'market_at': marketAt,
        'fetched_at': fetchedAt,
      };

  factory RowFacts.fromRow(Map<String, Object?> row) => RowFacts(
        family: row['family'] as String,
        values: () {
          final stored = _unpackFacts(row['facts'] as String);
          // The stored form only carries published values, and a fresh
          // extraction drops keys it emptied, so an absent key is the normal
          // case and only absent keys are filled here.
          return {
            for (final key in keysOf(row['family'] as String))
              if (!stored.containsKey(key)) key: '',
            ...stored,
          };
        }(),
        prices: _unpackPrices(row['prices'] as String),
        id: row['id'] as String,
        endpoint: row['endpoint'] as String,
        title: row['title'] as String? ?? '',
        category: row['category'] as String? ?? '',
        seller: row['seller'] as String? ?? '',
        sellerCity: row['seller_city'] as String? ?? '',
        unit: row['unit'] as String? ?? '',
        brand: row['brand'] as String? ?? '',
        material: row['material'] as String? ?? '',
        tax: row['tax'] as String? ?? '',
        terms: row['terms'] as String? ?? '',
        status: row['status'] as String? ?? '',
        specification: row['specification'] as String? ?? '',
        searchText: row['search'] as String? ?? '',
        sourceUrl: row['source_url'] as String? ?? '',
        haystack: row['haystack'] as String? ?? '',
        announceKey: row['announce_key'] as String,
        productKey: row['product_key'] as String?,
        amount: (row['amount'] as num?)?.toDouble(),
        currency: row['currency'] as String? ?? '',
        marketAt: row['market_at'] as int?,
        fetchedAt: row['fetched_at'] as int? ?? 0,
      );

  /// The comparable price in [basis]; an empty basis keeps the row's own unit.
  double? priceIn(String basis) => basis.isEmpty ? prices[unit] : prices[basis];

  /// `rangeBasis(Quote)` decided from stored values only.
  String get ownBasis => prices.containsKey('kg') ? 'kg' : unit;

  /// Compact wire form for the isolate and for the rows the UI renders.
  Map<String, Object?> toWire() => {
        'id': id,
        'endpoint': endpoint,
        'family': family,
        'values': values,
        'prices': prices,
        'sellerKey': sellerKey,
        'title': title,
        'category': category,
        'seller': seller,
        'sellerCity': sellerCity,
        'unit': unit,
        'brand': brand,
        'material': material,
        'tax': tax,
        'terms': terms,
        'status': status,
        'specification': specification,
        'search': searchText,
        'sourceUrl': sourceUrl,
        'amount': amount,
        'currency': currency,
        'marketAt': marketAt,
        'fetchedAt': fetchedAt,
      };

  /// Membership of one confirmed scope, evaluated without rebuilding a `Quote`
  /// and without compiling a regular expression per row.
  bool admits(String scopeFamily, Map<String, String> constraints,
      RegExp? cityBoundary) {
    if (family != scopeFamily) return false;
    if (constraints.isNotEmpty &&
        !ProductFacts(family, values).matches(constraints)) {
      return false;
    }
    return cityBoundary == null || cityBoundary.hasMatch(haystack);
  }

  /// Compiles the city scope once per confirmation; `null` means "all cities".
  static RegExp? cityBoundaryOf(String city) {
    final wanted = ProductText.normalize(city).trim();
    if (wanted.isEmpty) return null;
    return RegExp('(?<![آ-یA-Za-z])${RegExp.escape(wanted)}(?![آ-یA-Za-z])');
  }

  /// The domain's seller normaliser (`_norm` in `price_range.dart`), so the
  /// unique-seller count and the announcement identity match exactly, including
  /// `×` written as `x` and digit folding.
  String get sellerKey => specNorm(seller).replaceAll('×', 'x');
}

/// Compact row encodings: a stored row is decoded thousands of times per
/// confirmation, so it is split rather than JSON-parsed. Field values never
/// contain the separators (they are normalised source values, not free text:
/// `\u0001`/`\u0002` are stripped when packing).
String _packFacts(Map<String, String> values) => [
      for (final e in values.entries)
        if (e.value.isNotEmpty) '${e.key}\u0001${_clean(e.value)}'
    ].join('\u0002');

Map<String, String> _unpackFacts(String packed) {
  final out = <String, String>{};
  if (packed.isEmpty) return out;
  for (final pair in packed.split('\u0002')) {
    final at = pair.indexOf('\u0001');
    if (at <= 0) continue;
    out[pair.substring(0, at)] = pair.substring(at + 1);
  }
  return out;
}

String _packPrices(Map<String, double> prices) => [
      for (final e in prices.entries) '${e.key}\u0001${e.value}'
    ].join('\u0002');

Map<String, double> _unpackPrices(String packed) {
  final out = <String, double>{};
  if (packed.isEmpty) return out;
  for (final pair in packed.split('\u0002')) {
    final at = pair.indexOf('\u0001');
    if (at <= 0) continue;
    final value = double.tryParse(pair.substring(at + 1));
    if (value != null) out[pair.substring(0, at)] = value;
  }
  return out;
}

String _clean(String value) =>
    value.replaceAll('\u0001', ' ').replaceAll('\u0002', ' ');

/// Stable cheap fingerprint of a payload: the index is keyed by it, so an edited
/// payload is re-derived and an untouched one is never parsed again.
String payloadFingerprint(String payload) {
  var hash = 0x811c9dc5;
  for (var i = 0; i < payload.length; i++) {
    hash ^= payload.codeUnitAt(i);
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return '${payload.length.toRadixString(36)}-${hash.toRadixString(36)}';
}

/// Rebuilds a `Quote` for a row that is actually rendered, with the values the
/// index kept; the payload is not consulted (it holds no extra visible field).
Quote quoteFromWire(Map<String, Object?> wire) => Quote(
      id: wire['id'] as String,
      endpoint: wire['endpoint'] as String,
      seller: wire['seller'] as String? ?? '',
      sellerCity: wire['sellerCity'] as String? ?? '',
      title: wire['title'] as String? ?? '',
      category: wire['category'] as String? ?? '',
      brand: wire['brand'] as String? ?? '',
      material: wire['material'] as String? ?? '',
      tax: wire['tax'] as String? ?? '',
      terms: wire['terms'] as String? ?? '',
      status: wire['status'] as String? ?? '',
      unit: wire['unit'] as String? ?? '',
      amount: (wire['amount'] as num?)?.toDouble(),
      currency: wire['currency'] as String? ?? '',
      fetchedAt: DateTime.fromMillisecondsSinceEpoch(wire['fetchedAt'] as int,
          isUtc: true),
      sourceUrl: wire['sourceUrl'] as String? ?? '',
      sourceDateRaw: '',
      details: const {},
    );
