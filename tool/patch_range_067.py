#!/usr/bin/env python3
"""Re-apply the 0.7.6 range/refresh fixes onto the published 0.7.5 base.

The workspace rolled back more than once during this work, losing uncommitted
edits. Every patch below is checked before it is written and skipped when it is
already present, so this script is safe to run again and again.

Run it after any rollback, then `flutter analyze` and the test suite.
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
applied, skipped = [], []


def patch(rel, old, new, name, count=1):
    path = ROOT / rel
    text = path.read_text(encoding='utf-8')
    if new in text:
        skipped.append(name)
        return
    if old not in text:
        print(f'FAILED (anchor not found): {name} in {rel}', file=sys.stderr)
        sys.exit(1)
    path.write_text(text.replace(old, new, count), encoding='utf-8')
    applied.append(name)


# ---------------------------------------------------------------- the engine --
# 1. A price basis written *after* the currency ("۱۲۵,۰۰۰ تومان کیلو") is a basis
#    the source stated. It used to be missed, so real quotes were stored with
#    unit='unknown' and then excluded from every statistic while still being shown
#    in the candidate list — the reported "candidate without a price".
patch('lib/domain/text_engine.dart', """  static String priceUnit(String text) {
    final s = latin(text);
    if (RegExp(r'کیلویی|کیلویی|تومانی?\\s*[/\\\\]\\s*کیلو|ریال\\s*[/\\\\]\\s*کیلو')
        .hasMatch(s)) return 'kg';
    final m = RegExp(
            r'(?:هر\\s+|[/\\\\]\\s*|مبنای\\s+|واحد\\s*[:：]?\\s*|به\\s*ازای\\s+)(کیلوگرم|کیلو|متر\\s*مربع|مترمربع|شاخه|عدد|برگ|رول|تن|متر)')
        .firstMatch(s);
    return m == null ? 'unknown' : parseUnit(m[1]!);
  }""", """  static String priceUnit(String text) {
    final s = latin(text);
    if (RegExp(r'کیلویی|تومانی?\\s*[/\\\\]\\s*کیلو|ریال\\s*[/\\\\]\\s*کیلو')
        .hasMatch(s)) return 'kg';
    // The basis is written either before the amount ("هر کیلو ۱۲۵,۰۰۰") or after
    // the currency ("۱۲۵,۰۰۰ تومان کیلو"). Both are the source stating a basis;
    // neither may be treated as a guess.
    final m = RegExp(
            r'(?:هر\\s+|[/\\\\]\\s*|مبنای\\s+|بر\\s*مبنای\\s+|بر\\s*اساس\\s+|واحد\\s*[:：]?\\s*|به\\s*ازای\\s+|قیمت\\s+)(کیلوگرم|کیلو|متر\\s*مربع|مترمربع|شاخه|عدد|برگ|رول|تن|متر)(?![\\p{L}])',
            unicode: true)
        .firstMatch(s) ??
        RegExp(
                r'(?:تومان|ریال)\\s*(?:[/|،,]\\s*)?(کیلوگرم|کیلو|شاخه|عدد|برگ|رول|تن|متر\\s*مربع|مترمربع|متر)(?![\\p{L}])',
                unicode: true)
            .firstMatch(s);
    return m == null ? 'unknown' : parseUnit(m[1]!);
  }""", 'engine: basis written after the currency')

# ------------------------------------------------------- both price paths -----
# 2. A row whose source named no unit is still comparable when a mass lets the
#    domain convert it. One helper decides the basis for both the Quote path and
#    the indexed-row path, so the two can never disagree.
patch('lib/domain/price_range.dart',
      """String rangeBasis(Quote q) => q.priceFor('kg') != null ? 'kg' : q.unit;""",
      """String rangeBasis(Quote q) => q.priceFor('kg') != null ? 'kg' : q.unit;

/// Units a price can be compared in.
const comparableUnits = ['kg', 'ton', 'sheet', 'piece', 'roll', 'm', 'm2'];

/// The basis a row is shown under when nothing at all identifies one.
///
/// A price with no unit word and no mass cannot be converted, so it may not enter
/// a statistical comparison. It stays visible in the announcements with this
/// label and a stated reason — no conversion, no average and no guess.
const unpricedBasis = 'نامشخص';

/// The basis a quote can be compared on when the source did not state one.
///
/// The trade quotes steel per kilogram and per branch, so a row whose unit is
/// unknown is still comparable *if* a mass lets the domain convert it. The order
/// is fixed — kilograms first, then a whole piece — so two different readings of
/// the same offer never both enter the statistics.
String? resolvedBasis(Quote q) {
  if (q.unit != 'unknown' && comparableUnits.contains(q.unit)) return q.unit;
  if (q.priceFor('kg') != null) return 'kg';
  if (q.priceFor('piece') != null) return 'piece';
  return null;
}

/// The same decision for one already-derived index row.
///
/// [prices] is the row's own conversion table, so nothing is parsed or re-read.
String? resolvedRowBasis(Map<String, Object?> prices, String unit) {
  if (unit != 'unknown' && comparableUnits.contains(unit)) return unit;
  if (prices['kg'] is num) return 'kg';
  if (prices['piece'] is num) return 'piece';
  return null;
}""", 'range: resolved-basis helper for both paths')

# The Quote-based calculation.
patch('lib/domain/price_range.dart',
      """  for (final q in announcements) {
    final basis = query.basis.isEmpty ? q.unit : query.basis;
    final price = toman(q.priceFor(basis), q.currency);
    if (!productFields.containsKey(query.family) ||
        !['kg', 'ton', 'sheet', 'piece', 'roll', 'm', 'm2'].contains(basis) ||
        price == null ||""",
      """  for (final q in announcements) {
    // A user-chosen unit wins; otherwise the row's own unit, and when the source
    // named none, the basis the domain can actually convert (kg, then piece).
    final basis = query.basis.isNotEmpty
        ? query.basis
        : (resolvedBasis(q) ?? unpricedBasis);
    final price = toman(q.priceFor(basis), q.currency);
    // A row whose basis cannot be identified is not a candidate for comparison:
    // it stays in the announcements, excluded, with a reason that says so.
    if (basis == unpricedBasis) {
      reject('واحد قیمت در منبع مشخص نیست؛ مبلغ دیده می‌شود ولی در میانگین نیست');
      continue;
    }
    if (!productFields.containsKey(query.family) ||
        !comparableUnits.contains(basis) ||
        price == null ||""", 'range: Quote path uses the resolved basis')

# ...and the range key must name the basis the row was really counted in.
patch('lib/domain/price_range.dart',
      """  final ranges = [
    for (final e in grouped.entries)
      PriceRange(e.key, query.basis.isEmpty ? e.value.first.unit : query.basis,
          e.value.first, e.value)
  ];""",
      """  final ranges = <PriceRange>[
    for (final e in grouped.entries)
      PriceRange(
          e.key,
          query.basis.isEmpty
              ? (resolvedBasis(e.value.first) ?? e.value.first.unit)
              : query.basis,
          e.value.first,
          e.value)
  ];""", 'range: range card names the counted basis')

# The index-based projection (the fast path the tab actually uses).
patch('lib/domain/range_projection.dart',
      """    final price = item.value.price;
    final unit = basis.isEmpty ? item.row.unit : basis;
    if (price == null ||""",
      """    // The same basis decision as `calculateProductRange`: a user-chosen unit,
    // then the row's own unit, then whatever the row's own conversion table
    // supports. Keeping the two paths identical is what makes the tab's numbers
    // match the domain's.
    final unit = basis.isNotEmpty
        ? basis
        : (resolvedRowBasis(item.row.prices, item.row.unit) ?? unpricedBasis);
    final price = unit == unpricedBasis
        ? null
        : (rows[index]['prices'] is Map
            ? ((rows[index]['prices'] as Map)[unit] as num?)?.toDouble()
            : item.value.price);
    if (unit == unpricedBasis) {
      const reason = 'واحد قیمت در منبع مشخص نیست؛ مبلغ دیده می‌شود ولی در میانگین نیست';
      excluded[reason] = (excluded[reason] ?? 0) + 1;
      continue;
    }
    if (price == null ||""", 'projection: index path uses the resolved basis')

# ------------------------------------------------------- candidates ----------
# 3. A row with no money amount is not a candidate at all. It used to be listed,
#    which is what showed a "candidate" the tab could not put a number on.
patch('lib/domain/range_projection.dart',
      """  final allCandidates = [for (var i = 0; i < rows.length; i++) i];""",
      """  // A row with no price is not a candidate at all: it produced an entry the tab
  // could not put a number on. Rows are only kept when they carry an amount; the
  // UI still counts and states how many were withheld.
  final allCandidates = [
    for (var i = 0; i < rows.length; i++)
      if (rows[i]['amount'] is num) i
  ];""", 'projection: unpriced rows are not candidates')

# ------------------------------------------------------- refresh -------------
# 4. `reload()` decodes the whole archive on a fresh isolate and rebuilds the
#    range index. Once per source is linear per call but quadratic per refresh.
patch('lib/data/controller.dart',
      """  Future<void> refresh() async {
    if (busy || transferring || disposed) return;""",
      """  DateTime? _publishedAt;
  bool _publishing = false;
  bool _indexStale = false;

  /// Publishes received prices without letting 82 sources each pay for a whole
  /// archive decode.
  ///
  /// `reload()` decodes every stored row on a fresh isolate and rebuilds the
  /// range index. Doing that once per source is linear per call but quadratic
  /// per refresh, which is what makes a long refresh crawl on a large archive.
  /// The work is coalesced: the first source publishes immediately, so the tab
  /// never waits for the slowest source, and later sources publish at most once
  /// per window. The final state is always published by `refresh()` itself.
  Future<void> _publishProgress({bool force = false}) async {
    if (_publishing) return;
    final now = DateTime.now();
    if (!force &&
        _publishedAt != null &&
        now.difference(_publishedAt!) < const Duration(milliseconds: 2500)) {
      return;
    }
    _publishing = true;
    try {
      _publishedAt = now;
      await reload();
    } finally {
      _publishing = false;
    }
  }

  Future<void> refresh() async {
    if (busy || transferring || disposed) return;""", 'refresh: coalesced publish')

patch('lib/data/controller.dart',
      """          // Fresh rows are derived at write time; drop the previous answers.
          rangeSession.invalidate();""",
      """          // Fresh rows are derived at write time; drop the previous answers.
          // The index itself is rebuilt by the coalesced publish, not per source.
          _indexStale = true;""", 'refresh: index rebuilt once, not per source')

patch('lib/data/controller.dart',
      """          await reload();
        } catch (error, stack) {""",
      """          await _publishProgress(force: finished == 0);
        } catch (error, stack) {""", 'refresh: publish through the coalescer')

patch('lib/data/controller.dart',
      """        finished++;
        states = await store.syncStates();
        _notify();""",
      """        finished++;
        // The publish above already refreshed `states`; a source that was
        // throttled still needs its own status shown.
        if (_publishing) _notify();""", 'refresh: no duplicate state read')

patch('lib/data/controller.dart',
      """      busy = false;
      await reload();""",
      """      busy = false;
      if (_indexStale) {
        rangeSession.invalidate();
        _indexStale = false;
      }
      await reload();""", 'refresh: always publish the final archive')

# Note: the shared-worker snapshot token is already per-session upstream
# (`dataToken => 's$_session.d$_epoch'`), so no patch is needed for it here.

# ------------------------------------------------------- the tab -------------
# 6. The candidate list already excludes unpriced rows upstream; it now also states
#    how many were withheld, so a shorter list is explained rather than silent.
patch('lib/ui/range_page.dart',
      """    final catalog = selection?.candidates
            .where((p) => p.searchText.contains(needle))
            .toList() ??
        <CatalogueItem>[];""",
      """    final catalog = selection?.candidates
            .where((p) => p.searchText.contains(needle))
            .toList() ??
        <CatalogueItem>[];
    // Rows this scope holds that carry no amount at all: not candidates, but
    // counted here so a shorter list is explained instead of silent.
    final unpriced = (selection?.catalog ?? <CatalogueItem>[])
        .where((p) => p.example.amount == null)
        .length;""",
      'ui: count the withheld unpriced rows')

patch('lib/ui/range_page.dart',
      """            subtitle: Text(catalog.length == catalogVisible
                ? 'فقط اعلام دارای تاریخ معتبر در بازه و قیمت قابل‌مقایسه؛ '
                    'ردیف‌های بی‌تاریخ یا بی‌قیمت اصلاً کاندید نیستند'
                : 'فقط تاریخ‌دار و قیمت‌دار؛ ${fmt(catalog.length)} مورد در این بازه'),""",
      """            subtitle: Text(faDigits(
                '${catalog.length == catalogVisible ? 'فقط اعلام دارای تاریخ معتبر در بازه و قیمت قابل‌مقایسه' : 'فقط تاریخ‌دار و قیمت‌دار؛ ${fmt(catalog.length)} مورد در این بازه'}'
                '${unpriced == 0 ? '' : ' • ${fmt(unpriced)} ردیف بی‌قیمت نمایش داده نمی‌شود'}')),""",
      'ui: state how many rows were withheld')

print('applied:', ', '.join(applied) if applied else 'nothing (already up to date)')
if skipped:
    print('already present:', ', '.join(skipped))
