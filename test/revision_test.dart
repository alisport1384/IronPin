import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ironpin/data/app_logger.dart';
import 'package:ironpin/data/controller.dart';
import 'package:ironpin/data/sources.dart';
import 'package:ironpin/data/store.dart';
import 'package:ironpin/domain/market.dart';

Quote item(int i,
        {String thickness = '8', String date = '2026-11-05T08:00:00Z'}) =>
    Quote(
        id: 'row-$i',
        endpoint: 'test',
        seller: 'seller',
        sellerCity: 'مشهد',
        title: 'ورق $thickness میل',
        category: 'ورق',
        brand: 'brand',
        thickness: thickness,
        unit: 'kg',
        amount: 1000 + i.toDouble(),
        fetchedAt: DateTime.parse(date),
        sourceDateRaw: date,
        sourceUrl: 'https://example.com');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  group('Structured product specifications', () {
    test('8 and 10 mm sheets never share a comparison group', () {
      expect(item(1).comparisonGroup('kg'),
          isNot(item(2, thickness: '10').comparisonGroup('kg')));
      final filter = MarketFilter()..thickness = '۱۰';
      expect(
          filter
              .apply([item(1), item(2, thickness: '10')], DateTime.now())
              .single
              .id,
          'row-2');
    });
    test(
        'legacy payload reads thickness, size, dimensions and grade without losing ID',
        () {
      final rows = SourceParser.parse(
          endpoints.first,
          File('test/fixtures/melal_rebar.html').readAsStringSync(),
          DateTime.now());
      final old = rows.first.toJson()
        ..remove('size')
        ..remove('thickness')
        ..remove('grade')
        ..remove('dimensions');
      final q = Quote.fromJson(old);
      expect(q.id, rows.first.id);
      expect(q.sizeLabel, '12');
      expect(q.gradeLabel, 'A3');
      final sheet = SourceParser.parse(
              endpoints.firstWhere((e) => e.id == 'melal-sheet'),
              File('test/fixtures/melal_sheet.html').readAsStringSync(),
              DateTime.now())
          .first;
      expect(sheet.thicknessLabel, '2');
      expect(sheet.dimensionsLabel, isNotEmpty);
    });
    test('beam sizes, brands and grades are not interchangeable', () {
      final a = item(1).toJson()
        ..['category'] = 'تیرآهن'
        ..['size'] = '14'
        ..['thickness'] = ''
        ..['grade'] = 'IPE';
      final b = Map<String, dynamic>.from(a)..['size'] = '16';
      expect(Quote.fromJson(a).comparisonGroup('original'),
          isNot(Quote.fromJson(b).comparisonGroup('original')));
      b['size'] = '14';
      b['brand'] = 'other';
      expect(Quote.fromJson(a).comparisonGroup('kg'),
          isNot(Quote.fromJson(b).comparisonGroup('kg')));
    });
  });
  group('Retention without implicit deletion', () {
    late MarketStore store;
    setUp(() async {
      store = await MarketStore.open(
          dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
    });
    tearDown(() async {
      await store.close();
    });
    test('keep persists decision; only a new Persian month is due', () async {
      final now = DateTime.utc(2026, 11, 5);
      await store.saveSnapshot('test', [item(1, date: '2026-09-15T08:00:00Z')]);
      expect(await store.retentionDue(now), isTrue);
      await store.decideRetention(clearOld: false, now: now);
      expect(await store.retentionDue(now), isFalse);
      expect(await store.retentionDue(DateTime.utc(2026, 11, 25)), isTrue);
      expect(await store.historyCount(), 1);
      expect(MarketStore.retentionMonth(now), '1405-08');
      expect(dateLabel(MarketStore.retentionCutoff(now), time: false),
          '۱۴۰۵/۰۸/۰۱');
    });
    test('explicit cleanup deletes only older history, never latest/settings',
        () async {
      final now = DateTime.utc(2026, 11, 5);
      await store.saveSnapshot(
          'test', [item(1, date: '2026-09-15T08:00:00Z'), item(2)]);
      await store.setSetting('enabled', '["test"]');
      final removed = await store.decideRetention(clearOld: true, now: now);
      expect(removed, 1);
      expect(await store.history('row-1'), isEmpty);
      expect((await store.history('row-2')).length, 1);
      expect((await store.latest()).length, 2);
      expect(await store.setting('enabled'), '["test"]');
    });
    test('batch upsert preserves latest date guard for a large snapshot',
        () async {
      final rows = List.generate(1200, (i) => item(i));
      await store.saveSnapshot('test', rows);
      await store.saveSnapshot('test', rows);
      expect(await store.historyCount(), 1200);
      await store.saveSnapshot('test', [item(0, date: '2026-09-15T08:00:00Z')]);
      expect((await store.latest()).single.sourceDateRaw,
          rows.first.sourceDateRaw);
    });
  });
  test(
      'version-1 database preserves payload; explicit all-ON migration runs once',
      () async {
    final dir = await Directory.systemTemp.createTemp('ironpin-upgrade-');
    final path = '${dir.path}/old.db';
    var store =
        await MarketStore.open(dbPath: path, factory: databaseFactoryFfi);
    try {
      final legacy = item(1).toJson()
        ..remove('size')
        ..remove('thickness')
        ..remove('dimensions')
        ..remove('grade');
      await store.db.insert('latest', {
        'id': 'row-1',
        'endpoint': 'test',
        'payload': jsonEncode(legacy),
        'active': 1
      });
      await store.setSetting('enabled', '["melal-rebar"]');
      await store.setSetting('allRegisteredSourcesEnabledVersion', '1');
      await store.setSetting('autoRefresh', 'false');
      await store.db.execute('DROP INDEX history_id_seq');
      await store.db.execute('PRAGMA user_version=1');
      await store.close();
      store = await MarketStore.open(dbPath: path, factory: databaseFactoryFfi);
      expect((await store.latest()).single.thicknessLabel, '8');
      // Schema 4 adds the derived range index and schema 6 its `amount_raw`
      // column; schema 7 adds the endpoint index and schema 8 the refresh lease.
      expect(await store.db.getVersion(), 8);
      final c = MarketController(store);
      await c.init();
      expect(c.quotes.single.id, 'row-1');
      expect(c.enabled.contains('melal-rebar'), isTrue);
      expect(c.enabled.contains('melal-sheet'), isTrue);
      expect(endpoints.every((e) => c.enabled.contains(e.id)), isTrue);
      expect(await store.setting('allRegisteredSourcesEnabledVersion'), '4');
      await c.setEnabled('telegram-mashhad', false);
      c.dispose();
      final second = MarketController(store);
      await second.init();
      expect(second.enabled.contains('telegram-mashhad'), isFalse);
      second.dispose();
    } finally {
      await store.close();
      await dir.delete(recursive: true);
    }
  });
  group('Markdown logger', () {
    late Directory dir;
    late AppLogger logger;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('ironpin-logs-');
      logger = AppLogger(enabled: true);
      await logger.initialize(directory: dir);
    });
    tearDown(() async {
      await logger.flush();
      await dir.delete(recursive: true);
    });
    test('parallel event calls preserve ordered append and markdown format',
        () async {
      await Future.wait(List.generate(
          25, (i) => logger.record('source', 'event', {'rows': i})));
      final files = await logger.files();
      expect(files.length, 1);
      final text = await files.single.readAsString();
      expect(text, startsWith('# IronPin'));
      expect('## '.allMatches(text).length, 25);
      expect(text.indexOf('"rows":0'), lessThan(text.indexOf('"rows":24')));
      expect(logger.lastError, isNull);
    });
    test(
        'export sends existing md paths and treats picker cancellation as cancellation',
        () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AppLogger.platform, (call) async {
        calls.add(call);
        return null;
      });
      try {
        await logger.record('source', 'example', {'endpoint': 'test-source'});
        expect(await logger.export(), isNull);
        expect(calls.single.method, 'exportLogs');
        expect((calls.single.arguments['paths'] as List),
            everyElement(endsWith('.md')));
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(AppLogger.platform, null);
      }
    });
    test('write failures are reported, not propagated into UI', () async {
      final bad = File('${dir.path}/not-directory')..writeAsStringSync('x');
      final l = AppLogger(enabled: true);
      await l.initialize(directory: Directory(bad.path));
      await l.record('test', 'failed');
      expect(l.lastError, isNotNull);
    });
  });
  test(
      'all researched channels except unverified Tikahan have explicit evidence adapters',
      () {
    final registry =
        jsonDecode(File('assets/registry.json').readAsStringSync());
    final urls = endpoints.map((e) => e.url).toSet();
    for (final ch in registry['telegram_channels']) {
      if (ch['handle'] == 'tikahan') continue;
      expect(urls, contains('https://t.me/s/${ch['handle']}'));
    }
  });
  test('Mashhad image publications never become fresh numeric prices', () {
    final e = endpoints.firstWhere((e) => e.id == 'telegram-mashhad');
    final body = File('test/fixtures/mashhad_telegram.html').readAsStringSync();
    final rows = SourceParser.parse(e, body, DateTime.utc(2026, 11, 5));
    expect(rows, isNotEmpty);
    expect(
        rows.every((q) =>
            q.sellerCity == 'مشهد' &&
            q.amount == null &&
            q.announcedAt == null),
        isTrue);
    expect(rows.any((q) => q.details['قالب'] == 'تصویر'), isTrue);
    expect(
        rows.every((q) => q.details['زمان انتشار پیام']!.isNotEmpty), isTrue);
  });
  test('cached filtering is asynchronous and stale search work cannot win',
      () async {
    final store = await MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
    final c = MarketController(store)
      ..quotes =
          List.generate(8000, (i) => item(i, thickness: i.isEven ? '8' : '10'));
    try {
      c.filtered;
      expect(c.filtering, isTrue);
      c.filter.thickness = '10';
      c.changed();
      var ticks = 0;
      final timer =
          Timer.periodic(const Duration(milliseconds: 1), (_) => ticks++);
      final stop = Stopwatch()..start();
      while (c.filtering && stop.elapsed.inSeconds < 20) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      timer.cancel();
      expect(c.filtering, isFalse);
      expect(c.filtered.length, 4000);
      expect(c.filtered.every((q) => q.thicknessLabel == '10'), isTrue);
      stdout.writeln(
          'FILTER_METRIC rows=8000 matches=4000 elapsedMs=${stop.elapsedMilliseconds} mainTimerTicks=$ticks');
      expect(ticks, greaterThan(0));
      expect(identical(c.filtered, c.filtered), isTrue);
    } finally {
      c.dispose();
      await store.close();
    }
  });
  test('large HTTP HTML parsing leaves main isolate timers responsive',
      () async {
    final e = endpoints.first;
    final original = File('test/fixtures/melal_rebar.html').readAsStringSync();
    final body = List.filled(100, original).join('\n');
    final client = SourceClient(
        client: MockClient(
            (_) async => http.Response.bytes(utf8.encode(body), 200)));
    var ticks = 0;
    final timer =
        Timer.periodic(const Duration(milliseconds: 1), (_) => ticks++);
    try {
      final rows = await client.fetch(e);
      expect(rows.length, greaterThan(100));
      expect(ticks, greaterThan(2));
    } finally {
      timer.cancel();
      client.close();
    }
  });
}
