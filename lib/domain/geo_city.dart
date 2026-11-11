import 'dart:math' as math;

import 'geo_cities.g.dart';

/// Offline place knowledge: where a pair of map coordinates is, without a
/// geocoder and without a network call.
///
/// A seller's map link carries coordinates, not a city name. The bundled table
/// (GeoNames, CC BY 4.0) lists the populated places of Iran with their centre,
/// population and province, so a coordinate can be answered with the city it
/// falls in — or, outside every city, with the nearest one and the distance,
/// which is stated as such and never passed off as the seller's own words.
class GeoCity {
  final String name, province;
  final double lat, lng;
  final int population;
  const GeoCity(this.name, this.province, this.lat, this.lng, this.population);

  /// Rough radius of the built-up area, from the population alone.
  double get radiusKm =>
      (2 + math.sqrt(population) / 55).clamp(2.5, 50).toDouble();
}

class GeoHit {
  final GeoCity city;
  final double km;

  /// True when the point lies inside the city's own estimated radius.
  final bool inside;
  const GeoHit(this.city, this.km, this.inside);

  String get evidence => inside
      ? 'مختصات داخل محدوده ${city.name} (استان ${city.province})'
      : 'نزدیک‌ترین شهر به مختصات: ${city.name} '
          '(استان ${city.province}، حدود ${km.round()} کیلومتر)';
}

class Geo {
  static List<GeoCity>? _cities;
  static Map<String, Set<String>>? _provinces;

  static List<GeoCity> get cities => _cities ??= _load();

  static List<GeoCity> _load() {
    final out = <GeoCity>[];
    for (final line in geoCityTable.split('\n')) {
      final f = line.split('|');
      if (f.length != 5) continue;
      final lat = double.tryParse(f[1]), lng = double.tryParse(f[2]);
      final province = int.tryParse(f[4]);
      if (lat == null || lng == null || province == null) continue;
      out.add(GeoCity(
          f[0], geoProvinces[province], lat, lng, int.tryParse(f[3]) ?? 0));
    }
    return out;
  }

  /// One spelling for a place name: Arabic letter forms, half-spaces and
  /// spaces are all the same city to a reader.
  static String key(String name) => name
      .replaceAll('ي', 'ی')
      .replaceAll('ك', 'ک')
      .replaceAll('ئ', 'ی')
      .replaceAll(RegExp('[\u200c\\s\\-]+'), '')
      .trim();

  static double distanceKm(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371.0;
    final dLat = (lat2 - lat1) * math.pi / 180;
    final dLng = (lng2 - lng1) * math.pi / 180;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180) *
            math.cos(lat2 * math.pi / 180) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return 2 * r * math.asin(math.min(1, math.sqrt(a)));
  }

  /// The city a coordinate belongs to, or the nearest one within [maxKm].
  ///
  /// A point inside several estimated city areas goes to the one it is most
  /// central to (distance relative to that city's own radius), so a yard in
  /// اسلامشهر is not answered with تهران just because Tehran is large.
  static GeoHit? nearest(double lat, double lng, {double maxKm = 45}) {
    GeoHit? inside, near, metropolis;
    var insideScore = double.infinity;
    for (final c in cities) {
      // Cheap reject before the trigonometry: one degree is at least ~85 km.
      if ((c.lat - lat).abs() > 1 || (c.lng - lng).abs() > 1.2) continue;
      final d = distanceKm(lat, lng, c.lat, c.lng);
      if (d <= c.radiusKm) {
        final score = d / c.radiusKm;
        if (score < insideScore) {
          insideScore = score;
          inside = GeoHit(c, d, true);
        }
        // The built-up core of a city of a million people or more. The table
        // also lists quarters and satellite records that lie inside such a
        // city; a point in the core belongs to the city itself.
        if (c.population >= 1000000 &&
            d <= c.radiusKm * metropolisCore &&
            (metropolis == null || d < metropolis.km)) {
          metropolis = GeoHit(c, d, true);
        }
      } else if (d <= maxKm && (near == null || d < near.km)) {
        near = GeoHit(c, d, false);
      }
    }
    if (metropolis != null &&
        inside != null &&
        inside.city != metropolis.city &&
        inside.city.population < 200000) {
      return metropolis;
    }
    return inside ?? near;
  }

  /// Share of a metropolis radius counted as its own built-up core
  /// (Tehran: 21 km of 50; Mashhad: about 15 km).
  static const metropolisCore = 0.42;

  /// Provinces that have a place of this name (usually one).
  static Set<String> provincesOf(String city) {
    final index = _provinces ??= () {
      final map = <String, Set<String>>{};
      for (final c in cities) {
        (map[key(c.name)] ??= <String>{}).add(c.province);
      }
      return map;
    }();
    return index[key(city)] ?? const {};
  }

  /// The province of a city when the name is unambiguous, else `''`.
  static String provinceOf(String city) {
    final all = provincesOf(city);
    if (all.length == 1) return all.first;
    if (all.isEmpty) return '';
    // Several places share the name: the largest one is what a seller means
    // when writing it without a province («دولت‌آباد» is ambiguous, «تهران» not).
    GeoCity? best;
    for (final c in cities) {
      if (key(c.name) != key(city)) continue;
      if (best == null || c.population > best.population) best = c;
    }
    return best != null && best.population >= 100000 ? best.province : '';
  }
}
