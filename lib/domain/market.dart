import 'dart:convert';
import 'package:shamsi_date/shamsi_date.dart';

String latin(String value) {
  const fa = '۰۱۲۳۴۵۶۷۸۹٠١٢٣٤٥٦٧٨٩';
  var s = value;
  for (var i = 0; i < fa.length; i++) {
    s = s.replaceAll(fa[i], '${i % 10}');
  }
  return s
      .replaceAll('ي', 'ی')
      .replaceAll('ك', 'ک')
      .replaceAll('\u200c', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

double? number(String s) => double.tryParse(
    latin(s).replaceAll(RegExp('[,٬ ]'), '').replaceAll('٫', '.'));
DateTime? sourceDate(String raw) {
  final s = latin(raw);
  final m = RegExp(r'(1[34]\d{2})/(\d{1,2})/(\d{1,2})').firstMatch(s);
  if (m != null) {
    try {
      final j = Jalali(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
      final g = j.toGregorian();
      final t = RegExp(r'(\d{1,2}):(\d{2})(?::(\d{2}))?').firstMatch(s);
      return DateTime.utc(
              g.year,
              g.month,
              g.day,
              t == null ? 0 : int.parse(t[1]!),
              t == null ? 0 : int.parse(t[2]!),
              t?[3] == null ? 0 : int.parse(t![3]!))
          .subtract(const Duration(hours: 3, minutes: 30));
    } catch (_) {
      return null;
    }
  }
  return DateTime.tryParse(s)?.toUtc();
}

String dateLabel(DateTime? dt, {bool time = true}) {
  if (dt == null) return 'نامشخص';
  final ir = dt.toUtc().add(const Duration(hours: 3, minutes: 30));
  final j = Jalali.fromDateTime(ir);
  return '${j.year}/${j.month.toString().padLeft(2, '0')}/${j.day.toString().padLeft(2, '0')}${time ? '  ${ir.hour.toString().padLeft(2, '0')}:${ir.minute.toString().padLeft(2, '0')}' : ''}';
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
  if (s.contains('شاخه')) return 'piece';
  if (s == 'متر') return 'm';
  if (s == 'تن') return 'ton';
  if (s.contains('برگ')) return 'sheet';
  if (s.contains('رول')) return 'roll';
  return 'unknown';
}

String materialOf(String s) {
  if (s.contains('استیل')) return 'استنلس استیل';
  if (s.contains('آلومینیوم')) return 'آلومینیوم';
  if (s.contains('آلیاژ') ||
      RegExp(r'MO40|CK45|A516', caseSensitive: false).hasMatch(s)) {
    return 'فولاد آلیاژی';
  }
  return 'فولاد کربنی';
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
  // Legacy payloads are interpreted without changing their stable source IDs.
  late final String sizeLabel = size ??
      (_field((k) => k.contains('سایز') || k == 'size').isNotEmpty
          ? _field((k) => k.contains('سایز') || k == 'size')
          : RegExp(r'(?:میلگرد|تیرآهن|ناودانی|نبشی)(?:\s+سایز)?\s*(\d+(?:\.\d+)?)')
                  .firstMatch(latin(title))?[1] ??
              '');
  late final String thicknessLabel = thickness ??
      (_field((k) => k.contains('ضخامت')).isNotEmpty
          ? _field((k) => k.contains('ضخامت'))
          : RegExp(r'(?:ورق|ضخامت)\s*(\d+(?:\.\d+)?)\s*(?:میل|mm)')
                  .firstMatch(latin(title))?[1] ??
              '');
  late final String dimensionsLabel = dimensions ??
      (_field((k) => k.contains('ابعاد')).isNotEmpty
          ? _field((k) => k.contains('ابعاد'))
          : RegExp(r'\d+(?:\.\d+)?\s*[*×x]\s*\d+(?:\.\d+)?',
                      caseSensitive: false)
                  .firstMatch(latin(title))?[0] ??
              '');
  late final String gradeLabel = grade ??
      (_field((k) => k == 'standard' || k.contains('آنالیز')).isNotEmpty
          ? _field((k) => k == 'standard' || k.contains('آنالیز'))
          : RegExp(r'\b(?:A[1-4]|ST(?:37|52)|CK45|MO40|IPE|HEA|HEB)\b',
                      caseSensitive: false)
                  .firstMatch(latin(title))?[0] ??
              '');
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

  String unitName(String u) => u == 'piece' &&
          !['میلگرد', 'تیرآهن', 'نبشی', 'ناودانی', 'پروفیل', 'لوله', 'سپری']
              .contains(category)
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

  double? priceFor(String basis) =>
      _unitPrices[basis == 'original' ? unit : basis];
  String conversionBasis(String target) => target == unit
      ? 'اعلام مستقیم منبع'
      : [
          if (_positive(pieceKg)) 'وزن ${pieceKg!} کیلوگرم',
          if (_positive(lengthM)) 'طول ${lengthM!} متر',
          if (_positive(areaM2)) 'مساحت ${areaM2!} مترمربع',
          if (target == 'ton' || unit == 'ton') 'هر تن = ۱۰۰۰ کیلوگرم',
        ].join('؛ ');

  String comparisonGroup(String basis) =>
      '$category | $material | ${brand.isEmpty ? 'برند نامشخص:$title' : brand} | ${specificationLabel.isEmpty ? 'مشخصات نامشخص:$id' : specificationLabel} | ${details['حالت'] ?? ''} | ${lengthM ?? ''} | ${basis == 'kg' ? 'kg' : unit} | $currency | $tax | $terms';
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
  double? minPrice, maxPrice;
  bool mashhadFirst = true, onlyFresh = false, includeUnpriced = false;
  bool _sameMeasure(String a, String b) =>
      number(a) != null && number(b) != null
          ? number(a) == number(b)
          : latin(a) == latin(b);
  bool matches(Quote q, DateTime now) {
    final price = q.priceFor(basis);
    return (category.isEmpty || q.category == category) &&
        (material.isEmpty || q.material == material) &&
        (city.isEmpty ||
            (cityKind == 'seller' ? q.sellerCity : q.loadingCity) == city) &&
        (unit.isEmpty || q.unit == unit) &&
        (size.isEmpty || _sameMeasure(q.sizeLabel, size)) &&
        (thickness.isEmpty || _sameMeasure(q.thicknessLabel, thickness)) &&
        (grade.isEmpty ||
            latin(q.gradeLabel).toUpperCase() == latin(grade).toUpperCase()) &&
        (query.isEmpty || q.searchText.contains(latin(query).toLowerCase())) &&
        (!onlyFresh || q.isFresh(now)) &&
        (includeUnpriced || price != null) &&
        (minPrice == null || (price != null && price >= minPrice!)) &&
        (maxPrice == null || (price != null && price <= maxPrice!));
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
        size,
        thickness,
        grade
      ]);
  List<Quote> apply(Iterable<Quote> quotes, DateTime now) {
    for (final q in quotes) {
      q.searchText;
    }
    final list = quotes.where((q) => matches(q, now)).toList();
    list.sort((a, b) {
      // Never compare a branch amount directly with a kilogram amount.
      final group =
          a.comparisonGroup(basis).compareTo(b.comparisonGroup(basis));
      if (group != 0) return group;
      if (mashhadFirst) {
        final p = (a.sellerCity == 'مشهد' ? 0 : 1)
            .compareTo(b.sellerCity == 'مشهد' ? 0 : 1);
        if (p != 0) return p;
      }
      final pa = a.priceFor(basis), pb = b.priceFor(basis);
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
