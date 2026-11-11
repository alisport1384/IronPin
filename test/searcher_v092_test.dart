import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ironpin/domain/geo_city.dart';
import 'package:ironpin/domain/maps_link.dart';
import 'package:ironpin/domain/maps_resolver.dart';
import 'package:ironpin/domain/market.dart';
import 'package:ironpin/domain/ocr.dart';
import 'package:ironpin/domain/phone_city.dart';
import 'package:ironpin/domain/photo_scan.dart';
import 'package:ironpin/domain/searcher.dart';
import 'package:ironpin/domain/text_engine.dart';

final now = DateTime.utc(2026, 11, 11, 9);

class PassesOcr implements OcrEngine {
  final String text;
  final List<String> passes;
  PassesOcr(this.text, {this.passes = const []});

  @override
  Future<OcrResult> recognize(String path) async => OcrResult(text,
      confidence: 0.8, engine: 'fake-tesseract', passes: passes);

  @override
  Future<String?> cacheDirectory() async => Directory.systemTemp.path;
}

List<Quote> post(String text, {String city = 'نامشخص', String? photo}) =>
    TextPriceEngine.analyze(
        text: text,
        endpoint: 'telegram-test',
        seller: 'کانال',
        sellerCity: city,
        sourceUrl: 'https://t.me/test/5',
        fetchedAt: now,
        postId: 'test/5',
        publishedAt: now,
        image: photo != null,
        photoUrl: photo ?? '');

PhotoScanner scanner(OcrEngine engine) => PhotoScanner(
    client: MockClient((request) async => http.Response.bytes(
        [0xFF, 0xD8, 0xFF, 0xE0], 200,
        headers: {'content-type': 'image/jpeg'})),
    engine: engine);

void main() {
  liveForms();
  group('landline', () {
    test('local number written before the area code is one full number', () {
      final phones = phonesIn('تلفن: ۹۱۳۲۳۰۰۰-۰۲۱');
      expect(phones.length, 1);
      expect(phones.first.digits, '02191323000');
      expect(phones.first.city, 'تهران');
      expect(phones.first.complete, true);
    });

    test('bracketed area code', () {
      expect(phonesIn('(031) 5544 1234').first.digits, '03155441234');
    });

    test('county digits name the county, not the provincial capital', () {
      final kashan = classifyPhone('03155441234');
      expect(kashan.city, 'کاشان');
      expect(kashan.province, 'اصفهان');
      expect(kashan.countyLevel, true);
      expect(classifyPhone('05142221234').city, 'نیشابور');
      expect(classifyPhone('05138001234').city, 'مشهد');
    });

    test('a prefix two counties share stays at province level', () {
      final shared = classifyPhone('03142251234');
      expect(shared.countyLevel, false);
      expect(shared.city, 'اصفهان');
    });

    test('a mobile still proves no place', () {
      expect(classifyPhone('09121234567').hasCity, false);
    });
  });

  group('coordinates', () {
    test('a point inside a city answers with that city and its province', () {
      final tehran = Geo.nearest(35.6892, 51.3890)!;
      expect(tehran.city.name, 'تهران');
      expect(tehran.inside, true);
      final eslamshahr = Geo.nearest(35.5522, 51.2350)!;
      expect(eslamshahr.city.name, 'اسلامشهر');
      expect(eslamshahr.city.province, 'تهران');
      expect(Geo.nearest(36.2972, 59.6067)!.city.name, 'مشهد');
    });

    test('a quarter inside a metropolis answers with the metropolis', () {
      // شهرک گلستان، منطقه ۲۲ تهران (از یک لینک کوتاه واقعی).
      expect(Geo.nearest(35.748899, 51.247462)!.city.name, 'تهران');
      // تجریش و شهر ری بخشی از تهران‌اند.
      expect(Geo.nearest(35.8044, 51.4253)!.city.name, 'تهران');
      expect(Geo.nearest(35.5930, 51.4360)!.city.name, 'تهران');
      // شهرهای مستقل پیرامون تهران سر جای خودشان می‌مانند.
      expect(Geo.nearest(35.7200, 51.1100)!.city.name, 'قدس');
      expect(Geo.nearest(35.8327, 50.9915)!.city.name, 'کرج');
    });

    test('the middle of the desert has no city', () {
      expect(Geo.nearest(33.0, 56.0, maxKm: 20), isNull);
    });

    test('a map link with only coordinates names its city', () {
      final info = parseMapsUrl(
          'https://www.google.com/maps/place/x/@32.65,51.66,17z/data=!3d32.6546!4d51.6680');
      expect(info.city, 'اصفهان');
      expect(info.cityBasis, 'مختصات');
      expect(info.province, 'اصفهان');
    });

    test('Neshan, Balad and Waze links carry coordinates too', () {
      expect(parseMapsUrl('https://nshn.ir/?lat=35.7077402&lng=51.1828453').hasCoordinates, true);
      expect(
          parseMapsUrl('https://balad.ir/location?latitude=29.61&longitude=52.53&zoom=17').city,
          'شیراز');
      expect(parseMapsUrl('https://waze.com/ul?ll=38.08,46.29&z=10').city, 'تبریز');
      expect(isShortMapsUrl('https://nshn.ir/abc_def123'), true);
      expect(isShortMapsUrl('https://nshn.ir/?lat=35.7&lng=51.1'), false);
      expect(mapsLinksIn('لوکیشن: https://nshn.ir/?lat=35.7077402&lng=51.1828453').length, 1);
    });
  });

  group('phone ↔ map comparison', () {
    test('same province: the pin names the city, the phone confirms it', () {
      final rows = post('''
میلگرد آجدار 16 A3 قیمت 42,300 تومان هر کیلو
تلفن: 021-91323000
https://www.google.com/maps?q=35.5522,51.2350''');
      final found = Searcher.process(rows, now: now, windowDays: 30);
      expect(found.quotes, isNotEmpty);
      final q = found.quotes.first;
      expect(q.sellerCity, 'اسلامشهر');
      expect(q.details['مبنای شهر'], 'مختصات لینک نقشه');
      expect(q.details['مقایسه شواهد شهر'], contains('هم‌خوان در سطح استان تهران'));
      expect(q.details.containsKey('تعارض شهر'), false);
      expect(q.details['استان'], 'تهران');
    });

    test('different provinces are a recorded conflict', () {
      final rows = post('''
میلگرد آجدار 16 A3 قیمت 42,300 تومان هر کیلو
تلفن: 031-36201234
https://www.google.com/maps?q=35.6892,51.3890''');
      final q = Searcher.process(rows, now: now, windowDays: 30).quotes.first;
      expect(q.sellerCity, 'تهران');
      expect(q.details['تعارض شهر'], contains('تلفن: اصفهان'));
    });

    test('a short link is opened once for all rows of a post', () async {
      MapsResolver.clearCache();
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        return http.Response('', 302, headers: {
          'location':
              'https://consent.google.com/m?continue=https%3A%2F%2Fwww.google.com%2Fmaps%2Fplace%2FX%2F%4032.65%2C51.66%2C17z%2Fdata%3D!3d32.6546!4d51.6680'
        });
      });
      final rows = post('''
میلگرد 14 A3 قیمت 42,300 تومان هر کیلو
میلگرد 16 A3 قیمت 42,400 تومان هر کیلو
همراه 09121234567
https://maps.app.goo.gl/AbCdEf123456''');
      final found = await Searcher.processAsync(rows,
          now: now, windowDays: 30, resolver: MapsResolver(client));
      expect(calls, 1);
      expect(found.quotes.length, 2);
      expect(found.quotes.every((q) => q.sellerCity == 'اصفهان'), true);
    });
  });

  group('archive holds items, not sentences', () {
    test('message text never reaches a stored row', () {
      final rows = post('''
سلام و عرض ادب خدمت همکاران گرامی، امروز بازار کمی آرام بود و خریدار کم بود.
میلگرد آجدار 16 A3 قیمت 42,300 تومان هر کیلو
تحویل درب کارخانه، نقدی
تلفن: 021-91323000''');
      final q = Searcher.process(rows, now: now, windowDays: 30).quotes.first;
      for (final key in Searcher.proseKeys) {
        expect(q.details.containsKey(key), false, reason: key);
      }
      expect(q.details.values.any((v) => v.contains('عرض ادب')), false);
      expect(q.terms.contains('سلام'), false);
      expect(q.terms, contains('نقدی'));
      expect(q.amount, 42300);
      expect(q.sellerCity, 'تهران');
    });

    test('a product line with no amount is not stored', () {
      final rows = post('میلگرد و تیرآهن موجود است، برای قیمت تماس بگیرید');
      expect(Searcher.process(rows, now: now, windowDays: 30).quotes, isEmpty);
    });

    test('a price ten times its group is flagged, not removed', () {
      final rows = post('''
قیمت میلگرد
میلگرد 10 A3 قیمت 42,300 تومان هر کیلو
میلگرد 12 A3 قیمت 42,400 تومان هر کیلو
میلگرد 14 A3 قیمت 42,500 تومان هر کیلو
میلگرد 16 A3 قیمت 42,600 تومان هر کیلو
میلگرد 18 A3 قیمت 426,000 تومان هر کیلو''');
      final found = Searcher.process(rows, now: now, windowDays: 30);
      expect(found.quotes.length, 5);
      expect(found.flagged, 1);
      final odd = found.quotes.firstWhere((q) => q.amount == 426000);
      expect(odd.details['هشدار قیمت'], contains('نیازمند بازبینی'));
    });
  });

  test('a long list is really decided on a second isolate', () async {
    final rows = [
      for (var i = 0; i < 40; i++)
        ...post('میلگرد ${10 + (i % 8) * 2} A3 قیمت ${42000 + i * 10} تومان هر کیلو\nتلفن: 021-91323000')
    ];
    final found = await Searcher.processInBackground(rows,
        now: now, windowDays: 30);
    expect(found.quotes, isNotEmpty);
    expect(found.quotes.first.sellerCity, 'تهران');
    final same = Searcher.process(rows, now: now, windowDays: 30);
    expect(found.quotes.length, same.quotes.length);
  });

  group('picture rows', () {
    test('the caption locates the rows read from its picture', () async {
      final caption = post('''
لیست قیمت امروز
تلفن: ۹۱۳۲۳۰۰۰-۰۲۱
https://www.google.com/maps?q=35.5522,51.2350''', photo: 'https://cdn/list.jpg');
      final batch = await readPostPhotos(
          caption,
          scanner(PassesOcr('میلگرد آجدار 16 A3\n42,300 تومان هر کیلو')));
      final found = Searcher.process(batch.rows, now: now, windowDays: 30);
      final priced = found.quotes.where((q) => q.amount == 42300).toList();
      expect(priced, isNotEmpty);
      expect(priced.first.sellerCity, 'اسلامشهر');
      expect(priced.first.details['مقایسه شواهد شهر'], contains('هم‌خوان'));
      expect(priced.first.details.containsKey('متن OCR'), false);
    });

    test('the reading that yields priced rows is the one kept', () async {
      final caption = post('لیست قیمت', photo: 'https://cdn/list.jpg');
      final batch = await readPostPhotos(
          caption,
          scanner(PassesOcr('میلگرد آجدار ۰ تومان', passes: [
            'میلگرد آجدار ۰ تومان',
            'میلگرد آجدار 16 A3\n42,300 تومان هر کیلو\nتلفن 021-91323000',
          ])));
      final found = Searcher.process(batch.rows, now: now, windowDays: 30);
      expect(found.quotes.any((q) => q.amount == 42300), true);
      expect(found.quotes.first.sellerCity, 'تهران');
    });

    test('a table-only picture takes its product from the caption', () async {
      final caption =
          post('قیمت میلگرد آجدار ذوب آهن اصفهان', photo: 'https://cdn/t.jpg');
      final batch = await readPostPhotos(
          caption, scanner(PassesOcr('سایز 16 A3 قیمت 42,300 تومان هر کیلو')));
      final found = Searcher.process(batch.rows, now: now, windowDays: 30);
      expect(found.quotes.any((q) => q.amount == 42300), true);
    });
  });
}

// Forms seen on live short links (checked with tool/live_maps.dart).
void liveForms() {
  test('a redirect to /maps/search/lat,+lng carries the point', () {
    final info = parseMapsUrl(
        'https://www.google.com/maps/search/35.748899,+51.247462?coh=219680&entry=tts');
    expect(info.hasCoordinates, true);
    expect(info.city, 'تهران');
  });
}
