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

  /// Lookbehind-free native-JIT prefilter: rejects 99.99% of steel titles in
  /// nanoseconds without allocating normalised strings or entering Dart's
  /// interpreted lookbehind regex engine.
  static final _nonMetalFast = RegExp(
      r'قرص|[کك]پسول|شربت|آمپول|و[یي]ال|دارو|م[کك]مل|و[یي]تام[یي]ن|فول[یي][کك]|فروس|ف[یي]فول|ففول|فروگلوب[یي]ن|فرود[یي]ن|فروفورت|س[یي]دورال|هموگلوب[یي]ن|خون[یي]|فقر|بل[یي]ستر|قطره|گرم|د[یي]\s*اف|نئوپان|ها[یي]گلاس|ملام[یي]نه|گچ|[کك]ناف|[کك]اغذ|مقوا|پاسور|پل[کك]س[یي]|[کك]ربنات|[یي]ونول[یي]ت|پل[یي][کك]ا|fefol|ferrous|folic|tablet|capsule|blister|vitamin|supplement|pharmac|anemia|mdf|hdf|pvc|a4|a5|mg|mcg',
      caseSensitive: false);

  static final _nonMetal = RegExp(
      r'(?<![آ-ی])(?:قرص|کپسول|شربت|آمپول|ویال|دارو(?:خانه|یی)?|مکمل|ویتامین|فولیک|فروس|فیفول|ففول|فروگلوبین|فرودین|فروفورت|سیدورال|هموگلوبین|کم\s*خونی|فقر\s*آهن|بلیستر|قطره\s*آهن|میلی\s*گرم|میکروگرم|ام\s*دی\s*اف|نئوپان|هایگلاس|ملامینه|گچ\s*برگ|کناف|کاغذ|مقوا|پاسور|پلکسی|پلی\s*کربنات|یونولیت|پلیکا)(?![آ-ی])|'
      r'\b(?:fefol|ferrous|folic|tablets?|capsules?|blister|vitamins?|supplements?|pharmac(?:y|eutical)|anemia|mdf|hdf|upvc|pvc|a4|a5)\b|'
      r'\b\d+(?:\.\d+)?\s*(?:mg|mcg)\b',
      caseSensitive: false);

  /// True when [text] describes pharmaceuticals, dietary iron supplements,
  /// blister packs («قرص آهن یک ورق»), paper, MDF or other non-metal goods.
  static bool isNonMetal(String text) =>
      _nonMetalFast.hasMatch(text) && _nonMetal.hasMatch(normalize(text));

  static final product = RegExp(
      r'انکر\s*بولت|انکربولت|رول\s*بولت|بولت|\banchor\s+bolt\b|میلگرد(?:\s+بستر)?|تیر\s*آهن|تیراهن|هاش|ناودانی|نبشی|پروفیل|قوطی|لوله|ورق|پلیت|صفحه\s+(?:فولادی|آهنی|فلزی)|شیت|\b(?:plate|sheet)\b|چهارپهلو|مفتول|تسمه|سپری|رابیتس|توری|مش\s+جوشی|شمش|قراضه',
      caseSensitive: false);
  static String category(String text) {
    final norm = normalize(text);
    if (_nonMetalFast.hasMatch(norm) && _nonMetal.hasMatch(norm)) return '';
    final s = product.firstMatch(norm)?[0] ?? '';
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
    final rawNorm = normalize(text);
    if (_nonMetalFast.hasMatch(rawNorm) && _nonMetal.hasMatch(rawNorm)) {
      return const ProductSpec();
    }
    final s = rawNorm.replaceAll(
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
      final m = RegExp(
              'ورق\\s*(?:(?:آهن|آهنی|فولاد|فولادی|فلزی|سیاه|روغنی|گالوانیزه|رنگی|آجدار|استیل|اسیدشویی|گرم|سرد|برشی|فابریک)\\s*)*($measure)(?![\\d.])')
          .firstMatch(s);
      if (m != null) {
        final cand = m[1]!;
        final after = s.substring(m.end).trimLeft();
        final firstNum = double.tryParse(RegExp(n).firstMatch(cand)?[0] ?? '');
        final isPriceOrCode =
            RegExp(r'^(?:تومان|ریال|هزار|میلیون|[RT]\b)', caseSensitive: false)
                    .hasMatch(after) ||
                RegExp(r'^\d{1,3},\d{3}').hasMatch(cand) ||
                (firstNum != null && firstNum > 300);
        if (!isPriceOrCode) thick = cand;
      }
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
  final bool nonMetal;
  final bool steelOnly;
  final RegExp? _digits;
  final List<String> _textWords;

  ProductQuery._(this.spec, this.city, this.words, this.width,
      {this.nonMetal = false, this.steelOnly = false})
      : _digits = _compileDigits(words),
        _textWords = words
            .where((w) => !RegExp(r'^\d+(?:\.\d+)?$').hasMatch(w))
            .toList(growable: false);

  static RegExp? _compileDigits(List<String> words) {
    final nums =
        words.where((w) => RegExp(r'^\d+(?:\.\d+)?$').hasMatch(w)).toList();
    if (nums.isEmpty) return null;
    return RegExp('(?<![\\d.])(?:${nums.map(RegExp.escape).join('|')})(?![\\d.])');
  }

  factory ProductQuery.parse(String query, {List<String> cities = const []}) {
    if (ProductText.isNonMetal(query)) {
      return ProductQuery._(const ProductSpec(), '', const [], '',
          nonMetal: true);
    }
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
    var steelOnly = false;
    if (spec.category.isNotEmpty) {
      final genericMetal = RegExp(
          r'(?<!ذوب\s)(?<![آ-ی])(?:آهن|آهنی|فولاد|فولادی|فلزی)(?![آ-ی])');
      if (genericMetal.hasMatch(s)) {
        steelOnly = true;
        s = s.replaceAll(genericMetal, ' ');
      }
      s = s.replaceAll(
          RegExp(r'(?<![آ-ی])(?:یک|هر|تک|برگ|شاخه)(?![آ-ی])'), ' ');
    }
    s = s.replaceAll(
        RegExp(
            r'ضخامت|سایز|نمره|قطر|میلی\s*متر|میلیمتر|میلیمتری|میلی|میل(?!گرد)|\bmm\b|قیمت|لطفا|برای|خرید',
            caseSensitive: false),
        ' ');
    final words =
        s.split(RegExp(r'[^آ-یa-z0-9.]+')).where((s) => s.isNotEmpty).toList();
    return ProductQuery._(spec, city, words, width, steelOnly: steelOnly);
  }
  bool get needsText =>
      width.isNotEmpty || words.isNotEmpty || steelOnly;

  bool matches(
      {required String category,
      required String thickness,
      required String size,
      required String dimensions,
      required String grade,
      required String sellerCity,
      required String text,
      String material = ''}) {
    if (nonMetal) return false;
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
    if (ProductText.isNonMetal(text)) return false;
    String? lazyHay;
    String hay() => lazyHay ??= ProductText.normalize(text).toLowerCase();
    if (steelOnly) {
      final mat = material.isEmpty
          ? ''
          : ProductText.normalize(material).toLowerCase();
      final ok = mat.isNotEmpty
          ? (mat.contains('فولاد') ||
              mat.contains('استیل') ||
              mat.contains('آهن'))
          : (hay().contains('فولاد') ||
              hay().contains('استیل') ||
              hay().contains('آهن'));
      if (!ok) return false;
    }
    if (width.isNotEmpty &&
        !RegExp('عرض\\s*[:：]?\\s*${RegExp.escape(width)}(?![\\d.])')
            .hasMatch(hay())) return false;
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
    final h = hay();
    if (_digits != null && !_digits.hasMatch(h)) return false;
    for (final word in _textWords) {
      if (!h.contains(word)) return false;
    }
    return true;
  }
}
