import 'dart:convert';
import 'market.dart';
import 'money.dart';

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

String? exactProductKey(Quote q) {
  bool known(String s) =>
      s.trim().isNotEmpty &&
      !['نامشخص', 'نامعلوم', 'نامشخص/متفرقه'].contains(s.trim());
  if (!known(q.brand) ||
      !known(q.category) ||
      !known(q.material) ||
      q.specificationLabel.isEmpty) return null;
  if (q.category == 'ورق' &&
      (singleSpecNumber(q.thicknessLabel) == null ||
          q.dimensionsLabel.isEmpty)) {
    return null;
  }
  if (q.category == 'میلگرد' &&
      (singleSpecNumber(q.sizeLabel) == null ||
          q.gradeLabel.isEmpty ||
          RegExp(r'[,،/؛]|(?:\sتا\s)').hasMatch(q.gradeLabel))) {
    return null;
  }
  if (['پروفیل', 'لوله'].contains(q.category) &&
      (singleSpecNumber(q.thicknessLabel) == null ||
          (q.dimensionsLabel.isEmpty && q.sizeLabel.isEmpty))) return null;
  return jsonEncode([
    q.category,
    q.material,
    q.brand,
    q.title,
    q.sizeLabel,
    q.thicknessLabel,
    q.dimensionsLabel,
    q.gradeLabel,
    q.lengthM?.toString() ?? '',
    q.details['حالت'] ?? '',
    q.details['پوشش'] ?? '',
    q.details['رنگ'] ?? '',
    q.tax,
    q.terms
  ].map(_norm).toList());
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
    _norm(q.seller),
    rangeGroupKey(q),
    post ? '${uri.host}${uri.path}' : q.id,
    q.marketAt?.toUtc().toIso8601String(),
    if (!post) toman(q.priceFor(rangeBasis(q)), q.currency)
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
  RangeProduct(this.key, this.example, this.range, this.unavailableReasons);
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
  late final String searchText = latin(label).toLowerCase();
}

String catalogueKey(Quote q) =>
    rangeGroupKey(q) ??
    jsonEncode(['isolated-offer', q.endpoint, q.id, rangeBasis(q)]);

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
    reasons.add(
        'برند یا مشخصات دقیق کافی نیست؛ با کالای فروشنده دیگر ادغام نمی‌شود');
  }
  return reasons;
}

class RangeReport {
  final List<PriceRange> ranges;
  final Map<String, int> excluded;
  final DateTime at;
  final List<RangeProduct> products;
  const RangeReport(this.ranges, this.excluded, this.at,
      {this.products = const []});
}

/// All real announcements, not one vote per seller. Fetch/metadata changes
/// never add weight. Only dated, comparable, explicit currencies enter money.
RangeReport calculateRanges(Iterable<Quote> quotes, DateTime now) {
  final unique = <String, Quote>{};
  final catalogue = <String, Quote>{};
  final excluded = <String, int>{};
  final since = now.toUtc().subtract(const Duration(hours: 48));
  void reject(String why) =>
      excluded.update(why, (n) => n + 1, ifAbsent: () => 1);
  for (final q in quotes) {
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
      reject('مشخصات دقیق یا برند کافی نیست');
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
    final range = byKey[entry.key];
    return RangeProduct(entry.key, range?.example ?? entry.value, range,
        range == null ? rangeUnavailableReasons(entry.value, now) : const []);
  }).toList()
    ..sort((a, b) => a.label.compareTo(b.label));
  for (final product in products) {
    product.searchText;
  }
  return RangeReport(result, excluded, now.toUtc(), products: products);
}
