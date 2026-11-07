import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ironpin/data/backup.dart';
import 'package:ironpin/data/store.dart';
import 'package:ironpin/domain/market.dart';
import 'package:ironpin/domain/money.dart';
import 'package:ironpin/domain/price_range.dart';
import 'package:ironpin/domain/calculator.dart';

final now = DateTime.utc(2026, 11, 6, 12);
Quote offer(String id, double amount,
        {String seller = 'الف',
        String currency = 'تومان',
        String date = '2026-11-06T08:00:00Z',
        String? post,
        String thickness = '3',
        String brand = 'مبارکه',
        String unit = 'kg',
        double? mass,
        double? length,
        String tax = 'بدون مالیات',
        Map<String, String> details = const {}}) =>
    Quote(
        id: id,
        endpoint: 'e',
        seller: seller,
        title: 'ورق سیاه',
        category: 'ورق',
        brand: brand,
        thickness: thickness,
        dimensions: '1000×2000',
        grade: 'ST37',
        unit: unit,
        currency: currency,
        amount: amount,
        pieceKg: mass,
        lengthM: length,
        tax: tax,
        sourceDateRaw: date,
        sourceUrl: post ?? 'https://example.com/prices',
        fetchedAt: now,
        details: details);
Quote change(Quote q, Map<String, dynamic> fields) =>
    Quote.fromJson({...q.toJson(), ...fields});

// Used ONLY to construct deliberately invalid but checksum-consistent test files.
Future<File> rewrite(
    File file, void Function(List<Map<String, dynamic>>) edit) async {
  final rows = (await file.readAsLines())
      .map((s) => Map<String, dynamic>.from(jsonDecode(s)))
      .toList();
  rows.removeLast();
  edit(rows);
  final counts = {'latest': 0, 'history': 0, 'settings': 0, 'sync': 0};
  var crc = 2166136261;
  final body = StringBuffer();
  for (final row in rows) {
    final line = jsonEncode(row);
    for (final b in utf8.encode('$line\n')) {
      crc = ((crc ^ b) * 16777619) & 0xffffffff;
    }
    if (row['table'] is String && counts.containsKey(row['table'])) {
      counts[row['table']] = counts[row['table']]! + 1;
    }
    body.writeln(line);
  }
  body.writeln(jsonEncode({
    'end': true,
    'counts': counts,
    'algorithm': 'fnv1a32',
    'checksum': crc.toRadixString(16).padLeft(8, '0')
  }));
  final out = File('${file.path}.edited');
  return out.writeAsString(body.toString());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  group('Exact 48h all-announcement range', () {
    test('seller with two real announcements has twice the weight', () {
      final report = calculateRanges([
        offer('a1', 100,
            date: '2026-11-05T08:00:00Z', post: 'https://t.me/a/1'),
        offer('a2', 200, post: 'https://t.me/a/2'),
        offer('b', 900, seller: 'ب', post: 'https://t.me/b/1')
      ], now);
      final r = report.ranges.single;
      expect(r.minimum, 100);
      expect(r.maximum, 900);
      expect(r.mean, 400);
      expect(r.roundedMean, 400);
      expect(r.sellers, 2);
      expect(r.announcements.length, 3);
    });
    test('48-hour endpoints included; older/future/undated excluded', () {
      final boundary = now.subtract(const Duration(hours: 48));
      final report = calculateRanges([
        offer('a', 100, date: boundary.toIso8601String()),
        offer('b', 200, date: now.toIso8601String()),
        offer('old', 500,
            date: boundary
                .subtract(const Duration(microseconds: 1))
                .toIso8601String()),
        offer('future', 600,
            date: now.add(const Duration(seconds: 1)).toIso8601String()),
        offer('unknown', 700, date: '')
      ], now);
      expect(report.ranges.single.announcements.length, 2);
    });
    test('mean uses every point and half-up rounds one toman', () {
      final r = calculateRanges([offer('a', 100), offer('b', 101)], now)
          .ranges
          .single;
      expect(r.mean, 100.5);
      expect(r.roundedMean, 101);
      expect(r.rate('min'), 100);
      expect(r.rate('max'), 101);
      expect(r.rate('mean'), 101);
    });
    test('re-fetch and metadata changes do not add a vote', () {
      final a = offer('a', 100);
      final repeat = change(a, {
        'fetchedAt': now.add(const Duration(hours: 1)).toIso8601String(),
        'details': {'وضعیت': 'توضیح تازه'}
      });
      expect(
          calculateRanges([a, repeat], now).ranges.single.announcements.length,
          1);
    });
    test('edited same message/date uses its last captured revision', () {
      final a = offer('a', 100, post: 'https://t.me/a/10');
      final edit = change(a, {
        'amount': 200,
        'fetchedAt': now.add(const Duration(minutes: 1)).toIso8601String()
      });
      final r = calculateRanges([edit, a], now).ranges.single;
      expect(r.mean, 200);
      expect(r.announcements.length, 1);
    });
    test('two separate public posts with equal prices both count', () {
      final r = calculateRanges([
        offer('a', 100, post: 'https://t.me/a/10'),
        offer('b', 100, post: 'https://t.me/a/11')
      ], now)
          .ranges
          .single;
      expect(r.announcements.length, 2);
    });
    test('rials/tomans normalize; unknown currency never inferred by magnitude',
        () {
      final report = calculateRanges([
        offer('r', 1000, currency: 'ریال'),
        offer('t', 200),
        offer('x', 100000, currency: 'نامشخص')
      ], now);
      expect(report.ranges.single.mean, 150);
      expect(report.ranges.single.minimum, 100);
      expect(report.excluded.values.reduce((a, b) => a + b), 1);
      expect(toman(1, 'ریال'), .1);
      expect(toman(1000, 'R'), isNull);
    });
    test(
        'technical thickness and sheet kind separate; brand and tax do not exclude',
        () {
      final report = calculateRanges([
        offer('a', 100),
        offer('b', 200, thickness: '4'),
        offer('c', 300, brand: 'اکسین'),
        offer('d', 400, tax: 'با مالیات'),
        change(offer('e', 500), {'title': 'ورق روغنی'})
      ], now);
      expect(report.ranges.length, 3);
      expect(report.ranges.singleWhere((r) => r.announcements.length == 3).mean,
          closeTo(800 / 3, 1e-8));
    });
    test('all cities count; seller office is never inferred from factory', () {
      final r = calculateRanges([
        change(offer('a', 100), {'sellerCity': 'مشهد'}),
        change(offer('b', 200, seller: 'ب'), {'sellerCity': 'تهران'})
      ], now)
          .ranges
          .single;
      expect(r.mean, 150);
      expect(r.sellers, 2);
    });
    test(
        'missing brand/dimensions no longer blocks a priced product; physical groups remain explicit',
        () {
      final report = calculateRanges([
        offer('a', 100, brand: ''),
        offer('b', 200, thickness: '2,3'),
        change(offer('c', 300), {'dimensions': ''})
      ], now);
      expect(report.ranges.length, 3);
      expect(
          report.ranges.fold<int>(0, (n, r) => n + r.announcements.length), 3);
    });
    test(
        'only verified mass converts piece to kg; geometry never changes range',
        () {
      final r = calculateRanges(
          [offer('a', 100), offer('b', 6280, unit: 'sheet', mass: 62.8)], now);
      expect(r.ranges.single.mean, closeTo(100, 1e-9));
      final unknown = calculateRanges(
          [offer('a', 100), offer('b', 6280, unit: 'sheet')], now);
      expect(unknown.ranges.length, 2);
      expect(unknown.ranges.map((r) => r.basis).toSet(), {'kg', 'sheet'});
    });
    test('Persian words and digits match displayed, rounded amounts', () {
      expect(moneyWords(1234567),
          'یک میلیون و دویست و سی و چهار هزار و پانصد و شصت و هفت تومان');
      expect(moneyWords(100.5), 'صد و یک تومان');
      expect(moneyWords(0), 'صفر تومان');
      expect(faDigits('1405/08/15 12:30'), '۱۴۰۵/۰۸/۱۵ ۱۲:۳۰');
      expect(dateLabel(now).contains('1405'), isFalse);
    });
    test('financial filters use tomans without mutating raw rials', () {
      final r = offer('r', 1000, currency: 'ریال');
      final t = offer('t', 200);
      final f = MarketFilter()
        ..minPrice = 90
        ..maxPrice = 150;
      expect(f.apply([r, t], now).single.id, 'r');
      expect(r.amount, 1000);
      expect(r.currency, 'ریال');
      expect(r.priceFor('kg'), 1000);
      expect(r.tomanFor('kg'), 100);
      expect(r.comparisonGroup('kg'), t.comparisonGroup('kg'));
    });
    test('researched plate/pipe/solid shape formulas and overflow guard', () {
      final plate = SteelCalculator.calculate(
          shape: 'plate',
          values: {'b': 1000, 't': 2, 'coat': 0},
          density: 7850,
          inputUnit: 'piece',
          quantity: 1,
          lengthPerPiece: 2);
      expect(plate.kg, closeTo(31.4, 1e-10));
      expect(SteelCalculator.cost(plate, 'kg', 100), closeTo(3140, 1e-10));
      final pipe = SteelCalculator.calculate(
          shape: 'pipe',
          values: {'d': 48.3, 't': 2},
          density: 7850,
          inputUnit: 'm',
          quantity: 1);
      expect(pipe.kg, closeTo(2.2836551158209564, .000001));
      expect(
          () => SteelCalculator.cost(
              const WeightResult(1e300, 1, 1, 1, 1), 'kg', 1e300),
          throwsFormatException);
    });
  });
  group('Full backup: transactional safe merge', () {
    late Directory dir;
    late MarketStore source, target;
    late File file;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('ironpin-backup-test-');
      source = await MarketStore.open(
          dbPath: '${dir.path}/source.db', factory: databaseFactoryFfi);
      target = await MarketStore.open(
          dbPath: '${dir.path}/target.db', factory: databaseFactoryFfi);
      await source.saveSnapshot('e', [offer('a', 100), offer('retired', 200)]);
      await source.saveSnapshot('e', [offer('a', 110)]);
      await source.setSetting('enabled', '["e"]');
      await source.setSetting('customPreference', 'بله');
      await source.setSetting('autoRefresh', 'false');
      await source.setSetting('discoveredSources',
          '[{"url":"https://t.me/ahanresan","name":"آهن‌رسان"}]');
      file = File('${dir.path}/backup.jsonl');
      await MarketBackup(source).write(file);
    });
    tearDown(() async {
      await source.close();
      await target.close();
      await dir.delete(recursive: true);
    });
    test(
        'round trip restores inactive/current rows, history, settings and sync',
        () async {
      final result = await MarketBackup(target).merge(file);
      expect(result.latest, 2);
      expect(result.history, 3);
      expect((await target.latest()).single.amount, 110);
      expect((await target.db.query('latest')).length, 2);
      expect((await target.history('retired')).single.amount, 200);
      expect(await target.setting('customPreference'), 'بله');
      expect(await target.setting('discoveredSources'),
          await source.setting('discoveredSources'));
      expect((await target.syncStates()).keys, contains('e'));
    });
    test('export rejects a record that could not pass its own import limits',
        () async {
      final huge = change(offer('huge', 100), {
        'details': {'body': 'x' * (1024 * 1024 + 1)}
      });
      await source.saveSnapshot('e', [huge]);
      await expectLater(
          MarketBackup(source).write(file), throwsFormatException);
    });
    test('second import is idempotent, not extra history/announcements',
        () async {
      await MarketBackup(target).merge(file);
      final n = await target.historyCount();
      final result = await MarketBackup(target).merge(file);
      expect(result.history, 0);
      expect(result.latest, 0);
      expect(await target.historyCount(), n);
      expect((await target.rangeReport(now)).ranges.single.announcements.length,
          3);
    });
    test('newer local price and existing settings win; new channels merge',
        () async {
      await target
          .saveSnapshot('e', [offer('a', 900, date: '2026-11-06T10:00:00Z')]);
      await target.setSetting('enabled', '[]');
      await target.setSetting('customPreference', 'خیر');
      await target.setSetting('discoveredSources',
          '[{"url":"https://t.me/another","name":"دیگر"}]');
      await MarketBackup(target).merge(file);
      expect((await target.latest()).single.amount, 900);
      expect(await target.setting('enabled'), '[]');
      expect(await target.setting('customPreference'), 'خیر');
      expect(
          (jsonDecode((await target.setting('discoveredSources'))!) as List)
              .length,
          2);
      expect(await target.setting('autoRefresh'), 'false');
    });
    test(
        'explicit settings restore can recover source choices on an initialized new phone',
        () async {
      await target.setSetting('enabled', '[]');
      await target.setSetting('customPreference', 'خیر');
      await target.setSetting('allRegisteredSourcesEnabledVersion', '1');
      await target.setSetting('retentionMonth', '1405-08');
      await MarketBackup(target).merge(file, restoreSettings: true);
      expect(await target.setting('enabled'), '["e"]');
      expect(await target.setting('customPreference'), 'بله');
      expect(await target.setting('autoRefresh'), 'false');
      expect(await target.setting('allRegisteredSourcesEnabledVersion'), '1');
      expect(await target.setting('retentionMonth'), '1405-08');
    });
    test('truncated file rolls back ALL prior batches, not just final batch',
        () async {
      await target.saveSnapshot('e', [offer('keep', 999)]);
      final before = await target.historyCount();
      final text = await file.readAsLines();
      final bad = await File('${dir.path}/truncated')
          .writeAsString('${text.take(text.length - 1).join('\n')}\n');
      await expectLater(MarketBackup(target).merge(bad), throwsFormatException);
      expect(await target.historyCount(), before);
      expect((await target.latest()).single.id, 'keep');
      expect(await target.setting('customPreference'), isNull);
    });
    test(
        'multi-chunk rollback restores data after more than 300 prepared records',
        () async {
      await source.saveSnapshot('e', [
        for (var i = 0; i < 160; i++) offer('many-$i', 1000 + i.toDouble())
      ]);
      await MarketBackup(source).write(file);
      final lines = await file.readAsLines();
      expect(lines.length, greaterThan(300));
      final bad = await File('${dir.path}/multi-truncated')
          .writeAsString('${lines.take(lines.length - 1).join('\n')}\n');
      await target.saveSnapshot('e', [offer('keep', 999)]);
      final count = await target.historyCount();
      await expectLater(MarketBackup(target).merge(bad), throwsFormatException);
      expect(await target.historyCount(), count);
      expect((await target.latest()).single.id, 'keep');
      expect(await target.setting('customPreference'), isNull);
    });
    test('checksum damage and footer-count damage reject without mutation',
        () async {
      final bad = await File('${dir.path}/corrupt').writeAsString(
          (await file.readAsString()).replaceFirst('ورق سیاه', 'ورق سفید'));
      await expectLater(MarketBackup(target).merge(bad), throwsFormatException);
      expect(await target.historyCount(), 0);
      final lines = await file.readAsLines();
      final footer = jsonDecode(lines.last) as Map;
      footer['counts']['history'] = 999;
      lines[lines.length - 1] = jsonEncode(footer);
      await bad.writeAsString('${lines.join('\n')}\n');
      await expectLater(MarketBackup(target).merge(bad), throwsFormatException);
      expect(await target.historyCount(), 0);
    });
    test('unknown table/schema/unsafe source URL are rejected atomically',
        () async {
      for (final mode in ['table', 'schema', 'url']) {
        final bad = await rewrite(file, (rows) {
          if (mode == 'schema') {
            rows.first['schema'] = 999;
          } else {
            final r = rows.firstWhere((r) => r['table'] == 'latest');
            if (mode == 'table') {
              r['table'] = 'arbitrary';
            } else {
              final p = jsonDecode(r['row']['payload']);
              p['sourceUrl'] = 'javascript:alert(1)';
              r['row']['payload'] = jsonEncode(p);
            }
          }
        });
        await expectLater(MarketBackup(target).merge(bad), throwsA(anything));
        expect(await target.historyCount(), 0);
        expect(await target.latest(), isEmpty);
      }
    });
    test('missing currency cannot silently default to toman on restore',
        () async {
      final bad = await rewrite(file, (rows) {
        final r = rows.firstWhere((r) => r['table'] == 'latest');
        final p = jsonDecode(r['row']['payload']);
        p.remove('currency');
        r['row']['payload'] = jsonEncode(p);
      });
      await expectLater(MarketBackup(target).merge(bad), throwsFormatException);
      expect(await target.latest(), isEmpty);
    });
    test('invalid source setting and history ID mismatch reject', () async {
      for (final mode in ['setting', 'id']) {
        final bad = await rewrite(file, (rows) {
          if (mode == 'id') {
            rows.firstWhere((r) => r['table'] == 'history')['row']['id'] =
                'different-id';
          } else {
            rows.firstWhere((r) =>
                    r['table'] == 'settings' &&
                    r['row']['key'] == 'discoveredSources')['row']['value'] =
                '[{"url":"https://127.0.0.1/private","name":"bad"}]';
          }
        });
        await expectLater(
            MarketBackup(target).merge(bad), throwsFormatException);
        expect(await target.historyCount(), 0);
      }
    });
    test('records after footer and giant unterminated lines reject', () async {
      final bad = await File('${dir.path}/after')
          .writeAsString('${await file.readAsString()}{}\n');
      await expectLater(MarketBackup(target).merge(bad), throwsFormatException);
      await bad.writeAsString('x' * (2 * 1024 * 1024 + 1));
      await expectLater(MarketBackup(target).merge(bad), throwsFormatException);
      expect(await target.historyCount(), 0);
    });
    test('importing older history cannot become latest signature for refresh',
        () async {
      final newer = offer('a', 900, date: '2026-11-06T10:00:00Z');
      await target.saveSnapshot('e', [newer]);
      await MarketBackup(target).merge(file);
      final before = await target.historyCount();
      await target.saveSnapshot('e', [newer]);
      expect(await target.historyCount(), before);
    });
  });
}
