import 'city_scope.dart';
import 'dart:convert';
import 'market.dart';
import 'money.dart';
import 'product_schema.dart';

String _norm(String s) => latin(s)
    .toLowerCase()
    .trim()
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll('×', 'x');

/// Conservative identity: different titles or missing brands are not guessed
/// to denote the same product. Office/loading city does not restrict sellers.
double? singleSpecNumber(String value) {
  final text = latin(value).trim().replaceAll('٫', '.');
  if (!RegExp(r'^\d+(?:\.\d+)?$').hasMatch(text)) return null;
  final n = double.tryParse(text);
  return n != null && n.isFinite && n > 0 ? n : null;
}

/// Technical grouping only. Origin, brand, title, tax and seller do not gate it.
String? exactProductKey(Quote q) {
  final f = ProductFacts.of(q);
  if (!productFields.containsKey(f.family)) return null;
  // Proprietary anchors and bare rods are not interchangeable by diameter alone.
  if (f.family == 'بولت' &&
      [
        'kind',
        'size',
        'length',
        'threadLength',
        'pitch',
        'grade',
        'material',
        'coating',
        'accessories',
        'dimUnit'
      ].any((key) => (f.values[key] ?? '').isEmpty)) return null;
  if (f.family == 'بولت' &&
      RegExp('مکانیکی|شیمیایی').hasMatch(f.values['kind'] ?? '') &&
      ['model', 'embedment'].any((key) => (f.values[key] ?? '').isEmpty)) {
    return null;
  }
  return jsonEncode([
    f.family,
    for (final key in productFields[f.family]!.keys)
      if (key != 'mass') [key, specNorm(f.values[key] ?? '')]
  ]);
}

String rangeBasis(Quote q) => q.priceFor('kg') != null ? 'kg' : q.unit;

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
}
String? rangeGroupKey(Quote q) {
  final product = exactProductKey(q);
  return product == null ? null : jsonEncode([product, rangeBasis(q)]);
}

String announcementKey(Quote q) {
  final uri = Uri.tryParse(q.sourceUrl);
  final post =
      uri != null && RegExp(r'/[A-Za-z0-9_]+/\d+/?$').hasMatch(uri.path);
  // Edited versions of one public message are ONE announcement; newest wins.
  // Day-only tables have no separate publication identifier: identical rates
  // for the same row/date cannot safely be asserted to be distinct events.
  return jsonEncode([
    q.endpoint,
    q.id,
    _norm(q.seller),
    rangeGroupKey(q),
    post ? '${uri.host}${uri.path}' : q.id,
    q.marketAt?.toUtc().toIso8601String(),
    if (!post)
      toman(q.priceFor(rangeBasis(q)), q.currency) ??
          jsonEncode(
              [q.amount, q.currency, q.unit, q.details['مبلغ استخراج‌شده']])
  ]);
}

class PriceRange {
  final String key, basis;
  final Quote example;
  final List<Quote> announcements;
  final double minimum, maximum, mean;
  final int roundedMean, sellers;
  PriceRange(this.key, this.basis, this.example, this.announcements)
      : minimum = announcements
            .map((q) => toman(q.priceFor(basis), q.currency)!)
            .reduce((a, b) => a < b ? a : b),
        maximum = announcements
            .map((q) => toman(q.priceFor(basis), q.currency)!)
            .reduce((a, b) => a > b ? a : b),
        mean = announcements.fold<double>(
                0, (sum, q) => sum + toman(q.priceFor(basis), q.currency)!) /
            announcements.length,
        roundedMean = (announcements.fold<double>(0,
                    (sum, q) => sum + toman(q.priceFor(basis), q.currency)!) /
                announcements.length)
            .round(),
        sellers = announcements.map((q) => _norm(q.seller)).toSet().length;
  PriceRange.computed(this.key, this.basis, this.example, this.announcements,
      {required this.minimum,
      required this.maximum,
      required this.mean,
      required this.roundedMean,
      required this.sellers});
  double rate(String choice) => switch (choice) {
        'min' => minimum,
        'max' => maximum,
        _ => roundedMean.toDouble()
      };
  String get label => '${example.title} • ${example.brand} • '
      '${example.specificationLabel} • هر ${example.unitName(basis)}'
      ' • مالیات: ${example.tax} • شرایط: ${example.terms}';
}

/// Selection is the complete local catalogue, not only statistically usable rows.
/// Incomplete products stay isolated by offer ID; unknown specifications are
/// never guessed or pooled across sellers just to populate a numeric range.
class RangeProduct {
  final String key;
  final Quote example;
  final PriceRange? range;
  final List<String> unavailableReasons;
  final String? preparedSearch;
  RangeProduct(this.key, this.example, this.range, this.unavailableReasons,
      {this.preparedSearch});
  late final String label = range?.label ??
      [
        example.title.isEmpty ? 'کالای بدون عنوان' : example.title,
        example.category,
        example.brand.isEmpty ? 'برند نامشخص' : example.brand,
        example.specificationLabel.isEmpty
            ? 'مشخصات تکمیل نشده'
            : example.specificationLabel,
        'هر ${example.unitName(rangeBasis(example))}',
        example.seller,
        'مالیات: ${example.tax}',
        'شرایط: ${example.terms}'
      ].where((s) => s.isNotEmpty).join(' • ');
  late final String searchText = preparedSearch ?? latin(label).toLowerCase();

  /// True when this entry carries a money amount the tab can display.
  ///
  /// A row with no amount is not offered as a candidate: it only produced an
  /// entry with nothing to compare. It is counted as withheld by the UI, so the
  /// number of hidden rows is stated instead of the rows being shown.
  bool get priced =>
      example.amount != null && example.amount!.isFinite && example.amount! > 0;
}

String catalogueKey(Quote q) =>
    jsonEncode([q.endpoint, q.id, rangeGroupKey(q)]);

List<String> rangeUnavailableReasons(Quote q, DateTime now,
    {Duration window = const Duration(hours: 48)}) {
  final reasons = <String>[];
  final date = q.marketAt;
  if (date == null) {
    reasons.add('تاریخ نرخ/انتشار نامعلوم یا نامعتبر');
  } else if (date.isBefore(now.toUtc().subtract(window)) ||
      date.isAfter(now.toUtc())) {
    reasons.add('داخل بازه زمانی انتخاب‌شده اعلام معتبر ندارد');
  }
  if (q.amount == null || !q.amount!.isFinite || q.amount! <= 0) {
    reasons.add('مبلغ عددی معتبر ثبت نشده است');
  }
  if (toman(q.amount, q.currency) == null) reasons.add('ارز نرخ نامعلوم است');
  if (q.priceFor(rangeBasis(q)) == null) {
    reasons.add('واحد قیمت نامعلوم یا تبدیل معتبر موجود نیست');
  }
  if ((toman(q.priceFor(rangeBasis(q)), q.currency) ?? 0) > 9000000000000000) {
    reasons.add('مبلغ خارج از محدوده محاسبه است');
  }
  if (exactProductKey(q) == null) {
    reasons.add(ProductFacts.of(q).family == 'بولت'
        ? 'مشخصات تخصصی بولت برای مقایسه کامل نیست؛ نوع، ابعاد، رزوه، جنس، گرید، پوشش و شمول ست لازم است'
        : 'نوع محصول تشخیص داده نشده است؛ نیازمند بررسی مشخصات');
  }
  return reasons;
}

class RangeReport {
  final List<PriceRange> ranges;
  final Map<String, int> excluded;
  final DateTime at;
  final List<RangeProduct> products;
  final List<Quote> quotes;
  const RangeReport(this.ranges, this.excluded, this.at,
      {this.products = const [], this.quotes = const []});
}

/// All real announcements, not one vote per seller. Fetch/metadata changes
/// never add weight. Only dated, comparable, explicit currencies enter money.
RangeReport calculateRanges(Iterable<Quote> quotes, DateTime now) {
  final all = quotes.toList();
  final unique = <String, Quote>{};
  final catalogue = <String, Quote>{};
  final excluded = <String, int>{};
  final since = now.toUtc().subtract(const Duration(hours: 48));
  void reject(String why) =>
      excluded.update(why, (n) => n + 1, ifAbsent: () => 1);
  for (final q in all) {
    final productKey = catalogueKey(q);
    final previous = catalogue[productKey];
    if (previous == null || !q.fetchedAt.isBefore(previous.fetchedAt)) {
      catalogue[productKey] = q;
    }
    final date = q.marketAt;
    if (date == null) {
      reject('تاریخ نرخ/انتشار نامعلوم یا نامعتبر');
      continue;
    }
    if (date.isBefore(since) || date.isAfter(now.toUtc())) {
      reject('خارج از ۴۸ ساعت گذشته');
      continue;
    }
    if (toman(q.priceFor(rangeBasis(q)), q.currency) == null ||
        (q.amount ?? 0) <= 0 ||
        (toman(q.priceFor(rangeBasis(q)), q.currency) ?? 0) >
            9000000000000000) {
      reject('مبلغ، ارز یا واحد نامعتبر/نامعلوم');
      continue;
    }
    if (exactProductKey(q) == null) {
      reject('نوع محصول تشخیص داده نشده است');
      continue;
    }
    final key = announcementKey(q);
    final old = unique[key];
    if (old == null || !q.fetchedAt.isBefore(old.fetchedAt)) unique[key] = q;
  }
  final grouped = <String, List<Quote>>{};
  for (final q in unique.values) {
    (grouped[rangeGroupKey(q)!] ??= []).add(q);
  }
  final result = grouped.entries.map((e) {
    e.value.sort((a, b) => b.marketAt!.compareTo(a.marketAt!));
    return PriceRange(e.key, rangeBasis(e.value.first), e.value.first, e.value);
  }).toList()
    ..sort((a, b) => a.label.compareTo(b.label));
  final byKey = {for (final range in result) range.key: range};
  final products = catalogue.entries.map((entry) {
    final range = byKey[rangeGroupKey(entry.value)];
    return RangeProduct(entry.key, entry.value, range,
        range == null ? rangeUnavailableReasons(entry.value, now) : const []);
  }).toList()
    ..sort((a, b) => a.label.compareTo(b.label));
  for (final product in products) {
    product.searchText;
  }
  return RangeReport(result, excluded, now.toUtc(),
      products: products, quotes: all);
}

/// The user-selected family/fields define the scope, never an example offer.
class ProductRangeQuery {
  final String family, basis, city;
  final Map<String, String> fields;
  const ProductRangeQuery(this.family,
      {this.fields = const {}, this.basis = '', this.city = ''});
}

class ProductRangeResult {
  final List<Quote> announcements;
  final List<PriceRange> ranges;
  final Map<String, int> excluded;
  final DateTime at;
  const ProductRangeResult(
      this.announcements, this.ranges, this.excluded, this.at);
}

ProductRangeResult calculateProductRange(Map<String, Object> input) {
  final query = input['query'] as ProductRangeQuery,
      now = input['now'] as DateTime;
  // The window is the user's own selection (the capture window by default);
  // 48 hours stays the default for callers that do not choose one.
  final window = Duration(
      milliseconds: input['windowMs'] as int? ?? 48 * 3600 * 1000);
  final quotes = input['quotes'] as List<Quote>;
  final unique = <String, Quote>{}, excluded = <String, int>{};
  void reject(String reason) =>
      excluded.update(reason, (n) => n + 1, ifAbsent: () => 1);
  for (final q in quotes) {
    if (!cityMatches(q, query.city)) continue;
    final facts = ProductFacts.of(q);
    if ((facts.family.isEmpty ? 'سایر' : facts.family) != query.family ||
        !facts.matches(query.fields)) continue;
    if (q.marketAt == null) {
      reject('تاریخ اعلام نامعلوم');
      continue;
    }
    if (q.marketAt!.isAfter(now) || q.marketAt!.isBefore(now.subtract(window))) {
      reject('خارج از بازه زمانی انتخاب‌شده');
      continue;
    }
    final key = announcementKey(q), old = unique[key];
    if (old == null || !q.fetchedAt.isBefore(old.fetchedAt)) unique[key] = q;
  }
  final announcements = unique.values.toList()
    ..sort((a, b) => b.marketAt!.compareTo(a.marketAt!));
  final grouped = <String, List<Quote>>{};
  for (final q in announcements) {
    // A user-chosen unit wins; otherwise the row's own unit, then the unit its
    // own declared mass/length converts to, and finally the explicit «نامشخص»
    // group, which is compared only with itself.
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
        price == null ||
        !price.isFinite ||
        price <= 0 ||
        price > 9000000000000000) {
      reject('نمایش در اعلام‌ها؛ مبلغ/ارز/واحد یا تبدیل معتبر برای آمار ندارد');
      continue;
    }
    final technicalKey = exactProductKey(q);
    if (query.family == 'بولت' && technicalKey == null) {
      reject(
          'بولت با مشخصات ناقص؛ نوع، ابعاد، رزوه، گرید، پوشش و شمول ست برای مقایسه لازم است');
      continue;
    }
    final grouping =
        query.family == 'بولت' ? jsonEncode([basis, technicalKey]) : basis;
    (grouped[grouping] ??= []).add(q);
  }
  final ranges = <PriceRange>[
    for (final e in grouped.entries)
      PriceRange(
          e.key,
          query.basis.isEmpty
              ? (resolvedBasis(e.value.first) ?? e.value.first.unit)
              : query.basis,
          e.value.first,
          e.value)
  ];
  return ProductRangeResult(announcements, ranges, excluded, now);
}
