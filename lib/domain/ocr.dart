import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// One recognised image.
class OcrResult {
  final String text;

  /// Mean word confidence of the engine, `0..1`, when it reports one.
  final double? confidence;
  final String engine;
  final String? error;

  const OcrResult(this.text,
      {this.confidence, this.engine = 'tesseract-fas', this.error});

  static const empty = OcrResult('', engine: 'none');

  bool get isEmpty => text.trim().isEmpty;
  String get confidenceLabel =>
      confidence == null ? 'نامشخص' : '${(confidence! * 100).round()}٪';
}

/// On-device image text recognition.
///
/// ML Kit cannot read Persian (its text-recognition models cover Latin,
/// Chinese, Devanagari, Japanese and Korean only), so the app ships Tesseract
/// with the `fas` model and reads the picture itself. Nothing leaves the phone
/// and no image is uploaded.
abstract class OcrEngine {
  Future<OcrResult> recognize(String imagePath);

  /// Opens the system photo picker and copies the chosen picture into the app
  /// cache. Returns `null` when the user cancels.
  Future<String?> pickImage();

  static OcrEngine platform() =>
      Platform.isAndroid ? const MethodChannelOcrEngine() : const UnavailableOcrEngine();
}

class MethodChannelOcrEngine implements OcrEngine {
  const MethodChannelOcrEngine();
  static const _channel = MethodChannel('ir.ironpin.ironpin/ocr');

  @override
  Future<OcrResult> recognize(String imagePath) async {
    try {
      final map = await _channel.invokeMapMethod<String, Object?>(
          'recognize', {'path': imagePath});
      if (map == null) return const OcrResult('', error: 'پاسخ خالی از موتور OCR');
      final text = (map['text'] as String? ?? '').trim();
      final rawConfidence = map['confidence'];
      return OcrResult(text,
          confidence: rawConfidence is num ? rawConfidence.toDouble() : null,
          engine: map['engine'] as String? ?? 'tesseract-fas',
          error: map['error'] as String?);
    } on MissingPluginException {
      return const OcrResult('',
          engine: 'none', error: 'موتور OCR در این نسخه نصب نشده است');
    } on PlatformException catch (e) {
      return OcrResult('', engine: 'tesseract-fas', error: e.message ?? e.code);
    }
  }

  @override
  Future<String?> pickImage() async {
    try {
      return await _channel.invokeMethod<String>('pickImage');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}

/// Used on platforms without the native engine, and by tests.
class UnavailableOcrEngine implements OcrEngine {
  const UnavailableOcrEngine();

  @override
  Future<OcrResult> recognize(String imagePath) async =>
      const OcrResult('', engine: 'none', error: 'OCR در این پلتفرم در دسترس نیست');

  @override
  Future<String?> pickImage() async => null;
}

/// A confidence number for engines that do not report one.
///
/// It is a statement about the *text*, not about the picture: how much of it
/// looks like Persian steel vocabulary, whether a price and a contact exist, and
/// how much noise is in it. Deliberately capped below 1 so a row can never claim
/// a perfect read.
class OcrQuality {
  static const _products = [
    'آهن', 'میلگرد', 'ورق', 'تیرآهن', 'تیر آهن', 'نبشی', 'ناودانی', 'لوله',
    'پروفیل', 'قوطی', 'سپری', 'تسمه', 'بست', 'بولت', 'مفتول', 'توری', 'کلاف',
    'گالوانیزه', 'روغنی', 'آجدار', 'فولاد', 'شمش', 'ضخامت', 'سایز', 'گرید'
  ];

  static double score(String text) {
    final t = text.trim();
    if (t.isEmpty) return 0;
    var score = 0.0;
    final useful = t
        .replaceAll(RegExp(r'[\s\p{P}]', unicode: true), '')
        .runes
        .length;
    final persian = RegExp(r'[\u0600-\u06FF0-9]').allMatches(t).length;
    final total = t.replaceAll(RegExp(r'\s'), '').length;
    if (total > 0 && persian / total > 0.7) score += 0.3;
    if (useful > 40) score += 0.1;
    final hits = _products.where((p) => t.contains(p)).length;
    score += (hits >= 2 ? 0.3 : hits == 1 ? 0.15 : 0.0);
    if (RegExp(r'(?:تومان|ریال|تومن|ریال)').hasMatch(t)) score += 0.15;
    if (RegExp(r'\d[\d.,]{3,}').hasMatch(t)) score += 0.1;
    if (RegExp(r'0\d{2}[\s-]?\d{5,8}').hasMatch(t)) score += 0.05;
    if (RegExp(r'https?://|goo\.gl|maps\.app').hasMatch(t)) score += 0.05;
    return score > 0.95 ? 0.95 : score;
  }
}
