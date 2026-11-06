import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ironpin/domain/market.dart';
import 'package:ironpin/domain/text_engine.dart';
import 'package:ironpin/data/sources.dart';
import 'package:ironpin/data/public_messages.dart';

final now = DateTime.utc(2026, 11, 6, 12);
List<Quote> analyze(String text, {DateTime? published}) =>
    TextPriceEngine.analyze(
        text: text,
        endpoint: 'text-test',
        seller: 'فروشنده',
        sourceUrl: 'https://eitaa.com/steel',
        fetchedAt: now,
        postId: '1',
        publishedAt: published);
const modiran = '''📆 پنج‌شنبه 14 آبان 1405
#میلگرد_آجدار_آناهیتا_گیلان
سایز 8 (A2) ⬅️ 133,000 تومان 🔻2,000 تومان
سایز 10 (A2) ⬅️ 130,000 تومان 🔻2,000 تومان
سایز 12 (A3) ⬅️ 127,000 تومان 🔻2,000 تومان
☎️ 03134155''';
void main() {
  test(
      'Persian month with and without ماه, slash/dash/dot dates are equivalent',
      () {
    final d = sourceDate('1405/08/14');
    for (final s in [
      '۱۴ آبان ماه ۱۴۰۵',
      '۱۴ آبان ۱۴۰۵',
      '1405-08-14',
      '1405.08.14'
    ]) {
      expect(sourceDate(s), d, reason: s);
    }
    expect(sourceDate('1405/13/40'), null);
    expect(sourceDate('1405/8/14 25:80'), null);
  });
  test('real reviewed Eitaa caption splits models and ignores decreases', () {
    final rows = analyze(modiran);
    expect(rows.length, 3);
    expect(rows.map((q) => q.amount), [133000, 130000, 127000]);
    expect(rows.map((q) => q.sizeLabel), ['8', '10', '12']);
    expect(rows.map((q) => q.gradeLabel), ['A2', 'A2', 'A3']);
    expect(
        rows.every((q) =>
            q.unit == 'unknown' &&
            q.priceFor('kg') == null &&
            q.isWithinWeek(now)),
        true);
    expect(rows.first.announcedAt, sourceDate('1405/8/14'));
    expect(rows.first.publishedAt, null);
  });
  test('explicit currency and kilogram basis permit numeric comparisons', () {
    final r = analyze(
            '1405/08/15\nقیمت هر کیلوگرم به تومان\nمیلگرد 16 نیشابور : 125,000 تومان')
        .single;
    expect(r.unit, 'kg');
    expect(r.priceFor('kg'), 125000);
  });
  test('physical branch hashtag is NOT a pricing basis', () {
    final r = analyze(
            '1405-08-15\n#میلگرد_شاخه_انبار_مشهد\nمیلگرد 16 A3 نیشابور 125,000 تومان')
        .single;
    expect(r.amount, 125000);
    expect(r.unit, 'unknown');
  });
  test('separate product and amount lines and dot thousand separators', () {
    final r = analyze(
            '1405/08/15\nقیمت بر مبنای شاخه و تومان می باشد\nتیرآهن 14 اصفهان\n⬅ 7.600.000 تومان')
        .single;
    expect(r.amount, 7600000);
    expect(r.unit, 'piece');
    expect(r.sizeLabel, '14');
  });
  test(
      'unknown currency retains visible raw candidate, never promotes conversion',
      () {
    final r = analyze('1405-08-14\nمیلگرد 16 A3 نیشابور 123,050').single;
    expect(r.hasTextAmount, true);
    expect(r.amount, null);
    expect(r.currency, 'نامشخص');
    expect(r.details['مبلغ استخراج‌شده'], '123,050');
    expect((MarketFilter()..recentWeek = true).apply([r], now).length, 1);
  });
  test('price date wins over fresh re-publication', () {
    final r =
        analyze('1404/03/19\nتیرآهن 14 اصفهان 7,600,000 تومان', published: now)
            .single;
    expect(r.isWithinWeek(now), false);
    expect(r.publishedAt, now);
  });
  test('publication can date an undated rate but is not copied to announcedAt',
      () {
    final r = analyze('میلگرد 16 قیمت 125,000 تومان', published: now).single;
    expect(r.announcedAt, null);
    expect(r.marketAt, now);
    expect(r.isWithinWeek(now), true);
    expect(r.details['مبنای تاریخ'], contains('انتشار'));
  });
  test('fetch time cannot date undated messages', () {
    final r = analyze('میلگرد 16 قیمت 125,000 تومان').single;
    expect(r.marketAt, null);
    expect(r.isWithinWeek(now), false);
  });
  test('future and invalid explicit dates are not recent', () {
    expect(
        analyze('1405/09/20\nمیلگرد 16 125,000 تومان').single.isWithinWeek(now),
        false);
    expect(
        analyze('1405/13/40\nمیلگرد 16 125,000 تومان', published: now)
            .single
            .isWithinWeek(now),
        false);
  });
  test('7x24h inclusive boundary and newest across unrelated groups', () {
    final old = analyze('میلگرد 16 125,000 تومان',
            published: now.subtract(const Duration(days: 7)))
        .single;
    final fresh =
        analyze('ورق ضخامت 8 قیمت 130,000 تومان', published: now).single;
    final tooOld = analyze('میلگرد 18 125,000 تومان',
            published: now.subtract(const Duration(days: 7, seconds: 1)))
        .single;
    final f = MarketFilter()
      ..recentWeek = true
      ..sort = 'latest';
    expect(f.apply([old, tooOld, fresh], now).map((q) => q.title),
        [fresh.title, old.title]);
  });
  test('phone, quantities, changes and dates never become prices', () {
    final rows = analyze(
        '1405/8/15\nمیلگرد 16\n09151185927\nکاهش 2000 تومان\nحداقل سفارش 20000 کیلو\nتلفن 051-91003636');
    expect(rows.where((q) => q.hasTextAmount), isEmpty);
  });
  test('multiple unlabelled amounts are ambiguous, not arbitrarily selected',
      () {
    expect(
        analyze('میلگرد 16 : 120000 یا 125000').where((q) => q.hasTextAmount),
        isEmpty);
  });
  test(
      'currency conversion is never guessed and small explicit amounts are literal',
      () {
    final r = analyze('قیمت هر کیلو\nمیلگرد 16 : 125 ریال').single;
    expect(r.amount, 125);
    expect(r.currency, 'ریال');
  });
  test('terms, tax, length and branch mass require explicit evidence', () {
    final r = analyze(
            '1405/8/15\nقیمت هر شاخه به تومان\nمیلگرد 16 طول شاخه 12 متر وزن شاخه 24 کیلو 3,000,000 تومان\nتحویل مشهد؛ نقدی؛ بدون ارزش افزوده')
        .single;
    expect(r.tax, 'بدون ارزش افزوده');
    expect(r.terms, contains('نقدی'));
    expect(r.lengthM, 12);
    expect(r.pieceKg, 24);
    expect(r.priceFor('kg'), 125000);
  });
  test('stable IDs survive price edits', () {
    expect(analyze(modiran).first.id,
        analyze(modiran.replaceFirst('133,000', '135,000')).first.id);
  });
  test('actual Telegram fixture now yields price models without assuming kg',
      () {
    final e = endpoints.firstWhere((e) => e.parser == 'telegram');
    final rows = SourceParser.parse(
        e, File('test/fixtures/telegram.html').readAsStringSync(), now);
    expect(rows.where((q) => q.hasTextAmount).length, 8);
    expect(rows.first.amount, 20181000);
    expect(rows.first.announcedAt, sourceDate('1405/8/14'));
    expect(rows.first.unit, 'unknown');
    expect(rows.first.publishedAt, isNotNull);
  });
  test('semantic Eitaa post anchors do not join neighbouring messages', () {
    const e = SourceEndpoint('eitaa-test', 'آهن', 'https://eitaa.com/steel',
        'عمومی', 'eitaa', 'نامشخص');
    const page =
        '''<main><article><p>1405/08/14</p><p>قیمت هر کیلو به تومان</p><p>میلگرد 16 : 125,000 تومان</p><a href="https://eitaa.com/s/steel/1"><time datetime="2026-11-05T08:00:00Z">11:30</time></a></article><article><p>1405/08/15</p><p>قیمت هر شاخه به تومان</p><p>تیرآهن 14 : 7,600,000 تومان</p><a href="https://eitaa.com/s/steel/2">10:30</a></article></main>''';
    final r = SourceParser.parse(e, page, now);
    expect(r.length, 2);
    expect(r[0].unit, 'kg');
    expect(r[1].unit, 'piece');
    expect(r[0].publishedAt, DateTime.utc(2026, 11, 5, 8));
    expect(r[1].publishedAt, null);
  });
  test('Rubika profile is not a post or price and cannot pretend success', () {
    const e = SourceEndpoint('rubika-test', 'تهمتن',
        'https://rubika.ir/TahamtanIron', 'عمومی', 'rubika', 'نامشخص');
    expect(
        () => SourceParser.parse(
            e,
            '<h1>فولاد گستر تهمتن</h1><p>2,107 مشترک</p><p>میلگرد و تیرآهن</p><p>09151185927</p>',
            now),
        throwsFormatException);
  });
  test('only observed safe same-channel older links are followed', () {
    expect(
        PublicMessages.older(
            'https://eitaa.com/steel', '<a href="/steel?before=5">قبلی</a>'),
        'https://eitaa.com/steel?before=5');
    expect(
        PublicMessages.older('https://eitaa.com/steel',
            '<a href="https://evil.test/steel?before=5">قبلی</a>'),
        null);
  });
  test('discovery allows public handles, never phone/admin/bot/invite/SSRF',
      () {
    expect(publicChannel('https://rubika.ir/TahamtanIron')?.parser, 'rubika');
    for (final u in [
      'https://rubika.ir/989139595788',
      'https://ble.ir/join/abc',
      'https://eitaa.com/@admin',
      'http://127.0.0.1/test',
      'https://t.me/steelbot',
      'https://user:pass@eitaa.com/steel',
      'https://eitaa.com:444/steel'
    ]) {
      expect(publicChannel(u), null, reason: u);
    }
  });
  test('pagination merges messages and records bounded partial coverage',
      () async {
    var calls = 0;
    final client = SourceClient(
        maxChannelPages: 2,
        client: MockClient((request) async {
          calls++;
          final id = calls;
          return http.Response.bytes(
              utf8.encode(
                  '<article><p>1405/08/15</p><p>میلگرد 16 : 125,000 تومان</p><a href="/s/steel/$id">10:30</a></article><a href="/steel?before=${10 - id}">قبلی</a>'),
              200);
        }));
    const e = SourceEndpoint(
        'paging', 'آهن', 'https://eitaa.com/steel', 'عمومی', 'eitaa', 'نامشخص');
    final r = await client.fetch(e);
    expect(r.length, 2);
    expect(calls, 2);
    expect(client.complete[e.id], false);
    client.close();
  });
  test('range remains visible but never becomes the upper bound price', () {
    final r = analyze('1405/8/15\nمیلگرد 16 : 120000 تا 125000 تومان').single;
    expect(r.amount, null);
    expect(r.hasTextAmount, true);
    expect(r.details['مبلغ استخراج‌شده'], '120000 تا 125000');
  });
  test('relative dates use publication, never fetch time', () {
    final p = DateTime.utc(2026, 11, 5, 9);
    final r =
        analyze('قیمت امروز\nمیلگرد 16 125000 تومان', published: p).single;
    expect(r.announcedAt, sourceDate('1405/8/14'));
    expect(r.details['مبنای تاریخ'], contains('نسبی'));
    expect(
        analyze('قیمت امروز\nمیلگرد 16 125000 تومان').single.announcedAt, null);
  });
  test('same-day rate uses publication time for latest order, not fetch time',
      () {
    final p = DateTime.utc(2026, 11, 5, 9);
    expect(
        analyze('1405/8/14\nمیلگرد 16 125000 تومان', published: p)
            .single
            .marketAt,
        p);
  });
  test('product and contact in one line keeps actual price', () {
    expect(
        analyze('میلگرد 16 قیمت 125000 تومان تماس 09151185927').single.amount,
        125000);
  });
  test('invalid Gregorian dates are not normalized into a different day', () {
    expect(sourceDate('2026-02-31T08:00:00Z'), null);
  });
  test('older-page failure preserves the latest parsed page as partial',
      () async {
    var n = 0;
    final client = SourceClient(client: MockClient((_) async {
      if (n++ > 0) return http.Response('error', 503);
      return http.Response.bytes(
          utf8.encode(
              '<article><p>1405/08/15</p><p>میلگرد 16 : 125000 تومان</p><a href="/s/steel/1">10:30</a></article><a href="/steel?before=1">قبلی</a><a href="https://eitaa.com/new_steel">آهن</a>'),
          200);
    }));
    const e = SourceEndpoint('partial', 'آهن', 'https://eitaa.com/steel',
        'عمومی', 'eitaa', 'نامشخص');
    expect((await client.fetch(e)).length, 1);
    expect(client.complete[e.id], false);
    expect(
        client.discoveries[e.id]!
            .any((e) => e.url == 'https://eitaa.com/new_steel'),
        true);
    client.close();
  });
  test(
      'explicit thousands/millions and toman spelling are literal, not magnitude guesses',
      () {
    expect(analyze('میلگرد 16 : 125 هزار تومن').single.amount, 125000);
    expect(analyze('تیرآهن 14 : 7.6 میلیون تومان').single.amount, 7600000);
    expect(analyze('میلگرد 16 : 125 تومان').single.amount, 125);
  });
  test(
      'real source pattern: model heading before date retains context and literal kg basis',
      () {
    final r = analyze(
            '#میلگرد_درپاد_تبریز\n📆 شنبه 11 مهر ماه 1405\nسایز 10 (A2) هر کیلو⬅️ 113000 تومان\nمحل بارگیری: کارخانه (تبریز)\nنحوه تسویه: نقدی\nقیمت با احتساب ارزش افزوده')
        .single;
    expect(r.amount, 113000);
    expect(r.unit, 'kg');
    expect(r.category, 'میلگرد');
    expect(r.brand, contains('درپاد'));
    expect(r.tax, 'با ارزش افزوده');
    expect(r.isWithinWeek(now), false);
  });
  test('width/dimensions/quantities are not mistaken for unlabelled prices',
      () {
    for (final text in [
      'ورق ضخامت 0.6 عرض 1250',
      'ورق ابعاد 1250×2500',
      'ورق 2000 میلی متر',
      'میلگرد 16 وزن 2000 کیلو'
    ]) {
      expect(analyze(text).where((q) => q.hasTextAmount), isEmpty,
          reason: text);
    }
  });
  test('model dimensions preceding a separate price line remain attached', () {
    final r = analyze('قیمت ورق\nضخامت 0.6 عرض 1250\n125000 تومان').single;
    expect(r.amount, 125000);
    expect(r.thicknessLabel, '0.6');
    expect(r.title, contains('1250'));
  });
  test('emoji cleanup never leaves an unpaired UTF16 surrogate', () {
    final r = analyze('🔸میلگرد 16 : 125000 تومان').single;
    expect(r.title.runes.any((r) => r >= 0xd800 && r <= 0xdfff), false);
  });
  test(
      'reviewed Fiahan heat-treated model and bundle/retail conditions remain explicit',
      () {
    final r = analyze(
            'قیمت میلگرد\nسه شنبه 1405/08/12\nحرارتی 6.5 130,600 تومان\nقیمت های اعلامی به صورت بندیل به فروش می رسد؛ خرده فروشی بالاتر است')
        .single;
    expect(r.title, contains('حرارتی 6.5'));
    expect(r.sizeLabel, '6.5');
    expect(r.amount, 130600);
    expect(r.terms, contains('بندیل'));
    expect(r.unit, 'unknown');
  });
  test(
      'actual manufacturing news years are not a price range, nor substring الی in فعالیت',
      () {
    const news =
        '📌 فولاد کاوه اروند؛ تولیدکننده میلگرد و مفتول فولادی در جنوب کشور شرکت فولاد کاوه اروند در سال 1391 تأسیس شد و در منطقه آزاد اروند, شهر خرمشهر استان خوزستان فعالیت می کند. این کارخانه در زمینی به مساحت حدود 220 هکتار احداث شده و فاز نخست آن در سال 1396 به بهره برداری رسید.';
    expect(analyze(news).where((q) => q.hasTextAmount), isEmpty);
  });
  test(
      'model size and table dimensions cannot become a leading thousands group of the amount',
      () {
    for (final price in ['125,000', '125 000', '125.000']) {
      final r = analyze('میلگرد 16 $price تومان').single;
      expect(r.amount, 125000, reason: price);
      expect(r.sizeLabel, '16');
    }
    final r = analyze('ورق 3 میل 2×1 470.000 ریال').single;
    expect(r.amount, 470000);
    expect(r.thicknessLabel, '3');
    expect(r.dimensionsLabel, '2×1');
  });
  test(
      'explicit fields remain attached to the row; verified mass, length, area and row factory',
      () {
    final r = analyze(
            '1405/08/15\nقیمت هر کیلو به تومان\nورق 3 میل مبارکه عرض 1000 وزن هر برگ 47 کیلوگرم طول 2 متر مساحت هر برگ 2 متر مربع : 125000 تومان')
        .single;
    expect(r.amount, 125000);
    expect(r.brand, contains('مبارکه'));
    expect(r.thicknessLabel, '3');
    expect(r.pieceKg, 47);
    expect(r.lengthM, 2);
    expect(r.areaM2, 2);
    expect(r.details['عرض'], '1000');
  });
}
