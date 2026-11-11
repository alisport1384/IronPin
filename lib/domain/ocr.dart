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

  /// Every reading the engine made of the same picture (different layout
  /// modes and contrast). [text] is the engine's own pick; the caller may find
  /// that another reading yields more priced product rows.
  final List<String> passes;

  const OcrResult(this.text,
      {this.confidence,
      this.engine = 'tesseract-fas',
      this.error,
      this.passes = const []});

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

  /// A directory this app may write a downloaded picture into, when the platform
  /// exposes one.
  Future<String?> cacheDirectory();

  static OcrEngine platform() =>
      Platform.isAndroid ? const MethodChannelOcrEngine() : const UnavailableOcrEngine();
}

class MethodChannelOcrEngine implements OcrEngine {
  const MethodChannelOcrEngine();
  static const _channel = MethodChannel('ir.ironpin.ironpin/ocr');

  @override
  Future<String?> cacheDirectory() async {
    try {
      return await _channel.invokeMethod<String>('cacheDir');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

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
          error: map['error'] as String?,
          passes: [
            for (final pass in (map['passes'] as List? ?? const []))
              if (pass is String && pass.trim().isNotEmpty) pass
          ]);
    } on MissingPluginException {
      return const OcrResult('',
          engine: 'none', error: 'موتور OCR در این نسخه نصب نشده است');
    } on PlatformException catch (e) {
      return OcrResult('', engine: 'tesseract-fas', error: e.message ?? e.code);
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
  Future<String?> cacheDirectory() async => null;
}
