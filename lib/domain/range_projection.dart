import 'dart:convert';

import 'market.dart';
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

/// The index rows of one snapshot, expanded once: every row's facts and its
/// comparable wire form. A new question (other product, city or unit) then only
/// filters this list instead of re-expanding 17 000 rows.
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

/// The answer of a confirmed scope, computed from indexed rows only.
///
/// Membership is decided exactly as `calculateProductRange` decides it (same
/// family test, same `ProductFacts.matches`, same 48-hour window, same one entry
/// per announcement, newest receipt wins), then each unit is a pure projection of
/// that set. No payload is parsed and no `Quote` is built here.
({List<Map<String, Object?>> rows, List<Map<String, Object?>> ranges,
  Map<String, int> excluded, int kept, List<Map<String, Object?>> catalog})
    project(
  List<Map<String, Object?>> indexRows, {
  required String family,
  required Map<String, String> fields,
  required String basis,
  required String city,
  required int nowMs,
}) =>
    projectPrepared(prepare(indexRows),
        family: family,
        fields: fields,
        basis: basis,
        city: city,
        nowMs: nowMs);

/// Same answer as [project], over an index that is already expanded.
({List<Map<String, Object?>> rows, List<Map<String, Object?>> ranges,
  Map<String, int> excluded, int kept, List<Map<String, Object?>> catalog})
    projectPrepared(
  PreparedIndex index, {
  required String family,
  required Map<String, String> fields,
  required String basis,
  required String city,
  required int nowMs,
}) {
  const window = 48 * 3600 * 1000;
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
  final rows = <Map<String, Object?>>[];
  final grouped = <String, List<int>>{};
  final groupBasis = <String, String>{};
  final excluded = <String, int>{};
  for (final item in kept) {
    final index = rows.length;
    rows.add({...item.value.wire, 'source': item.value.source});
    final price = item.value.price;
    final unit = basis.isEmpty ? item.row.unit : basis;
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
  return (
    rows: rows,
    ranges: ranges,
    excluded: excluded,
    kept: kept.length,
    catalog: [for (final item in catalogRows) item.row.toWire()]
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
  CatalogueItem(this.key, this.wire, this.at);

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
  final int inputRows;
  final int keptRows;
  final DateTime at;
  final bool fromMemory;
  const RangeAnswer(this.result, this.catalog, this.inputRows, this.keptRows,
      this.at, {this.fromMemory = false});

  RangeAnswer asMemory() =>
      RangeAnswer(result, catalog, inputRows, keptRows, at, fromMemory: true);
}

/// The UI-facing answer of a projection, built once inside the worker isolate.
RangeAnswer buildAnswer(
  ({List<Map<String, Object?>> rows, List<Map<String, Object?>> ranges,
          Map<String, int> excluded, int kept,
          List<Map<String, Object?>> catalog}) projected,
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
  // Catalogue: every stored row of this scope, with the real reason it is not in
  // the statistics instead of an invented number.
  final catalogues = <CatalogueItem>[];
  for (var i = 0; i < projected.catalog.length; i++) {
    final wire = projected.catalog[i];
    catalogues.add(CatalogueItem(
        '${wire['endpoint']}:${wire['id']}:$i', wire, at));
  }
  return RangeAnswer(
      ProductRangeResult(quotes, ranges, projected.excluded, at),
      catalogues,
      inputRows,
      projected.kept,
      at);
}

/// Catalogue search text of a row, prepared once per confirmation.
String catalogueSearch(Map<String, Object?> wire) =>
    wire['search'] as String? ?? specNorm('${wire['title']} ${wire['seller']}');
