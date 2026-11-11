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

  const MapsInfo({
    required this.url,
    required this.kind,
    this.lat,
    this.lng,
    this.placeName = '',
    this.city = '',
    this.inIran = false,
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
      if (city.isNotEmpty) 'شهر $city',
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
    r'(?:https?://)?(?:www\.)?(?:google\.[a-z.]{2,7}/maps[^\s<>"\]\)]*|maps\.google\.[a-z.]{2,7}[^\s<>"\]\)]*|maps\.app\.goo\.gl/[^\s<>"\]\)]*|goo\.gl/maps/[^\s<>"\]\)]*|g\.co/maps/[^\s<>"\]\)]*)',
    caseSensitive: false);

bool isMapsUrl(String value) => mapsUrlPattern.hasMatch(latin(value));

/// A link whose coordinates live behind a redirect (`maps.app.goo.gl/…`).
bool isShortMapsUrl(String value) {
  final v = latin(value).toLowerCase();
  return v.contains('maps.app.goo.gl') ||
      v.contains('goo.gl/maps') ||
      v.contains('g.co/maps');
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
  final shortLink = lower.contains('maps.app.goo.gl') ||
      lower.contains('goo.gl/maps') ||
      lower.contains('g.co/maps');

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
  take(RegExp(r'[?&](?:q|query|ll|center|destination|daddr)=(-?\d{1,3}\.\d+)\s*,\s*(-?\d{1,3}\.\d+)'));
  take(RegExp(r'@(-?\d{1,3}\.\d+),(-?\d{1,3}\.\d+)'));
  take(RegExp(r'/(-?\d{1,3}\.\d+),(-?\d{1,3}\.\d+)'));

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
  final city = cityInText('$place ${_decode(url)}');

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
      inIran: inIran);
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
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s.length > 90 ? s.substring(0, 90) : s;
}

/// First known city named in a text, or `''`.
String cityInText(String text) {
  final t = latin(text);
  String best = '';
  for (final city in knownCities) {
    final key = latin(city);
    if (key.isEmpty) continue;
    if (RegExp('(?:^|[^\\p{L}])${RegExp.escape(key)}(?:[^\\p{L}]|\$)', unicode: true)
        .hasMatch(t)) {
      if (key.length > best.length) best = key;
    }
  }
  if (best.isEmpty) {
    for (final entry in cityLatinNames.entries) {
      if (RegExp('(?:^|[^a-z])${RegExp.escape(entry.key)}(?:[^a-z]|\$)')
          .hasMatch(t.toLowerCase())) {
        return entry.value;
      }
    }
    return '';
  }
  for (final city in knownCities) {
    if (latin(city) == best) return city;
  }
  return '';
}

final RegExp _addressLine = RegExp(
    r'(?:آدرس|نشانی|موقعیت|کارخانه|کارگاه|انبار|دفتر|محل)\s*[:：]?\s*([^\n]{4,120})');

/// Written address of a post, or `''`.
String addressIn(String text) {
  final m = _addressLine.firstMatch(latin(text));
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
  if (withCity.hasCity) out['مبنای شهر از نقشه'] = withCity.city;
  return out;
}
