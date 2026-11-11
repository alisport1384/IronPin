import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ironpin/data/public_messages.dart';
import 'package:ironpin/domain/market.dart';
import 'package:ironpin/domain/ocr.dart';
import 'package:ironpin/domain/photo_scan.dart';
import 'package:ironpin/domain/searcher.dart';
import 'package:ironpin/domain/text_engine.dart';

final now = DateTime.utc(2026, 11, 11, 9);

class FakeOcr implements OcrEngine {
  final String text;
  final double? confidence;
  int calls = 0;
  FakeOcr(this.text, {this.confidence = 0.85});

  @override
  Future<OcrResult> recognize(String path) async {
    calls++;
    return OcrResult(text, confidence: confidence, engine: 'fake-tesseract');
  }

  @override
  Future<String?> cacheDirectory() async => Directory.systemTemp.path;
}

/// A post that carries nothing but a picture, exactly as the reader builds it.
Quote photoOnlyPost(String url) => TextPriceEngine.analyze(
    text: 'لیست قیمت',
    endpoint: 'telegram-shahrahan',
    seller: 'کانال',
    sellerCity: 'نامشخص',
    sourceUrl: 'https://t.me/shahrahan/12',
    fetchedAt: now,
    postId: 'shahrahan/12',
    publishedAt: now,
    image: true,
    photoUrl: url).first;

void main() {
  const priceList = '''
قیمت میلگرد
#میلگرد
میلگرد آجدار سایز 16 A3
11,890,000 تومان
تلفن: 021-91323000''';

  test('a picture the post published is read automatically, no manual pick',
      () async {
    final ocr = FakeOcr(priceList);
    final scanner = PhotoScanner(
        client: MockClient((request) async =>
            http.Response.bytes([0xFF, 0xD8, 0xFF, 0xE0], 200,
                headers: {'content-type': 'image/jpeg'})),
        engine: ocr);
    final batch = await readPostPhotos(
        [photoOnlyPost('https://cdn/x.jpg')], scanner);
    expect(ocr.calls, 1);
    expect(batch.read, 1);
    // The rows the picture produced then go through the ordinary searcher.
    final found = Searcher.process(batch.rows, now: now, windowDays: 30);
    final priced = found.quotes.where((q) => q.amount == 11890000).toList();
    expect(priced.isNotEmpty, true);
    expect(priced.first.sellerCity, 'تهران');
    expect(priced.first.details['پیوست تصویر'], 'https://cdn/x.jpg');
    // The reader hands the full text to the searcher as evidence…
    expect(batch.rows.any((q) => (q.details['متن OCR'] ?? '').contains('میلگرد')),
        true);
    // …and the searcher stores the item, not the text (0.9.2).
    expect(found.quotes.any((q) => q.details.containsKey('متن OCR')), false);
  });

  test('an unreadable picture keeps the post and records why', () async {
    final scanner = PhotoScanner(
        client: MockClient((request) async => http.Response.bytes(
            [0x00], 200, headers: {'content-type': 'image/jpeg'})),
        engine: FakeOcr(''));
    final batch =
        await readPostPhotos([photoOnlyPost('https://cdn/y.jpg')], scanner);
    expect(batch.read, 0);
    expect(batch.failed, 1);
    expect(batch.rows.single.details['خواندن تصویر'], contains('متن خوانایی'));
  });

  test('a download failure never blocks the source', () async {
    final scanner = PhotoScanner(
        client: MockClient((request) async => http.Response('nope', 500)),
        engine: FakeOcr(priceList));
    final batch =
        await readPostPhotos([photoOnlyPost('https://cdn/z.jpg')], scanner);
    expect(batch.rows.length, 1);
    expect(batch.rows.single.details['خواندن تصویر'], contains('500'));
  });

  test('without an OCR engine the picture is not even downloaded', () async {
    var requests = 0;
    final scanner = PhotoScanner(
        client: MockClient((request) async {
          requests++;
          return http.Response('', 200);
        }),
        engine: const UnavailableOcrEngine());
    final batch =
        await readPostPhotos([photoOnlyPost('https://cdn/w.jpg')], scanner);
    expect(requests, 0);
    expect(batch.rows.single.details['خواندن تصویر'], contains('در دسترس نیست'));
  });

  test('the reader finds the picture a post carries', () {
    final doc = html.parse('''
      <div class="tgme_widget_message">
        <a class="tgme_widget_message_photo_wrap"
           style="background-image:url('https://cdn4.telesco.pe/file/price-table.jpg')"></a>
        <div class="tgme_widget_message_text">قیمت میلگرد</div>
      </div>''');
    final box = doc.querySelector('.tgme_widget_message')!;
    expect(PublicMessages.photoOf(box, Uri.parse('https://t.me/s/shahrahan')),
        'https://cdn4.telesco.pe/file/price-table.jpg');
  });

  test('emoji and avatars are not mistaken for a price list', () {
    final doc = html.parse('''
      <div><img class="emoji" src="https://t.me/img/emoji/1.png">
      <img class="avatar" src="https://t.me/img/avatar/1.png">
      <img src="https://eitaa.com/img/table-price.jpg"></div>''');
    expect(
        PublicMessages.photoOf(doc.querySelector('div')!,
            Uri.parse('https://eitaa.com/s/shahr_ahan')),
        'https://eitaa.com/img/table-price.jpg');
  });
}
