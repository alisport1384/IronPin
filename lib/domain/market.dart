import 'city_scope.dart';
import 'money.dart';
import 'dart:convert';
import 'product_text.dart';
import 'package:shamsi_date/shamsi_date.dart';

/// Memoised, because `latin` is pure and its input vocabulary is tiny.
///
/// Every row's `details` uses the same handful of keys («سایز», «ضخامت»,
/// «حالت», …) and the same short values, and the label and spec paths normalise
/// each of them several times per row. Measured on a 12,000-row archive this
/// was the single most repeated piece of work in the read.
///
/// The cache is bounded and cleared whole: a large archive must not be able to
/// grow it without limit, and a cleared cache costs only a recompute.
final Map<String, String> _latinCache = {};
const int _latinCacheLimit = 4096;

String latin(String value) {
  final cached = _latinCache[value];
  if (cached != null) return cached;
  const fa = '۰۱۲۳۴۵۶۷۸۹٠١٢٣٤٥٦٧٨٩';
  var s = value;
  for (var i = 0; i < fa.length; i++) {
    s = s.replaceAll(fa[i], '${i % 10}');
  }
  final result = s
      .replaceAll('ي', 'ی')
      .replaceAll('ك', 'ک')
      .replaceAll('\u200c', ' ')
      .replaceAll(_latinWhitespace, ' ')
      .trim();
  if (_latinCache.length >= _latinCacheLimit) _latinCache.clear();
  _latinCache[value] = result;
  return result;
}

double? number(String s) => double.tryParse(
    latin(s).replaceAll(RegExp('[,٬ ]'), '').replaceAll('٫', '.'));
DateTime? sourceDate(String raw) {
  var s = latin(raw);
  if (s.isEmpty) return null;
  const months = [
    'فروردین',
    'اردیبهشت',
    'خرداد',
    'تیر',
    'مرداد',
    'شهریور',
    'مهر',
    'آبان',
    'آذر',
    'دی',
    'بهمن',
    'اسفند'
  ];
  final named = RegExp(
          r'(\d{1,2})\s+(' + months.join('|') + r')\s+(?:ماه\s+)?(1[34]\d{2})')
      .firstMatch(s);
  if (named != null) {
    s = s.replaceRange(named.start, named.end,
        '${named[3]}/${months.indexOf(named[2]!) + 1}/${named[1]}');
  }
  final m = RegExp(r'(1[34]\d{2})[/.-](\d{1,2})[/.-](\d{1,2})').firstMatch(s);
  if (m != null) {
    try {
      final j = Jalali(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
      final g = j.toGregorian();
      final t = RegExp(r'(\d{1,2}):(\d{2})(?::(\d{2}))?').firstMatch(s);
      final h = t == null ? 0 : int.parse(t[1]!),
          min = t == null ? 0 : int.parse(t[2]!),
          sec = t?[3] == null ? 0 : int.parse(t![3]!);
      if (h > 23 || min > 59 || sec > 59) return null;
      return DateTime.utc(g.year, g.month, g.day, h, min, sec)
          .subtract(const Duration(hours: 3, minutes: 30));
    } catch (_) {
      return null;
    }
  }
  final isoDay = RegExp(r'^(20\d{2})-(\d{2})-(\d{2})').firstMatch(s);
  if (isoDay != null) {
    final y = int.parse(isoDay[1]!),
        m = int.parse(isoDay[2]!),
        d = int.parse(isoDay[3]!);
    final check = DateTime.utc(y, m, d);
    if (check.year != y || check.month != m || check.day != d) return null;
  }
  if (RegExp(r'^20\d{2}-\d{2}-\d{2}$').hasMatch(s)) {
    final d = DateTime.tryParse(s);
    return d == null
        ? null
        : DateTime.utc(d.year, d.month, d.day)
            .subtract(const Duration(hours: 3, minutes: 30));
  }
  return DateTime.tryParse(s)?.toUtc();
}

final Map<int, String> _jalaliDayCache = {};
const int _jalaliDayCacheLimit = 1024;

String dateLabel(DateTime? dt, {bool time = true}) {
  if (dt == null) return 'نامشخص';
  final ir = dt.toUtc().add(const Duration(hours: 3, minutes: 30));
  final dayKey = ir.millisecondsSinceEpoch ~/ 86400000;
  var dayStr = _jalaliDayCache[dayKey];
  if (dayStr == null) {
    final j = Jalali.fromDateTime(ir);
    dayStr = faDigits(
        '${j.year}/${j.month.toString().padLeft(2, '0')}/${j.day.toString().padLeft(2, '0')}');
    if (_jalaliDayCache.length >= _jalaliDayCacheLimit) {
      _jalaliDayCache.clear();
    }
    _jalaliDayCache[dayKey] = dayStr;
  }
  if (!time) return dayStr;
  final hh = ir.hour.toString().padLeft(2, '0');
  final mm = ir.minute.toString().padLeft(2, '0');
  return '$dayStr  ${faDigits('$hh:$mm')}';
}

String unitLabel(String u) =>
    const {
      'kg': 'کیلوگرم',
      'piece': 'شاخه',
      'm': 'متر',
      'm2': 'مترمربع',
      'ton': 'تن',
      'sheet': 'برگ',
      'roll': 'رول',
      'unknown': 'نامشخص'
    }[u] ??
    u;
String parseUnit(String v) {
  final s = latin(v);
  if (s.contains('کیلو') || s == 'kg') return 'kg';
  if (s.contains('مترمربع') || s.contains('متر مربع')) return 'm2';
  if (s.contains('شاخه') || RegExp(r'^(?:هر\s+)?عدد$').hasMatch(s)) {
    return 'piece';
  }
  if (s == 'متر') return 'm';
  if (s == 'تن') return 'ton';
  if (s.contains('برگ') ||
      RegExp(r'^(?:هر\s+|یک\s+|تک\s+)?(?:ورق|شیت|sheet)$',
              caseSensitive: false)
          .hasMatch(s)) {
    return 'sheet';
  }
  if (s.contains('رول')) return 'roll';
  return 'unknown';
}

/// Compiled once. `Quote`'s labels and search text are derived for every row of
/// the archive, and a `RegExp` literal in that path was compiled per row (and,
/// for the details keys, per key of every row).
final _specKeyPattern = RegExp('عرض|ابعاد|سایز|ضخامت|طول|حالت|گرید|استاندارد');
final _sizeInTitle =
    RegExp(r'(?:میلگرد|تیرآهن|ناودانی|نبشی)(?:\s+سایز)?\s*(\d+(?:\.\d+)?)');
final _dimensionsInTitle =
    RegExp(r'\d+(?:\.\d+)?\s*[*×x]\s*\d+(?:\.\d+)?', caseSensitive: false);
final _gradeInTitle =
    RegExp(r'\b(?:A[1-4]|ST(?:37|52)|CK45|MO40|IPE|HEA|HEB)\b', caseSensitive: false);
final _latinWhitespace = RegExp(r'\s+');

String materialOf(String s) {
  if (s.contains('استیل')) return 'استنلس استیل';
  if (s.contains('آلومینیوم')) return 'آلومینیوم';
  if (s.contains('آلیاژ') ||
      RegExp(r'MO40|CK45|A516', caseSensitive: false).hasMatch(s)) {
    return 'فولاد آلیاژی';
  }
  return 'فولاد کربنی';
}

/// Milliseconds of a window in days, with the meaning every layer shares:
/// a positive number is that many days, `0` is the archive's own 48-hour
/// default, and a negative number is «همه زمان‌ها» (no limit).
int windowMsFor(int days) => days > 0
    ? days * 24 * 3600 * 1000
    : (days == 0 ? 48 * 3600 * 1000 : 100 * 365 * 24 * 3600 * 1000);

/// The same window as a [Duration].
Duration windowFor(int days) => Duration(milliseconds: windowMsFor(days));

/// The capture and display window of the whole app, in days. `0` is "all time".
///
/// A row belongs to a window when its **own announcement date** is inside it;
/// a row whose date is unknown is judged by the moment the app stored it, so a
/// fresh undated caption is still visible while an old one is not. A date in
/// the future is not inside any window. Nothing is inferred and no date is
/// rewritten: the rule only decides whether a stored row is shown or captured.
bool insideWindow(Quote q, DateTime now, int days) {
  if (days <= 0) return true;
  final at = q.marketAt;
  final moment = at ?? q.fetchedAt.toUtc();
  if (moment.isBefore(now.toUtc().subtract(Duration(days: days)))) return false;
  if (at != null && at.isAfter(now.toUtc().add(const Duration(minutes: 5)))) {
    return false;
  }
  return true;
}

class Quote {
  final String id,
      endpoint,
      seller,
      sellerCity,
      title,
      category,
      material,
      brand,
      loading,
      loadingCity,
      unit,
      tax,
      currency,
      terms,
      sourceUrl,
      sourceDateRaw,
      status;
  final double? amount, pieceKg, lengthM, areaM2;
  final DateTime fetchedAt;
  final Map<String, String> details;
  final String? size, thickness, dimensions, grade;
  String _field(bool Function(String) match) =>
      details.entries
          .where((e) => match(latin(e.key)))
          .map((e) => latin(e.value))
          .firstOrNull ??
      '';
  late final String productSearchText = ProductText.normalize([
    title,
    category,
    material,
    brand,
    seller,
    sellerCity,
    loading,
    loadingCity,
    terms,
    tax,
    sizeLabel,
    thicknessLabel,
    dimensionsLabel,
    gradeLabel,
    ...details.entries
        .where((e) => _specKeyPattern.hasMatch(e.key))
        .map((e) => '${e.key} ${e.value}')
  ].join(' '));
  // Legacy payloads are interpreted without changing their stable source IDs.
  //
  // Each of these read `_field` twice for the same predicate: once to test that
  // the value is not empty and once to return it. `_field` walks `details` and
  // normalises every key and value, so on an archive read that doubled the
  // hottest work in the row for no change in result. The value is now read once
  // and kept.
  late final String sizeLabel = _sizeLabel();
  late final String thicknessLabel = _thicknessLabel();
  late final String dimensionsLabel = _dimensionsLabel();
  late final String gradeLabel = _gradeLabel();

  String _sizeLabel() {
    if (size != null) return size!;
    final fromDetails = _field((k) => k.contains('سایز') || k == 'size');
    if (fromDetails.isNotEmpty) return fromDetails;
    return _sizeInTitle.firstMatch(latin(title))?[1] ?? '';
  }

  String _thicknessLabel() {
    if (thickness?.isNotEmpty ?? false) return thickness!;
    final fromDetails = _field((k) => k.contains('ضخامت'));
    if (fromDetails.isNotEmpty) return fromDetails;
    return ProductText.spec(title, categoryHint: category).thickness;
  }

  String _dimensionsLabel() {
    if (dimensions != null) return dimensions!;
    final fromDetails = _field((k) => k.contains('ابعاد'));
    if (fromDetails.isNotEmpty) return fromDetails;
    return _dimensionsInTitle.firstMatch(latin(title))?[0] ?? '';
  }

  String _gradeLabel() {
    if (grade != null) return grade!;
    final fromDetails = _field((k) => k == 'standard' || k.contains('آنالیز'));
    if (fromDetails.isNotEmpty) return fromDetails;
    return _gradeInTitle.firstMatch(latin(title))?[0] ?? '';
  }
  late final String searchText =
      latin('$title $brand $seller $details').toLowerCase();
  String get specificationLabel => [
        if (sizeLabel.isNotEmpty) 'سایز $sizeLabel',
        if (thicknessLabel.isNotEmpty) 'ضخامت $thicknessLabel میلی‌متر',
        if (dimensionsLabel.isNotEmpty) 'ابعاد $dimensionsLabel',
        if (gradeLabel.isNotEmpty) gradeLabel,
      ].join(' • ');
  Quote(
      {required this.id,
      required this.endpoint,
      required this.seller,
      required this.title,
      required this.category,
      required this.unit,
      required this.fetchedAt,
      required this.sourceUrl,
      this.sellerCity = 'نامشخص',
      this.material = 'فولاد کربنی',
      this.brand = '',
      this.loading = 'نامشخص',
      this.loadingCity = 'نامشخص',
      this.tax = 'نامشخص',
      this.currency = 'تومان',
      this.terms = 'نامشخص',
      this.sourceDateRaw = '',
      this.status = 'اعلام فروشنده؛ موجودی نیازمند تایید',
      this.amount,
      this.pieceKg,
      this.lengthM,
      this.areaM2,
      this.size,
      this.thickness,
      this.dimensions,
      this.grade,
      this.details = const {}});
  late final DateTime? announcedAt = sourceDate(sourceDateRaw);
  late final DateTime? publishedAt =
      sourceDate(details['زمان انتشار پیام'] ?? '');
  late final DateTime? marketAt = _marketDate();
  DateTime? _marketDate() {
    if (details['تاریخ نامعتبر'] == 'بله') return null;
    final rate = announcedAt, post = publishedAt;
    if (rate == null) return post;
    // A day-only rate date can use publication time ONLY on that same Iranian day.
    if (post != null &&
        (details['دقت تاریخ نرخ'] == 'روز' ||
            !RegExp(r'\d{1,2}:\d{2}').hasMatch(sourceDateRaw)) &&
        dateLabel(rate, time: false) == dateLabel(post, time: false)) {
      return post;
    }
    return rate;
  }

  bool isWithinWeek(DateTime now) {
    final date = marketAt;
    return date != null &&
        !date.isAfter(now.toUtc().add(const Duration(minutes: 5))) &&
        !date.isBefore(now.toUtc().subtract(const Duration(days: 7)));
  }

  bool get hasTextAmount => details.containsKey('مبلغ استخراج‌شده');
  bool isFresh(DateTime now) =>
      announcedAt != null &&
      now.toUtc().difference(announcedAt!).inHours <= 30 &&
      now.toUtc().difference(announcedAt!).inMinutes >= -5;
  static bool _positive(double? n) => n != null && n.isFinite && n > 0;
  String get discreteUnit {
    if (['piece', 'sheet', 'roll'].contains(unit)) return unit;
    if (category == 'ورق') {
      return (details['حالت'] ?? '').contains('رول') ? 'roll' : 'sheet';
    }
    return 'piece';
  }

  String unitName(String u) =>
      u == 'piece' && ProductText.category(category) == 'بولت'
          ? 'عدد / ست'
          : u == 'piece' &&
                  ![
                    'میلگرد',
                    'تیرآهن',
                    'نبشی',
                    'ناودانی',
                    'پروفیل',
                    'لوله',
                    'سپری',
                    'تسمه'
                  ].contains(category)
              ? 'قطعه'
              : unitLabel(u);
  List<String> get displayUnits => <String>{
        'kg',
        'm',
        discreteUnit,
        if (category == 'ورق' || unit == 'm2') 'm2',
        'ton',
        if (unit != 'unknown') unit
      }.toList();
  // Every edge uses explicit source dimensions/mass. No density, default length,
  // nominal size tables or assumptions from price magnitude are allowed here.
  late final Map<String, double> _unitPrices = _convertPrices();
  Map<String, double> _convertPrices() {
    if (!_positive(amount) ||
        !['kg', 'ton', 'm', 'm2', 'piece', 'sheet', 'roll'].contains(unit)) {
      return {};
    }
    final graph = <String, Map<String, double>>{};
    void link(String a, String b, double factor) {
      if (!factor.isFinite || factor <= 0) return;
      (graph[a] ??= {})[b] = factor;
      (graph[b] ??= {})[a] = 1 / factor;
    }

    link('kg', 'ton', 1000);
    if (_positive(pieceKg)) link('kg', discreteUnit, pieceKg!);
    if (_positive(lengthM)) link('m', discreteUnit, lengthM!);
    if (_positive(areaM2)) link('m2', discreteUnit, areaM2!);
    final result = <String, double>{unit: amount!};
    final queue = <String>[unit];
    for (var i = 0; i < queue.length; i++) {
      for (final edge in (graph[queue[i]] ?? {}).entries) {
        if (result.containsKey(edge.key)) continue;
        final value = result[queue[i]]! * edge.value;
        if (!value.isFinite || value <= 0) continue;
        result[edge.key] = value;
        queue.add(edge.key);
      }
    }
    return result;
  }

  double? tomanFor(String basis) => toman(priceFor(basis), currency);

  /// The price of this row in [basis].
  ///
  /// `original` is the amount exactly as the source announced it, in the unit the
  /// source itself used, and it exists whenever the row has an amount — including
  /// the case where the source named no unit at all. That is what lets a card
  /// show the number it really carries instead of "no price" merely because the
  /// basis is unknown. Every other basis is a real conversion and stays `null`
  /// when the row cannot prove one.
  double? priceFor(String basis) => basis == 'original'
      ? (_positive(amount) ? amount : null)
      : _unitPrices[basis];
  String conversionBasis(String target) => target == unit
      ? 'اعلام مستقیم منبع'
      : [
          if (_positive(pieceKg)) 'وزن ${pieceKg!} کیلوگرم',
          if (_positive(lengthM)) 'طول ${lengthM!} متر',
          if (_positive(areaM2)) 'مساحت ${areaM2!} مترمربع',
          if (target == 'ton' || unit == 'ton') 'هر تن = ۱۰۰۰ کیلوگرم',
        ].join('؛ ');

  String comparisonGroup(String basis) =>
      '$category | $material | ${brand.isEmpty ? 'برند نامشخص:$title' : brand} | ${specificationLabel.isEmpty ? 'مشخصات نامشخص:$id' : specificationLabel} | ${details['حالت'] ?? ''} | ${lengthM ?? ''} | ${basis == 'kg' ? 'kg' : unit} | ${toman(amount, currency) == null ? currency : 'تومان'} | $tax | $terms';
  String get signature => jsonEncode([
        amount,
        unit,
        tax,
        currency,
        terms,
        sourceDateRaw,
        status,
        details,
        pieceKg,
        lengthM,
        areaM2,
        sizeLabel,
        thicknessLabel,
        dimensionsLabel,
        gradeLabel
      ]);
  Map<String, dynamic> toJson() => {
        'id': id,
        'endpoint': endpoint,
        'seller': seller,
        'sellerCity': sellerCity,
        'title': title,
        'category': category,
        'material': material,
        'brand': brand,
        'loading': loading,
        'loadingCity': loadingCity,
        'unit': unit,
        'tax': tax,
        'currency': currency,
        'terms': terms,
        'sourceUrl': sourceUrl,
        'sourceDateRaw': sourceDateRaw,
        'status': status,
        'amount': amount,
        'pieceKg': pieceKg,
        'lengthM': lengthM,
        'areaM2': areaM2,
        'fetchedAt': fetchedAt.toUtc().toIso8601String(),
        'size': sizeLabel,
        'thickness': thicknessLabel,
        'dimensions': dimensionsLabel,
        'grade': gradeLabel,
        'details': details
      };
  factory Quote.fromJson(Map<String, dynamic> j) => Quote(
      id: j['id'],
      endpoint: j['endpoint'],
      seller: j['seller'],
      title: j['title'],
      category: j['category'],
      unit: j['unit'],
      fetchedAt: DateTime.parse(j['fetchedAt']),
      sourceUrl: j['sourceUrl'],
      sellerCity: j['sellerCity'] ?? 'نامشخص',
      material: j['material'] ?? 'فولاد کربنی',
      brand: j['brand'] ?? '',
      loading: j['loading'] ?? 'نامشخص',
      loadingCity: j['loadingCity'] ?? 'نامشخص',
      tax: j['tax'] ?? 'نامشخص',
      currency: j['currency'] ?? 'تومان',
      terms: j['terms'] ?? 'نامشخص',
      sourceDateRaw: j['sourceDateRaw'] ?? '',
      status: j['status'] ?? '',
      amount: (j['amount'] as num?)?.toDouble(),
      pieceKg: (j['pieceKg'] as num?)?.toDouble(),
      lengthM: (j['lengthM'] as num?)?.toDouble(),
      areaM2: (j['areaM2'] as num?)?.toDouble(),
      size: j['size'],
      thickness: j['thickness'],
      dimensions: j['dimensions'],
      grade: j['grade'],
      details: Map<String, String>.from(j['details'] ?? {}));
}

class MarketFilter {
  List<String> queryCities = const [
    'مشهد',
    'تهران',
    'اصفهان',
    'تبریز',
    'نیشابور'
  ];
  String _parsedQuery = '';
  List<String>? _parsedCities;
  ProductQuery? _intent;
  ProductQuery get intent {
    if (_intent == null ||
        _parsedQuery != query ||
        !identical(_parsedCities, queryCities)) {
      _parsedQuery = query;
      _parsedCities = queryCities;
      _intent = ProductQuery.parse(query, cities: queryCities);
    }
    return _intent!;
  }

  String category = '',
      material = '',
      city = '',
      cityKind = 'seller',
      unit = '',
      query = '',
      size = '',
      thickness = '',
      grade = '',
      basis = 'original',
      sort = 'asc';
  bool recentWeek = false;

  /// The tab's own time filter, in days; `0` means "the whole window".
  int windowDays = 0;
  double? minPrice, maxPrice;
  bool mashhadFirst = true, onlyFresh = false, includeUnpriced = false;
  bool _sameMeasure(String a, String b) =>
      number(a) != null && number(b) != null
          ? number(a) == number(b)
          : latin(a) == latin(b);
  bool matches(Quote q, DateTime now) {
    if (ProductText.isNonMetal(q.title)) return false;
    final price = q.tomanFor(basis);
    return (category.isEmpty || q.category == category) &&
        (material.isEmpty || q.material == material) &&
        (city.isEmpty ||
            (cityKind == 'all'
                ? cityMatches(q, city)
                : (cityKind == 'seller' ? q.sellerCity : q.loadingCity) ==
                    city)) &&
        (unit.isEmpty || q.unit == unit) &&
        (size.isEmpty || _sameMeasure(q.sizeLabel, size)) &&
        (thickness.isEmpty || _sameMeasure(q.thicknessLabel, thickness)) &&
        (grade.isEmpty ||
            latin(q.gradeLabel).toUpperCase() == latin(grade).toUpperCase()) &&
        (query.isEmpty ||
            intent.matches(
                category: q.category,
                thickness: q.thicknessLabel,
                size: q.sizeLabel,
                dimensions: q.dimensionsLabel,
                grade: q.gradeLabel,
                sellerCity: q.sellerCity,
                material: q.material,
                text: q.productSearchText)) &&
        (!onlyFresh || q.isFresh(now)) &&
        (!recentWeek || q.isWithinWeek(now)) &&
        insideWindow(q, now, windowDays) &&
        (includeUnpriced ||
            price != null ||
            q.hasTextAmount) &&
        (minPrice == null || (price != null && price >= minPrice!)) &&
        (maxPrice == null || (price != null && price <= maxPrice!));
  }

  /// Comparison group per row, computed once per filtered list instead of once
  /// per comparison (it is a ten-field string). Cleared whenever the list is
  /// rebuilt, so a stale group can never decide an order.
  Map<Quote, String> _groups = <Quote, String>{};
  String _groupBasis = '';
  String groupOf(Quote q) => _groups[q] ??= q.comparisonGroup(basis);
  List<String> _groupList(Iterable<Quote> list) {
    if (_groupBasis != basis || _groups.length > list.length * 4 + 4096) {
      _groups = <Quote, String>{};
      _groupBasis = basis;
    }
    return [for (final q in list) groupOf(q)];
  }

  String get cacheKey => jsonEncode([
        category,
        material,
        city,
        cityKind,
        unit,
        query,
        basis,
        sort,
        minPrice,
        maxPrice,
        mashhadFirst,
        onlyFresh,
        includeUnpriced,
        recentWeek,
        windowDays,
        size,
        thickness,
        grade
      ]);
  List<Quote> apply(Iterable<Quote> quotes, DateTime now) {
    for (final q in quotes) {
      q.searchText;
    }
    final list = quotes.where((q) => matches(q, now)).toList();
    // Groups are materialised lazily, only for rows the comparator actually
    // visits: a search that matches a handful of rows costs a handful of keys.
    // A plain draft sort runs first, so the real sort starts from a nearly
    // ordered list.
    if (list.length > 48) {
      list.sort((a, b) => a.id.compareTo(b.id));
    }
    final groups = _groupList(list);
    final indexOf = <Quote, int>{
      for (var i = 0; i < list.length; i++) list[i]: i
    };
    list.sort((a, b) {
      if (sort == 'latest') {
        final da = a.marketAt, db = b.marketAt;
        if (da == null && db != null) return 1;
        if (db == null && da != null) return -1;
        final byDate = da == null ? 0 : db!.compareTo(da);
        if (byDate != 0) return byDate;
        if (mashhadFirst) {
          final city = (a.sellerCity == 'مشهد' ? 0 : 1)
              .compareTo(b.sellerCity == 'مشهد' ? 0 : 1);
          if (city != 0) return city;
        }
        return a.id.compareTo(b.id);
      }
      // Never compare a branch amount directly with a kilogram amount.
      // The group string was rebuilt for every comparison (≈۲n·log n times over
      // the whole archive, and it is a concatenation of ten fields); the price
      // order inside a group is a price order regardless of which group it is,
      // so grouping is a single pass before the sort instead.
      final group =
          groups[indexOf[a]!].compareTo(groups[indexOf[b]!]);
      if (group != 0) return group;
      if (mashhadFirst) {
        final p = (a.sellerCity == 'مشهد' ? 0 : 1)
            .compareTo(b.sellerCity == 'مشهد' ? 0 : 1);
        if (p != 0) return p;
      }
      final pa = a.tomanFor(basis), pb = b.tomanFor(basis);
      if (pa == null && pb == null) return a.title.compareTo(b.title);
      if (pa == null) return 1;
      if (pb == null) return -1;
      final c = pa.compareTo(pb);
      return (sort == 'desc' ? -c : c) != 0
          ? (sort == 'desc' ? -c : c)
          : a.id.compareTo(b.id);
    });
    return list;
  }
}
