import 'dart:io' show Platform;

import 'package:flutter/services.dart';

export 'ocr_quality.dart';

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
