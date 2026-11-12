import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ironpin/data/app_logger.dart';
import 'package:ironpin/data/controller.dart';
import 'package:ironpin/data/sources.dart';
import 'package:ironpin/data/store.dart';
import 'package:ironpin/domain/city_scope.dart';
import 'package:ironpin/domain/market.dart';
import 'package:ironpin/domain/price_range.dart';
import 'package:ironpin/domain/range_task.dart';
import 'package:ironpin/domain/text_engine.dart';
import 'package:ironpin/ui/range_page.dart';
import 'package:ironpin/ui/prices_page.dart';

final at = DateTime.utc(2026, 11, 7, 12);
Quote row(int n, {String city = 'مشهد', double amount = 100}) => Quote(
    id: 'q$n',
    endpoint: 'e',
    seller: 'فروشنده',
    sellerCity: city,
    title: 'ورق سیاه 3',
    category: 'ورق',
    thickness: '3',
    amount: amount,
    unit: 'kg',
    currency: 'تومان',
    sourceDateRaw: at.subtract(const Duration(hours: 1)).toIso8601String(),
    fetchedAt: at,
    sourceUrl: 'https://example.com/$n');
Quote change(Quote q, Map<String, dynamic> patch) =>
    Quote.fromJson({...q.toJson(), ...patch});
Map<String, Object?> request(List<Quote> rows, {String city = 'مشهد'}) => {
      'payloads': rows.map((q) => jsonEncode(q.toJson())).toList(),
      'family': 'ورق',
      'fields': <String, String>{},
      'basis': '',
      'city': city,
      'now': at.millisecondsSinceEpoch,
    };

/// Waits for a confirmed range answer or an error with bounded real-time pumps.
/// Drags the outer page until [target] is on screen. A single
/// `scrollUntilVisible` can give up when the list only gets its real extent
/// after the confirmed result is published.
Future<void> _scrollTo(WidgetTester t, Finder target) async {
  for (var i = 0; i < 20; i++) {
    if (target.evaluate().isNotEmpty) return;
    await t.drag(find.byType(Scrollable).first, const Offset(0, -200));
    await t.pumpAndSettle();
  }
}

Future<void> _settleRange(WidgetTester t) async {
  for (var i = 0; i < 120; i++) {
    await t
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
    await t.pump();
    if (find.byType(LinearProgressIndicator).evaluate().isEmpty) break;
  }
  await t.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  test(
      'global city covers explicit office, loading, production and product title',
      () {
    final other = row(0, city: 'تهران');
    expect(cityMatches(other, 'مشهد'), false);
    for (final patch in [
      {'sellerCity': 'مشهد'},
      {'loadingCity': 'مشهد'},
      {'loading': 'انبار مشهد'},
      {'title': 'ورق کارخانه مشهد'},
      {'brand': 'پروفیل مشهد'},
      {
        'details': {'محل تولید': 'مشهد'}
      },
      {
        'details': {'مبدأ بار': 'مشهد'}
      },
    ]) {
      expect(cityMatches(change(other, patch), 'مشهد'), true, reason: '$patch');
    }
    expect(
        cityMatches(
            change(other, {
              'details': {'متن اصلی': 'ارسال سراسر ایران؛ مشهد تهران'}
            }),
            'مشهد'),
        false);
    expect(
        cityMatches(
            change(other, {
              'brand': 'مبارکه',
              'sellerCity': '',
              'sourceUrl': 'https://mashhad.example.com'
            }),
            'مشهد'),
        false);
    expect(cityMatches(change(other, {'title': 'ورق مشهدی'}), 'مشهد'), false);
    expect(cityMatches(row(0, city: ''), 'مشهد'), false);
    expect(cityMatches(other, ''), true);
  });
  test('global city persists and immediately shields old cached lists',
      () async {
    final store = await MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
    final c = MarketController(store)..quotes = [row(1), row(2, city: 'تهران')];
    // The rows carry the fixed date of this file; the test is about the city.
    c.filter
      ..recentWeek = false
      ..windowDays = 0;
    expect(c.filtered.length, 2);
    await c.setCity('مشهد');
    expect(c.filtered.map((q) => q.id).toList(), ['q1']);
    expect(c.filter.cityKind, 'all');
    final next = MarketController(store);
    await next.init();
    expect(next.selectedCity, 'مشهد');
    expect(next.enabled.length, endpoints.length);
    expect(next.loggingEnabled, false);
    c.dispose();
    next.dispose();
    await store.close();
  });
  test('logging default OFF writes nothing; explicit opt-in and OFF work',
      () async {
    final directory = await Directory.systemTemp.createTemp('log071');
    final log = AppLogger();
    try {
      await log.initialize(directory: directory);
      await log.record('source', 'ignored', {'rows': 1});
      expect(await log.files(), isEmpty);
      await log.setEnabled(true);
      await log.record('source', 'visible', {'rows': 2});
      await log.flush();
      final before =
          [for (final f in await log.files()) await f.readAsString()].join();
      expect(before, contains('visible'));
      await log.setEnabled(false);
      await log.record('source', 'not_written', {'rows': 3});
      await log.flush();
      expect([for (final f in await log.files()) await f.readAsString()].join(),
          before);
    } finally {
      await directory.delete(recursive: true);
    }
  });
  test('logger opt-in preference persists independently of selected city',
      () async {
    final store = await MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
    final directory = await Directory.systemTemp.createTemp('global-log071');
    await AppLogger.instance.initialize(directory: directory);
    final c = MarketController(store);
    try {
      await c.init();
      expect(c.loggingEnabled, false);
      await c.setLogging(true);
      await c.setCity('شیراز');
      final next = MarketController(store);
      await next.init();
      expect(next.loggingEnabled, true);
      expect(next.selectedCity, 'شیراز');
      next.dispose();
      await c.setLogging(false);
    } finally {
      c.dispose();
      await store.close();
      await directory.delete(recursive: true);
    }
  });
  test(
      'range worker matches domain rules; cities, uncertainty, units and catalogue preserved',
      () async {
    final rows = [
      row(1), row(2, amount: 200), row(3, city: 'تهران', amount: 9999),
      change(row(4), {'sourceDateRaw': '2026-10-01'}),
      change(row(5), {'currency': 'نامشخص'}),
      change(row(6), {'unit': 'piece', 'amount': 500.0}),
      change(row(7, city: 'تهران', amount: 300), {
        'details': {'محل تولید': 'مشهد'}
      }),
      row(1), // refetch duplicate must not gain weight.
    ];
    final stages = <String>[];
    final selection = await RangeTask()
        .run(request(rows), onProgress: (s, _, __) => stages.add(s));
    final expected = calculateProductRange({
      'quotes': rows,
      'query': const ProductRangeQuery('ورق', city: 'مشهد'),
      'now': at
    });
    expect(selection.result.announcements.map((q) => q.id).toSet(),
        expected.announcements.map((q) => q.id).toSet());
    expect(selection.result.ranges.length, 2);
    expect(
        selection.result.ranges.firstWhere((r) => r.basis == 'kg').mean, 200);
    expect(
        selection.result.ranges
            .firstWhere((r) => r.basis == 'kg')
            .announcements
            .length,
        3);
    expect(selection.catalog.length, 6);
    expect(selection.catalog.any((p) => p.example.id == 'q4'), true);
    expect(stages, contains('محاسبه اعلام‌های معتبر ۴۸ ساعت'));
  });
  test('worker gives a terminal empty result, not indefinite loading',
      () async {
    final selection = await RangeTask().run(request([]));
    expect(selection.result.ranges, isEmpty);
    expect(selection.catalog, isEmpty);
  });
  test('worker exception and deadline both terminate; retry succeeds',
      () async {
    await expectLater(RangeTask().run({'family': 'ورق'}), throwsStateError);
    await expectLater(
        RangeTask()
            .run(request(List.generate(2000, row)), timeout: Duration.zero),
        throwsA(isA<TimeoutException>()));
    expect((await RangeTask().run(request([row(1)]))).result.ranges.single.mean,
        100);
  });
  test('cancel terminates a confirmed job without admitting its late result',
      () async {
    final task = RangeTask();
    final future = task.run(request(List.generate(2000, row)));
    final assertion = expectLater(future, throwsA(isA<RangeCancelled>()));
    task.cancel();
    await assertion;
    expect(task.running, false);
  });
  test(
      'large stable snapshot emits progress and leaves main-isolate timers responsive',
      () async {
    final rows = List.generate(
        8730,
        (i) => row(i,
            city: i.isEven ? 'مشهد' : 'تهران',
            amount: 100 + (i % 200).toDouble()));
    final input = request(rows);
    final watch = Stopwatch()..start();
    var ticks = 0, progress = 0;
    final timer =
        Timer.periodic(const Duration(milliseconds: 1), (_) => ticks++);
    final next =
        await RangeTask().run(input, onProgress: (_, __, ___) => progress++);
    timer.cancel();
    expect(next.catalog.length, 4365);
    expect(next.result.announcements.length, 4365);
    expect(progress, greaterThan(10));
    expect(ticks, greaterThan(0));
    stdout.writeln(
        'RANGE071_METRIC rows=8730 selected=4365 elapsedMs=${watch.elapsedMilliseconds} mainTimerTicks=$ticks progress=$progress');
  });
  test('new Mashhad endpoints are distinct existing-channel identities', () {
    for (final id in ['telegram-bonyan-ghavam', 'eitaa-bonyan-ghavam']) {
      final e = endpoints.singleWhere((e) => e.id == id);
      expect(e.sellerCity, 'مشهد');
      expect(e.defaultEnabled, true);
      final canonical = publicChannel(e.url)!.id;
      expect(
          endpoints.where((s) => publicChannel(s.url)?.id == canonical).length,
          1);
    }
  });
  test('observed Bonyan rows never invent currency/unit or fresh dates', () {
    final e = endpoints.singleWhere((e) => e.id == 'telegram-bonyan-ghavam');
    const text =
        '13 آبان 1405\nتیرآهن 14 اصفهان 22.800،000\nمیلگرد 8 A3 140000';
    final rows = TextPriceEngine.analyze(
        text: text,
        endpoint: e.id,
        seller: e.name,
        sourceUrl: e.url,
        fetchedAt: at,
        postId: 'observed');
    expect(
        rows.where((q) => q.details['مبلغ استخراج‌شده']?.isNotEmpty ?? false),
        isNotEmpty);
    expect(
        rows.every((q) => q.currency == 'نامشخص' && q.unit == 'unknown'), true);
    expect(
        rows.every((q) =>
            q.marketAt == null || at.difference(q.marketAt!).inHours >= 48),
        true);
    expect(calculateRanges(rows, at).ranges, isEmpty);
  });
  test('buyer offers and doubling labor never become selling prices', () {
    for (final text in [
      'خریداریم تیر14 اصفهان 22400 تومان هر کیلوگرم',
      'دستمزد دوبله کردن تیرآهن14 : 900000 تومان هر شاخه'
    ]) {
      final rows = TextPriceEngine.analyze(
          text: text,
          endpoint: 'e',
          seller: 'آهن',
          sourceUrl: 'https://example.com',
          fetchedAt: at,
          postId: 'buy');
      expect(rows.where((q) => q.amount != null), isEmpty, reason: text);
    }
  });
  test('selected city never reduces enabled-source acquisition or stored data',
      () async {
    final store = await MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
    final client = RecordingClient();
    final c = MarketController(store, client: client);
    try {
      await c.init();
      // The recorded rows carry the fixed date of this file; the test is about
      // the city never limiting what is acquired, not about the time window.
      await c.setDiscoveryDays(0);
      await c.setCity('مشهد');
      final selected = [
        endpoints.firstWhere((e) => e.sellerCity == 'مشهد'),
        endpoints.firstWhere((e) => e.sellerCity == 'تهران')
      ];
      c.enabled = selected.map((e) => e.id).toSet();
      await c.refresh();
      expect(client.seen.toSet(), c.enabled);
      final stored = await store.latest();
      expect(stored.length, 2);
      expect(stored.any((q) => q.sellerCity == 'تهران'), true);
      expect(c.filtered.every((q) => cityMatches(q, 'مشهد')), true);
    } finally {
      c.dispose();
      await store.close();
    }
  });
  testWidgets(
      'refresh revisions do not restart confirmed range; city change clears stale result',
      (t) async {
    final store = await t.runAsync(() => MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi));
    final date = DateTime.now()
        .toUtc()
        .subtract(const Duration(hours: 1))
        .toIso8601String();
    await t.runAsync(() => store!.saveSnapshot('e', [
          change(row(1), {'sourceDateRaw': date}),
          change(row(2, amount: 200), {'sourceDateRaw': date})
        ]));
    final c = MarketController(store!);
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AnimatedBuilder(
                animation: c, builder: (_, __) => RangePage(c: c)))));
    await t.tap(find.byType(ListTile).first);
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('تأیید و نمایش رنج'), 250,
        scrollable: find.byType(Scrollable).first);
    await t.tap(find.text('تأیید و نمایش رنج'));
    // Refresh revisions keep arriving while the confirmed job is still running.
    await t.runAsync(() async {
      for (var i = 0; i < 30; i++) {
        c.historyRevision++;
        c.changed();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await _settleRange(t);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await t.scrollUntilVisible(find.text('۱۵۰ تومان / کیلوگرم'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('۱۵۰ تومان / کیلوگرم'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('داده جدید رسیده است'), findsOneWidget);
    await t.runAsync(() => c.setCity('تهران'));
    await t.pumpAndSettle();
    expect(find.text('۱۵۰ تومان / کیلوگرم'), findsNothing);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox.shrink());
    c.dispose();
    await t.runAsync(store.close);
  });
  testWidgets(
      'city-search Back preserves scope; only explicit all-cities clears it',
      (t) async {
    var city = 'مشهد';
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => FilledButton(
                    child: const Text('choose city'),
                    onPressed: () async {
                      final value = await showSearch<String?>(
                          context: context,
                          delegate: CitySearch(['مشهد', 'تهران']));
                      if (value != null) city = value;
                    })))));
    await t.tap(find.text('choose city'));
    await t.pumpAndSettle();
    await t.tap(find.byIcon(Icons.arrow_back));
    await t.pumpAndSettle();
    expect(city, 'مشهد');
    await t.tap(find.text('choose city'));
    await t.pumpAndSettle();
    await t.tap(find.text('تمام شهرهای ایران'));
    await t.pumpAndSettle();
    expect(city, '');
    expect(t.takeException(), isNull);
  });
  testWidgets('a zero read budget still ends the spinner and never blocks data',
      (t) async {
    final store = await t.runAsync(() => MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi));
    // The rate must be inside the 48-hour confirmation window, so its real
    // source date is derived from the current clock, not from a fixed day.
    final recent = DateTime.now()
        .toUtc()
        .subtract(const Duration(hours: 1))
        .toIso8601String();
    await t.runAsync(() => store!.saveSnapshot('e', [
          change(row(1), {'sourceDateRaw': recent}),
          change(row(2, amount: 200), {'sourceDateRaw': recent})
        ]));
    final c = MarketController(store!);
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: RangePage(c: c, readTimeout: Duration.zero))));
    await t.tap(find.byType(ListTile).first);
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('تأیید و نمایش رنج'), 250,
        scrollable: find.byType(Scrollable).first);
    await t.tap(find.text('تأیید و نمایش رنج'));
    await _settleRange(t);
    // No deadline error stands between the user and the stored data: the
    // confirmation completes and the answer is shown.
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.textContaining('مهلت محاسبه تمام شد'), findsNothing);
    await _scrollTo(t, find.text('۱۵۰ تومان / کیلوگرم'));
    expect(find.text('۱۵۰ تومان / کیلوگرم'), findsOneWidget);
    await _scrollTo(t, find.text('تأیید و نمایش رنج'));
    expect(find.text('تأیید و نمایش رنج'), findsOneWidget);
    expect(await t.runAsync(() => store.latest()), isNotEmpty);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox.shrink());
    c.dispose();
    await t.runAsync(store.close);
  });
}

class RecordingClient extends SourceClient {
  final seen = <String>[];
  @override
  Future<List<Quote>> fetch(SourceEndpoint e,
      {int windowDays = 0, int? pageLimit}) async {
    seen.add(e.id);
    complete[e.id] = true;
    return [
      change(row(seen.length, city: e.sellerCity), {'endpoint': e.id})
    ];
  }
}
