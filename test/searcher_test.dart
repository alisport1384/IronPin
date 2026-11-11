import 'package:flutter_test/flutter_test.dart';
import 'package:ironpin/domain/maps_link.dart';
import 'package:ironpin/domain/market.dart';
import 'package:ironpin/domain/ocr.dart';
import 'package:ironpin/domain/phone_city.dart';
import 'package:ironpin/domain/searcher.dart';
import 'package:ironpin/domain/text_engine.dart';

final now = DateTime.utc(2026, 11, 11, 9);

List<Quote> analyze(String text,
        {DateTime? published,
        bool image = false,
        double? confidence,
        String endpoint = 'search-test'}) =>
    TextPriceEngine.analyze(
        text: text,
        endpoint: endpoint,
        seller: 'فروشنده',
        sourceUrl: 'https://eitaa.com/steel',
        fetchedAt: now,
        postId: '1',
        publishedAt: published,
        image: image,
        ocrConfidence: confidence,
        ocrEngine: confidence == null ? '' : 'tesseract-fas+eng');

/// The picture the user reported: price list + landline + map link.
const photoText = '''لیست قیمت روز
میلگرد آجدار سایز 16 A3
قیمت هر کیلو : 42,500 تومان
تیرآهن 18 IPE
قیمت هر کیلو : 38,900 تومان
تلفن ثابت: 031-34155000
موبایل: 09151234567
آدرس: اصفهان، شهرک صنعتی جی
https://www.google.com/maps/place/Isfahan/@32.6546,51.6680,12z''';

void main() {
  group('phone → city', () {
    test('a full landline locates its city, a mobile never does', () {
      final fixed = classifyPhone('031-34155000');
      expect(fixed.kind, 'ثابت');
      expect(fixed.city, 'اصفهان');
      expect(fixed.complete, true);

      final mobile = classifyPhone('09151234567');
      expect(mobile.kind, 'موبایل');
      expect(mobile.city, '');
      expect(mobile.operator, 'همراه اول');
      expect(mobile.evidence, contains('شهر از شماره همراه تعیین نمی‌شود'));
    });

    test('a truncated area code the channel wrote is still evidence', () {
      final info = classifyPhone('03134155');
      expect(info.city, 'اصفهان');
      expect(info.complete, false);
      expect(info.evidence, contains('ناقص'));
      expect(landlineCityIn('☎️ 03134155'), 'اصفهان');
    });

    test('+98 and Persian digits normalise', () {
      expect(classifyPhone('+98 21 8888 7777').city, 'تهران');
      expect(classifyPhone('۰۵۱۳۸۴۳۰۰۰۰').city, 'مشهد');
    });

    test('an unknown prefix does not invent a city', () {
      final info = classifyPhone('09991234567');
      expect(info.city, '');
      expect(info.operator, '');
    });

    test('an order code next to a phone is not read as the phone', () {
      final phones = phonesIn('تلفن 051-38430000 کد 12345678901234567890');
      expect(phones.first.city, 'مشهد');
    });
  });

  group('maps link', () {
    test('a long link gives coordinates, place name and city', () {
      final info = parseMapsUrl(
          'https://www.google.com/maps/place/Mashhad/@36.2972,59.6067,12z');
      expect(info.hasCoordinates, true);
      expect(info.lat, closeTo(36.2972, 1e-4));
      expect(info.lng, closeTo(59.6067, 1e-4));
      expect(info.placeName, 'Mashhad');
      expect(info.inIran, true);
    });

    test('place names the app knows are read as a city', () {
      final info = parseMapsUrl(
          'https://www.google.com/maps/place/اصفهان,+شهرک+صنعتی+جی/@32.6,51.6,14z');
      expect(info.city, 'اصفهان');
    });

    test('?q=lat,lng and !3d!4d shapes are understood', () {
      expect(parseMapsUrl('https://maps.google.com/?q=35.7,51.4').lng,
          closeTo(51.4, 1e-6));
      expect(
          parseMapsUrl(
                  'https://www.google.com/maps/place/x/data=!3d36.31!4d59.55?x=1')
              .lat,
          closeTo(36.31, 1e-6));
    });

    test('a short link is stored as unresolved, never guessed', () {
      final info = parseMapsUrl('https://maps.app.goo.gl/AbCdEf123');
      expect(info.kind, 'لینک کوتاه');
      expect(info.hasCoordinates, false);
      expect(info.evidence, contains('لینک کوتاه'));
    });

    test('coordinates outside Iran are refused', () {
      final info = parseMapsUrl('https://www.google.com/maps/@48.85,2.35,12z');
      expect(info.inIran, false);
      expect(info.hasCoordinates, false);
    });
  });

  group('image analysis (the reported photo)', () {
    List<Quote> run({double confidence = 0.88}) => Searcher.process(
            analyze(photoText,
                published: now, image: true, confidence: confidence),
            now: now,
            windowDays: 30)
        .quotes;

    test('products, prices and the city all come out of one picture', () {
      final rows = run();
      expect(rows.length, 2);
      final rebar = rows.firstWhere((q) => q.title.contains('میلگرد'));
      final beam = rows.firstWhere((q) => q.title.contains('تیرآهن'));
      expect(rebar.amount, 42500);
      expect(beam.amount, 38900);
      expect(rebar.currency, 'تومان');
      expect(rebar.sellerCity, 'اصفهان');
      expect(rebar.details['مبنای شهر'], contains('آدرس'));
      expect(rebar.details['شماره 1'], contains('031'));
      expect(rebar.details['نقشه 1'], contains('مختصات'));
      expect(rebar.details['اطمینان OCR'], '88٪');
    });

    test('the phone number resolves the city when no address is written', () {
      final rows = Searcher.process(
              analyze('''ورق گالوانیزه ضخامت 2
قیمت : 61,300 تومان
تلفن: 051-38430000''', published: now, image: true, confidence: 0.8),
              now: now,
              windowDays: 30)
          .quotes;
      expect(rows.length, 1);
      expect(rows.single.sellerCity, 'مشهد');
      expect(rows.single.details['مبنای شهر'], contains('پیش‌شماره'));
    });

    test('a disagreement between map and phone is recorded, not hidden', () {
      final rows = Searcher.process(
              analyze('''نبشی 100x10
قیمت : 55,000 تومان
تلفن: 051-38430000
https://www.google.com/maps/place/Isfahan/@32.65,51.66,12z''',
                  published: now, image: true, confidence: 0.8),
              now: now,
              windowDays: 30)
          .quotes;
      expect(rows.single.details['تعارض شهر'], contains('نقشه'));
      expect(rows.single.details['تعارض شهر'], contains('تلفن'));
      expect(rows.single.sellerCity, 'اصفهان');
    });

    test('a low OCR confidence keeps the row but marks the digits', () {
      final rows = Searcher.process(
              analyze('میلگرد سایز 16 A3\nقیمت : 42,500 تومان',
                  published: now, image: true, confidence: 0.4),
              now: now,
              windowDays: 30)
          .quotes;
      expect(rows.single.status, contains('اطمینان OCR'));
    });

    test('nothing is stored when the picture holds no product or price', () {
      final result = Searcher.process(
          analyze('کاغذ یادداشت\nبا تشکر از همکاری شما',
              published: now, image: true, confidence: 0.5),
          now: now,
          windowDays: 30);
      expect(result.quotes, isEmpty);
      expect(result.noise, greaterThan(0));
    });
  });

  group('searcher rules', () {
    test('rows outside the parent window are dropped', () {
      final old = analyze('میلگرد سایز 16 A3\nقیمت : 42,500 تومان',
          published: DateTime.utc(2026, 8, 1));
      final result =
          Searcher.process(old, now: now, windowDays: 30);
      expect(result.quotes, isEmpty);
      expect(result.outOfWindow, 1);
    });

    test('the same offer twice becomes one row', () {
      final rows = [
        ...analyze('میلگرد سایز 16 A3\nقیمت : 42,500 تومان', published: now),
        ...analyze('میلگرد سایز 16 A3\nقیمت : 42,500 تومان',
            published: now, endpoint: 'other-source'),
      ];
      final result = Searcher.process(rows, now: now, windowDays: 30);
      expect(result.quotes.length, 1);
      expect(result.duplicates, 1);
    });

    test('prose without a product is not saved as a row', () {
      final result = Searcher.process(
          analyze('با سلام خدمت مشتریان گرامی\nفروشگاه ما تعطیل است',
              published: now),
          now: now,
          windowDays: 30);
      expect(result.quotes, isEmpty);
    });

    test('rows are ordered by family, then product, then city', () {
      final rows = Searcher.process([
        ...analyze('تیرآهن 18 IPE\nقیمت : 38,900 تومان', published: now),
        ...analyze('میلگرد سایز 16 A3\nقیمت : 42,500 تومان', published: now),
      ], now: now, windowDays: 30).quotes;
      expect(rows.first.title, contains('میلگرد'));
      expect(rows.last.title, contains('تیرآهن'));
    });

    test('each family knows the features it needs', () {
      final rows = Searcher.process(
          analyze('میلگرد آجدار سایز 16\nقیمت : 42,500 تومان',
              published: now),
          now: now,
          windowDays: 30).quotes;
      expect(rows.single.details['خانواده محصول'], 'میلگرد');
      expect(rows.single.details['نقص مشخصات'], contains('گرید'));
    });

    test('counts are grouped by product family', () {
      final result = Searcher.process([
        ...analyze('میلگرد سایز 16 A3\nقیمت : 42,500 تومان', published: now),
        ...analyze('تیرآهن 18 IPE\nقیمت : 38,900 تومان', published: now),
      ], now: now, windowDays: 30);
      expect(result.categories['میلگرد'], 1);
      expect(result.categories['تیرآهن'], 1);
    });
  });

  group('OCR text repair', () {
    test('product vocabulary survives, common misreads are repaired', () {
      final cleaned = Searcher.cleanOcrText('آهن كيلو 42 500 تومان\r\n\r\n');
      expect(cleaned, contains('آهن'));
      expect(cleaned, contains('کیلو'));
      expect(cleaned, contains('42,500'));
      expect(cleaned.contains('\n\n'), false);
    });

    test('digits misread as letters are repaired only between digits', () {
      expect(Searcher.cleanOcrText('1O8 عدد'), '108 عدد');
      expect(Searcher.cleanOcrText('IPE لوله'), 'IPE لوله');
    });

    test('quality score rises with real content and never reaches 1', () {
      final low = OcrQuality.score('تصویر');
      final high = OcrQuality.score(photoText);
      expect(high, greaterThan(low));
      expect(high, lessThanOrEqualTo(0.95));
    });
  });
}
