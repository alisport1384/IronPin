/// Shared, offline product vocabulary for ingestion and semantic search.
/// No currency, physical weight, publication time or missing unit is inferred.
class ProductText {
  static String normalize(String value) {
    const digits = '۰۱۲۳۴۵۶۷۸۹٠١٢٣٤٥٦٧٨٩';
    var s = value;
    for (var i = 0; i < digits.length; i++) {
      s = s.replaceAll(digits[i], '${i % 10}');
    }
    return s
        .replaceAll('ي', 'ی')
        .replaceAll('ك', 'ک')
        .replaceAll('\u200c', ' ')
        .replaceAll('_', ' ')
        .replaceAll('٫', '.')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static final product = RegExp(
      r'انکر\s*بولت|انکربولت|رول\s*بولت|بولت|\banchor\s+bolt\b|میلگرد(?:\s+بستر)?|تیر\s*آهن|تیراهن|هاش|ناودانی|نبشی|پروفیل|قوطی|لوله|ورق|پلیت|صفحه\s+(?:فولادی|آهنی|فلزی)|شیت|\b(?:plate|sheet)\b|چهارپهلو|مفتول|تسمه|سپری|رابیتس|توری|مش\s+جوشی|شمش|قراضه',
      caseSensitive: false);
  static String category(String text) {
    final s = product.firstMatch(normalize(text))?[0] ?? '';
    if (s.contains('تیر') || s == 'هاش') return 'تیرآهن';
    if (RegExp(r'پلیت|صفحه|شیت|plate|sheet', caseSensitive: false)
        .hasMatch(s)) {
      return 'ورق';
    }
    if (RegExp(r'بولت|anchor', caseSensitive: false).hasMatch(s)) return 'بولت';
    if (s == 'قوطی') return 'پروفیل';
    return s;
  }

  static const n = r'\d+(?:\.\d+)?';
  static const measure =
      r'\d+(?:\.\d+)?(?:\s*(?:و|،|,|تا|الی|-|/)\s*\d+(?:\.\d+)?)*';
  static final dimension =
      RegExp('$n\\s*[x×*]\\s*$n(?:\\s*[x×*]\\s*$n)?', caseSensitive: false);
  static final gauge = RegExp(
      r'\b(?:A[1-4]|ST\s*(?:14|37|44|52)|IPE|IPN|INP|HEA|HEB|HEM|UPN|UPE|UNP|A516|A283|CK45|MO40|304L?|316L?|430|3SP|5SP|S(?:235|275|355|420|460)(?:JR|J0|J2|K2)?H?)\b',
      caseSensitive: false);
  static String numeric(String value) =>
      double.tryParse(normalize(value))?.toString() ?? normalize(value);
  static bool same(String a, String b) =>
      a.isNotEmpty && b.isNotEmpty && numeric(a) == numeric(b);
  static bool measureMatches(String wanted, String actual) {
    if (same(wanted, actual)) return true;
    final a = normalize(actual), w = double.tryParse(normalize(wanted));
    if (w == null) return normalize(wanted) == a;
    final range = RegExp('^($n)\\s*(?:تا|الی|[-–])\\s*($n)\$').firstMatch(a);
    if (range != null) {
      final first = double.parse(range[1]!), last = double.parse(range[2]!);
      return w >= (first < last ? first : last) &&
          w <= (first > last ? first : last);
    }
    if (RegExp('^$n(?:\\s*(?:و|،|,)\\s*$n)+\$').hasMatch(a)) {
      return a
          .split(RegExp(r'\s*(?:و|،|,)\s*'))
          .any((x) => double.tryParse(x) == w);
    }
    return false;
  }

  static ProductSpec spec(String text, {String categoryHint = ''}) {
    final s = normalize(text).replaceAll(
            RegExp(r'پلیت|صفحه\s+(?:فولادی|آهنی|فلزی)|شیت|\b(?:plate|sheet)\b',
                caseSensitive: false),
            'ورق'),
        cat = category(s).isEmpty ? categoryHint : category(s);
    var thick = RegExp('ضخامت\\s*[:：]?\\s*($measure)').firstMatch(s)?[1] ?? '';
    if (thick.isEmpty &&
        ['ورق', 'پروفیل', 'لوله', 'نبشی', 'ناودانی', 'تسمه', 'سپری']
            .contains(cat)) {
      thick =
          RegExp('($measure)\\s*(?:میلی\\s*متر|میلیمتر|میلیمتری|میل|mm)(?![A-Za-z])',
                      caseSensitive: false)
                  .firstMatch(s)?[1] ??
              '';
    }
    if (thick.isEmpty && cat == 'ورق') {
      thick =
          RegExp('ورق\\s*(?:(?:آهن|سیاه|روغنی|گالوانیزه|رنگی|آجدار|استیل|گرم|سرد|برشی|فابریک)\\s*)*($measure)(?![\\d.])')
                  .firstMatch(s)?[1] ??
              '';
    }
    var size =
        RegExp('(?:سایز|نمره|قطر)\\s*[:：]?\\s*($measure)').firstMatch(s)?[1] ??
            '';
    if (size.isEmpty && cat == 'بولت') {
      size = RegExp(r'\bM\s*(\d+(?:\.\d+)?)', caseSensitive: false)
              .firstMatch(s)?[1] ??
          '';
    }
    if (size.isEmpty && cat != 'ورق') {
      size =
          RegExp('(?:میلگرد(?: بستر)?|تیر\\s*آهن|تیراهن|نبشی|ناودانی|مفتول|چهارپهلو|سپری|حرارتی)\\s*($measure)')
                  .firstMatch(s)?[1] ??
              '';
    }
    return ProductSpec(
        category: cat,
        thickness: thick,
        size: size,
        dimensions: dimension.firstMatch(s)?[0] ?? '',
        grade:
            (gauge.firstMatch(s)?[0] ?? '').replaceAll(' ', '').toUpperCase());
  }
}

class ProductSpec {
  final String category, thickness, size, dimensions, grade;
  const ProductSpec(
      {this.category = '',
      this.thickness = '',
      this.size = '',
      this.dimensions = '',
      this.grade = ''});
}

/// A query is parsed once per change, not once for each market row.
class ProductQuery {
  final ProductSpec spec;
  final String city;
  final List<String> words;
  final String width;
  ProductQuery._(this.spec, this.city, this.words, this.width);
  factory ProductQuery.parse(String query, {List<String> cities = const []}) {
    var s = ProductText.normalize(query).toLowerCase();
    final spec = ProductText.spec(s);
    String city = '';
    final ordered = [...cities]..sort((a, b) => b.length.compareTo(a.length));
    for (final candidate in ordered) {
      final re = RegExp(
          '(?<![آ-ی])${RegExp.escape(ProductText.normalize(candidate))}(?![آ-ی])');
      final m = re.firstMatch(s);
      if (m == null) continue;
      final prefix = s.substring(0, m.start);
      final explicit = RegExp(r'(?:در|شهر|دفتر|فروشنده)\s*$').hasMatch(prefix);
      final factory =
          RegExp(r'(?:فولاد|کارخانه|شکفته|پروفیل)\s*$').hasMatch(prefix);
      if (!explicit &&
          ((spec.category.isNotEmpty && candidate != 'مشهد') || factory)) {
        continue;
      }
      city = candidate;
      if (explicit) {
        final label =
            RegExp(r'(?:در|شهر|دفتر|فروشنده)\s*$').firstMatch(prefix)!;
        s = s.replaceRange(label.start, m.end, ' ');
      } else {
        s = s.replaceAll(re, ' ');
      }
      break;
    }
    final widthMatch =
        RegExp('عرض\\s*[:：]?\\s*(${ProductText.n})').firstMatch(s);
    final width = widthMatch?[1] ?? '';
    if (widthMatch != null) {
      s = s.replaceRange(widthMatch.start, widthMatch.end, ' ');
    }
    if (spec.grade.isNotEmpty) s = s.replaceAll(ProductText.gauge, ' ');
    if (spec.dimensions.isNotEmpty) {
      s = s.replaceAll(ProductText.dimension, ' ');
    }
    s = s.replaceAll(ProductText.product, ' ');
    // Remove only recognized spec numbers with numeric boundaries: 3 is not 30.
    for (final value
        in [spec.thickness, spec.size].where((x) => x.isNotEmpty)) {
      s = s.replaceFirst(
          RegExp('(?<![\\d.])${RegExp.escape(value)}(?![\\d.])'), ' ');
    }
    s = s.replaceAll(
        RegExp(
            r'ضخامت|سایز|نمره|قطر|میلی\s*متر|میلیمتر|میلیمتری|میلی|میل(?!گرد)|\bmm\b|قیمت|لطفا|برای|خرید',
            caseSensitive: false),
        ' ');
    final words =
        s.split(RegExp(r'[^آ-یa-z0-9.]+')).where((s) => s.isNotEmpty).toList();
    return ProductQuery._(spec, city, words, width);
  }
  bool matches(
      {required String category,
      required String thickness,
      required String size,
      required String dimensions,
      required String grade,
      required String sellerCity,
      required String text}) {
    if (spec.category.isNotEmpty && spec.category != category) return false;
    if (spec.thickness.isNotEmpty &&
        !ProductText.measureMatches(spec.thickness, thickness)) return false;
    if (spec.size.isNotEmpty && !ProductText.measureMatches(spec.size, size)) {
      return false;
    }
    if (spec.grade.isNotEmpty &&
        spec.grade !=
            ProductText.normalize(grade).replaceAll(' ', '').toUpperCase()) {
      return false;
    }
    if (city.isNotEmpty && city != sellerCity) return false;
    final hay = ProductText.normalize(text).toLowerCase();
    if (width.isNotEmpty &&
        !RegExp('عرض\\s*[:：]?\\s*${RegExp.escape(width)}(?![\\d.])')
            .hasMatch(hay)) return false;
    if (spec.dimensions.isNotEmpty) {
      String dims(String s) => ProductText.normalize(s)
          .toLowerCase()
          .replaceAll(RegExp(r'\s+'), '')
          .replaceAll(RegExp('[×*]'), 'x');
      final wanted = dims(spec.dimensions), actual = dims(dimensions);
      final reverse = wanted.split('x').reversed.join('x');
      if (actual != wanted &&
          actual != reverse &&
          !actual.endsWith('x$wanted')) {
        return false;
      }
    }
    if (words.isEmpty) return true;
    // Normalising/copying the haystack was done per row; the digits branch
    // compiled a fresh RegExp per row. Both now happen at most once per call.
    final RegExp? digits = words.any(
            (w) => RegExp(r'^\d+(?:\.\d+)?$').hasMatch(w))
        ? RegExp(r'(?<![\d.])(?:' +
                words
                    .where((w) => RegExp(r'^\d+(?:\.\d+)?$').hasMatch(w))
                    .map(RegExp.escape)
                    .join('|') +
                r')(?![\d.])')
        : null;
    if (digits != null && !digits.hasMatch(hay)) return false;
    for (final word in words) {
      if (RegExp(r'^\d+(?:\.\d+)?$').hasMatch(word)) continue;
      if (!hay.contains(word)) return false;
    }
    return true;
  }
}
