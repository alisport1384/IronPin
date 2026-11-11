import 'geo_city.dart';
import 'market.dart' show latin;
import 'phone_city.dart' show cityLatinNames, knownCities;

/// A Google Maps reference found in a post or in an image.
///
/// The app has no geocoder and no network call of its own, so a link is read the
/// way the sender wrote it:
///
///  * a long link carries the coordinates (`@35.27,59.21`, `!3d!4d`, `?q=`,
///    `?ll=`) or a place name (`/place/Kaveh+Steel/`), and both are facts;
///  * a short link (`maps.app.goo.gl/…`) carries nothing, so it is stored as
///    «لینک کوتاه؛ بدون مختصات» and never guessed;
///  * coordinates outside Iran's bounding box are refused, because a marker
///    dropped in another country is a bad paste, not a location.
class MapsInfo {
  final String url;

  /// `مختصات`, `نام مکان`, `لینک کوتاه` or `نامعتبر`.
  final String kind;
  final double? lat, lng;
  final String placeName;

  /// City read out of the place name or the link's address text.
  final String city;
  final bool inIran;

  /// Province of the coordinates (or of the named city), `''` when unknown.
  final String province;

  /// How [city] was reached: `نام مکان` (written in the link) or `مختصات`
  /// (the coordinates fall in, or nearest to, that city).
  final String cityBasis;

  /// Distance from the coordinates to the centre of [city], when the city was
  /// taken from the coordinates.
  final double? cityKm;

  const MapsInfo({
    required this.url,
    required this.kind,
    this.lat,
    this.lng,
    this.placeName = '',
    this.city = '',
    this.inIran = false,
    this.province = '',
    this.cityBasis = '',
    this.cityKm,
  });

  bool get hasCoordinates => lat != null && lng != null && inIran;
  bool get hasCity => city.isNotEmpty;

  String get coordinates => hasCoordinates
      ? '${lat!.toStringAsFixed(5)},${lng!.toStringAsFixed(5)}'
      : '';

  String get evidence {
    final parts = <String>[
      if (hasCoordinates) 'مختصات $coordinates',
      if (placeName.isNotEmpty) 'مکان «$placeName»',
      if (city.isNotEmpty)
        cityBasis == 'مختصات'
            ? 'شهر $city${province.isEmpty ? '' : '، استان $province'} '
                '(از مختصات${cityKm == null ? '' : '، ${cityKm!.round()} کیلومتر تا مرکز شهر'})'
            : 'شهر $city${province.isEmpty ? '' : '، استان $province'}',
      if (!hasCoordinates && placeName.isEmpty)
        kind == 'لینک کوتاه'
            ? 'لینک کوتاه؛ مختصات داخل آدرس نیست و بازکردن آن نیازمند اینترنت است'
            : 'آدرس بدون مختصات',
      if (lat != null && lng != null && !inIran) 'مختصات بیرون از ایران؛ رد شد',
    ];
    return parts.join(' • ');
  }
}

final RegExp mapsUrlPattern = RegExp(
    r'(?:https?://)?(?:www\.)?(?:google\.[a-z.]{2,7}/maps[^\s<>"\]\)]*|maps\.google\.[a-z.]{2,7}[^\s<>"\]\)]*|maps\.app\.goo\.gl/[^\s<>"\]\)]*|goo\.gl/maps/[^\s<>"\]\)]*|g\.co/maps/[^\s<>"\]\)]*|nshn\.ir/[^\s<>"\]\)]*|neshan\.org/maps[^\s<>"\]\)]*|balad\.ir/[^\s<>"\]\)]*|waze\.com/(?:[a-z\-]+/)?(?:ul|live-map)[^\s<>"\]\)]*)',
    caseSensitive: false);

bool isMapsUrl(String value) => mapsUrlPattern.hasMatch(latin(value));

/// A link whose coordinates live behind a redirect (`maps.app.goo.gl/…`).
bool isShortMapsUrl(String value) {
  final v = latin(value).toLowerCase();
  if (v.contains('maps.app.goo.gl') ||
      v.contains('goo.gl/maps') ||
      v.contains('g.co/maps')) {
    return true;
  }
  // Neshan and Balad share codes (`nshn.ir/abc123`, `balad.ir/p/…`) carry no
  // coordinates of their own; the ones that do are ordinary long links.
  final hasPoint = RegExp(r'[?&#](?:lat|latitude|ll|origin|destination)=|/@-?\d')
      .hasMatch(v);
  if (hasPoint) return false;
  return RegExp(r'nshn\.ir/[a-z0-9_\-]{4,}').hasMatch(v) ||
      RegExp(r'balad\.ir/p/').hasMatch(v) ||
      v.contains('neshan.org/maps/share');
}

/// Short links of a text, de-duplicated, in the order they were written.
List<String> shortMapsLinksIn(String text) {
  final out = <String>[];
  for (final m in mapsUrlPattern.allMatches(latin(text))) {
    var url = m[0]!;
    if (!url.startsWith('http')) url = 'https://$url';
    if (isShortMapsUrl(url) && !out.contains(url)) out.add(url);
  }
  return out;
}

/// Every maps link of a text, with what can be read from it offline.
List<MapsInfo> mapsLinksIn(String text) {
  final out = <MapsInfo>[];
  final seen = <String>{};
  for (final m in mapsUrlPattern.allMatches(latin(text))) {
    var url = m[0]!;
    if (!url.startsWith('http')) url = 'https://$url';
    if (!seen.add(url)) continue;
    out.add(parseMapsUrl(url));
  }
  return out;
}

/// Parses one Maps URL. Pure, no network.
MapsInfo parseMapsUrl(String raw) {
  var url = latin(raw).trim();
  if (!url.startsWith('http')) url = 'https://$url';
  final lower = url.toLowerCase();
  final shortLink = isShortMapsUrl(lower);

  double? lat, lng;
  void take(RegExp re) {
    if (lat != null) return;
    final m = re.firstMatch(url);
    final a = m == null ? null : double.tryParse(m[1] ?? '');
    final b = m == null ? null : double.tryParse(m[2] ?? '');
    if (a == null || b == null) return;
    if (a.abs() > 90 || b.abs() > 180) return;
    lat = a;
    lng = b;
  }

  // Long URL shapes, most specific first.
  take(RegExp(r'!3d(-?\d{1,3}\.\d+)!4d(-?\d{1,3}\.\d+)'));
  take(RegExp(r'[?&](?:q|query|ll|center|destination|daddr)=(-?\d{1,3}\.\d+)(?:\s|\+|%20)*,(?:\s|\+|%20)*(-?\d{1,3}\.\d+)'));
  // Neshan (`?lat=…&lng=…`) and Balad (`?latitude=…&longitude=…`).
  take(RegExp(r'[?&]lat(?:itude)?=(-?\d{1,3}\.\d+)&(?:amp;)?(?:lng|lon|longitude)=(-?\d{1,3}\.\d+)'));
  take(RegExp(r'[?&](?:destination|origin)=(-?\d{1,3}\.\d+)\s*(?:,|%2C)\s*(-?\d{1,3}\.\d+)', caseSensitive: false));
  take(RegExp(r'[?&](?:q|query|ll|center)=(-?\d{1,3}\.\d+)%2C(-?\d{1,3}\.\d+)', caseSensitive: false));
  take(RegExp(r'@(-?\d{1,3}\.\d+),(-?\d{1,3}\.\d+)'));
  take(RegExp(r'/(-?\d{1,3}\.\d+),(?:\+|%20)*(-?\d{1,3}\.\d+)'));

  var place = '';
  final placeMatch = RegExp(r'/place/([^/@?]+)').firstMatch(url);
  if (placeMatch != null) {
    place = _cleanPlace(placeMatch[1]!);
  } else {
    final q = RegExp(r'[?&](?:q|query)=([^&]+)').firstMatch(url);
    if (q != null) {
      final value = _decode(q[1]!.replaceAll('+', ' '));
      if (!RegExp(r'^-?\d{1,3}\.\d+\s*,\s*-?\d{1,3}\.\d+$').hasMatch(value)) {
        place = _cleanPlace(value);
      }
    }
    if (place.isEmpty) {
      final dir = RegExp(r'/dir/([^/@?]+)').firstMatch(url);
      if (dir != null) place = _cleanPlace(dir[1]!);
    }
  }

  final inIran = lat != null &&
      lng != null &&
      lat! >= 24.5 &&
      lat! <= 40.0 &&
      lng! >= 43.5 &&
      lng! <= 63.5;

  // A city named inside the place name or the query is written evidence.
  final named = cityInText('$place ${_decode(url)}');
  // Coordinates answer with the city they fall in; a place name the seller
  // typed is still the stronger statement and is kept when both exist.
  final hit = inIran ? Geo.nearest(lat!, lng!) : null;
  final city = named.isNotEmpty ? named : (hit?.city.name ?? '');
  final province = hit?.city.province ??
      (named.isEmpty ? '' : Geo.provinceOf(named));

  final kind = (lat != null && lng != null)
      ? 'مختصات'
      : shortLink
          ? 'لینک کوتاه'
          : place.isNotEmpty
              ? 'نام مکان'
              : 'نامعتبر';
  return MapsInfo(
      url: url,
      kind: kind,
      lat: lat,
      lng: lng,
      placeName: place,
      city: city,
      inIran: inIran,
      province: province,
      cityBasis: city.isEmpty
          ? ''
          : named.isNotEmpty
              ? 'نام مکان'
              : 'مختصات',
      cityKm: named.isEmpty ? hit?.km : null);
}

String _decode(String value) {
  try {
    return Uri.decodeComponent(value);
  } catch (_) {
    // A raw Persian place name is legal in a URL but not valid percent
    // encoding; the text itself is what the seller wrote, so keep it.
    return value;
  }
}

String _cleanPlace(String value) {
  var s = _decode(value.replaceAll('+', ' '));
  // Direction marks that maps pages wrap names in are not part of the name.
  s = s.replaceAll(RegExp('[\u200e\u200f\u202a-\u202e\u2066-\u2069]'), '');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s.length > 90 ? s.substring(0, 90) : s;
}

/// One alternation over every known city name, longest first, compiled once.
///
/// This ran once per stored row with a fresh `RegExp` per city (hundreds of
/// compilations per row); on a large refresh that alone kept the interface
/// busy for seconds.
final Map<String, String> _cityByKey = () {
  final out = <String, String>{};
  for (final city in knownCities) {
    out[Geo.key(latin(city))] = city;
  }
  for (final c in Geo.cities) {
    // Short or common-word names («بم» is listed above on purpose) are only
    // accepted from the curated list; the gazetteer adds real city names.
    if (c.population < 20000 || c.name.length < 4) continue;
    out.putIfAbsent(Geo.key(latin(c.name)), () => c.name);
  }
  return out;
}();

final RegExp _cityPattern = () {
  final names = <String>{};
  for (final city in [...knownCities, ..._cityByKey.values]) {
    names.add(latin(city));
  }
  final ordered = names.toList()..sort((a, b) => b.length.compareTo(a.length));
  // A half-space, a space or nothing between the parts is the same name.
  final body = ordered
      .map((n) => n
          .split(RegExp('[\u200c\\s]+'))
          .map(RegExp.escape)
          .join('[\u200c\\s]?'))
      .join('|');
  return RegExp('(?<![\\p{L}])(?:$body)(?![\\p{L}])', unicode: true);
}();

final RegExp _latinCityPattern = () {
  final ordered = cityLatinNames.keys.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  return RegExp('(?<![a-z])(?:${ordered.map(RegExp.escape).join('|')})(?![a-z])');
}();

/// Words that look like a city but are a product, a brand or a mill in a steel
/// price list («میلگرد نیشابور» is a mill, not the seller's office).
final RegExp _millContext = RegExp(
    r'(?:میلگرد|تیرآهن|نبشی|ناودانی|ورق|فولاد|ذوب\s*آهن|نورد|کارخانه|برند|تولیدی|محصول)\s*$');

/// First known city named in a text, or `''`.
String cityInText(String text) {
  final t = latin(text);
  String best = '';
  for (final m in _cityPattern.allMatches(t)) {
    final hit = m[0]!;
    if (hit.length > best.length) best = hit;
  }
  if (best.isEmpty) {
    final m = _latinCityPattern.firstMatch(t.toLowerCase());
    return m == null ? '' : (cityLatinNames[m[0]!] ?? '');
  }
  return _cityByKey[Geo.key(best)] ?? '';
}

/// Every known city named in a text, in the order written, without the ones
/// that directly follow a product or mill word.
List<String> citiesInText(String text) {
  final t = latin(text);
  final out = <String>[];
  for (final m in _cityPattern.allMatches(t)) {
    final before = t.substring(m.start > 24 ? m.start - 24 : 0, m.start);
    if (_millContext.hasMatch(before)) continue;
    final city = _cityByKey[Geo.key(m[0]!)];
    if (city != null && !out.contains(city)) out.add(city);
  }
  return out;
}

/// «آدرس/نشانی» introduce an address by themselves; the weaker words (دفتر،
/// انبار، محل بارگیری …) only when the seller put a colon after them, so
/// «کارخانه ذوب‌آهن اصفهان» in a price row is never read as the seller's address.
final RegExp _addressLine = RegExp(
    r'(?:آدرس|ادرس|نشانی)(?:\s+(?:دفتر|انبار|کارخانه|فروشگاه|ما))?\s*[:：\-]?\s*([^\n]{4,160})');
final RegExp _weakAddressLine = RegExp(
    r'(?:دفتر(?:\s+(?:مرکزی|فروش))?|انبار|محل\s+بارگیری|موقعیت|کارگاه|فروشگاه)\s*[:：]\s*([^\n]{4,160})');

/// Written address of a post, or `''`.
String addressIn(String text) {
  final t = latin(text);
  final m = _addressLine.firstMatch(t) ?? _weakAddressLine.firstMatch(t);
  if (m == null) return '';
  return m[1]!.trim();
}

/// Evidence lines for every maps link of a text.
Map<String, String> mapsEvidence(String text) {
  final links = mapsLinksIn(text);
  if (links.isEmpty) return const {};
  final out = <String, String>{};
  for (var i = 0; i < links.length && i < 3; i++) {
    out['نقشه ${i + 1}'] = links[i].evidence;
  }
  final withCity = links.firstWhere((l) => l.hasCity, orElse: () => links.first);
  if (withCity.hasCity) {
    out['مبنای شهر از نقشه'] = withCity.cityBasis == 'مختصات'
        ? '${withCity.city} (از مختصات)'
        : withCity.city;
  }
  return out;
}
