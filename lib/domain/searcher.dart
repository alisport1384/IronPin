import 'dart:isolate';

import 'geo_city.dart';
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

  /// Rows whose price is far from the rest of the same product group in the
  /// same read. They are kept and marked, never silently removed.
  final int flagged;
  const SearcherResult(this.quotes,
      {this.outOfWindow = 0,
      this.noise = 0,
      this.duplicates = 0,
      this.flagged = 0});

  Map<String, int> get categories => Searcher.categoryCounts(quotes);
  int get kept => quotes.length;

  String get summary =>
      'نگه‌داشته ${quotes.length} • خارج از بازه $outOfWindow • بی‌محصول/بی‌قیمت $noise • تکراری $duplicates'
      '${flagged == 0 ? '' : ' • قیمت نیازمند بازبینی $flagged'}';
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
  /// seller typed) → the written postal address → the map link (a place name,
  /// or the city its coordinates fall in) → the landline (county digits, else
  /// the province code). A mobile number is never a place.
  ///
  /// The evidence kinds are then **compared**: a landline only proves a
  /// province (or a county), a map pin proves a point, so «۰۲۱» next to a pin
  /// in اسلامشهر agree — same province — and the pin, being the more precise
  /// statement, names the city. Only evidence from different provinces is a
  /// conflict, and a conflict is written down, not resolved silently.
  static Quote resolvePlace(Quote q) {
    final text = _messageText(q);
    final place = _placeOf(text);
    final declared = _city(q.sellerCity);
    final declaredProvince = declared.isEmpty ? '' : Geo.provinceOf(declared);

    final chosen = declared.isNotEmpty
        ? declared
        : place.addressCity.isNotEmpty
            ? place.addressCity
            : place.mapsCity.isNotEmpty
                ? place.mapsCity
                : place.phoneCity;
    final basis = declared.isNotEmpty
        ? 'شهر اعلامی خود منبع/فروشنده'
        : place.addressCity.isNotEmpty
            ? 'آدرس نوشته‌شده در متن'
            : place.mapsCity.isNotEmpty
                ? (place.mapsFromCoordinates
                    ? 'مختصات لینک نقشه'
                    : 'نام مکان در لینک نقشه')
                : place.phoneCity.isNotEmpty
                    ? (place.phoneCounty
                        ? 'پیش‌شماره و رقم‌های شهرستان تلفن ثابت'
                        : 'پیش‌شماره تلفن ثابت${place.phoneFull ? '' : ' (ناقص)'}')
                    : 'نامشخص';

    // (label, city, province, precise) — a province-code landline is not a
    // statement about the city, only about the province.
    final named = <({String label, String city, String province, bool exact})>[
      if (declared.isNotEmpty)
        (label: 'منبع', city: declared, province: declaredProvince, exact: true),
      if (place.addressCity.isNotEmpty)
        (
          label: 'آدرس',
          city: place.addressCity,
          province: Geo.provinceOf(place.addressCity),
          exact: true
        ),
      if (place.mapsCity.isNotEmpty)
        (
          label: 'نقشه',
          city: place.mapsCity,
          province: place.mapsProvince,
          exact: true
        ),
      if (place.phoneCity.isNotEmpty)
        (
          label: 'تلفن',
          city: place.phoneCity,
          province: place.phoneProvince,
          exact: place.phoneCounty
        ),
    ];
    var comparison = '';
    final conflicts = <String>[];
    if (named.length >= 2) {
      bool sameCity(String a, String b) => Geo.key(a) == Geo.key(b);
      var allSameCity = true, clash = false;
      for (var i = 0; i < named.length; i++) {
        for (var j = i + 1; j < named.length; j++) {
          final a = named[i], b = named[j];
          if (sameCity(a.city, b.city)) continue;
          allSameCity = false;
          final sameProvince = a.province.isNotEmpty &&
              b.province.isNotEmpty &&
              a.province == b.province;
          // Two different cities of one province only disagree when both
          // sources actually speak about the city.
          if (!sameProvince || (a.exact && b.exact)) clash = true;
        }
      }
      if (allSameCity) {
        comparison = 'هم‌خوان: ${named.first.city}';
      } else if (!clash) {
        final province = named
            .map((e) => e.province)
            .firstWhere((p) => p.isNotEmpty, orElse: () => '');
        comparison = 'هم‌خوان در سطح استان $province: '
            '${named.map((e) => '${e.label} ${e.exact ? e.city : 'استان ${e.province}'}').join(' ↔ ')}'
            '؛ دقیق‌ترین شاهد ثبت شد';
      } else {
        comparison = 'ناهم‌خوان؛ قوی‌ترین شاهد ثبت شد';
        conflicts
            .add(named.map((e) => '${e.label}: ${e.city}').join(' ≠ '));
      }
    }
    final province = chosen.isEmpty
        ? ''
        : (named
            .where((e) => Geo.key(e.city) == Geo.key(chosen))
            .map((e) => e.province)
            .firstWhere((p) => p.isNotEmpty, orElse: () => ''));

    final j = q.toJson();
    j['sellerCity'] = chosen.isEmpty ? q.sellerCity : chosen;
    j['details'] = <String, String>{
      ...q.details,
      'مبنای شهر': basis,
      if (province.isNotEmpty) 'استان': province,
      if (comparison.isNotEmpty) 'مقایسه شواهد شهر': comparison,
      if (conflicts.isNotEmpty) 'تعارض شهر': conflicts.join(' | '),
      ...place.phoneEvidence,
      ...place.mapsEvidence,
      if (place.address.isNotEmpty) 'آدرس متن': place.address,
    };
    return Quote.fromJson(j);
  }

  /// Place evidence of one message, computed once: every row of a thirty-row
  /// price list carries the same message, and reading its phones, links and
  /// address thirty times was most of the cost of a large refresh.
  static final Map<String, _PlaceEvidence> _placeMemo = {};

  static _PlaceEvidence _placeOf(String text) {
    final known = _placeMemo[text];
    if (known != null) return known;
    final address = addressIn(text);
    final addressCities = address.isEmpty ? const <String>[] : citiesInText(address);
    final links = mapsLinksIn(text);
    MapsInfo? map;
    for (final link in links) {
      if (!link.hasCity) continue;
      // A pin is the more precise statement; a name-only link is next.
      if (map == null || (link.hasCoordinates && !map.hasCoordinates)) map = link;
    }
    final landline = phonesIn(text).where((p) => p.hasCity).toList()
      ..sort((a, b) {
        if (a.countyLevel != b.countyLevel) return a.countyLevel ? -1 : 1;
        if (a.complete != b.complete) return a.complete ? -1 : 1;
        return b.digits.length.compareTo(a.digits.length);
      });
    final phone = landline.isEmpty ? null : landline.first;
    final result = _PlaceEvidence(
        address: address.length > 140 ? address.substring(0, 140) : address,
        addressCity: addressCities.isEmpty ? '' : addressCities.first,
        mapsCity: map?.city ?? '',
        mapsProvince: map?.province ?? '',
        mapsFromCoordinates: map?.cityBasis == 'مختصات',
        phoneCity: phone?.city ?? '',
        phoneProvince: phone?.province ?? '',
        phoneCounty: phone?.countyLevel ?? false,
        phoneFull: phone?.complete ?? false,
        phoneEvidence: phoneEvidence(text),
        mapsEvidence: mapsEvidence(text));
    if (_placeMemo.length >= 64) _placeMemo.remove(_placeMemo.keys.first);
    _placeMemo[text] = result;
    return result;
  }

  /// The seller's place as one free text states it — a channel introduction
  /// or the contact lines of a website — in the same order of evidence as
  /// [resolvePlace]: the written address, then a map link, then the prefix of
  /// a landline. A mobile number names no city and an empty text names none.
  ///
  /// هوش جستجوگر ۲ only collects such text; the place is decided here.
  static ({String city, String basis}) placeOfText(String text) {
    if (text.trim().isEmpty) return (city: '', basis: '');
    final place = _placeOf(text);
    if (place.addressCity.isNotEmpty) {
      return (city: place.addressCity, basis: 'آدرس نوشته‌شده در متن');
    }
    if (place.mapsCity.isNotEmpty) {
      return (
        city: place.mapsCity,
        basis: place.mapsFromCoordinates
            ? 'مختصات لینک نقشه'
            : 'نام مکان در لینک نقشه'
      );
    }
    if (place.phoneCity.isNotEmpty) {
      return (
        city: place.phoneCity,
        basis: place.phoneCounty
            ? 'پیش‌شماره و رقم‌های شهرستان تلفن ثابت'
            : 'پیش‌شماره تلفن ثابت${place.phoneFull ? '' : ' (ناقص)'}'
      );
    }
    return (city: '', basis: '');
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
        // Contact lines of the post a picture was attached to (phones, map
        // links, address) — carried over so an image row is located by what
        // its own post says.
        q.details[captionEvidenceKey] ?? '',
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
    final flagged = _flagOutliers(list);
    // Last step, after every rule has read the message: the archive keeps the
    // product, its price and the evidence lines — not the message.
    for (var i = 0; i < list.length; i++) {
      list[i] = compact(list[i]);
    }
    return SearcherResult(list,
        outOfWindow: outOfWindow,
        noise: noise,
        duplicates: duplicates,
        flagged: flagged);
  }

  /// Key under which the contact lines of a post travel with its image rows.
  static const captionEvidenceKey = 'شواهد تماس پست';

  /// Detail entries that hold whole messages. They are working material for
  /// the rules above and are never written to the archive.
  static const proseKeys = {
    'متن پیام',
    'متن OCR',
    'نقشه (بازشده)',
    captionEvidenceKey,
  };

  /// The contact lines of a text and nothing else: lines that carry a phone
  /// number, a map link or an address keyword. Product talk and greetings are
  /// left behind.
  static String contactLines(String text) {
    final out = <String>[];
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.length > 400) continue;
      if (phonesIn(line).isNotEmpty ||
          isMapsUrl(line) ||
          addressIn(line).isNotEmpty) {
        out.add(line.length > 260 ? line.substring(0, 260) : line);
      }
      if (out.length >= 12) break;
    }
    return out.join('\n');
  }

  static final _termTags = <RegExp, String>{
    RegExp(r'نقد'): 'نقدی',
    RegExp(r'اعتبار|مدت\s*دار|چک|اقساط'): 'اعتباری/چکی',
    RegExp(r'پیش\s*پرداخت'): 'پیش‌پرداخت',
    RegExp(r'تسویه'): 'تسویه',
    RegExp(r'درب\s*کارخانه'): 'تحویل درب کارخانه',
    RegExp(r'درب\s*انبار'): 'تحویل درب انبار',
    RegExp(r'بنگاه'): 'تحویل بنگاه',
    RegExp(r'حداقل\s*سفارش'): 'حداقل سفارش دارد',
    RegExp(r'کرایه|هزینه\s*حمل'): 'کرایه حمل ذکر شده',
    RegExp(r'بندیل'): 'بندیل',
    RegExp(r'شاخه\s*ای|شاخه‌ای'): 'شاخه‌ای',
  };

  /// Sale terms as short tags instead of the sentences they were written in.
  static String compactTerms(String terms) {
    if (terms.trim().isEmpty) return terms;
    final t = ProductText.normalize(terms);
    final tags = <String>[
      for (final e in _termTags.entries)
        if (e.key.hasMatch(t)) e.value
    ];
    return tags.isEmpty ? 'نامشخص' : tags.join('؛ ');
  }

  static String _clip(String value, int max) {
    final v = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return v.runes.length <= max ? v : '${String.fromCharCodes(v.runes.take(max))}…';
  }

  /// What is written to the archive for one row: product, price, place and the
  /// short evidence lines. Whole messages, OCR dumps and free sentences are
  /// removed here, in one place, for every source kind.
  static Quote compact(Quote q) {
    final details = <String, String>{};
    for (final e in q.details.entries) {
      if (proseKeys.contains(e.key)) continue;
      final max = switch (e.key) {
        'شاهد ردیف' => 160,
        'سرعنوان گروه' => 80,
        'آدرس متن' => 140,
        _ => 220,
      };
      details[e.key] = _clip(e.value, max);
    }
    final j = q.toJson();
    j['details'] = details;
    j['title'] = _clip(q.title, 110);
    j['terms'] = compactTerms(q.terms);
    return Quote.fromJson(j);
  }

  /// Marks prices that sit far away from the same product group of the same
  /// read. A dropped or doubled digit (the usual OCR and typing error) lands
  /// an order of magnitude away from its neighbours; a real discount does not.
  /// Rows are flagged for review and kept — an unusual price can be genuine.
  static int _flagOutliers(List<Quote> rows) {
    final groups = <String, List<int>>{};
    for (var i = 0; i < rows.length; i++) {
      final q = rows[i];
      final amount = q.amount;
      if (amount == null || amount <= 0) continue;
      if (q.unit == 'unknown' || q.currency == 'نامشخص') continue;
      final family = ProductFacts.of(q).family;
      if (family.isEmpty) continue;
      (groups['$family|${q.unit}|${q.currency}'] ??= []).add(i);
    }
    var flagged = 0;
    for (final members in groups.values) {
      if (members.length < 5) continue;
      final values = [for (final i in members) rows[i].amount!]..sort();
      final median = values[values.length ~/ 2];
      if (median <= 0) continue;
      for (final i in members) {
        final ratio = rows[i].amount! / median;
        if (ratio < 4 && ratio > 0.25) continue;
        final j = rows[i].toJson();
        j['details'] = <String, String>{
          ...rows[i].details,
          'هشدار قیمت': 'فاصلهٔ زیاد با میانهٔ ${members.length} ردیف هم‌گروه در همین خواندن '
              '(${ratio >= 4 ? 'حدود ${ratio.round()} برابر' : 'کمتر از یک‌چهارم'})؛ '
              'احتمال افتادن/اضافه‌شدن رقم — نیازمند بازبینی',
        };
        final status = rows[i].status;
        j['status'] = status.contains('نیازمند بازبینی')
            ? status
            : '$status • قیمت نیازمند بازبینی';
        rows[i] = Quote.fromJson(j);
        flagged++;
      }
    }
    return flagged;
  }

  /// Opens the shortened map links of every row, then applies the normal rules.
  ///
  /// Up to three short links of a post are opened, only while the app is
  /// online (the caller passes a resolver), each link once per run however
  /// many rows share the post, and the resolved address is appended to the
  /// row's own text as evidence — never as a guess about the seller's location.
  static Future<void> resolveShortLinks(
      List<Quote> rows, MapsResolver resolver) async {
    final byText = <String, ({String evidence, String opened})>{};
    for (var i = 0; i < rows.length; i++) {
      final q = rows[i];
      final text = _messageText(q);
      var answer = byText[text];
      if (answer == null) {
        final links = shortMapsLinksIn(text);
        if (links.isEmpty) {
          answer = (evidence: '', opened: '');
        } else {
          final lines = <String>[], opened = <String>[];
          for (final link in links.take(3)) {
            final info = await resolver.resolve(link);
            lines.add(MapsResolver.evidenceLine(info, link));
            // The final address is kept next to the row so the ordinary
            // offline parser reads it exactly like a link written in full.
            if (info != null) opened.add(info.url);
            if (info != null && info.hasCoordinates) break;
          }
          answer = (evidence: lines.join(' | '), opened: opened.join('\n'));
        }
        byText[text] = answer;
      }
      if (answer.evidence.isEmpty) continue;
      final j = q.toJson();
      final details = Map<String, String>.from(q.details);
      details['بازکردن لینک نقشه'] = answer.evidence;
      if (answer.opened.isNotEmpty) details['نقشه (بازشده)'] = answer.opened;
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
      out['استان از تلفن'] = landline.first.province;
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
    // The rules are pure and regex-heavy. A long list is decided off the
    // interface thread, so a refresh of many large sources never stalls a
    // frame; a short one is cheaper to decide in place than to copy.
    if (list.length < backgroundThreshold) {
      return process(list,
          now: now,
          windowDays: windowDays,
          keepManualFallback: keepManualFallback);
    }
    try {
      return await processInBackground(list,
          now: now,
          windowDays: windowDays,
          keepManualFallback: keepManualFallback);
    } catch (_) {
      // No second isolate available (some embedders): same answer, in place.
      return process(list,
          now: now,
          windowDays: windowDays,
          keepManualFallback: keepManualFallback);
    }
  }

  /// [process] on a second isolate.
  ///
  /// It is a function of its own on purpose: the closure sent to the isolate
  /// may hold only the rows and the three settings. Written inline in
  /// [processAsync] it would also hold the link resolver and its HTTP client,
  /// which cannot be sent, and the work would silently stay on the interface
  /// thread.
  static Future<SearcherResult> processInBackground(List<Quote> list,
          {required DateTime now,
          required int windowDays,
          bool keepManualFallback = true}) =>
      Isolate.run(() => process(list,
          now: now,
          windowDays: windowDays,
          keepManualFallback: keepManualFallback));

  /// Row count from which [processAsync] works on a background isolate.
  static const backgroundThreshold = 24;

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
    if (manual && keepManualFallback) return true;
    // A product line with no amount at all («تماس بگیرید», a caption, a
    // greeting that names a product) is a sentence, not an offer: the archive
    // holds products with their announced price, nothing else.
    return hasPrice || announced;
  }

  /// Which of two copies of the same offer is the one to keep.
  ///
  /// On the same publication day the later read wins: a channel that re-issues
  /// today's list with a corrected price must update the archive instead of being
  /// thrown away in favour of the copy read an hour earlier. History keeps both
  /// values; only the current row is replaced.
  static bool _newer(Quote a, Quote b) {
    final x = publishedOf(a), y = publishedOf(b);
    if (x != null && y != null) {
      if (x.isAfter(y)) return true;
      if (x.isBefore(y)) return false;
    }
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
      // The amount is deliberately not part of the identity: the same product
      // announced twice on the same day is one offer and the newer read replaces
      // the older one. With the amount in the key, a corrected price either
      // duplicated the product or was dropped as "not newer", so a refresh
      // appeared to change nothing.
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

class _PlaceEvidence {
  final String address, addressCity, mapsCity, mapsProvince;
  final String phoneCity, phoneProvince;
  final bool mapsFromCoordinates, phoneCounty, phoneFull;
  final Map<String, String> phoneEvidence, mapsEvidence;
  const _PlaceEvidence(
      {required this.address,
      required this.addressCity,
      required this.mapsCity,
      required this.mapsProvince,
      required this.mapsFromCoordinates,
      required this.phoneCity,
      required this.phoneProvince,
      required this.phoneCounty,
      required this.phoneFull,
      required this.phoneEvidence,
      required this.mapsEvidence});
}
