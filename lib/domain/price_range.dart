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
  return jsonEncode([
    f.family,
    for (final key in productFields[f.family]!.keys)
      if (key != 'mass') [key, specNorm(f.values[key] ?? '')]
  ]);
}

String rangeBasis(Quote q) => q.priceFor('kg') != null ? 'kg' : q.unit;
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
}

String catalogueKey(Quote q) =>
    jsonEncode([q.endpoint, q.id, rangeGroupKey(q)]);

List<String> rangeUnavailableReasons(Quote q, DateTime now) {
  final reasons = <String>[];
  final date = q.marketAt;
  if (date == null) {
    reasons.add('تاریخ نرخ/انتشار نامعلوم یا نامعتبر');
  } else if (date.isBefore(now.toUtc().subtract(const Duration(hours: 48))) ||
      date.isAfter(now.toUtc())) {
    reasons.add('در ۴۸ ساعت گذشته اعلام معتبر ندارد');
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
    reasons.add('نوع محصول تشخیص داده نشده است؛ نیازمند بررسی مشخصات');
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
    if (q.marketAt!.isAfter(now) ||
        q.marketAt!.isBefore(now.subtract(const Duration(hours: 48)))) {
      reject('خارج از ۴۸ ساعت');
      continue;
    }
    final key = announcementKey(q), old = unique[key];
    if (old == null || !q.fetchedAt.isBefore(old.fetchedAt)) unique[key] = q;
  }
  final announcements = unique.values.toList()
    ..sort((a, b) => b.marketAt!.compareTo(a.marketAt!));
  final grouped = <String, List<Quote>>{};
  for (final q in announcements) {
    final basis = query.basis.isEmpty ? q.unit : query.basis;
    final price = toman(q.priceFor(basis), q.currency);
    if (!productFields.containsKey(query.family) ||
        !['kg', 'ton', 'sheet', 'piece', 'roll', 'm', 'm2'].contains(basis) ||
        price == null ||
        !price.isFinite ||
        price <= 0 ||
        price > 9000000000000000) {
      reject('نمایش در اعلام‌ها؛ مبلغ/ارز/واحد یا تبدیل معتبر برای آمار ندارد');
      continue;
    }
    (grouped[basis] ??= []).add(q);
  }
  final ranges = [
    for (final e in grouped.entries)
      PriceRange(e.key, e.key, e.value.first, e.value)
  ];
  return ProductRangeResult(announcements, ranges, excluded, now);
}
