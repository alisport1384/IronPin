import 'dart:convert';

import 'market.dart';
import 'money.dart';
import 'price_range.dart';
import 'product_schema.dart';
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
/// The index rows of one snapshot, expanded once: every row's facts and its
/// comparable wire form. A new question (other product, city or unit) then only
/// filters this list instead of re-expanding every row.
class PreparedIndex {
  final List<RowFacts> facts;
  final List<Map<String, Object?>> wires;
  PreparedIndex(this.facts, this.wires);
  int get length => facts.length;
}

PreparedIndex prepare(List<Map<String, Object?>> indexRows) {
  final facts = <RowFacts>[];
  final wires = <Map<String, Object?>>[];
  for (final raw in indexRows) {
    final row = RowFacts.fromRow(raw);
    facts.add(row);
    wires.add(row.toWire());
  }
  return PreparedIndex(facts, wires);
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
}) =>
    projectPrepared(prepare(indexRows),
        family: family,
        fields: fields,
        basis: basis,
        city: city,
        nowMs: nowMs,
        windowMs: windowMs);

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
  final facts = index.facts, wires = index.wires;
  for (var source = 0; source < facts.length; source++) {
    final row = facts[source];
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
    final value =
        RangeRow.of(row, source: source, basis: basis, wire: wires[source]);
    final previous = unique[value.key];
    if (previous == null || previous.row.fetchedAt <= row.fetchedAt) {
      unique[value.key] = (row: row, value: value);
    }
  }
  final kept = unique.values.toList()
    ..sort((a, b) => (b.row.marketAt ?? 0).compareTo(a.row.marketAt ?? 0));
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
    if (family == 'بولت' && item.row.productKey == null) {
      const reason =
          'بولت با مشخصات ناقص؛ نوع، ابعاد، رزوه، گرید، پوشش و شمول ست برای مقایسه لازم است';
      excluded[reason] = (excluded[reason] ?? 0) + 1;
      continue;
    }
    final group = family == 'بولت'
        ? jsonEncode([unit, item.row.productKey])
        : unit;
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
  // could not put a number on. Rows are only kept when they carry an amount; the
  // UI still counts and states how many were withheld.
  final allCandidates = [
    for (var i = 0; i < rows.length; i++)
      if (rows[i]['amount'] is num) i
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
  CatalogueItem(this.key, this.wire, this.at, {this.counted = true});

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
  // Which announcements can be counted, by identity of the rendered row.
  final counted = <String>{};
  for (final i in projected.announceIndices) {
    final wire = wires[i];
    counted.add('${wire['endpoint']}\u0001${wire['id']}');
  }
  final candidates = <CatalogueItem>[];
  for (var i = 0; i < projected.candidates.length; i++) {
    final wire = projected.candidates[i];
    // Offarable means: inside the window and with a comparable price. A real
    // announcement that has no number stays in the answer's counts, not here.
    final key = '${wire['endpoint']}\u0001${wire['id']}';
    if (counted.contains(key) || _hasComparablePrice(wire, basis)) {
      candidates.add(
          CatalogueItem('${wire['endpoint']}:${wire['id']}:$i', wire, at,
              counted: counted.contains(key)));
    }
  }
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
  return RangeAnswer(
      ProductRangeResult(quotes, ranges, projected.excluded, at),
      candidates,
      inputRows,
      projected.kept,
      at,
      candidates: candidates);
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
  final since = nowMs - scope.maxAgeDays * 24 * 3600 * 1000;
  final future = nowMs + 5 * 60 * 1000;
  final basis = scope.basis;
  final needle = specNorm(scope.query);
  // Search words of the classic query, split and normalised once: the row is
  // tested per word, never re-split per row.
  final words = needle.isEmpty
      ? const <String>[]
      : needle.split(RegExp(r'[^آ-یa-z0-9.]+')).where((w) => w.isNotEmpty).toList();
  final digits = words.where((w) => RegExp(r'^\d+(?:\.\d+)?$').hasMatch(w));
  final digitRe = digits.isEmpty
      ? null
      : RegExp('(?<![\\d.])(?:${digits.map(RegExp.escape).join('|')})(?![\\d.])');
  final textWords = words.where((w) => !RegExp(r'^\d+(?:\.\d+)?$').hasMatch(w));
  final grade = latin(scope.grade).toUpperCase();
  final sizeWanted = number(scope.size);
  final thicknessWanted = number(scope.thickness);
  final cityBoundary = scope.city.isEmpty || scope.cityKind != 'all'
      ? null
      : RowFacts.cityBoundaryOf(scope.city);
  final wires = <Map<String, Object?>>[];
  // Reasons are counted, never invented: a row is withheld here only because it
  // is outside the window (or has no real announcement date) or has no
  // comparable price, and the two counts say how many.
  var undated = 0, unpriced = 0;
  // One entry per stored offer, however many rows it has: the archive keeps a
  // latest row and one history row per receipt, and a card per receipt would show
  // the same seller's same offer twice. The newest receipt speaks for the offer,
  // and a withheld offer is counted once, never once per row.
  final slot = <String, int>{};
  final held = <String, int>{};
  for (final raw in indexRows) {
    final identity = '${raw['endpoint']}\u0001${raw['id']}';
    final seen = slot[identity];
    if (seen == null && !held.containsKey(identity)) {
      // First sighting of this offer: decide it below.
    } else if (seen != null) {
      // Already a candidate: keep the newest receipt of it. Two receipts of the
      // same second are not "newer", but the archive's own current row is the
      // last word — and the query returns it last, so a tie hands it the card.
      if (((raw['fetched_at'] as int?) ?? 0) >=
          ((wires[seen]['fetched_at'] as int?) ?? 0)) {
        wires[seen] = raw;
      }
      continue;
    } else {
      // Already withheld: a second row of the same offer is not a second reason.
      continue;
    }
    final marketAt = raw['market_at'] as int?;
    // The window is the user's own filter, so a row outside it is not a
    // candidate at all — and it is reported as such, not as "undated".
    if (marketAt == null || marketAt > future || marketAt < since) {
      undated++;
      held[identity] = 1;
      continue;
    }
    final unit = raw['unit'] as String? ?? '';
    final currency = raw['currency'] as String? ?? '';
    final prices = unpackPrices(raw['prices'] as String? ?? '');
    // The comparable price of the requested basis, in toman, computed exactly as
    // the money helpers do. With no explicit basis the row's own basis is used:
    // its unit, or the unit its own declared mass converts to. A row whose source
    // stated no unit still carries a real amount, and it is shown with that
    // amount — a row is never dropped from the list for lacking a basis; the
    // reason it cannot be averaged is stated on the card instead.
    final basisKey = basis == 'original' || basis.isEmpty
        ? (resolvedRowBasis(prices, unit) ?? '')
        : basis;
    final price = toman(prices[basisKey], currency) ??
        (basisKey.isEmpty
            ? toman((raw['amount'] as num?)?.toDouble(), currency)
            : null);
    final comparable = price != null && price.isFinite && price > 0;
    if (!comparable) {
      // `MarketFilter.matches` keeps a row that has no comparable price when the
      // row still carries the amount its source wrote (`hasTextAmount`), or when
      // the user turned on «نمایش اعلام‌های بدون قیمت معتبر». This path dropped
      // both, so the prices tab listed fewer offers than the filter it mirrors:
      // a range offer («۴۱,۰۰۰ تا ۴۳,۰۰۰») or an amount whose currency the
      // source never stated disappeared instead of being shown with its text.
      final hasTextAmount = (raw['amount_raw'] as String? ?? '').isNotEmpty;
      if (!scope.includeUnpriced && !hasTextAmount) {
        unpriced++;
        held[identity] = 1;
        continue;
      }
      // A bound is a bound on a comparable number; a row without one can never
      // satisfy it, exactly as the classic filter decides.
      if (scope.minPrice != null || scope.maxPrice != null) continue;
    } else if ((scope.minPrice != null && price < scope.minPrice!) ||
        (scope.maxPrice != null && price > scope.maxPrice!)) {
      // A price filter is a filter on the same comparable number.
      continue;
    }
    if (scope.category.isNotEmpty && raw['category'] != scope.category) {
      continue;
    }
    if (scope.material.isNotEmpty && raw['material'] != scope.material) {
      continue;
    }
    if (scope.unit.isNotEmpty && unit != scope.unit) continue;
    // Size, thickness and grade were compared on the rendered labels by the
    // classic filter; the labels are stored with the row, so the same comparison
    // is one text test here. A label that is empty never satisfies a filter.
    if ((scope.size.isNotEmpty &&
            !_sameMeasure(scope.size, sizeWanted,
                raw['size_num'] as num?, raw['size_label'] as String? ?? '')) ||
        (scope.thickness.isNotEmpty &&
            !_sameMeasure(scope.thickness, thicknessWanted,
                raw['thickness_num'] as num?,
                raw['thickness_label'] as String? ?? '')) ||
        (grade.isNotEmpty &&
            raw['grade_label'] != null &&
            latin(raw['grade_label'] as String).toUpperCase() != grade)) {
      continue;
    }
    if (scope.city.isNotEmpty &&
        (scope.cityKind == 'all'
            ? !(cityBoundary?.hasMatch(raw['haystack'] as String? ?? '') ?? true)
            : (raw['seller_city'] as String? ?? '') != scope.city)) {
      continue;
    }
    if (scope.onlyFresh && !_fresh(raw, nowMs)) continue;
    if (digitRe != null &&
        !digitRe.hasMatch(raw['search'] as String? ?? '')) {
      continue;
    }
    if (textWords.isNotEmpty &&
        !_containsEvery(raw['search'] as String? ?? '', textWords)) {
      continue;
    }
    // Nothing is materialised here: the passing index rows themselves go to the
    // list, which copies the columns it draws as it renders them.
    slot[identity] = wires.length;
    wires.add(raw);
  }
  return (wires: wires, withheld: undated + unpriced, undated: undated, unpriced: unpriced);
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

/// The 30-hour freshness rule of `Quote.isFresh`, from the stored date only.
bool _fresh(Map<String, Object?> raw, int nowMs) {
  final at = raw['market_at'] as int?;
  if (at == null) return false;
  final age = nowMs - at;
  return age >= -5 * 60 * 1000 && age <= 30 * 3600 * 1000;
}

/// Every search word present in the stored search text; the text was normalised
/// with the same `specNorm` the classic query normalises with.
bool _containsEvery(String text, Iterable<String> words) {
  for (final word in words) {
    if (!text.contains(word)) return false;
  }
  return true;
}


/// The comparable price of a rendered row, checked the way the money helpers do.
bool _hasComparablePrice(Map<String, Object?> wire, String basis) {
  final prices = wire['prices'];
  final unit = wire['unit'] as String? ?? '';
  final key = basis == 'original' || basis.isEmpty ? unit : basis;
  // The row's own amount is a real price even when no per-unit conversion was
  // written: without this fallback such a row was dropped from the candidates
  // although the archive holds a number for it.
  final raw = prices is Map && prices[key] != null
      ? prices[key]
      : wire['amount'];
  final price = toman(raw is num ? raw.toDouble() : null,
      wire['currency'] as String? ?? '');
  return price != null && price.isFinite && price > 0;
}

/// Catalogue search text of a row, prepared once per confirmation.
String catalogueSearch(Map<String, Object?> wire) =>
    wire['search'] as String? ?? specNorm('${wire['title']} ${wire['seller']}');
