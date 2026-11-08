import 'dart:convert';
import 'market.dart';
import 'product_text.dart';
import 'product_schema.dart';

/// Deterministic on-device extraction. Source text is evidence, never instructions.
/// No density/default length, price magnitude currency inference or network calls.
class TextPriceEngine {
  static const version = '2';
  static final product = ProductText.product;
  static String normalize(String text) => text
      .replaceAll('\r', '')
      .split('\n')
      .map((s) => latin(s)
          .replaceAll('_', ' ')
          .replaceAll('،', ',')
          .replaceAll('تومن', 'تومان'))
      .join('\n');
  static String key(String value) {
    var n = 2166136261;
    for (final b in utf8.encode(value)) {
      n = ((n ^ b) * 16777619) & 0xffffffff;
    }
    return n.toRadixString(16);
  }

  static String category(String text) => ProductText.category(text);
  static Quote enrich(Quote q) {
    final spec = ProductText.spec(q.title, categoryHint: q.category);
    final j = q.toJson();
    for (final e in {
      'thickness': spec.thickness,
      'size': spec.size,
      'grade': spec.grade,
      'dimensions': spec.dimensions
    }.entries) {
      if ((j[e.key] as String? ?? '').isEmpty && e.value.isNotEmpty) {
        j[e.key] = e.value;
      }
    }
    final normalized = Quote.fromJson(j);
    final facts = ProductFacts.of(normalized);
    if (facts.family.isNotEmpty) j['category'] = facts.family;
    j['details'] = {
      ...q.details,
      'تحلیل خودکار': 'محلی v$version',
      'نسخه مشخصات': '1',
      for (final field in facts.values.entries)
        if (field.value.isNotEmpty) 'مشخصات.${field.key}': field.value,
      'مبنای مشخصات': 'عنوان و ستون همان ردیف؛ مقدار نامعلوم حدس زده نشد'
    };
    return Quote.fromJson(j);
  }

  static String brandOf(String text) {
    final model = text.split(RegExp('بارگیری|تحویل|انبار')).first;
    return RegExp(
                r'ذوب\s*آهن(?:\s*اصفهان)?|(?:فولاد\s*)?مبارکه(?:\s*اصفهان)?|آناهیتا(?:\s*گیلان)?|ظفر\s*بناب|نیشابور|فولاد\s*خراسان|کاویان|اکسین(?:\s*اهواز)?|گیلان|بافق(?:\s*یزد)?|آریان\s*فولاد|فایکو|راد\s*همدان|درپاد(?:\s*تبریز)?')
            .firstMatch(model)?[0] ??
        '';
  }

  static String currency(String text) {
    final t = text.contains('تومان'), r = text.contains('ریال');
    return t == r
        ? 'نامشخص'
        : t
            ? 'تومان'
            : 'ریال';
  }

  static String priceUnit(String text) {
    final s = latin(text);
    if (RegExp(r'کیلویی|تومانی?\s*[/\\]\s*کیلو|ریال\s*[/\\]\s*کیلو')
        .hasMatch(s)) return 'kg';
    // The basis is written either before the amount ("هر کیلو ۱۲۵,۰۰۰") or after
    // the currency ("۱۲۵,۰۰۰ تومان کیلو"). Both are the source stating a basis;
    // neither may be treated as a guess.
    final m = RegExp(
            r'(?:هر\s+|[/\\]\s*|مبنای\s+|بر\s*مبنای\s+|بر\s*اساس\s+|واحد\s*[:：]?\s*|به\s*ازای\s+|قیمت\s+)(کیلوگرم|کیلو|متر\s*مربع|مترمربع|شاخه|عدد|برگ|رول|تن|متر)(?![\p{L}])',
            unicode: true)
        .firstMatch(s) ??
        RegExp(
                r'(?:تومان|ریال)\s*(?:[/|،,]\s*)?(کیلوگرم|کیلو|شاخه|عدد|برگ|رول|تن|متر\s*مربع|مترمربع|متر)(?![\p{L}])',
                unicode: true)
            .firstMatch(s);
    return m == null ? 'unknown' : parseUnit(m[1]!);
  }

  static String terms(String text) => RegExp(
          r'[^\n]*(?:نقد|اعتبار|چک|تسویه|اقساط|تحویل|بارگیری|حداقل\s*سفارش|پیش\s*پرداخت|حمل|کرایه|بندیل|بندل|خرده\s*فروشی|عمده\s*فروشی)[^\n]*')
      .allMatches(text)
      .map((m) => m[0]!.trim())
      .where((s) => s.length < 260)
      .take(8)
      .join('؛ ');
  static String tax(String text) {
    final without = RegExp(
            r'بدون\s*(?:ارزش\s*افزوده|مالیات)|ارزش\s*افزوده\s*جدا|به\s*علاوه\s*(?:مالیات|ارزش\s*افزوده)')
        .hasMatch(text);
    final included =
        RegExp(r'(?:با|شامل|احتساب)\s*(?:ارزش\s*افزوده|مالیات)').hasMatch(text);
    return without == included
        ? 'نامشخص'
        : without
            ? 'بدون ارزش افزوده'
            : 'با ارزش افزوده';
  }

  static DateTime? dateIn(String text) {
    final s = latin(text);
    final m = RegExp(
            r'(?:1[34]\d{2})[/.\-]\d{1,2}[/.\-]\d{1,2}(?:\s+(?:ساعت\s*)?\d{1,2}:\d{2})?|\d{1,2}\s+(?:فروردین|اردیبهشت|خرداد|تیر|مرداد|شهریور|مهر|آبان|آذر|دی|بهمن|اسفند)\s+(?:ماه\s+)?1[34]\d{2}|20\d{2}-\d{2}-\d{2}(?:T[^\s]+)?')
        .firstMatch(s);
    return m == null ? null : sourceDate(m[0]!);
  }

  static final datePattern = RegExp(
      r'(?:1[34]\d{2})[/.\-]\d{1,2}[/.\-]\d{1,2}|\d{1,2}\s+(?:فروردین|اردیبهشت|خرداد|تیر|مرداد|شهریور|مهر|آبان|آذر|دی|بهمن|اسفند)\s+(?:ماه\s+)?1[34]\d{2}|20\d{2}-\d{2}-\d{2}');
  static final priceNumber = RegExp(
      r'(?<![\d.])(?:\d+(?:[.٫]\d+)?(?=\s*(?:هزار|میلیون)\s*(?:تومان|ریال))|(?:\d{1,3}(?:[,٬.]\d{3})+|\d{1,3}(?: \d{3})+)|\d{4,9}|\d{1,3}(?=\s*(?:تومان|ریال)))(?:٫\d+)?(?![\d.,٬])');
  static double? money(String raw) => number(raw
      .replaceAll('.', '')
      .replaceAll('٬', '')
      .replaceAll(',', '')
      .replaceAll(' ', ''));

  static String monetaryMask(String line) {
    var masked = line;
    final protected = <List<int>>[];
    for (final m in RegExp(
            r'(?:ضخامت|سایز|قطر|نمره|عرض|ارتفاع|طول|وزن|میلگرد(?: بستر)?|حرارتی|تیر\s*آهن|تیراهن|نبشی|ناودانی|ورق\s*(?:(?:آهن|سیاه|روغنی|گالوانیزه|رنگی|آجدار|استیل|گرم|سرد|برشی|فابریک)\s*)*)\s*[:：]?\s*(\d+(?:[.٫]\d+)?)')
        .allMatches(line)) {
      if (RegExp(r'^\s*(?:(?:هزار|میلیون)\s*)?(?:تومان|ریال)')
          .hasMatch(line.substring(m.end))) continue;
      protected.add([m.end - m[1]!.length, m.end]);
    }
    for (final m in RegExp(
            r'\d+(?:[.٫]\d+)?\s*[x×*]\s*\d+(?:[.٫]\d+)?(?:\s*[x×*]\s*\d+(?:[.٫]\d+)?)?',
            caseSensitive: false)
        .allMatches(line)) {
      protected.add([m.start, m.end]);
    }
    for (final range in protected) {
      masked =
          masked.replaceRange(range[0], range[1], ' ' * (range[1] - range[0]));
    }
    return masked;
  }

  static List<Quote> analyze(
      {required String text,
      required String endpoint,
      required String seller,
      required String sourceUrl,
      required DateTime fetchedAt,
      required String postId,
      String sellerCity = 'نامشخص',
      DateTime? publishedAt,
      bool image = false,
      bool manual = false}) {
    if (text.length > 120000) {
      throw const FormatException(
          'متن بیش از حد بزرگ است؛ پیام‌ها را جدا وارد کنید.');
    }
    final normalized = normalize(text);
    final lines =
        normalized.split('\n').where((s) => s.trim().isNotEmpty).toList();
    // A buy bid is not a published selling price. Do not turn service labor
    // amounts in these observed channel posts into steel market quotations.
    if (lines.isNotEmpty &&
        RegExp(r'خریداریم').hasMatch(lines.first) &&
        !RegExp(r'فروش|عرضه').hasMatch(normalized)) return [];
    final out = <Quote>[];
    String heading = '',
        contextCategory = '',
        contextCurrency = 'نامشخص',
        contextUnit = 'unknown';
    String globalUnit = 'unknown', globalCurrency = 'نامشخص';
    String? pending;
    DateTime? priceDate;
    bool invalidDate = false;
    String datePrecision = 'نامشخص', dateBasis = 'تاریخ صریح داخل متن';
    final allTerms = terms(normalized), allTax = tax(normalized);
    var lastPriceIndex = -1, lastBasisIndex = -1;
    final occurrences = <String, int>{};
    for (var index = 0; index < lines.length && out.length < 300; index++) {
      var line = lines[index].trim();
      final inDate = datePattern.hasMatch(line);
      if (inDate) {
        priceDate = dateIn(line);
        dateBasis = 'تاریخ صریح داخل متن';
        datePrecision =
            RegExp(r'\d{1,2}:\d{2}').hasMatch(line) ? 'زمان' : 'روز';
        invalidDate = priceDate ==
            null; // invalid explicit date MUST NOT inherit a prior valid date
        pending = null;
        if (lastPriceIndex >= 0 && lastBasisIndex <= lastPriceIndex) {
          contextUnit = globalUnit = 'unknown';
          contextCurrency = globalCurrency = 'نامشخص';
        }
        if (product.hasMatch(line) && line.length < 150) {
          heading = datePattern.stringMatch(line) == line ? heading : line;
        }
        line = line.replaceAll(datePattern, ' ').trim();
      }
      final relative =
          RegExp(r'(?:قیمت|نرخ|تاریخ)\s*(?:روز\s*)?(امروز|دیروز)(?:\s|[:：]|$)')
              .firstMatch(line);
      if (!inDate && relative != null && publishedAt != null) {
        priceDate = sourceDate(dateLabel(publishedAt, time: false))!
            .subtract(Duration(days: relative[1] == 'دیروز' ? 1 : 0));
        datePrecision = 'روز';
        dateBasis = 'تاریخ نسبی از زمان انتشار پیام';
        invalidDate = false;
      }
      if (line.isEmpty) continue;
      if (RegExp(r'^https?://|^@|(?:تلفن|تماس|همراه|شماره|☎|📞|📱|داخلی|عضو|مشترک|مشاهده|کد\s*پستی)')
              .hasMatch(line) &&
          !product.hasMatch(line) &&
          !RegExp(r'سایز|ضخامت').hasMatch(line)) {
        pending = null;
        continue;
      }
      if (RegExp(r'کاهش|افزایش|تغییر|تخفیف|اجرت|کرایه|هزینه حمل|دوبله کردن')
              .hasMatch(line) &&
          !RegExp(r'سایز|ضخامت|قیمت|⬅').hasMatch(line)) continue;
      if (RegExp(r'تأسیس|تاسیس|بهره برداری|کارمند|تولیدکننده|ظرفیت تولید')
              .hasMatch(line) &&
          !RegExp(r'تومان|ریال|قیمت|نرخ|💰').hasMatch(line)) continue;
      if (RegExp(
              r'خریداریم|خریدار\s+(?:تیر|میلگرد|ورق|آهن)|دستمزد|اجرت\s+(?:دوبل|برش|خم|جوش)|دوبله\s*کردن')
          .hasMatch(line)) {
        pending = null;
        continue;
      }
      final cat = category(line);
      if (cat.isEmpty &&
          RegExp(r'حداقل\s*سفارش|^وزن|^طول|^تعداد|^بارگیری').hasMatch(line)) {
        continue;
      }
      final lineCurrency = currency(line);
      final lineUnit = priceUnit(line);
      final numbers = priceNumber.allMatches(monetaryMask(line)).where((m) {
        final raw = m[0]!.replaceAll(RegExp(r'[,٬. ]'), '');
        if (RegExp(r'^0\d{9,10}$').hasMatch(raw)) return false;
        final before = line.substring(0, m.start),
            after = line.substring(m.end);
        if (RegExp(r'[x×*]\s*$', caseSensitive: false).hasMatch(before) ||
            RegExp(r'^\s*[x×*]', caseSensitive: false).hasMatch(after)) {
          return false;
        }
        if (RegExp(
                r'^\s*(?:کیلوگرم|کیلو|میلی\s*متر|سانتی\s*متر|mm|cm|متر|تن|تایی|عدد|میل|هکتار|نفر|دستگاه|درصد)(?:\s|$|[،,؛:])')
            .hasMatch(after)) return false;
        if (RegExp(
                r'(?:وزن|طول|عرض|ارتفاع|ابعاد|ضخامت|سایز|قطر|نمره|بار|کیلوگرم|تعداد|شاخه|سال)\s*[:：]?\s*$')
            .hasMatch(before)) return false;
        if (RegExp(r'(?:کاهش|افزایش|تغییر|تخفیف|🔻|🔺|⬇|⬆)\s*$')
            .hasMatch(before)) return false;
        return true;
      }).toList();
      final onlyContext = numbers.isEmpty;
      if (onlyContext) {
        if (cat.isEmpty &&
            contextCategory.isNotEmpty &&
            RegExp(r'ضخامت|سایز|ابعاد|قطر|نمره').hasMatch(line)) pending = line;
        if (cat.isNotEmpty) {
          heading = line;
          contextCategory = cat;
          pending = line;
          // Product group boundary must not inherit unit/currency from the previous product.
          contextUnit = globalUnit;
          contextCurrency = globalCurrency;
        }
        if (lineCurrency != 'نامشخص' &&
            RegExp(r'قیمت|مبنا|واحد|نرخ|تومان|ریال').hasMatch(line)) {
          contextCurrency = lineCurrency;
          lastBasisIndex = index;
          if (cat.isEmpty) globalCurrency = lineCurrency;
        }
        if (lineUnit != 'unknown') {
          contextUnit = lineUnit;
          lastBasisIndex = index;
          if (cat.isEmpty) globalUnit = lineUnit;
        }
        continue;
      }
      final descriptor = cat.isNotEmpty ||
          RegExp(r'سایز|ضخامت|ابعاد|نمره|حرارتی|آجدار|ساده|\d+(?:[.٫]\d+)?\s*میل|A[1-4]|ST(?:37|52)',
                  caseSensitive: false)
              .hasMatch(line);
      final candidate = descriptor
          ? line
          : pending == null
              ? ''
              : '$pending $line';
      if (candidate.isEmpty ||
          (cat.isEmpty &&
              contextCategory.isEmpty &&
              category(candidate).isEmpty)) {
        pending = null;
        continue;
      }
      // A plain number after a model is a candidate, not a verified comparable rate.
      // More than one unlabelled number is ambiguous; never guess which is the price.
      final labelled = numbers
          .where((m) =>
              RegExp(r'^\s*(?:تومان|ریال)').hasMatch(line.substring(m.end)))
          .toList();
      final range = numbers.length == 2 &&
          RegExp(r'^(?:تا|الی|–|-|—)$').hasMatch(
              line.substring(numbers.first.end, numbers.last.start).trim());
      final candidates = range
          ? numbers
          : labelled.isNotEmpty
              ? labelled
              : numbers;
      if ((!range && numbers.length != 1) || candidates.isEmpty) {
        pending = null;
        continue;
      }
      final chosen = candidates.first;
      final scale = RegExp(r'^\s*(هزار|میلیون)\s*(?:تومان|ریال)')
          .firstMatch(line.substring(chosen.end));
      final value = scale == null
          ? money(chosen[0]!)
          : (number(chosen[0]!) ?? double.nan) *
              (scale[1] == 'میلیون' ? 1000000 : 1000);
      if (value == null || !value.isFinite || value <= 0) {
        pending = null;
        continue;
      }
      var cur = lineCurrency;
      if (cur == 'نامشخص' &&
          !line.contains('ریال') &&
          !line.contains('تومان')) {
        cur = contextCurrency;
      }
      final unit = lineUnit == 'unknown' ? contextUnit : lineUnit;
      final productCategory = cat.isNotEmpty
          ? cat
          : category(candidate).isNotEmpty
              ? category(candidate)
              : contextCategory;
      var model = (descriptor ? line.substring(0, chosen.start) : pending!)
          .replaceAll(RegExp(r'[:：=⬅️✅🔹▫️💰]+', unicode: true), ' ')
          .trim();
      if (model.isEmpty) model = heading;
      final sizeMatch = RegExp(
              r'(?:سایز|نمره|میلگرد|حرارتی|تیرآهن|تیر آهن|نبشی|ناودانی)\s*(\d+(?:[٫.]\d+)?(?:\s*[,/و]\s*\d+(?:[٫.]\d+)?)*)')
          .firstMatch(model);
      final sharedSpec = ProductText.spec(model, categoryHint: productCategory);
      final thick = sharedSpec.thickness.isEmpty ? null : sharedSpec.thickness;
      final dims = RegExp(
              r'\d+(?:\.\d+)?\s*[x×*]\s*\d+(?:\.\d+)?(?:\s*[x×*]\s*\d+(?:\.\d+)?)?',
              caseSensitive: false)
          .firstMatch(model)?[0];
      final grade = sharedSpec.grade.isNotEmpty
          ? sharedSpec.grade
          : ProductText.spec(heading).grade;
      // Multiple sizes are retained as a group, not expanded into invented independent offers.
      final spec =
          '$productCategory|$heading|$model|$unit|$cur|${priceDate?.toIso8601String() ?? ''}';
      final count = occurrences.update(spec, (n) => n + 1, ifAbsent: () => 0);
      final identity = '$endpoint:$postId:${key(spec)}:$count';
      final priceTime = priceDate;
      final dateIssue = invalidDate ? 'تاریخ صریح نامعتبر' : '';
      final loading = RegExp(r'(?:انبار|تحویل|بارگیری)\s*[:：]?\s*([^\n]{2,65})')
              .firstMatch('$heading\n$normalized')?[0] ??
          'نامشخص';
      final issues = <String>[
        if (cur == 'نامشخص') 'ارز اعلام نشده/متعارض',
        if (unit == 'unknown') 'مبنای واحد قیمت اعلام نشده',
        if (range) 'بازه قیمت؛ نه مبلغ یکتای قابل مقایسه',
        if (dateBasis.contains('نسبی')) dateBasis,
        if (priceTime == null && publishedAt == null)
          'تاریخ معتبر در دسترس نیست',
        if (dateIssue.isNotEmpty) dateIssue,
        if (manual) 'متن ورودی کاربر؛ دریافت مستقل منبع تأیید نشده',
      ];
      out.add(Quote(
          id: identity,
          endpoint: endpoint,
          seller: seller,
          sellerCity: sellerCity,
          title: model.contains(productCategory)
              ? model
              : '$productCategory $model',
          category: productCategory,
          unit: unit,
          currency: cur,
          amount: cur == 'نامشخص' || range ? null : value,
          lengthM: number(RegExp(r'(?:طول(?: شاخه)?|حالت)\s*[:：]?\s*(\d+(?:\.\d+)?)\s*متر')
                  .firstMatch(candidate)?[1] ??
              ''),
          pieceKg: number(
              RegExp(r'وزن\s*(?:هر|یک)?\s*(?:شاخه|برگ|رول)\s*[:：]?\s*(\d+(?:\.\d+)?)\s*کیلو')
                      .firstMatch(candidate)?[1] ??
                  ''),
          tax: tax(candidate) == 'نامشخص' ? allTax : tax(candidate),
          terms: allTerms.isEmpty ? 'نامشخص' : allTerms,
          brand: brandOf(model).isNotEmpty ? brandOf(model) : brandOf(heading),
          material: materialOf('$heading $model'),
          areaM2: number(RegExp(r'مساحت\s*(?:(?:هر|یک)\s*(?:برگ|ورق|شاخه)\s*)?[:：]?\s*(\d+(?:\.\d+)?)\s*متر\s*مربع')
                  .firstMatch(candidate)?[1] ??
              ''),
          loading: loading,
          sourceUrl: sourceUrl,
          fetchedAt: fetchedAt,
          sourceDateRaw: priceTime?.toIso8601String() ?? '',
          size: sizeMatch?[1] ?? (sharedSpec.size.isEmpty ? null : sharedSpec.size),
          thickness: thick,
          dimensions: dims,
          grade: grade,
          status: issues.isEmpty ? 'استخراج متنی با مبلغ/ارز/واحد صریح؛ موجودی نیازمند تأیید' : issues.join('؛ '),
          details: {
            'تحلیل متن': 'محلی v$version',
            'متن پیام': text,
            if (heading.isNotEmpty) 'سرعنوان گروه': heading,
            if (RegExp(r'عرض\s*[:：]?\s*(\d+(?:\.\d+)?)').hasMatch(model))
              'عرض': RegExp(r'عرض\s*[:：]?\s*(\d+(?:\.\d+)?)')
                  .firstMatch(model)![1]!,
            'شاهد ردیف': candidate,
            'مبلغ استخراج‌شده': range
                ? '${numbers.first[0]} تا ${numbers.last[0]}'
                : chosen[0]!,
            if (invalidDate) 'تاریخ نامعتبر': 'بله',
            'مبنای ارز': cur,
            'مبنای واحد': unit == 'piece' && productCategory == 'بولت'
                ? 'عدد / ست'
                : unitLabel(unit),
            'زمان انتشار پیام': publishedAt?.toUtc().toIso8601String() ?? '',
            'دقت تاریخ نرخ': datePrecision,
            'مبنای تاریخ': priceTime != null
                ? dateBasis
                : publishedAt != null
                    ? 'زمان انتشار؛ تاریخ خود نرخ تصریح نشده'
                    : 'نامشخص',
            'وضعیت استخراج': issues.isEmpty ? 'صریح' : issues.join('؛ '),
            if (manual) 'ورودی دستی': 'بله',
            if (image) 'قالب': 'متن همراه تصویر؛ تصویر OCR نشده'
          }));
      lastPriceIndex = index;
      pending = null;
    }
    if (out.isEmpty && (product.hasMatch(normalized) || image)) {
      out.add(Quote(
          id: '$endpoint:$postId',
          endpoint: endpoint,
          seller: seller,
          sellerCity: sellerCity,
          title: normalized.length > 110
              ? String.fromCharCodes(normalized.runes.take(110))
              : normalized,
          category:
              category(normalized).isEmpty ? 'عمومی' : category(normalized),
          unit: 'unknown',
          currency: 'نامشخص',
          fetchedAt: fetchedAt,
          sourceUrl: sourceUrl,
          sourceDateRaw: priceDate?.toIso8601String() ?? '',
          status: image
              ? 'فهرست تصویری/متن فاقد مبلغ روشن؛ OCR انجام نشده'
              : 'متن فاقد مبلغ یکتای قابل استخراج',
          details: {
            if (invalidDate) 'تاریخ نامعتبر': 'بله',
            'متن پیام': text,
            if (heading.isNotEmpty) 'سرعنوان گروه': heading,
            'زمان انتشار پیام': publishedAt?.toUtc().toIso8601String() ?? '',
            'قالب': image ? 'تصویر' : 'متن',
            'تحلیل متن': 'محلی v$version',
            if (manual) 'ورودی دستی': 'بله'
          }));
    }
    return out;
  }
}
