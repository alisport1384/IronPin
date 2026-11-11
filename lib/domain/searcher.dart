import 'market.dart';
import 'maps_link.dart';
import 'maps_resolver.dart';
import 'phone_city.dart';
import 'product_schema.dart';
import 'product_text.dart';

/// One searcher intelligence.
///
/// Everything the reader does after a post or an image has been turned into a
/// list of quotes happens here and nowhere else: the parent time window, the
/// product vocabulary, the price that must belong to a product, the place the
/// seller wrote (address, map, phone), the order the rows are published in, and
/// the duplicates that must not be stored twice.
///
/// Two rules are deliberate:
///
///  * it never writes prose into the archive. A row that carries neither a
///    product nor a price is dropped instead of being saved as a sentence;
///  * it never guesses a place. Each place is one of four written evidence
///    kinds, the strongest wins, and a disagreement is recorded instead of being
///    silently resolved.
class SearcherResult {
  final List<Quote> quotes;
  final int outOfWindow, noise, duplicates;
  const SearcherResult(this.quotes,
      {this.outOfWindow = 0, this.noise = 0, this.duplicates = 0});

  Map<String, int> get categories => Searcher.categoryCounts(quotes);
  int get kept => quotes.length;

  String get summary =>
      'نگه‌داشته ${quotes.length} • خارج از بازه $outOfWindow • بی‌محصول/بی‌قیمت $noise • تکراری $duplicates';
}

class Searcher {
  /// The parent window of the app: the days the user set under the cities
  /// section. Every read of a post is measured against it.
  final int windowDays;
  const Searcher({this.windowDays = 30});

  // ---------------------------------------------------------------- time window

  /// When the row itself says the price was valid, else when the post appeared.
  static DateTime? publishedOf(Quote q) {
    final raw = q.details['زمان انتشار پیام'] ?? '';
    final parsed = raw.isEmpty ? null : DateTime.tryParse(raw);
    if (parsed != null) return parsed;
    final own = q.sourceDateRaw;
    return own.isEmpty ? null : DateTime.tryParse(own);
  }

  /// The parent-window test. A row with no date at all is kept (the source
  /// published it now, we simply cannot date it) but marked, never silently
  /// dropped as old.
  static bool insideWindow(Quote q, DateTime now, int days) {
    final at = publishedOf(q);
    if (at == null) return true;
    if (days <= 0) return true;
    final start = now.subtract(Duration(days: days));
    return !at.isBefore(start.subtract(const Duration(days: 1))) &&
        !at.isAfter(now.add(const Duration(days: 1)));
  }

  // -------------------------------------------------------------- product facts

  /// The product vocabulary, applied to one row: family, identity and the
  /// features that belong to that family alone.
  static Quote productKnowledge(Quote q) {
    final facts = ProductFacts.of(q);
    final features = <String, String>{
      for (final e in facts.values.entries)
        if (e.value.trim().isNotEmpty) e.key.trim(): e.value.trim()
    };
    final missing = requiredFeatures(facts.family)
        .where((key) => !features.keys.any((k) => _sameField(k, key)))
        .toList();
    final j = q.toJson();
    final details = Map<String, String>.from(q.details);
    details['خانواده محصول'] = facts.family.isEmpty ? 'نامشخص' : facts.family;
    for (final e in features.entries) {
      details['ویژگی.${e.key}'] = e.value;
    }
    if (facts.family.isNotEmpty) {
      details['ویژگی‌های لازم این خانواده'] =
          requiredFeatures(facts.family).join('، ');
      details['نقص مشخصات'] =
          missing.isEmpty ? 'ندارد' : '${missing.join('، ')} اعلام نشده';
    }
    j['details'] = details;
    return Quote.fromJson(j);
  }

  static bool _sameField(String a, String b) {
    final x = ProductText.normalize(a), y = ProductText.normalize(b);
    return x == y || x.contains(y) || y.contains(x);
  }

  /// What each product family must state to be comparable. A missing field is
  /// reported; it is never filled from the amount or from another row.
  static List<String> requiredFeatures(String family) => switch (family) {
        'میلگرد' => const ['سایز', 'گرید'],
        'تیرآهن' => const ['سایز', 'بال'],
        'نبشی' => const ['ابعاد', 'ضخامت'],
        'ناودانی' => const ['سایز', 'ضخامت'],
        'ورق' => const ['ضخامت', 'ابعاد', 'نوع'],
        'لوله' => const ['سایز', 'ضخامت', 'نوع'],
        'پروفیل' => const ['ابعاد', 'ضخامت', 'نوع'],
        'بولت' => const ['نوع', 'قطر'],
        'توری' => const ['ابعاد', 'ضخامت'],
        'مفتول' => const ['سایز'],
        _ => const [],
      };

  // ------------------------------------------------------------ place evidence

  /// City of one row, from what the seller wrote, strongest evidence first.
  ///
  /// Written by the source (the city column of a price table, or a city the
  /// seller typed) → the written postal address → the map link → the landline
  /// area code. A mobile number is never a place.
  static Quote resolvePlace(Quote q) {
    final text = _messageText(q);
    final declared = _city(q.sellerCity);
    final address = cityInText(addressIn(text));
    final maps = mapsLinksIn(text).where((m) => m.hasCity).map((m) => m.city);
    final mapsCity = maps.isEmpty ? '' : maps.first;
    final phones = phonesIn(text);
    final landline = phones.where((p) => p.hasCity).toList();
    final phoneCity = landline.isEmpty ? '' : landline.first.city;
    final phoneFull = landline.isNotEmpty && landline.first.complete;

    final chosen = declared.isNotEmpty
        ? declared
        : address.isNotEmpty
            ? address
            : mapsCity.isNotEmpty
                ? mapsCity
                : phoneCity;
    final basis = declared.isNotEmpty
        ? 'شهر اعلامی خود منبع/فروشنده'
        : address.isNotEmpty
            ? 'آدرس نوشته‌شده در متن'
            : mapsCity.isNotEmpty
                ? 'نام مکان در لینک نقشه'
                : phoneCity.isNotEmpty
                    ? 'پیش‌شماره تلفن ثابت${phoneFull ? '' : ' (ناقص)'}'
                    : 'نامشخص';

    final conflicts = <String>[];
    final named = <String, String>{
      if (declared.isNotEmpty) 'منبع': declared,
      if (address.isNotEmpty) 'آدرس': address,
      if (mapsCity.isNotEmpty) 'نقشه': mapsCity,
      if (phoneCity.isNotEmpty) 'تلفن': phoneCity,
    };
    if (named.values.toSet().length > 1) {
      conflicts.add(named.entries.map((e) => '${e.key}: ${e.value}').join(' ≠ '));
    }
    final agree = named.length >= 2 && named.values.toSet().length == 1;

    final j = q.toJson();
    j['sellerCity'] = chosen.isEmpty ? q.sellerCity : chosen;
    j['details'] = <String, String>{
      ...q.details,
      'مبنای شهر': basis,
      if (named.length >= 2)
        'مقایسه شواهد شهر':
            agree ? 'هم‌خوان: ${named.values.first}' : 'ناهم‌خوان؛ قوی‌ترین شاهد ثبت شد',
      if (conflicts.isNotEmpty) 'تعارض شهر': conflicts.join(' | '),
      ...phoneEvidence(text),
      ...mapsEvidence(text),
      if (address.isNotEmpty) 'آدرس متن': address,
    };
    return Quote.fromJson(j);
  }

  static String _city(String value) {
    final c = value.trim();
    if (c.isEmpty ||
        c == 'نامشخص' ||
        c == 'عمومی' ||
        c == 'همه' ||
        c == 'نامعلوم') {
      return '';
    }
    return c;
  }

  static String _messageText(Quote q) => [
        q.details['متن پیام'] ?? '',
        q.details['متن OCR'] ?? '',
        // A short map link that was opened adds the address it really points at.
        q.details['نقشه (بازشده)'] ?? '',
      ].where((s) => s.isNotEmpty).join('\n');

  // ------------------------------------------------------------------ pipeline

  /// Turns whatever the sources returned into what the archive may keep:
  /// in-window, product-bearing, priced-or-explicitly-unpriced rows with their
  /// place resolved, one copy of each offer, ordered.
  static SearcherResult process(Iterable<Quote> rows,
      {required DateTime now,
      required int windowDays,
      bool keepManualFallback = true}) {
    var outOfWindow = 0, noise = 0, duplicates = 0;
    final kept = <String, Quote>{};
    for (final raw in rows) {
      if (!insideWindow(raw, now, windowDays)) {
        outOfWindow++;
        continue;
      }
      final q = resolvePlace(productKnowledge(raw));
      if (!_hasSubstance(q, keepManualFallback: keepManualFallback)) {
        noise++;
        continue;
      }
      final key = _identity(q);
      final existing = kept[key];
      if (existing == null) {
        kept[key] = q;
      } else {
        duplicates++;
        if (_newer(q, existing)) kept[key] = q;
      }
    }
    final list = kept.values.toList()..sort(compare);
    return SearcherResult(list,
        outOfWindow: outOfWindow, noise: noise, duplicates: duplicates);
  }

  /// Opens the shortened map links of every row, then applies the normal rules.
  ///
  /// Only the first short link of a post is opened, only while the app is online
  /// (the caller passes a resolver), and the resolved address is appended to the
  /// row's own text as evidence — never as a guess about the seller's location.
  static Future<void> resolveShortLinks(
      List<Quote> rows, MapsResolver resolver) async {
    for (var i = 0; i < rows.length; i++) {
      final q = rows[i];
      final text = _messageText(q);
      final links = shortMapsLinksIn(text);
      if (links.isEmpty) continue;
      final info = await resolver.resolve(links.first);
      final j = q.toJson();
      final details = Map<String, String>.from(q.details);
      details['بازکردن لینک نقشه'] = MapsResolver.evidenceLine(info, links.first);
      // The final address is kept next to the row so the ordinary offline
      // parser reads it exactly like a link the seller wrote in full.
      if (info != null) details['نقشه (بازشده)'] = info.url;
      j['details'] = details;
      rows[i] = Quote.fromJson(j);
    }
  }

  /// What a picture actually contained, written for the user.
  ///
  /// When an image yields no storable row this is the answer to "what did you
  /// see?": the product family the post names, the city its landline proves, the
  /// state of its map link, and whether any amount was legible at all.
  static Map<String, String> imageEvidence(String text, {List<Quote> rows = const []}) {
    final out = <String, String>{};
    final family = ProductText.category(text);
    if (family.isNotEmpty) out['خانواده محصول'] = family;
    final landline = phonesIn(text).where((p) => p.hasCity).toList();
    if (landline.isNotEmpty) {
      out['شهر از تلفن'] =
          '${landline.first.city} (پیش‌شماره ${landline.first.areaCode})';
    }
    final links = mapsLinksIn(text);
    if (links.isNotEmpty) {
      out['نقشه'] = links.first.hasCity
          ? 'شهر ${links.first.city}'
          : links.first.kind == 'لینک کوتاه'
              ? 'لینک کوتاه؛ بازکردن لازم دارد'
              : links.first.evidence;
    }
    // A phone number is not a price: strip contact tokens before counting.
    var body = text;
    for (final phone in phonesIn(text)) {
      body = body.replaceAll(phone.digits, ' ');
    }
    final amounts = RegExp(r'\d[\d,٬.]{4,}')
        .allMatches(body)
        .map((m) => m[0]!.replaceAll(RegExp(r'[.,]$'), ''))
        .toSet()
        .length;
    out['مبلغ‌های خوانده‌شده'] = amounts == 0
        ? 'هیچ مبلغی خوانا نبود'
        : '$amounts عدد${rows.isEmpty ? ' (بدون محصول قابل‌انتساب)' : ''}';
    return out;
  }

  /// [process] with the one network step the searcher is allowed to make.
  static Future<SearcherResult> processAsync(Iterable<Quote> rows,
      {required DateTime now,
      required int windowDays,
      MapsResolver? resolver,
      bool keepManualFallback = true}) async {
    final list = rows.toList();
    if (resolver != null) {
      await resolveShortLinks(list, resolver);
    }
    return process(list,
        now: now,
        windowDays: windowDays,
        keepManualFallback: keepManualFallback);
  }

  /// A stored row must be about a product, and about its price.
  ///
  /// The analyzer's own fallback row ("متن فاقد مبلغ…") is a sentence, not an
  /// offer; it is dropped here unless the user typed it themselves and is
  /// waiting to see what the app read from their own text.
  static bool _hasSubstance(Quote q, {required bool keepManualFallback}) {
    final product = ProductFacts.of(q).family;
    final hasProduct =
        product.isNotEmpty || ProductText.category(q.title).isNotEmpty;
    final hasPrice = q.amount != null && q.amount! > 0;
    // A source that announces an amount without stating its currency is kept:
    // the amount is the source's own text (`hasTextAmount`), it is displayed as
    // announced, and the missing currency is recorded as a caveat. What is *not*
    // kept is a sentence with no product in it.
    final announced = q.hasTextAmount;
    final manual = q.details['ورودی دستی'] == 'بله';
    if (!hasProduct) return manual && keepManualFallback;
    return hasPrice || announced || q.currency != 'نامشخص' || q.unit != 'unknown';
  }

  static bool _newer(Quote a, Quote b) {
    final x = publishedOf(a), y = publishedOf(b);
    if (x != null && y != null) return x.isAfter(y);
    return a.fetchedAt.isAfter(b.fetchedAt);
  }

  /// Identity of an offer, so two channels reposting it merge and two sizes of
  /// the same product do not.
  static String _identity(Quote q) {
    final facts = ProductFacts.of(q);
    String part(String v) => ProductText.normalize(v).replaceAll(' ', '');
    return [
      part(facts.family.isEmpty ? q.category : facts.family),
      part(q.title),
      part(q.size ?? ''),
      part(q.thickness ?? ''),
      part(q.dimensions ?? ''),
      part(q.grade ?? ''),
      part(q.brand),
      part(q.unit),
      part(q.currency),
      part(q.sellerCity),
      q.amount?.toStringAsFixed(0) ?? '',
      q.publishedOfDay,
    ].join('|');
  }

  /// The order the app shows steel products in, so a refresh never reshuffles
  /// the list just because a family's name sorts differently in Persian.
  static const familyOrder = [
    'میلگرد', 'تیرآهن', 'نبشی', 'ناودانی', 'ورق', 'لوله', 'پروفیل', 'قوطی',
    'تسمه', 'سپری', 'توری', 'مفتول', 'بولت', 'شمش', 'کلاف'
  ];

  static int _familyRank(String family) {
    final at = familyOrder.indexOf(family);
    return at < 0 ? familyOrder.length : at;
  }

  /// Publication order: product family, then the product itself, then place,
  /// then the cheaper price of the same product.
  static int compare(Quote a, Quote b) {
    final fa = ProductFacts.of(a).family, fb = ProductFacts.of(b).family;
    var c = _familyRank(fa).compareTo(_familyRank(fb));
    if (c != 0) return c;
    c = fa.compareTo(fb);
    if (c != 0) return c;
    c = a.title.compareTo(b.title);
    if (c != 0) return c;
    c = a.sellerCity.compareTo(b.sellerCity);
    if (c != 0) return c;
    final pa = a.amount, pb = b.amount;
    if (pa != null && pb != null) return pa.compareTo(pb);
    if (pa != null) return -1;
    if (pb != null) return 1;
    return 0;
  }

  static Map<String, int> categoryCounts(Iterable<Quote> rows) {
    final out = <String, int>{};
    for (final q in rows) {
      final family = ProductFacts.of(q).family;
      final key = family.isEmpty ? (q.category.isEmpty ? 'نامشخص' : q.category) : family;
      out[key] = (out[key] ?? 0) + 1;
    }
    final keys = out.keys.toList()..sort();
    return {for (final k in keys) k: out[k]!};
  }

  // -------------------------------------------------------------- image input

  /// Repairs what Persian OCR typically breaks before the analyzer sees it.
  ///
  /// Deliberately narrow: only the letters that Persian OCR confuses on steel
  /// vocabulary are rewritten, and digits are only touched between digits, so
  /// «آهن» can never be damaged.
  static String cleanOcrText(String raw) {
    var s = raw
        .replaceAll('\u200c', ' ')
        // Bidi control marks: a chat bubble and OCR both insert them around a
        // Persian line, and they break every URL and number they touch.
        .replaceAll(RegExp('[\u200e\u200f\u202a-\u202e\u2066-\u2069]'), '')
        .replaceAll('\t', ' ')
        .replaceAll('ي', 'ی')
        .replaceAll('ك', 'ک')
        .replaceAll('ﻻ', 'لا')
        .replaceAll(RegExp(r'[ ]{2,}'), ' ');
    // Truncated digits of a price are the most common OCR loss: put the
    // thousands separators back where the source used them.
    s = s.replaceAllMapped(
        RegExp(r'\b(\d{1,3}(?:[ \u00a0]\d{3})+)\b'),
        (m) => m[1]!.replaceAll(RegExp(r'[ \u00a0]'), ','));
    // Only between two digits, so a product name is never rewritten.
    s = s.replaceAllMapped(
        RegExp(r'(?<=\d)[oO](?=\d)'), (_) => '0');
    s = s.replaceAllMapped(RegExp(r'(?<=\d)[lI](?=\d)'), (_) => '1');
    final lines = s
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    // A chat bubble wraps a long link: `https://maps.app.goo.gl` on one line and
    // `/KyKq5e2b7vr…` on the next. Without joining them the link is lost.
    for (var i = 0; i < lines.length - 1; i++) {
      final head = lines[i], next = lines[i + 1];
      if (RegExp(r'https?://\S+$').hasMatch(head) &&
          RegExp(r'^(?:/|\?|#)').hasMatch(next)) {
        // Only the path token belongs to the link; whatever the bubble or OCR
        // wrote next to it on the same line stays a line of its own.
        final parts = next.split(RegExp(r'\s+'));
        final tail = next.substring(parts.first.length).trim();
        lines[i] = '$head${parts.first}';
        if (tail.isEmpty) {
          lines.removeAt(i + 1);
        } else {
          lines[i + 1] = tail;
        }
        i--;
      }
    }
    return lines.join('\n');
  }
}

extension on Quote {
  /// Day precision of the row, used by the identity so that today's and last
  /// week's price of the same product are two facts, not one overwritten one.
  String get publishedOfDay {
    final at = Searcher.publishedOf(this);
    if (at == null) return '';
    return '${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')}';
  }
}
