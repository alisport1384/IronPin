import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ironpin/data/backup.dart';
import 'package:ironpin/data/controller.dart';
import 'package:ironpin/data/store.dart';
import 'package:ironpin/domain/market.dart';
import 'package:ironpin/domain/price_range.dart';
import 'package:ironpin/ui/prices_page.dart';
import 'package:ironpin/ui/range_page.dart';
import 'package:ironpin/ui/chart_page.dart';

Quote q(double amount, {String id = 'a'}) => Quote(
    id: id,
    endpoint: 'e',
    seller: 'فروشنده',
    title: 'ورق سیاه 3',
    category: 'ورق',
    brand: 'مبارکه',
    thickness: '3',
    dimensions: '1000x2000',
    grade: 'ST37',
    amount: amount,
    unit: 'kg',
    sourceDateRaw: DateTime.now()
        .toUtc()
        .subtract(const Duration(hours: 1))
        .toIso8601String(),
    fetchedAt: DateTime.now().toUtc(),
    sourceUrl: 'https://example.com');
Finder field(String label) => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == label);

/// Waits for a confirmed range answer or an error with bounded real-time pumps.
Future<void> _settleRange(WidgetTester t) async {
  for (var i = 0; i < 120; i++) {
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)));
    await t.pump();
    if (find.byType(LinearProgressIndicator).evaluate().isEmpty) break;
  }
  await t.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  testWidgets(
      'range cost uses selected rate; changing rate clears stale total, not quantity',
      (t) async {
    final range = calculateRanges([q(100), q(200, id: 'b')], DateTime.now())
        .ranges
        .single;
    Widget app(double rate) => MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: RangeCost(range: range, rate: rate))));
    await t.pumpWidget(app(100));
    await t.pumpAndSettle();
    await t.enterText(field('مقدار مورد نیاز (کیلوگرم)'), '۱۰');
    await t.tap(find.text('محاسبه هزینه'));
    await t.pumpAndSettle();
    expect(find.text('هزینه برآوردی: ۱٬۰۰۰ تومان'), findsOneWidget);
    expect(find.textContaining('یک هزار تومان'), findsOneWidget);
    await t.pumpWidget(app(200));
    await t.pumpAndSettle();
    expect(find.text('هزینه برآوردی: ۱٬۰۰۰ تومان'), findsNothing);
    expect(
        (t.widget<TextField>(field('مقدار مورد نیاز (کیلوگرم)')))
            .controller!
            .text,
        '۱۰');
    await t.tap(find.text('محاسبه هزینه'));
    await t.pumpAndSettle();
    expect(find.text('هزینه برآوردی: ۲٬۰۰۰ تومان'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets(
      'dimensional range estimate validates thickness and needs explicit product match',
      (t) async {
    final range = calculateRanges([q(100)], DateTime.now()).ranges.single;
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: RangeCost(range: range, rate: 100)))));
    await t.pumpAndSettle();
    await t.tap(find.text('محاسبه وزن از ابعاد'));
    await t.pumpAndSettle();
    await t.enterText(field('عرض (میلی‌متر)'), '۱۰۰۰');
    await t.enterText(field('طول هر شاخه/برگ/قطعه (متر)'), '۲');
    await t.ensureVisible(find.text('محاسبه هزینه'));
    await t.tap(find.text('محاسبه هزینه'));
    await t.pumpAndSettle();
    expect(find.text('تطبیق ابعاد و جنس با کالای انتخابی را تأیید کنید.'),
        findsOneWidget);
    await t.ensureVisible(find.byType(CheckboxListTile));
    await t.tap(find.byType(CheckboxListTile));
    await t.pumpAndSettle();
    await t.ensureVisible(find.text('محاسبه هزینه'));
    await t.tap(find.text('محاسبه هزینه'));
    await t.pumpAndSettle();
    expect(find.text('هزینه برآوردی: ۴٬۷۱۰ تومان'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets(
      'explicit rial price is converted once in card, unit panel and details',
      (t) async {
    final rial = Quote.fromJson({...q(470000).toJson(), 'currency': 'ریال'});
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child:
                    QuoteCard(q: rial, basis: 'original', onChart: () {})))));
    await t.pumpAndSettle();
    expect(find.text('۴۷٬۰۰۰٫۰۰'), findsOneWidget);
    expect(find.text('تومان / کیلوگرم'), findsOneWidget);
    await t.tap(find.text('ورق سیاه ۳'));
    await t.pumpAndSettle();
    expect(find.text('۴۷٬۰۰۰٫۰۰ تومان'), findsOneWidget);
    await t.ensureVisible(find.text('جزئیات بیشتر'));
    await t.tap(find.text('جزئیات بیشتر'));
    await t.pumpAndSettle();
    expect(find.text('۴۷٬۰۰۰٫۰۰ تومان / کیلوگرم'), findsOneWidget);
    expect(find.text('۴۷٬۰۰۰٫۰۰ ریال / کیلوگرم'), findsNothing);
    expect(find.textContaining('۴۷۰٬۰۰۰٫۰۰ ریال؛ هر ۱۰ ریال = ۱ تومان'),
        findsWidgets);
    expect(rial.amount, 470000);
    expect(rial.currency, 'ریال');
    expect(t.takeException(), isNull);
  });
  testWidgets(
      'product-first range requires confirmation and pools matching local prices without overflow',
      (t) async {
    t.view.physicalSize = const Size(360, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final store = await t.runAsync(() => MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi));
    await t.runAsync(() => store!.saveSnapshot('e', [q(100), q(200, id: 'b')]));
    final c = MarketController(store!);
    addTearDown(() async {
      c.dispose();
      await store.close();
    });
    await t.pumpWidget(MaterialApp(home: Scaffold(body: RangePage(c: c))));
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)));
    await t.pumpAndSettle();
    // The title names the window the tab is really using (one month by default).
    expect(find.textContaining('رنج‌گیری'), findsOneWidget);
    await t.tap(find.byType(ListTile).first);
    await t.pumpAndSettle();
    expect(find.text('۱۵۰ تومان / کیلوگرم'), findsNothing);
    await t.scrollUntilVisible(find.text('تأیید و نمایش رنج'), 250,
        scrollable: find.byType(Scrollable).first);
    await t.tap(find.text('تأیید و نمایش رنج'));
    // Real isolate and I/O time does not advance with the fake clock: wait
    // for the confirmed answer with bounded pumps instead of one fixed sleep.
    await _settleRange(t);
    await t.scrollUntilVisible(find.text('۱۵۰ تومان / کیلوگرم'), 300,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('۱۵۰ تومان / کیلوگرم'), findsOneWidget);
    await t.tap(find.text('محاسبه هزینه • کیلوگرم'));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('محاسبات همان کالا'), 300,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('محاسبات همان کالا'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  test('chart samples are real ordered points preserving extrema and endpoints',
      () {
    final values = List.generate(12000, (i) => 100 + (i % 20).toDouble());
    values[4321] = -500;
    values[8911] = 9000;
    final indices = chartSampleIndices(values);
    expect(indices.length, lessThanOrEqualTo(1000));
    expect(indices.first, 0);
    expect(indices.last, 11999);
    expect(indices, containsAll([4321, 8911]));
    for (var i = 1; i < indices.length; i++) {
      expect(indices[i], greaterThan(indices[i - 1]));
    }
  });
  test(
      'native picker cancellation cleans temporary export; import cancellation does not mutate',
      () async {
    final dir = await Directory.systemTemp.createTemp('ironpin-picker-');
    final store = await MarketStore.open(
        dbPath: '${dir.path}/source.db', factory: databaseFactoryFfi);
    const channel = MethodChannel('ir.ironpin/storage');
    final methods = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      if (call.method == 'backupDirectory') return dir.path;
      if (call.method == 'exportBackup') {
        expect(File((call.arguments as Map)['path']).existsSync(), true);
        return null;
      }
      if (call.method == 'importBackup') return null;
      throw MissingPluginException();
    });
    try {
      final backup = MarketBackup(store);
      expect(await backup.exportToPicker(), isNull);
      expect(await backup.importFromPicker(), isNull);
      expect(
          dir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.jsonl')),
          isEmpty);
      expect(methods, ['backupDirectory', 'exportBackup', 'importBackup']);
      expect(await store.historyCount(), 0);
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await store.close();
      await dir.delete(recursive: true);
    }
  });
}
