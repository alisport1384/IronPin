import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;
import '../domain/market.dart';
import '../domain/text_engine.dart';
import '../domain/product_text.dart';

/// Header-driven tables, not a guessed endpoint or platform-specific JSON API.
/// Only explicit table/cell currency is authoritative; page receipt is not rate time.
class PublicTables {
  static List<Quote> read(
      {required String body,
      required String url,
      required String endpoint,
      required String seller,
      required String city,
      required String category,
      required DateTime fetchedAt}) {
    final doc = html.parse(body), out = <Quote>[];
    DateTime? precedingDate;
    String rawDate = '', sheetKind = '';
    String precedingTax = 'نامشخص';
    var tableIndex = 0;
    final seen = <String, int>{};
    void table(Element table) {
      final rows = table.querySelectorAll('tr');
      List<String>? headers;
      for (final row in rows) {
        final cells = row.children
            .where((e) => e.localName == 'th' || e.localName == 'td')
            .toList();
        final text = cells.map((c) => latin(c.text)).toList();
        if (text.any((s) => s.contains('قیمت')) &&
            ((text.any((s) => s.contains('واحد')) &&
                    text.any((s) =>
                        s.contains('ضخامت') ||
                        s.contains('نام کالا') ||
                        s.contains('محصول') ||
                        s.contains('اسم'))) ||
                (text.any((s) => s.contains('محصول')) &&
                    text.any((s) => s.contains('تاریخ'))))) {
          headers = text;
          continue;
        }
        if (headers == null || cells.length != headers.length) continue;
        String field(String pattern) {
          final i = headers!.indexWhere((h) => RegExp(pattern).hasMatch(h));
          return i < 0 ? '' : text[i];
        }

        var title = text
                .where((s) =>
                    ProductText.category(s).isNotEmpty &&
                    (category == 'عمومی' ||
                        ProductText.category(s) == category))
                .firstOrNull ??
            '';
        if (title.isEmpty) continue;
        final anchor = cells
            .expand((c) => c.querySelectorAll('a'))
            .where((a) => ProductText.category(a.text).isNotEmpty)
            .firstOrNull;
        if (anchor != null) title = latin(anchor.text);
        final rowCategory = ProductText.category(title);
        if (rowCategory == 'ورق' &&
            sheetKind.isNotEmpty &&
            !title.contains(sheetKind)) {
          title = title.replaceFirst('ورق', 'ورق $sheetKind');
        }
        final price = field(r'^قیمت(?:\s|\(|$)');
        final priceHeader = headers.firstWhere(
            (h) => RegExp(r'^قیمت(?:\s|\(|$)').hasMatch(h),
            orElse: () => '');
        final cur = TextPriceEngine.currency('$priceHeader $price');
        final prices = RegExp(
                r'(?<![\d.])(?:\d{1,3}(?:[,٬.]\d{3})+(?:٫\d+)?|\d{1,3}(?: \d{3})+|\d+(?:[٫.]\d+)?)(?![\d.,٬])')
            .allMatches(price)
            .toList();
        final rawPrice = prices.length == 1 ? prices.single[0]! : price;
        final amount = RegExp(r'استعلام|تماس|ناموجود').hasMatch(price) ||
                prices.length != 1
            ? null
            : TextPriceEngine.money(rawPrice);
        final valid = amount != null && amount.isFinite && amount > 0;
        final spec = ProductText.spec(title, categoryHint: rowCategory);
        final unitText = field('واحد'), unit = parseUnit(unitText);
        final thicknessRaw = field('ضخامت');
        final thickness = number(thicknessRaw)?.toString() ?? spec.thickness;
        final width = field('عرض'), length = field('طول');
        final lengthHeader =
            headers.firstWhere((h) => h.contains('طول'), orElse: () => '');
        final dims = field('ابعاد').isNotEmpty
            ? field('ابعاد')
            : ProductText.dimension.hasMatch(field('سایز'))
                ? ProductText.dimension.stringMatch(field('سایز'))!
                : (width.isNotEmpty && length.isNotEmpty
                    ? '$length × $width'
                    : '');
        final rowDate = field('تاریخ|بروزرسانی|به روز'),
            announced =
                rowDate.isNotEmpty ? sourceDate(rowDate) : precedingDate;
        final brand = field('برند|کارخانه|تولید کننده'),
            grade = field('گرید|استاندارد');
        final scope = table.querySelector('caption')?.text ?? '';
        final identity = '$tableIndex|$title|$brand|$dims|$unit|$cur';
        final count = seen.update(identity, (v) => v + 1, ifAbsent: () => 0);
        final issues = [
          if (!valid)
            prices.length > 1
                ? 'مبلغ چندگانه؛ مبنای واحد/مالیات روشن نیست'
                : 'تماس/استعلام؛ نه قیمت صفر',
          if (cur == 'نامشخص') 'ارز جدول تصریح نشده',
          if (unit == 'unknown') 'واحد قیمت تصریح نشده',
          if (announced == null) 'تاریخ نرخ نامشخص'
        ];
        out.add(Quote(
            id: '$endpoint:${TextPriceEngine.key(identity)}:$count',
            endpoint: endpoint,
            seller: seller,
            sellerCity: city,
            title: title,
            category: rowCategory,
            brand: brand.isEmpty ? 'نامشخص' : brand,
            grade: grade.isEmpty ? null : grade,
            thickness: thickness,
            dimensions: dims,
            amount: valid && cur != 'نامشخص' ? amount : null,
            currency: cur,
            unit: unit,
            fetchedAt: fetchedAt,
            sourceUrl: url,
            sourceDateRaw: announced?.toIso8601String() ?? '',
            loading: scope.isEmpty ? 'نامشخص' : scope,
            material: materialOf(title),
            tax: TextPriceEngine.tax(field('مالیات|ارزش افزوده')) == 'نامشخص'
                ? precedingTax
                : TextPriceEngine.tax(field('مالیات|ارزش افزوده')),
            terms:
                field('شرایط|تسویه').isEmpty ? 'نامشخص' : field('شرایط|تسویه'),
            lengthM: RegExp(r'\bm\b|متر').hasMatch(lengthHeader)
                ? number(length)
                : null,
            status: issues.isEmpty
                ? 'جدول عمومی؛ موجودی نیازمند تأیید'
                : issues.join('؛ '),
            details: {
              for (var i = 0; i < headers.length; i++)
                if (headers[i].isNotEmpty) headers[i]: text[i],
              if (valid || prices.length > 1) 'مبلغ استخراج‌شده': rawPrice,
              if (prices.length > 1) 'مبلغ چندگانه': 'بله',
              if (rowDate.isNotEmpty && announced == null)
                'تاریخ نامعتبر': 'بله',
              'مبنای ارز': cur == 'نامشخص'
                  ? 'نامشخص؛ از نام سایت حدس زده نشد'
                  : 'سرستون/سلول قیمت',
              'مبنای واحد': unit == 'unknown' ? 'نامشخص' : 'سلول واحد جدول',
              'مبنای تاریخ': announced == null
                  ? 'نامشخص'
                  : rowDate.isNotEmpty
                      ? 'تاریخ ردیف جدول'
                      : 'تاریخ صریح پیش از جدول',
              if (announced != null) 'دقت تاریخ نرخ': 'روز',
              if (rawDate.isNotEmpty)
                'تاریخ متن منبع': rowDate.isNotEmpty ? rowDate : rawDate,
              'شاهد ردیف': text.join(' | '),
              'حدود منبع': 'جدول عمومی؛ انتشار مستقل پیام در دسترس نیست'
            }));
      }
      tableIndex++;
    }

    void visit(Node node) {
      if (node is Element) {
        if (['script', 'style', 'nav', 'footer', 'noscript', 'time']
            .contains(node.localName)) return;
        if (node.localName == 'table') {
          table(node);
          return;
        }
        final text = latin(node.text);
        if (RegExp(r'^h[1-6]$').hasMatch(node.localName ?? '') &&
            ProductText.category(text).isNotEmpty) {
          precedingDate = null;
          rawDate = '';
          precedingTax = 'نامشخص';
        }
        if (text.length < 120 && TextPriceEngine.tax(text) != 'نامشخص') {
          precedingTax = TextPriceEngine.tax(text);
        }
        if (text.length < 120 &&
            text.contains('ورق') &&
            (RegExp(r'^h[1-6]$').hasMatch(node.localName ?? '') ||
                text.startsWith('لیست قیمت'))) {
          sheetKind =
              RegExp('سیاه|روغنی|گالوانیزه|آجدار|استیل').firstMatch(text)?[0] ??
                  '';
        }
        // Only a small dated block preceding the table, never a whole article
        // with a date somewhere in its footer, is a price-date candidate.
        if (text.length < 120 && TextPriceEngine.datePattern.hasMatch(text)) {
          final bare = TextPriceEngine.datePattern.stringMatch(text);
          if (text == bare ||
              RegExp(r'^(?:شنبه|یکشنبه|دوشنبه|سه\s*شنبه|چهارشنبه|پنج\s*شنبه|جمعه)\s')
                  .hasMatch(text) ||
              RegExp('تاریخ|بروزرسانی|به روز|لیست قیمت').hasMatch(text)) {
            precedingDate = TextPriceEngine.dateIn(text);
            rawDate = text;
          }
        }
      }
      for (final child in node.nodes) {
        visit(child);
      }
    }

    visit(doc.body ?? doc);
    return out;
  }
}
