import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'market.dart';
import 'ocr.dart';
import 'searcher.dart';
import 'text_engine.dart';

/// What one picture attached to a post produced.
class PhotoRead {
  final String url;
  final String text;

  /// `0..1` when the engine reports it, else the text-based estimate.
  final double? confidence;
  final String engine;
  final String? error;

  const PhotoRead(this.url,
      {this.text = '',
      this.confidence,
      this.engine = 'tesseract',
      this.error});

  bool get ok => text.trim().isNotEmpty;
  String get confidenceLabel => confidence == null
      ? 'نامشخص'
      : '${(confidence! * 100).round()}٪';
}

/// Reads the picture a channel itself published — automatically.
///
/// A public post often carries the price list only as an image. Asking the user
/// to pick that image by hand made the feature pointless: the scan already knows
/// the picture's address, so it downloads it, reads it on the phone with the
/// Persian OCR model, and hands the text to the ordinary analyzer. Nothing is
/// uploaded, the download is bounded, and a failure leaves the post exactly as it
/// was — with the picture kept as evidence.
class PhotoScanner {
  final http.Client client;
  final OcrEngine engine;
  final Duration timeout;
  final int maxBytes;
  final Future<Directory> Function() tempDirectory;

  PhotoScanner({
    required this.client,
    required this.engine,
    this.timeout = const Duration(seconds: 20),
    this.maxBytes = 8 * 1024 * 1024,
    Future<Directory> Function()? tempDirectory,
  }) : tempDirectory = tempDirectory ?? _defaultTempDirectory(engine);

  /// The app's own cache directory when the platform exposes one, otherwise the
  /// system temp directory. The native reader refuses files outside the app
  /// sandbox, so asking the engine first is what makes this work on Android.
  static Future<Directory> Function() _defaultTempDirectory(OcrEngine engine) {
    return () async {
      try {
        final path = await engine.cacheDirectory();
        if (path != null && path.isNotEmpty) {
          final dir = Directory('$path/ironpin-ocr');
          if (!dir.existsSync()) dir.createSync(recursive: true);
          return dir;
        }
      } catch (_) {
        // Fall through to the system temp directory.
      }
      return Directory.systemTemp;
    };
  }

  /// Set when this run has no usable engine (for example inside the background
  /// isolate, where Flutter plugins are not registered). Once set, no picture is
  /// downloaded just to fail.
  late bool _blocked = engine is UnavailableOcrEngine;
  bool get blocked => _blocked;

  /// Reads one picture address. Returns an empty [PhotoRead] on any failure.
  Future<PhotoRead> read(String url) async {
    if (url.isEmpty) return PhotoRead(url, error: 'نشانی تصویر خالی است');
    if (_blocked) {
      return PhotoRead(url, error: 'موتور OCR در این اجرا در دسترس نیست');
    }
    Uint8List bytes;
    try {
      final response = await client
          .get(Uri.parse(url), headers: {'user-agent': 'IronPin/0.9.1 (public post image)'})
          .timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return PhotoRead(url, error: 'تصویر با کد ${response.statusCode} دریافت نشد');
      }
      final type = response.headers['content-type'] ?? '';
      if (type.isNotEmpty && !type.startsWith('image/')) {
        return PhotoRead(url, error: 'پاسخ تصویر نیست ($type)');
      }
      bytes = response.bodyBytes;
      if (bytes.isEmpty) return PhotoRead(url, error: 'تصویر خالی است');
      if (bytes.length > maxBytes) {
        return PhotoRead(url, error: 'تصویر بزرگ‌تر از حد مجاز است');
      }
    } catch (error) {
      return PhotoRead(url, error: 'دریافت تصویر ناموفق بود: $error');
    }

    File? file;
    try {
      final dir = await tempDirectory();
      file = File('${dir.path}/ironpin-photo-${DateTime.now().microsecondsSinceEpoch}.img');
      await file.writeAsBytes(bytes, flush: true);
      final result = await engine.recognize(file.path);
      if (result.error != null &&
          (result.error!.contains('نصب نشده') ||
              result.error!.contains('در دسترس نیست'))) {
        _blocked = true;
      }
      final text = Searcher.cleanOcrText(result.text);
      if (text.isEmpty) {
        return PhotoRead(url,
            engine: result.engine, error: result.error ?? 'متن خوانایی در تصویر نبود');
      }
      return PhotoRead(url,
          text: text,
          confidence: result.confidence ?? OcrQuality.score(text),
          engine: result.engine,
          error: result.error);
    } catch (error) {
      return PhotoRead(url, error: 'خواندن تصویر ناموفق بود: $error');
    } finally {
      try {
        await file?.delete();
      } catch (_) {
        // A leftover temp file is not worth failing a scan over.
      }
    }
  }
}

/// What one pass of automatic picture reading produced.
class PhotoBatch {
  final List<Quote> rows;
  final int read;
  final int failed;
  const PhotoBatch(this.rows, {this.read = 0, this.failed = 0});
}

/// Reads every picture the fetched posts carry and returns the rows they really
/// contain. Used by the manual refresh and by the background scan alike, so the
/// photo path is never a special case and never needs the user to pick a file.
Future<PhotoBatch> readPostPhotos(List<Quote> rows, PhotoScanner scanner,
    {String defaultCurrency = 'نامشخص',
    bool Function()? cancelled,
    // Bounded on purpose: a channel that posts ten pictures must not turn one
    // refresh into a download marathon. Six per source, cheapest evidence first.
    int maxPhotos = 6}) async {
  if (rows.isEmpty) return PhotoBatch(rows);
  final out = <Quote>[];
  var read = 0, failed = 0;
  for (final q in rows) {
    if (read + failed >= maxPhotos && (q.details['پیوست تصویر'] ?? '').isNotEmpty) {
      out.add(q);
      continue;
    }
    if (cancelled?.call() ?? false) {
      out.add(q);
      continue;
    }
    final url = q.details['پیوست تصویر'] ?? '';
    if (url.isEmpty || (q.amount != null && q.hasTextAmount)) {
      out.add(q);
      continue;
    }
    final photo = await scanner.read(url);
    if (!photo.ok) {
      failed++;
      final j = q.toJson();
      j['details'] = {
        ...q.details,
        'خواندن تصویر': photo.error ?? 'متن خوانایی در تصویر نبود',
      };
      out.add(Quote.fromJson(j));
      continue;
    }
    read++;
    final text = Searcher.cleanOcrText(photo.text);
    final analyzed = TextPriceEngine.analyze(
        text: text,
        endpoint: q.endpoint,
        seller: q.seller,
        sellerCity: q.sellerCity,
        sourceUrl: q.sourceUrl,
        fetchedAt: q.fetchedAt,
        postId: '${q.id}-ocr',
        publishedAt: Searcher.publishedOf(q),
        image: true,
        ocrConfidence: photo.confidence,
        ocrEngine: photo.engine,
        photoUrl: url,
        defaultCurrency: defaultCurrency);
    if (analyzed.isEmpty) {
      failed++;
      final j = q.toJson();
      j['details'] = {
        ...q.details,
        'خواندن تصویر': 'متن خوانده شد ولی مبلغ/محصول قابل‌انتساب نبود',
        'اطمینان OCR': photo.confidenceLabel,
        'متن OCR': text,
      };
      out.add(Quote.fromJson(j));
      continue;
    }
    for (final row in analyzed) {
      final j = row.toJson();
      j['details'] = {...row.details, 'متن OCR': text};
      out.add(Quote.fromJson(j));
    }
  }
  return PhotoBatch(out, read: read, failed: failed);
}
