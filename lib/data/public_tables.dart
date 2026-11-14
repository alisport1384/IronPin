import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;
import '../domain/market.dart';
import '../domain/text_engine.dart';
import '../domain/product_text.dart';

/// Header-driven tables, not a guessed endpoint or platform-specific JSON API.
/// Only explicit table/cell currency is authoritative; page receipt is not rate time.
class PublicTables {
  static final _priceColumn = RegExp(r'^قیمت(?:\s|\(|$)');
  // A column that describes the thing sold. A date column alone does not: a
  // table of dates and prices is the history of one price, not a price list.
  static final _attributeColumn = RegExp(
      'سایز|ضخامت|برند|کارخانه|تولید کننده|استاندارد|آنالیز|محل تحویل|بارگیری|واحد|حالت|وزن|نام|محصول|کالا|شرح|ابعاد|طول|عرض|گرید');
  static final _statisticColumn =
      RegExp(r'^(?:میانگین|میانه|کمترین|بیشترین|بازه)(?:\s|$)');
  static final _nameLabel = RegExp(r'^\s*نام\s*(?:کالا|محصول)\s*[:：]\s*');

  // A title that announces figures about prices rather than prices on offer.
  static final _statisticTitle =
      RegExp('میانه|میانگین|نمودار|روند|مقایسه|تاریخچه|پیش‌بینی|پیش بینی');

  /// The product a heading or a table caption names, without the words around
  /// it: «قیمت میلگرد ۸» → «میلگرد 8», «قیمت تیرآهن ۱۴ به تفکیک کارخانه» →
  /// «تیرآهن 14». Empty when the text names no product of the vocabulary or is
  /// a sentence rather than a title.
  static String ownerPhrase(String heading) {
    final parts = latin(heading)
        .split(RegExp(r'[|·•:؛(\[+]| - | – '))
        .map((p) => p.trim())
        .where((p) => ProductText.category(p).isNotEmpty);
    if (parts.isEmpty) return '';
    final phrase = parts.first
        .replaceFirst(
            RegExp(r'^(?:(?:جدول|لیست|آخرین)\s+)?قیمت\s+(?:(?:روز|امروز|خرید|فروش)\s+)?'),
            '')
        .replaceFirst(
            RegExp(r'\s+(?:امروز|به تفکیک|در بازار|بازار|همه|تمام|کلیه)(?:\s.*)?$'),
            '')
        .trim();
    // A title names its product first («میلگرد 8», «ورق سیاه»). A phrase
    // that only mentions one («روند تغییرات قیمت پروفیل») is about something
    // else — a trend, a comparison — and owns no rows.
    return phrase.length > 48 ||
            ProductText.product.matchAsPrefix(ProductText.normalize(phrase)) ==
                null
        ? ''
        : phrase;
  }

  /// [headingOwned] is the reading for a seller's website nobody wrote an
  /// adapter for. Such pages rarely repeat the product in every row: the
  /// heading above the table (or its caption) says what the table lists, the
  /// header says which column is the price, and the rows carry size, brand and
  /// amount. In this mode
  ///
  /// * a header is a first/`thead`/all-`th` row with a «قیمت» column and at
  ///   least one describing column; a table of averages and ranges is not a
  ///   price list and is left alone;
  /// * a row may name its product itself, in a hidden «نام کالا : …» cell, or
  ///   inherit it from the table's caption or the nearest title before the
  ///   table (a heading, or the `<header>` of its section) — written by the
  ///   source in each case, and recorded as the basis; a title that announces
  ///   a median, a chart or a comparison owns nothing;
  /// * a one-cell row with a date («آخرین بروز رسانی : …») dates the table, and
  ///   a unit written in the price header («قیمت (تومان/کیلو)») is the unit;
  /// * when one heading owns several tables whose rows cannot be told apart
  ///   (no brand, no product in the row), none of them is read: their
  ///   difference is somewhere this reader cannot see.
  ///
  /// Nothing else changes: currency still comes only from the header or the
  /// cell, an amount without it stays a text amount, and a date is never taken
  /// from the time of reading.
  static List<Quote> read(
      {required String body,
      required String url,
      required String endpoint,
      required String seller,
      required String city,
      required String category,
      required DateTime fetchedAt,
      bool inlinePriceUnits = false,
      bool headingOwned = false}) {
    final doc = html.parse(body), out = <Quote>[];
    DateTime? precedingDate;
    String rawDate = '', sheetKind = '';
    String precedingTax = 'نامشخص';
    var tableIndex = 0;
    final seen = <String, int>{};
    // Heading-owned reading: the product phrase of the nearest heading that
    // names one, and the tables that depend on it alone.
    var owner = '';
    final owned = <String, List<List<Quote>>>{};
    void table(Element table) {
      final rows = table.querySelectorAll('tr');
      List<String>? headers;
      final caption = headingOwned
          ? ownerPhrase(table.querySelector('caption')?.text ?? '')
          : '';
      // Of a caption and the heading before the table, the one that says
      // more: «تیرآهن 14» rather than «تیرآهن».
      final tableOwner = caption.isEmpty || owner.contains(caption)
          ? owner
          : caption;
      DateTime? tableDate;
      var tableDateRaw = '';
      if (headingOwned) {
        for (final row in rows) {
          final only = row.children
              .where((e) => e.localName == 'th' || e.localName == 'td')
              .toList();
          if (only.length != 1) continue;
          final t = latin(only.single.text);
          if (t.length < 200 &&
              RegExp('بروز|به روز|تاریخ').hasMatch(t) &&
              TextPriceEngine.datePattern.hasMatch(t)) {
            tableDate = TextPriceEngine.dateIn(t);
            tableDateRaw = TextPriceEngine.datePattern.stringMatch(t) ?? '';
            if (tableDate != null) break;
          }
        }
      }
      final local = <Quote>[];
      var inherited = false, rowIndex = -1;
      for (final row in rows) {
        rowIndex++;
        final cells = row.children
            .where((e) => e.localName == 'th' || e.localName == 'td')
            .toList();
        final text = cells.map((c) => latin(c.text)).toList();
        if (text.any((s) => s.contains('قیمت')) &&
            ((inlinePriceUnits && text.any((s) => s.contains('محصول'))) ||
                (text.any((s) => s.contains('واحد')) &&
                    text.any((s) =>
                        s.contains('ضخامت') ||
                        s.contains('نام کالا') ||
                        s.contains('محصول') ||
                        s.contains('اسم'))) ||
                (text.any((s) => s.contains('محصول')) &&
                    text.any((s) =>
                        RegExp('تاریخ|بروزرسانی|به روز').hasMatch(s))))) {
          headers = text;
          continue;
        }
        if (headingOwned &&
            headers == null &&
            text.length >= 2 &&
            (rowIndex == 0 ||
                row.parent?.localName == 'thead' ||
                cells.every((c) => c.localName == 'th')) &&
            text.any(_priceColumn.hasMatch) &&
            text.any((s) =>
                !_priceColumn.hasMatch(s) && _attributeColumn.hasMatch(s)) &&
            !text.any(_statisticColumn.hasMatch)) {
          headers = text;
          continue;
        }
        if (headers == null) continue;
        // A hidden detail cell after the described columns is still the row.
        if (cells.length != headers.length &&
            !(headingOwned && cells.length > headers.length)) {
          continue;
        }
        if (text.any(ProductText.isNonMetal)) continue;
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
        var titleBasis = '';
        if (headingOwned) {
          final named = title.replaceFirst(_nameLabel, '');
          if (named != title) {
            title = named;
            titleBasis = 'سلول نام کالا در همان ردیف';
          } else if (title.isEmpty && tableOwner.isNotEmpty) {
            // The heading names the product; the row adds what tells it apart.
            final size = field(r'^(?:سایز|ابعاد)'),
                maker = field('برند|کارخانه|تولید کننده');
            title = [
              tableOwner,
              if (size.isNotEmpty && !tableOwner.contains(size)) size,
              if (maker.isNotEmpty && !tableOwner.contains(maker)) maker
            ].join(' ');
            titleBasis = tableOwner == caption
                ? 'عنوان جدول'
                : 'سرعنوان پیش از جدول';
            if (maker.isEmpty) inherited = true;
          }
        }
        if (title.isEmpty) continue;
        final heading = cells
            .expand((c) => c.querySelectorAll('h3,h4'))
            .where((h) => ProductText.category(h.text).isNotEmpty)
            .firstOrNull;
        final anchor = cells
            .expand((c) => c.querySelectorAll('a'))
            .where((a) => ProductText.category(a.text).isNotEmpty)
            .firstOrNull;
        if (heading != null) {
          title = latin(heading.text);
        } else if (anchor != null) {
          title = latin(anchor.text);
        }
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
        final unitText = field(r'^واحد(?:\s|$)');
        final cellUnit = parseUnit(unitText);
        final headerUnit =
            headingOwned ? TextPriceEngine.priceUnit(priceHeader) : 'unknown';
        final unit = cellUnit != 'unknown'
            ? cellUnit
            : inlinePriceUnits
                ? TextPriceEngine.priceUnit(price)
                : headerUnit;
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
            announced = rowDate.isNotEmpty
                ? sourceDate(rowDate)
                : (tableDate ?? precedingDate);
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
        local.add(Quote(
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
            loading: field('بارگیری|محل تحویل').isNotEmpty
                ? field('بارگیری|محل تحویل')
                : scope.isEmpty
                    ? 'نامشخص'
                    : scope,
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
              'مبنای واحد': unit == 'unknown'
                  ? 'نامشخص'
                  : cellUnit != 'unknown'
                      ? 'سلول واحد جدول'
                      : inlinePriceUnits
                          ? 'عبارت صریح هر واحد در سلول قیمت'
                          : 'واحد نوشته‌شده در سرستون قیمت',
              'مبنای تاریخ': announced == null
                  ? 'نامشخص'
                  : rowDate.isNotEmpty
                      ? 'تاریخ ردیف جدول'
                      : tableDate != null
                          ? 'تاریخ نوشته‌شده درون جدول'
                          : 'تاریخ صریح پیش از جدول',
              if (announced != null) 'دقت تاریخ نرخ': 'روز',
              if (titleBasis.isNotEmpty) 'مبنای نام کالا': titleBasis,
              if (rowDate.isEmpty && tableDate != null)
                'تاریخ متن منبع': tableDateRaw
              else if (rawDate.isNotEmpty)
                'تاریخ متن منبع': rowDate.isNotEmpty ? rowDate : rawDate,
              'شاهد ردیف': text.join(' | '),
              'حدود منبع': 'جدول عمومی؛ انتشار مستقل پیام در دسترس نیست'
            }));
      }
      tableIndex++;
      if (inherited) {
        owned.putIfAbsent(tableOwner, () => []).add(local);
      } else {
        out.addAll(local);
      }
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
        if ((inlinePriceUnits ? RegExp(r'^h[12]$') : RegExp(r'^h[1-6]$'))
                .hasMatch(node.localName ?? '') &&
            ProductText.category(text).isNotEmpty) {
          precedingDate = null;
          rawDate = '';
          precedingTax = 'نامشخص';
        }
        // The title of what follows: a heading, or the <header> a section
        // gives itself. One that names a product owns the tables after it;
        // one that announces a median, a chart or a comparison disowns them.
        if (headingOwned &&
            text.length < 160 &&
            RegExp(r'^(?:h[1-6]|header)$').hasMatch(node.localName ?? '')) {
          if (_statisticTitle.hasMatch(text)) {
            owner = '';
          } else {
            final phrase = ownerPhrase(node.text);
            if (phrase.isNotEmpty) owner = phrase;
          }
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
    for (final tables in owned.values) {
      // One heading, one indistinguishable table: its rows are that product.
      // Several: what separates them is not written where it can be read.
      if (tables.length == 1) out.addAll(tables.single);
    }
    return out;
  }
}
