import 'dart:convert';
import 'dart:typed_data';

import 'market.dart';
import 'money.dart';
import 'price_range.dart';
import 'product_schema.dart';
import 'product_text.dart';
import 'row_facts.dart';

/// One comparable price row of a confirmed range answer.
class RangeRow {
  /// Index of the source row, so an answer is a list of indices, not data.
  final int source;
  final Map<String, Object?> wire;
  final double? price;

  /// Comparable price in the row's own basis, needed by the announcement identity.
  final double? ownPrice;

  RangeRow.of(RowFacts row,
      {required this.source, required String basis, Map<String, Object?>? wire})
      : wire = wire ?? row.toWire(),
        price = row.priceIn(basis),
        ownPrice = row.priceIn(row.ownBasis);

  /// Identity of one announcement, contract-identical to `announcementKey`.
  /// Joined with a separator no identity component can contain, instead of
  /// JSON-encoding thousands of keys per confirmation.
  String get key => '${wire['endpoint']}\u0001${wire['id']}\u0001'
      '${wire['sellerKey']}\u0001${wire['productKey']}\u0001'
      '${wire['marketAt']}\u0001$ownPrice';
}

/// The answer of a confirmed scope, computed from indexed rows only.
///
/// Membership is decided exactly as `calculateProductRange` decides it (same
/// family test, same `ProductFacts.matches`, same 48-hour window, same one entry
/// per announcement, newest receipt wins), then each unit is a pure projection of
/// that set. No payload is parsed and no `Quote` is built here.
/// The index rows of one snapshot, grouped by family once and deduplicating
/// shared row maps. Wire maps are built lazily only for rows inside the target
/// family and time window, keeping memory bounded even at 100,000+ rows.
class PreparedIndex {
  final int length;
  final Map<String, List<({int source, RowFacts row})>> _byFamily;
  final Map<String, List<({int source, Map<String, Object?> raw})>>
      _rawByFamily;
  final Map<Map<String, Object?>, RowFacts> _factCache;
  PreparedIndex(List<RowFacts> facts, [List<Map<String, Object?>> _ = const []])
      : length = facts.length,
        _byFamily = _groupFacts(facts),
        _rawByFamily = const {},
        _factCache = Map<Map<String, Object?>, RowFacts>.identity();
  PreparedIndex._raw(this.length, this._rawByFamily)
      : _byFamily = <String, List<({int source, RowFacts row})>>{},
        _factCache = Map<Map<String, Object?>, RowFacts>.identity();
  const PreparedIndex._(this.length, this._byFamily)
      : _rawByFamily = const {},
        _factCache = const {};

  static Map<String, List<({int source, RowFacts row})>> _groupFacts(
      List<RowFacts> facts) {
    final out = <String, List<({int source, RowFacts row})>>{};
    for (var i = 0; i < facts.length; i++) {
      (out[facts[i].family] ??= []).add((source: i, row: facts[i]));
    }
    return out;
  }

  List<({int source, RowFacts row})> forFamily(String family) {
    final cached = _byFamily[family];
    if (cached != null) return cached;
    final rawList = _rawByFamily.remove(family);
    if (rawList == null || rawList.isEmpty) return const [];
    final built = <({int source, RowFacts row})>[
      for (final item in rawList)
        (
          source: item.source,
          row: _factCache.putIfAbsent(
              item.raw, () => RowFacts.fromRow(item.raw))
        )
    ];
    _byFamily[family] = built;
    return built;
  }
}

PreparedIndex prepare(List<Map<String, Object?>> indexRows) {
  final rawByFamily = <String, List<({int source, Map<String, Object?> raw})>>{};
  for (var i = 0; i < indexRows.length; i++) {
    final raw = indexRows[i];
    final family = raw['family'] as String? ?? '';
    (rawByFamily[family] ??= []).add((source: i, raw: raw));
  }
  return PreparedIndex._raw(indexRows.length, rawByFamily);
}

({List<Map<String, Object?>> rows, List<Map<String, Object?>> ranges,
  Map<String, int> excluded, int kept, List<Map<String, Object?>> catalog,
  List<Map<String, Object?>> candidates, List<int> announceIndices})
    project(
  List<Map<String, Object?>> indexRows, {
  required String family,
  required Map<String, String> fields,
  required String basis,
  required String city,
  required int nowMs,
  int windowMs = 48 * 3600 * 1000,
}) {
  final cache = Map<Map<String, Object?>, RowFacts>.identity();
  final matching = <({int source, RowFacts row})>[];
  for (var i = 0; i < indexRows.length; i++) {
    final raw = indexRows[i];
    if (raw['family'] != family) continue;
    final row = cache.putIfAbsent(raw, () => RowFacts.fromRow(raw));
    matching.add((source: i, row: row));
  }
  return projectPrepared(
    PreparedIndex._(indexRows.length, {if (matching.isNotEmpty) family: matching}),
    family: family,
    fields: fields,
    basis: basis,
    city: city,
    nowMs: nowMs,
    windowMs: windowMs,
  );
}

/// Same answer as [project], over an index that is already expanded.
({List<Map<String, Object?>> rows, List<Map<String, Object?>> ranges,
  Map<String, int> excluded, int kept, List<Map<String, Object?>> catalog,
  List<Map<String, Object?>> candidates, List<int> announceIndices})
    projectPrepared(
  PreparedIndex index, {
  required String family,
  required Map<String, String> fields,
  required String basis,
  required String city,
  required int nowMs,
  int windowMs = 48 * 3600 * 1000,
}) {
  final window = windowMs;
  final since = nowMs - window;
  final constraints = {
    for (final e in fields.entries)
      if (e.value.trim().isNotEmpty) e.key: e.value
  };
  final boundary = RowFacts.cityBoundaryOf(city);
  final unique = <String, ({RowFacts row, RangeRow value})>{};
  // Selection is the whole local catalogue of the scope — old, undated and
  // unpriced rows included — while the statistics stay strictly 48 hours.
  final catalog = <String, ({RowFacts row, int fetchedAt})>{};
  final wireCache = Map<RowFacts, Map<String, Object?>>.identity();
  for (final entry in index.forFamily(family)) {
    final source = entry.source;
    final row = entry.row;
    if (!row.admits(family, constraints, boundary)) continue;
    final fetchedAt = row.fetchedAt;
    // One selectable entry per stored offer, however often it was re-received.
    final catalogKey = '${row.endpoint}\u0001${row.id}';
    final known = catalog[catalogKey];
    if (known == null || known.fetchedAt <= fetchedAt) {
      catalog[catalogKey] = (row: row, fetchedAt: fetchedAt);
    }
    final marketAt = row.marketAt;
    if (marketAt == null || marketAt > nowMs || marketAt < since) continue;
    final wire = wireCache.putIfAbsent(row, () => row.toWire());
    final value = RangeRow.of(row, source: source, basis: basis, wire: wire);
    final previous = unique[value.key];
    if (previous == null || previous.row.fetchedAt <= row.fetchedAt) {
      unique[value.key] = (row: row, value: value);
    }
  }
  final kept = unique.values.toList()
    ..sort((a, b) => (b.row.marketAt ?? 0).compareTo(a.row.marketAt ?? 0));
  // The whole scope is one product, so its claims must agree in kilograms —
  // the unit the trade converts per ton with. A claim ten times away from
  // the middle claim carries a wrong digit: it is withheld from the averages
  // and the candidates, with its reason recorded, while its announcement
  // stays visible in the list above.
  final agreedMiddle =
      agreedKgMiddle([for (final item in kept) item.row.priceIn('kg')]);
  // One rendered row per announcement, like `buildAnswer` keeps them: the
  // candidates are the rows a user can actually see.
  final seenRows = <String>{};
  final rows = <Map<String, Object?>>[];
  final grouped = <String, List<int>>{};
  final groupBasis = <String, String>{};
  final excluded = <String, int>{};
  for (final item in kept) {
    if (!seenRows.add(
        '${item.value.wire['endpoint']}\u0001${item.value.wire['id']}')) {
      continue;
    }
    final index = rows.length;
    rows.add({...item.value.wire, 'source': item.value.source});
    // The same basis decision as `calculateProductRange`: a user-chosen unit,
    // then the row's own unit, then whatever the row's own conversion table
    // supports. Keeping the two paths identical is what makes the tab's numbers
    // match the domain's.
    final unit = basis.isNotEmpty
        ? basis
        : (resolvedRowBasis(item.row.prices, item.row.unit) ?? unpricedBasis);
    final price = unit == unpricedBasis ? null : item.row.priceIn(unit);
    if (unit == unpricedBasis) {
      const reason = 'واحد قیمت در منبع مشخص نیست؛ مبلغ دیده می‌شود ولی در میانگین نیست';
      excluded[reason] = (excluded[reason] ?? 0) + 1;
      continue;
    }
    if (price == null ||
        !price.isFinite ||
        price <= 0 ||
        price > 9000000000000000) {
      const reason =
          'نمایش در اعلام‌ها؛ مبلغ/ارز/واحد یا تبدیل معتبر برای آمار ندارد';
      excluded[reason] = (excluded[reason] ?? 0) + 1;
      continue;
    }
    // A number that cannot stand beside the product's other numbers (the
    // «هر کیلو ۱۰۰ هزار، هر تن ۱۰ هزار» pair): neither claim may become an
    // average or a candidate while they contradict each other.
    if (kgDisagrees(agreedMiddle, item.row.priceIn('kg'))) {
      excluded[kgDisagreementReason] =
          (excluded[kgDisagreementReason] ?? 0) + 1;
      continue;
    }
    if (family == 'بولت' && item.row.productKey == null) {
      const reason =
          'بولت با مشخصات ناقص؛ نوع، ابعاد، رزوه، گرید، پوشش و شمول ست برای مقایسه لازم است';
      excluded[reason] = (excluded[reason] ?? 0) + 1;
      continue;
    }
    // Every family groups by basis + technical specification, exactly like
    // `calculateProductRange`: rows of one product keep their own indicators,
    // «۱ کیلوگرم» and «۱ تن» stay separate groups, and rows without exact
    // specifications pool per unit under a null technical key.
    final group = jsonEncode([unit, item.row.productKey]);
    (grouped[group] ??= []).add(index);
    groupBasis[group] = unit;
  }
  final ranges = <Map<String, Object?>>[];
  for (final entry in grouped.entries) {
    final unit = groupBasis[entry.key]!;
    final members = entry.value;
    double at(int i) => rows[i]['prices'] is Map
        ? ((rows[i]['prices'] as Map)[unit] as num).toDouble()
        : 0;
    final prices = [for (final i in members) at(i)];
    final min = prices.reduce((a, b) => a < b ? a : b);
    final max = prices.reduce((a, b) => a > b ? a : b);
    final mean = prices.fold<double>(0, (a, b) => a + b) / prices.length;
    ranges.add({
      'key': entry.key,
      'basis': unit,
      'indices': members,
      'min': min,
      'max': max,
      'mean': mean,
      'rounded': mean.round(),
      'source': [for (final i in members) rows[i]['source']],
      'sellers': {for (final i in members) rows[i]['sellerKey']}.length,
    });
  }
  final catalogRows = catalog.values.toList()
    ..sort((a, b) => a.row.title.compareTo(b.row.title));
  // Candidates are the rows the user can choose between: inside the window and
  // with a comparable price. The narrower «اعلام‌های نتیجه» list is the subset
  // that can also be counted in a range (a bolt without full specs is a real,
  // visible candidate but cannot be pooled with another).
  final counted = <int>{};
  for (final range in ranges) {
    for (final i in range['indices'] as List) {
      counted.add(i as int);
    }
  }
  // A row with no price is not a candidate at all: it produced an entry the tab
  // could not put a number on. Rows are only kept when they carry a real,
  // positive amount — a source that writes «۰ تومان» means "no price", which is
  // exactly what «قیمت ندارد» says in the announcements; the UI still counts and
  // states how many were withheld.
  final allCandidates = [
    for (var i = 0; i < rows.length; i++)
      if (rows[i]['amount'] is num && (rows[i]['amount'] as num) > 0) i
  ];
  final countedCandidates = [
    for (var i = 0; i < rows.length; i++)
      if (counted.contains(i)) i
  ];
  return (
    rows: rows,
    ranges: ranges,
    excluded: excluded,
    kept: kept.length,
    catalog: [for (final item in catalogRows) item.row.toWire()],
    candidates: [
      for (final i in allCandidates) {...rows[i], 'counted': counted.contains(i)}
    ],
    announceIndices: countedCandidates
  );
}

/// The three indicators of a candidate's own product, as the range tab states
/// them on the candidate and on the product card: the same min/max/mean the
/// statistics are built from, the candidate's own price inside that range, and
/// the roles the price earns there («پایین‌ترین»، «بالاترین»، «نزدیک‌ترین به
/// میانگین»). One product's marks never carry another product's numbers.
class CandidateMark {
  /// Id of the source quote the mark belongs to.
  final String id;

  /// The candidate's own comparable price in [basis], in toman.
  final double price;
  final String basis;
  final double minimum, maximum, mean;

  /// (price − mean) / mean × 100 — the candidate's deviation from its own
  /// product's mean.
  final double deviationPct;
  final List<String> roles;

  const CandidateMark(
      {required this.id,
      required this.price,
      required this.basis,
      required this.minimum,
      required this.maximum,
      required this.mean,
      required this.deviationPct,
      required this.roles});
}

/// One selectable entry of the local catalogue.
///
/// The quote and its search text are cheap; the reasons it is outside the
/// statistics are not (they walk the price/specification rules), so they are
/// computed the first time an entry is actually shown — expanding the catalogue
/// costs only the rows on screen, never the whole archive.
class CatalogueItem {
  final String key;
  final Map<String, Object?> wire;
  final DateTime at;

  /// True when this candidate can also be counted in a range of its unit.
  final bool counted;

  /// The candidate's own product indicators; built with the answer, never
  /// fetched later — see [buildAnswer].
  final CandidateMark? mark;

  CatalogueItem(this.key, this.wire, this.at,
      {this.counted = true, this.mark});

  /// Built only when the entry is actually shown.
  late final Quote example = quoteFromWire(wire);
  late final String searchText = catalogueSearch(wire);
  late final List<String> unavailableReasons =
      rangeUnavailableReasons(example, at);
}

/// A confirmed range answer, built from the persisted index.
///
/// [result] and [catalog] are the same domain objects the UI always rendered;
/// they are constructed only from the rows the answer needs, never from the whole
/// archive. Lives here, in the domain layer, because the persistent worker builds
/// it inside its own isolate.
class RangeAnswer {
  final ProductRangeResult result;
  final List<CatalogueItem> catalog;

  /// Every selectable candidate of the scope (real announcement date and a
  /// comparable price); [catalog] is the same list carrying the reason text of
  /// the entries that have one.
  final List<CatalogueItem> candidates;
  final int inputRows;
  final int keptRows;
  final DateTime at;
  final bool fromMemory;
  const RangeAnswer(this.result, this.catalog, this.inputRows, this.keptRows,
      this.at,
      {this.fromMemory = false, List<CatalogueItem>? candidates})
      : candidates = candidates ?? catalog;

  RangeAnswer asMemory() => RangeAnswer(result, catalog, inputRows, keptRows, at,
      fromMemory: true, candidates: candidates);
}

/// The UI-facing answer of a projection, built once inside the worker isolate.
RangeAnswer buildAnswer(
  ({List<Map<String, Object?>> rows, List<Map<String, Object?>> ranges,
          Map<String, int> excluded, int kept,
          List<Map<String, Object?>> catalog,
          List<Map<String, Object?>> candidates,
          List<int> announceIndices}) projected,
  {required String basis, required DateTime at, required int inputRows}) {
  final wires = projected.rows;
  final quotes = [for (final wire in wires) quoteFromWire(wire)];
  final ranges = [
    for (final range in projected.ranges)
      PriceRange.computed(
          range['key'] as String,
          range['basis'] as String,
          quotes[(range['indices'] as List).first as int],
          [for (final i in range['indices'] as List) quotes[i as int]],
          minimum: (range['min'] as num).toDouble(),
          maximum: (range['max'] as num).toDouble(),
          mean: (range['mean'] as num).toDouble(),
          roundedMean: range['rounded'] as int,
          sellers: range['sellers'] as int)
  ];
  // Every counted row's own product indicators, decided inside the range it is
  // counted in — the mark and the product card can never disagree.
  final markByIndex = <int, CandidateMark>{};
  for (final range in projected.ranges) {
    final unit = range['basis'] as String;
    final indices = [for (final i in range['indices'] as List) i as int];
    final values = [
      for (final i in indices) toman(quotes[i].priceFor(unit), quotes[i].currency)!
    ];
    final marks = _marksFor(values,
        ids: [for (final i in indices) quotes[i].id],
        basis: unit,
        minimum: (range['min'] as num).toDouble(),
        maximum: (range['max'] as num).toDouble(),
        mean: (range['mean'] as num).toDouble());
    for (var k = 0; k < indices.length; k++) {
      markByIndex[indices[k]] = marks[k];
    }
  }
  // The candidates are exactly the rows the statistics are built from: a real
  // announcement date inside the window and a comparable price in its unit.
  // An offer without a date or without such a price is never offered here — it
  // stays in the announcements and is counted under «علت نبودن در آمار» — so
  // min, max and mean are taken from every candidate the tab lists, and every
  // listed candidate is counted in them.
  final candidates = <CatalogueItem>[
    for (final i in projected.announceIndices)
      CatalogueItem('${wires[i]['endpoint']}:${wires[i]['id']}:$i', wires[i], at,
          counted: true, mark: markByIndex[i])
  ];
  return RangeAnswer(
      ProductRangeResult(quotes, ranges, projected.excluded, at),
      candidates,
      inputRows,
      projected.kept,
      at,
      candidates: candidates);
}

/// The marks of one range's members: one helper shared by the answer path and
/// by [buildProductRanges], so the roles and the deviation are identical
/// wherever the same numbers are shown.
///
/// A price earns «پایین‌ترین»/«بالاترین» on exact equality with the range's
/// extremes, and «نزدیک‌ترین به میانگین» when its distance to the mean is the
/// smallest of the group (ties both earn it — a single-member product is all
/// three roles at once).
List<CandidateMark> _marksFor(List<double> prices,
    {required List<String> ids,
    required String basis,
    required double minimum,
    required double maximum,
    required double mean}) {
  var nearest = double.infinity;
  for (final price in prices) {
    final distance = (price - mean).abs();
    if (distance < nearest) nearest = distance;
  }
  return [
    for (var i = 0; i < prices.length; i++)
      CandidateMark(
          id: ids[i],
          price: prices[i],
          basis: basis,
          minimum: minimum,
          maximum: maximum,
          mean: mean,
          deviationPct: mean == 0 ? 0 : (prices[i] - mean) / mean * 100,
          roles: [
            if (prices[i] == minimum) 'پایین‌ترین',
            if (prices[i] == maximum) 'بالاترین',
            if ((prices[i] - mean).abs() <= nearest) 'نزدیک‌ترین به میانگین',
          ])
  ];
}

/// Per-product indicator ranges over an already-selected set of quotes — the
/// candidates of a confirmed answer — plus the marks of each range's members.
///
/// This is the card view of the same statistics: the input rows already passed
/// the window, the kilogram agreement and the price checks on the way in, so
/// only the cheap guards (a real date not in the future, a comparable unit, a
/// positive price) run again. Rows are grouped exactly as
/// `calculateProductRange` groups them, so every product keeps its own
/// mean/high/low and «۱ کیلوگرم» listings never merge with «۱ تن».
(List<PriceRange>, Map<String, List<CandidateMark>>) buildProductRanges(
    List<Quote> quotes, DateTime now,
    {String basis = ''}) {
  final grouped = <String, ({String basis, List<Quote> rows})>{};
  for (final q in quotes) {
    final marketAt = q.marketAt;
    if (marketAt == null || marketAt.isAfter(now)) continue;
    final unit =
        basis.isNotEmpty ? basis : (resolvedBasis(q) ?? unpricedBasis);
    if (unit == unpricedBasis) continue;
    final price = toman(q.priceFor(unit), q.currency);
    if (price == null || !price.isFinite || price <= 0) continue;
    final key = jsonEncode([unit, exactProductKey(q)]);
    final slot = grouped[key];
    if (slot == null) {
      grouped[key] = (basis: unit, rows: [q]);
    } else {
      slot.rows.add(q);
    }
  }
  final ranges = <PriceRange>[];
  final marks = <String, List<CandidateMark>>{};
  for (final entry in grouped.entries) {
    final unit = entry.value.basis;
    final rows = entry.value.rows;
    final range = PriceRange(entry.key, unit, rows.first, rows);
    marks[entry.key] = _marksFor(
        [for (final q in rows) toman(q.priceFor(unit), q.currency)!],
        ids: [for (final q in rows) q.id],
        basis: unit,
        minimum: range.minimum,
        maximum: range.maximum,
        mean: range.mean);
    ranges.add(range);
  }
  ranges.sort((a, b) => a.example.title.compareTo(b.example.title));
  return (ranges, marks);
}

/// What the prices tab asks for: the same scope the classic filter describes,
/// expressed as the derived columns of one stored row so it can be decided
/// without building a `Quote`.
///
/// Every field the filter can set has a column here. A field with no column is
/// *not* silently ignored — [selectCandidates] falls back to the classic filter
/// for that field, so the fast path can only ever be equal to the old answer.
class CandidateScope {
  /// `MarketFilter.basis`, exactly.
  final String basis;

  /// The search words, in the same normal form the classic query uses.
  final String query;

  /// Window in days, counted back from `now`.
  final int maxAgeDays;

  /// Exact-match scope, in the same form the filter compares against.
  final String category, material, city, unit, size, thickness, grade;
  final String cityKind;
  final bool onlyFresh, includeUnpriced;
  final double? minPrice, maxPrice;
  final List<String> queryCities;

  const CandidateScope({
    required this.basis,
    required this.query,
    required this.maxAgeDays,
    this.category = '',
    this.material = '',
    this.city = '',
    this.unit = '',
    this.size = '',
    this.thickness = '',
    this.grade = '',
    this.cityKind = 'all',
    this.onlyFresh = false,
    // The same default as `MarketFilter.includeUnpriced`: a scope that does not
    // say otherwise hides announcements with no price at all, exactly as the
    // classic filter does. A row that still carries the amount its source wrote
    // is kept either way, which is also what the classic filter decides.
    this.includeUnpriced = false,
    this.minPrice,
    this.maxPrice,
    this.queryCities = const ['مشهد', 'تهران', 'اصفهان', 'تبریز', 'نیشابور'],
  });

  /// The columns this scope cannot decide from index values alone.
  ///
  /// An empty query needs nothing; a non-empty one is matched by the classic
  /// `ProductQuery` over the rendered text, which the index does not rebuild.
  List<String> get undecidable => [if (query.isNotEmpty) 'query'];
}

/// A selectable candidate of the stored archive.
///
/// Decided from the derived columns only, so no `Quote` and no text extraction
/// is built for the thousands of rows that never reach the screen: the two hard
/// requirements — a real announcement date and a comparable price in the chosen
/// basis — are checked as numbers, and every other field is one comparison on a
/// column that was derived by the domain's own rule at write time.
({List<Map<String, Object?>> wires, int withheld, int undated, int unpriced})
    selectCandidates(
  List<Map<String, Object?>> indexRows, {
  required CandidateScope scope,
  required int nowMs,
}) {
  final selector = CandidateSelector(scope: scope, nowMs: nowMs);
  for (final raw in indexRows) {
    selector.add(raw);
  }
  return selector.finish();
}

/// Stateful form of [selectCandidates]: identical decisions, one row at a
/// time, so a caller with a large archive can feed rows in slices and yield
/// to the UI isolate between slices instead of blocking it for the whole
/// scan. The synchronous [selectCandidates] is this same loop without the
/// pauses, so the two paths can never disagree.
class CandidateSelector {
  CandidateSelector({
    required this.scope,
    required this.nowMs,
    int offerCount = 0,
  })  : _since = nowMs - scope.maxAgeDays * 24 * 3600 * 1000,
        _future = nowMs + 5 * 60 * 1000,
        _intent = scope.query.trim().isEmpty
            ? null
            : ProductQuery.parse(scope.query, cities: scope.queryCities),
        _grade = latin(scope.grade).toUpperCase(),
        _sizeWanted = number(scope.size),
        _thicknessWanted = number(scope.thickness),
        _cityBoundary = scope.city.isEmpty || scope.cityKind != 'all'
            ? null
            : RowFacts.cityBoundaryOf(scope.city),
        _slotState = offerCount > 0 ? Uint8List(offerCount) : null,
        _slotPos = offerCount > 0 ? Int32List(offerCount) : null,
        _slotFetchedAt = offerCount > 0 ? Int64List(offerCount) : null;

  final CandidateScope scope;
  final int nowMs;
  final int _since;
  final int _future;
  final ProductQuery? _intent;
  final String _grade;
  final double? _sizeWanted;
  final double? _thicknessWanted;
  final RegExp? _cityBoundary;
  final Uint8List? _slotState;
  final Int32List? _slotPos;
  final Int64List? _slotFetchedAt;

  final List<Map<String, Object?>> wires = [];
  int undated = 0, unpriced = 0;
  // Offer identity without a per-row string allocation: offers are deduped
  // by (endpoint, id), kept as nested maps so scanning 100k rows builds no
  // identity strings at all (the concatenated key was one allocation and
  // one hash per row, pure garbage-collector pressure on low-end phones).
  final Map<String, Map<String, int>> _slot = {};
  final Map<String, Set<String>> _held = {};

  static double? _resolvePrice(
      String packed, String unit, String basis, String currency, num? amount) {
    final wantOwn = basis == 'original' || basis.isEmpty;
    final target = wantOwn
        ? (unit != 'unknown' && comparableUnits.contains(unit) ? unit : '')
        : basis;
    if (packed.isNotEmpty) {
      double? exact, kg, piece;
      var pos = 0;
      final n = packed.length;
      while (pos < n) {
        var next = packed.indexOf('\u0002', pos);
        if (next < 0) next = n;
        final sep = packed.indexOf('\u0001', pos);
        if (sep > pos && sep < next) {
          final u = packed.substring(pos, sep);
          if (target.isNotEmpty) {
            if (u == target) {
              exact = double.tryParse(packed.substring(sep + 1, next));
              break;
            }
          } else {
            if (u == 'kg') {
              kg = double.tryParse(packed.substring(sep + 1, next));
              break;
            } else if (u == 'piece') {
              piece = double.tryParse(packed.substring(sep + 1, next));
            }
          }
        }
        pos = next + 1;
      }
      final rawVal = target.isNotEmpty ? exact : (kg ?? piece);
      if (rawVal != null) return toman(rawVal, currency);
      if (target.isNotEmpty || kg != null || piece != null) return null;
    }
    if (wantOwn && target.isEmpty) {
      return toman(amount?.toDouble(), currency);
    }
    return null;
  }

  void addWithSlot(
      Map<String, Object?> raw, int offerSlot, bool knownNonMetal) {
    if (knownNonMetal) return;
    final states = _slotState!;
    final st = states[offerSlot];
    if (st == 2) return;
    if (st == 1) {
      final fetchedAt = (raw['fetched_at'] as int?) ?? 0;
      if (fetchedAt >= _slotFetchedAt![offerSlot]) {
        wires[_slotPos![offerSlot]] = raw;
        _slotFetchedAt[offerSlot] = fetchedAt;
      }
      return;
    }
    if (!_acceptRow(raw, raw['title'] as String? ?? '', offerSlot: offerSlot)) {
      return;
    }
    states[offerSlot] = 1;
    _slotPos![offerSlot] = wires.length;
    _slotFetchedAt![offerSlot] = (raw['fetched_at'] as int?) ?? 0;
    wires.add(raw);
  }

  void add(Map<String, Object?> raw) {
    final title = raw['title'] as String? ?? '';
    if (ProductText.isNonMetal(title)) return;
    final endpoint = raw['endpoint'] as String? ?? '';
    final offerId = raw['id'] as String? ?? '';
    final seen = _slot[endpoint]?[offerId];
    if (seen == null && !(_held[endpoint]?.contains(offerId) ?? false)) {
    } else if (seen != null) {
      if (((raw['fetched_at'] as int?) ?? 0) >=
          ((wires[seen]['fetched_at'] as int?) ?? 0)) {
        wires[seen] = raw;
      }
      return;
    } else {
      return;
    }
    if (!_acceptRow(raw, title, endpoint: endpoint, offerId: offerId)) return;
    (_slot[endpoint] ??= {})[offerId] = wires.length;
    wires.add(raw);
  }

  bool _acceptRow(Map<String, Object?> raw, String title,
      {String? endpoint, String? offerId, int? offerSlot}) {
    final marketAt = raw['market_at'] as int?;
    if (marketAt == null || marketAt > _future || marketAt < _since) {
      undated++;
      if (offerSlot != null) {
        _slotState![offerSlot] = 2;
      } else if (endpoint != null && offerId != null) {
        (_held[endpoint] ??= {}).add(offerId);
      }
      return false;
    }
    final unit = raw['unit'] as String? ?? '';
    final currency = raw['currency'] as String? ?? '';
    final packed = raw['prices'] as String? ?? '';
    final price = _resolvePrice(
        packed, unit, scope.basis, currency, raw['amount'] as num?);
    final comparable = price != null && price.isFinite && price > 0;
    if (!comparable) {
      final hasTextAmount = (raw['amount_raw'] as String? ?? '').isNotEmpty;
      if (!scope.includeUnpriced && !hasTextAmount) {
        unpriced++;
        if (offerSlot != null) {
          _slotState![offerSlot] = 2;
        } else if (endpoint != null && offerId != null) {
          (_held[endpoint] ??= {}).add(offerId);
        }
        return false;
      }
      if (scope.minPrice != null || scope.maxPrice != null) return false;
    } else if ((scope.minPrice != null && price < scope.minPrice!) ||
        (scope.maxPrice != null && price > scope.maxPrice!)) {
      return false;
    }
    final cat = raw['category'] as String? ?? '';
    if (scope.category.isNotEmpty && cat != scope.category) {
      return false;
    }
    final material = raw['material'] as String? ?? '';
    if (scope.material.isNotEmpty && material != scope.material) {
      return false;
    }
    if (scope.unit.isNotEmpty && unit != scope.unit) return false;
    final sizeLabel = raw['size_label'] as String? ?? '';
    final thicknessLabel = raw['thickness_label'] as String? ?? '';
    final gradeLabel = raw['grade_label'] as String? ?? '';
    if ((scope.size.isNotEmpty &&
            !_sameMeasure(
                scope.size, _sizeWanted, raw['size_num'] as num?, sizeLabel)) ||
        (scope.thickness.isNotEmpty &&
            !_sameMeasure(scope.thickness, _thicknessWanted,
                raw['thickness_num'] as num?, thicknessLabel)) ||
        (_grade.isNotEmpty &&
            gradeLabel.isNotEmpty &&
            latin(gradeLabel).toUpperCase() != _grade)) {
      return false;
    }
    final sellerCity = raw['seller_city'] as String? ?? '';
    if (scope.city.isNotEmpty &&
        (scope.cityKind == 'all'
            ? !(_cityBoundary?.hasMatch(raw['haystack'] as String? ?? '') ??
                true)
            : sellerCity != scope.city)) {
      return false;
    }
    if (scope.onlyFresh) {
      final age = nowMs - marketAt;
      if (age < -5 * 60 * 1000 || age > 30 * 3600 * 1000) return false;
    }
    final intent = _intent;
    if (intent != null) {
      if (intent.nonMetal) return false;
      if (intent.spec.category.isNotEmpty && intent.spec.category != cat) {
        return false;
      }
      if (intent.words.isEmpty && intent.width.isEmpty) {
        if (!intent.matches(
            category: cat,
            thickness: thicknessLabel,
            size: sizeLabel,
            dimensions: raw['dimensions_label'] as String? ?? '',
            grade: gradeLabel,
            sellerCity: sellerCity,
            material: material,
            text: title,
            knownMetal: true)) {
          return false;
        }
      } else {
        if (!intent.matchesRow(
            category: cat,
            thickness: thicknessLabel,
            size: sizeLabel,
            dimensions: raw['dimensions_label'] as String? ?? '',
            grade: gradeLabel,
            sellerCity: sellerCity,
            material: material,
            search: raw['search'] as String? ?? '',
            brand: raw['brand'] as String? ?? '',
            loading: raw['loading'] as String? ?? '',
            loadingCity: raw['loading_city'] as String? ?? '',
            terms: raw['terms'] as String? ?? '',
            tax: raw['tax'] as String? ?? '')) {
          return false;
        }
      }
    }
    return true;
  }

  ({List<Map<String, Object?>> wires, int withheld, int undated, int unpriced})
      finish() => (
            wires: wires,
            withheld: undated + unpriced,
            undated: undated,
            unpriced: unpriced
          );
}

/// `MarketFilter._sameMeasure`, decided from the stored rendered label.
///
/// The label is the very value the classic filter compares (`q.thicknessLabel`,
/// `q.sizeLabel`), so a query that matched before matches now, and one that did
/// not still does not. A label that is empty can never satisfy a non-empty
/// filter, exactly as before.
bool _sameMeasure(
    String wanted, double? wantedValue, num? storedValue, String storedLabel) {
  // The stored number was derived from the same label, so this is the classic
  // comparison with the parsing already finished.
  if (wantedValue != null && storedValue != null) {
    return wantedValue == storedValue.toDouble();
  }
  return latin(wanted) == latin(storedLabel);
}

/// Catalogue search text of a row, prepared once per confirmation.
String catalogueSearch(Map<String, Object?> wire) =>
    wire['search'] as String? ?? specNorm('${wire['title']} ${wire['seller']}');
