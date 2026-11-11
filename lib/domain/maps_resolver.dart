import 'package:http/http.dart' as http;

import 'maps_link.dart';

/// Resolves a shortened map link into the place it points at.
///
/// A channel writes `maps.app.goo.gl/KyKq5e…` (or `nshn.ir/…`, `balad.ir/p/…`);
/// the coordinates live behind that redirect, so the only way to know the
/// location is to ask the server where it sends you. The rules:
///
///  * the redirect chain is followed by hand, with a plain non-browser client:
///    a browser-like User-Agent is answered with a JavaScript page that has no
///    `Location` header at all;
///  * a consent page (`consent.google.com/…?continue=<real address>`) is not a
///    dead end — the real address is its `continue` parameter;
///  * an answer without a redirect is searched for the address it names
///    (canonical link, `og:` tags, static-map `center=`/`markers=`);
///  * every link is asked once per run: the answer, or the fact that there was
///    none, is remembered;
///  * a failure leaves the link exactly as written and never invents a place.
class MapsResolver {
  final http.Client client;
  final Duration timeout;
  final int maxHops;

  MapsResolver(this.client,
      {this.timeout = const Duration(seconds: 7), this.maxHops = 5});

  static const _agent = 'IronPin/0.9.2 (public link resolution)';

  /// Answers of this app run, keyed by the link as written. `null` is a real
  /// answer too ("could not be opened") and is not asked again for a while.
  static final Map<String, ({MapsInfo? info, DateTime at})> _cache = {};
  static const _negativeTtl = Duration(minutes: 30);

  static void clearCache() => _cache.clear();

  Future<MapsInfo?> resolve(String url) async {
    final key = url.trim();
    final known = _cache[key];
    if (known != null &&
        (known.info != null ||
            DateTime.now().difference(known.at) < _negativeTtl)) {
      return known.info;
    }
    final info = await _resolve(key);
    if (_cache.length > 400) _cache.remove(_cache.keys.first);
    _cache[key] = (info: info, at: DateTime.now());
    return info;
  }

  static bool _useful(MapsInfo info) =>
      info.hasCoordinates || info.hasCity || info.placeName.isNotEmpty;

  Future<MapsInfo?> _resolve(String url) async {
    final start = Uri.tryParse(url.startsWith('http') ? url : 'https://$url');
    if (start == null) return null;
    var current = start;
    MapsInfo? weak;
    for (var hop = 0; hop < maxHops; hop++) {
      http.Response response;
      try {
        final request = http.Request('GET', current)
          ..followRedirects = false
          ..headers['user-agent'] = _agent
          ..headers['accept-language'] = 'fa,en;q=0.8';
        final streamed = await client.send(request).timeout(timeout);
        response = await http.Response.fromStream(streamed).timeout(timeout);
      } catch (_) {
        return weak;
      }
      final location = response.headers['location'];
      if (location == null || location.isEmpty) {
        if (response.statusCode >= 200 && response.statusCode < 300) {
          final inBody = _placeInBody(response.body);
          if (inBody != null) return inBody;
          final info = parseMapsUrl(current.toString());
          if (_useful(info)) return info;
        }
        return weak;
      }
      var next = current.resolve(location);
      // The consent wall carries the real destination in `continue`.
      final onward = next.queryParameters['continue'];
      if (next.host.contains('consent.') && onward != null) {
        final real = Uri.tryParse(onward);
        if (real != null && real.hasScheme) next = real;
      }
      if (next.toString() == current.toString()) return weak;
      current = next;
      if (!isShortMapsUrl(current.toString())) {
        final info = parseMapsUrl(current.toString());
        // Coordinates end the search. A bare place name is kept, but one more
        // hop may still turn it into coordinates.
        if (info.hasCoordinates) return info;
        if (_useful(info)) weak = info;
      }
    }
    return weak;
  }

  static final _longMaps = RegExp(
      r'https?:(?://|\\/\\/)(?:www\.)?(?:google\.[a-z.]{2,7}|maps\.google\.[a-z.]{2,7}|neshan\.org|balad\.ir)(?:/|\\/)(?:maps|location)[^\s"<>]{0,600}',
      caseSensitive: false);
  static final _staticCentre = RegExp(
      r'(?:center|markers|ll)=(-?\d{1,3}\.\d+)(?:%2C|,)(-?\d{1,3}\.\d+)',
      caseSensitive: false);

  /// The first place a page names: a full map address, else the centre of the
  /// preview map it embeds.
  static MapsInfo? _placeInBody(String body) {
    if (body.isEmpty) return null;
    for (final m in _longMaps.allMatches(body).take(12)) {
      final url = m[0]!
          .replaceAll(r'\/', '/')
          .replaceAll('&amp;', '&')
          .replaceAll(r'\u0026', '&')
          .replaceAll(r'\u003d', '=');
      final info = parseMapsUrl(url);
      if (info.hasCoordinates) return info;
    }
    final centre = _staticCentre.firstMatch(body);
    if (centre != null) {
      final info = parseMapsUrl(
          'https://www.google.com/maps?q=${centre[1]},${centre[2]}');
      if (info.hasCoordinates) return info;
    }
    for (final m in _longMaps.allMatches(body).take(12)) {
      final info = parseMapsUrl(m[0]!.replaceAll(r'\/', '/').replaceAll('&amp;', '&'));
      if (_useful(info)) return info;
    }
    return null;
  }

  /// Text-ready line for `details`: what the link resolved to, or why it did not.
  static String evidenceLine(MapsInfo? info, String originalUrl) {
    if (info == null) {
      return 'لینک کوتاه باز نشد (بدون اینترنت، مسدود یا لینک نامعتبر)؛ مکان از آن استنتاج نشد';
    }
    final parts = <String>[
      if (info.hasCoordinates) 'مختصات ${info.coordinates}',
      if (info.placeName.isNotEmpty) 'مکان «${info.placeName}»',
      if (info.city.isNotEmpty)
        'شهر ${info.city}${info.cityBasis == 'مختصات' ? ' (از مختصات)' : ''}',
      'از بازکردن $originalUrl',
    ];
    return parts.join(' • ');
  }
}
