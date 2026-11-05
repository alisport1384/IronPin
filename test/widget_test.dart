import 'dart:io';
import 'dart:convert';
import 'package:ironpin/ui/info_page.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ironpin/main.dart';
import 'package:ironpin/data/controller.dart';
import 'package:ironpin/data/store.dart';
import 'package:ironpin/data/sources.dart';
import 'package:ironpin/ui/calculator_page.dart';
import 'package:ironpin/domain/market.dart';
import 'package:ironpin/ui/chart_page.dart';

void main() {
  late MarketController c;
  setUpAll(() async {
    sqfliteFfiInit();
    final loader = FontLoader('Vazirmatn')
      ..addFont(rootBundle.load('assets/Vazirmatn-Regular.ttf'));
    await loader.load();
  });
  setUp(() async {
    final store = await MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
    c = MarketController(store);
    c.cities = ['مشهد', 'تهران', 'اصفهان', 'تبریز'];
    c.autoRefresh = false;
  });
  tearDown(() async {
    c.dispose();
    await c.store.close();
  });
  testWidgets('RTL app has all four working tabs and truthful empty state',
      (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(IronPinApp(controller: c));
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)));
    await t.pumpAndSettle();
    expect(find.text('قیمت‌ها'), findsOneWidget);
    expect(find.text('نمودار'), findsOneWidget);
    expect(find.text('محاسبات'), findsOneWidget);
    expect(find.text('اطلاعات'), findsOneWidget);
    expect(find.text('هنوز قیمتی دریافت نشده'), findsOneWidget);
    final element = t.element(find.byType(NavigationBar));
    expect(Directionality.of(element), TextDirection.rtl);
    await t.tap(find.text('نمودار'));
    await t.pumpAndSettle();
    expect(find.text('سری قابل نمایش وجود ندارد'), findsOneWidget);
    await t.tap(find.text('محاسبات'));
    await t.pumpAndSettle();
    expect(find.text('محاسبه وزن و هزینه'), findsOneWidget);
    await t.tap(find.text('اطلاعات'));
    await t.pumpAndSettle();
    expect(find.text('اطلاعات و منابع'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets(
      'observed real fixture offers render without overflow on narrow screen',
      (t) async {
    t.view.physicalSize = const Size(360, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    c.quotes = SourceParser.parse(
        endpoints.first,
        File('test/fixtures/melal_rebar.html').readAsStringSync(),
        DateTime.utc(2026, 11, 5));
    await t.pumpWidget(IronPinApp(controller: c));
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)));
    await t.pumpAndSettle();
    expect(find.text('میلگرد 12 ذوب آهن اصفهان'), findsWidgets);
    expect(t.takeException(), isNull);
    await t.tap(find.byTooltip('فیلتر قیمت و شهر'));
    await t.pumpAndSettle();
    expect(find.text('فیلتر بازار'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('calculator accepts defaults and computes a real result',
      (t) async {
    await t
        .pumpWidget(const MaterialApp(home: Scaffold(body: CalculatorPage())));
    await t.pumpAndSettle();
    final button = find.text('محاسبه');
    await t.scrollUntilVisible(button, 500,
        scrollable: find.byType(Scrollable).first);
    await t.tap(button);
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('وزن کل برآوردی'), 300,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('وزن کل برآوردی'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets(
      'thousands of offers use a lazy chart search, not an eager dropdown',
      (t) async {
    c.quotes = List.generate(
        6000,
        (i) => Quote(
            id: 'offer-$i',
            endpoint: 'e',
            seller: 'فروشنده آزمایشی',
            title: 'ورق ${i.isEven ? 8 : 10} میل',
            category: 'ورق',
            brand: 'brand',
            unit: 'kg',
            amount: 1000 + i.toDouble(),
            sourceUrl: 'https://example.com',
            fetchedAt: DateTime.now()));
    await t.runAsync(() async {
      c.filtered;
      while (c.filtering) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    await t.pumpWidget(IronPinApp(controller: c));
    await t.pumpAndSettle();
    await t.tap(find.text('نمودار'));
    await t.pump();
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await t.pumpAndSettle();
    expect(find.byType(QuoteSearch), findsNothing);
    expect(
        find.byType(DropdownMenuItem<String>).evaluate().length, lessThan(10));
    await t.tap(find.byWidgetPredicate((w) => w is OutlinedButton).first);
    await t.pumpAndSettle();
    expect(find.byType(ListTile).evaluate().length, lessThan(30));
    await t.enterText(find.byType(TextField), '10');
    await t.pumpAndSettle();
    expect(find.textContaining('ورق 10 میل'), findsWidgets);
    expect(t.takeException(), isNull);
  });
  testWidgets('simple calculator hides density and preserves input across tabs',
      (t) async {
    await t.pumpWidget(IronPinApp(controller: c));
    await t.pumpAndSettle();
    await t.tap(find.text('محاسبات'));
    await t.pumpAndSettle();
    expect(find.text('۱. چه کالایی داری؟'), findsOneWidget);
    expect(find.text('چگالی (کیلوگرم بر مترمکعب)'), findsNothing);
    final first = find.byType(TextField).first;
    await t.enterText(first, '20');
    await t.tap(find.text('قیمت‌ها'));
    await t.pumpAndSettle();
    await t.tap(find.text('محاسبات'));
    await t.pumpAndSettle();
    expect((t.widget<TextField>(find.byType(TextField).first)).controller!.text,
        '20');
    expect(t.takeException(), isNull);
  });

  testWidgets(
      'beginner sheet example gives 31.4 kg without millimetre confusion',
      (t) async {
    await t
        .pumpWidget(const MaterialApp(home: Scaffold(body: CalculatorPage())));
    await t.pumpAndSettle();
    await t.tap(find.text('میلگرد'));
    await t.pumpAndSettle();
    await t.tap(find.text('ورق').last);
    await t.pumpAndSettle();
    final calculate = find.text('محاسبه');
    await t.scrollUntilVisible(calculate, 400,
        scrollable: find.byType(Scrollable).first);
    await t.tap(calculate);
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('۳۱٫۴۰۰ کیلوگرم'), 250,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('۳۱٫۴۰۰ کیلوگرم'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets(
      'beginner beam uses declared branch mass, never a guessed size table',
      (t) async {
    await t
        .pumpWidget(const MaterialApp(home: Scaffold(body: CalculatorPage())));
    await t.pumpAndSettle();
    await t.tap(find.text('میلگرد'));
    await t.pumpAndSettle();
    await t.tap(find.text('تیرآهن، نبشی یا ناودانی — با وزن فروشنده').last);
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField).first, '155');
    final calculate = find.text('محاسبه');
    await t.scrollUntilVisible(calculate, 400,
        scrollable: find.byType(Scrollable).first);
    await t.tap(calculate);
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('۱۵۵٫۰۰۰ کیلوگرم'), 250,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('۱۵۵٫۰۰۰ کیلوگرم'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets(
      'domestic directory filters owner, city and platform without fake rates',
      (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    c.registry = jsonDecode(File('assets/registry.json').readAsStringSync());
    await t.pumpWidget(MaterialApp(home: Scaffold(body: InfoPage(c: c))));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.byType(TextField), 500,
        scrollable: find.byType(Scrollable).first, maxScrolls: 40);
    await t.enterText(find.byType(TextField), 'رادمان');
    await t.pumpAndSettle();
    await t.tap(find.text('تمام شهرها • مشهد در اولویت'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField).last, 'مشهد');
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(ListTile, 'مشهد'));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(
        find.byType(DropdownButtonFormField<String>), 150,
        scrollable: find.byType(Scrollable).first, maxScrolls: 30);
    await t.tap(find.text('همه پیام‌رسان‌ها'));
    await t.pumpAndSettle();
    await t.tap(find.text('ایتا').last);
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('رادمان آهن • ایتا'), 150,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('رادمان آهن • ایتا'), findsOneWidget);
    expect(find.text('رادمان آهن • روبیکا'), findsNothing);
    expect(find.text('نوین پارس • بله'), findsNothing);
    expect(t.takeException(), isNull);
  });
}
