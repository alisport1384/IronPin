import 'package:http/http.dart' as http;

import 'maps_link.dart';

/// Resolves a shortened Google Maps link into the place it points at.
///
/// A channel writes `maps.app.goo.gl/KyKq5e…`; the coordinates and the place name
/// live behind that redirect, so the only way to know the location is to ask the
/// server where it sends you. Three rules keep this honest:
///
///  * the redirect is followed with the app's own HTTP client, while the app is
///    online anyway, and never more than [maxHops] times;
///  * a failure (offline, rate limit, unknown host) leaves the link exactly as
///    written — «لینک کوتاه؛ باز نشد» — and never invents a place;
///  * the resolved URL is parsed by the same offline parser, so the evidence
///    recorded is still what Google's own address says.
class MapsResolver {
  final http.Client client;
  final Duration timeout;
  final int maxHops;

  MapsResolver(this.client, {this.timeout = const Duration(seconds: 7), this.maxHops = 3});

  /// Resolves the first short link of a text and returns its evidence.
  ///
  /// The returned [MapsInfo] is the parsed *final* address, with `kind` kept as
  /// evidence of how it was reached.
  Future<MapsInfo?> resolve(String url) async {
    final start = Uri.tryParse(url.startsWith('http') ? url : 'https://$url');
    if (start == null) return null;
    var current = start;
    for (var hop = 0; hop < maxHops; hop++) {
      http.Response response;
      try {
        // HEAD first: it is cheap and usually carries the same redirect chain.
        final request = http.Request('HEAD', current)
          ..followRedirects = false
          ..headers['user-agent'] = 'IronPin/0.9.1 (public link resolution)';
        final streamed = await client.send(request).timeout(timeout);
        response = await http.Response.fromStream(streamed);
      } catch (_) {
        try {
          final request = http.Request('GET', current)
            ..followRedirects = false
            ..headers['user-agent'] = 'IronPin/0.9.1 (public link resolution)';
          final streamed = await client.send(request).timeout(timeout);
          response = await http.Response.fromStream(streamed);
        } catch (_) {
          return null;
        }
      }
      final location = response.headers['location'];
      if (location == null || location.isEmpty) {
        if (response.statusCode >= 200 && response.statusCode < 300) {
          // Some short links answer 200 and put the real address inside the page
          // (`<link rel=canonical>`, `og:url`, a meta refresh, or a `;URL=`).
          // Read the body and take the first Maps address it names.
          final inBody = _mapsUrlIn(response.body);
          if (inBody != null) {
            final info = parseMapsUrl(inBody);
            if (info.hasCoordinates || info.hasCity || info.placeName.isNotEmpty) {
              return info;
            }
          }
          final info = parseMapsUrl(current.toString());
          return info.hasCoordinates || info.hasCity || info.placeName.isNotEmpty
              ? info
              : null;
        }
        return null;
      }
      final next = current.resolve(location);
      if (next.toString() == current.toString()) return null;
      current = next;
      if (!isShortMapsUrl(current.toString())) {
        final info = parseMapsUrl(current.toString());
        return info.hasCoordinates || info.hasCity || info.placeName.isNotEmpty
            ? info
            : null;
      }
    }
    return null;
  }

  static final _longMaps = RegExp(
      r'https?://(?:www\.)?(?:google\.[a-z.]{2,7}|maps\.google\.[a-z.]{2,7})/maps\S{0,400}',
      caseSensitive: false);

  static String? _mapsUrlIn(String body) {
    if (body.isEmpty) return null;
    final at = _longMaps.firstMatch(body);
    return at?[0]?.replaceAll('&amp;', '&');
  }

  /// Text-ready line for `details`: what the link resolved to, or why it did not.
  static String evidenceLine(MapsInfo? info, String originalUrl) {
    if (info == null) {
      return 'لینک کوتاه باز نشد (بدون اینترنت یا مسدود)؛ مکان از آن استنتاج نشد';
    }
    final parts = <String>[
      if (info.hasCoordinates) 'مختصات ${info.coordinates}',
      if (info.placeName.isNotEmpty) 'مکان «${info.placeName}»',
      if (info.city.isNotEmpty) 'شهر ${info.city}',
      'از بازکردن $originalUrl',
    ];
    return parts.join(' • ');
  }
}
