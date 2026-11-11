// ignore_for_file: avoid_print
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:ironpin/domain/maps_resolver.dart';
import 'package:ironpin/domain/ocr_quality.dart';
import 'package:ironpin/domain/searcher.dart';
import 'package:ironpin/domain/text_engine.dart';

/// Runs one OCR text file through the same path the app uses for a photo:
/// cleanOcrText → TextPriceEngine.analyze → Searcher.processAsync.
///
/// Usage: dart run tool/photo_pipeline.dart <ocr.txt> [--no-network]
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: photo_pipeline.dart <ocr.txt> [--no-network]');
    exit(64);
  }
  final online = !args.contains('--no-network');
  final raw = File(args.first).readAsStringSync();
  final text = Searcher.cleanOcrText(raw);
  final now = DateTime.now().toUtc();
  final confidence = OcrQuality.score(text);
  final rows = TextPriceEngine.analyze(
      text: text,
      endpoint: 'local-image',
      seller: 'تحلیل عکس',
      sourceUrl: 'file:${args.first}',
      fetchedAt: now,
      postId: 'image-${TextPriceEngine.key(text)}',
      publishedAt: now,
      image: true,
      manual: true,
      ocrConfidence: confidence,
      ocrEngine: 'tesseract-fas+eng');
  final client = http.Client();
  final found = await Searcher.processAsync(rows,
      now: now,
      windowDays: 30,
      keepManualFallback: false,
      resolver: online ? MapsResolver(client) : null);
  client.close();
  print('== cleaned text ==');
  print(text);
  print('== OCR confidence: ${(confidence * 100).round()}% ==');
  print('== stored rows: ${found.kept} (noise ${found.noise}, '
      'outOfWindow ${found.outOfWindow}, duplicates ${found.duplicates}) ==');
  for (final q in found.quotes) {
    print('- ${q.title} | amount=${q.amount} ${q.currency} | unit=${q.unit} '
        '| city=${q.sellerCity}');
    for (final e in q.details.entries) {
      if (e.key.startsWith('مبنای شهر') ||
          e.key.startsWith('شماره') ||
          e.key.startsWith('نقشه') ||
          e.key.startsWith('بازکردن') ||
          e.key.startsWith('تعارض') ||
          e.key.startsWith('اطمینان') ||
          e.key.startsWith('آدرس')) {
        print('    ${e.key}: ${e.value}');
      }
    }
  }
  if (found.quotes.isEmpty) {
    print('== what the picture held ==');
    Searcher.imageEvidence(text, rows: rows).forEach((k, v) => print('  $k: $v'));
  }
  print('== categories: ${found.categories} ==');
}
