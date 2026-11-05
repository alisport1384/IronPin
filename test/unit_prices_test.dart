import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironpin/domain/market.dart';
import 'package:ironpin/data/sources.dart';
import 'package:ironpin/ui/prices_page.dart';
import 'package:ironpin/ui/common.dart';

Quote q(
        {String unit = 'kg',
        double amount = 100.123,
        double? mass = 12.5,
        double? length = 6,
        double? area,
        String category = 'میلگرد',
        String currency = 'تومان'}) =>
    Quote(
        id: 'q',
        endpoint: 'e',
        seller: 'seller',
        sellerCity: 'مشهد',
        title: 'میلگرد 16',
        category: category,
        unit: unit,
        currency: currency,
        amount: amount,
        pieceKg: mass,
        lengthM: length,
        areaM2: area,
        fetchedAt: DateTime.utc(2026, 11, 5),
        sourceUrl: 'https://example.com');
void main() {
  test('kg, metre, branch and tonne computed without intermediate rounding',
      () {
    final a = q();
    expect(a.priceFor('kg'), 100.123);
    expect(a.priceFor('piece'), closeTo(1251.5375, 1e-9));
    expect(a.priceFor('m'), closeTo(208.58958333333334, 1e-9));
    expect(a.priceFor('ton'), 100123);
    expect(fmt(a.priceFor('m'), decimals: 2), '۲۰۸٫۵۹');
  });
  test('branch price inverts with explicit mass and length', () {
    final a = q(unit: 'piece', amount: 900, mass: 15, length: 12);
    expect(a.priceFor('kg'), 60);
    expect(a.priceFor('m'), 75);
    expect(a.priceFor('piece'), 900);
  });
  test('length alone can convert branch to metre but never to kilogram', () {
    final a = q(unit: 'piece', amount: 1200, mass: null, length: 12);
    expect(a.priceFor('m'), 100);
    expect(a.priceFor('kg'), null);
  });
  test('metre native price needs no mass for branch conversion', () {
    final a = q(unit: 'm', amount: 100, mass: null, length: 6);
    expect(a.priceFor('piece'), 600);
    expect(a.priceFor('kg'), null);
  });
  test('missing length is never guessed from rebar nominal size', () {
    final a = q(length: null);
    expect(a.priceFor('m'), null);
    expect(a.priceFor('piece'), isNotNull);
  });
  test('no geometric estimate from a plate thickness or dimensions', () {
    final j = q(category: 'ورق', mass: null, length: 2, area: 3).toJson()
      ..['title'] = 'ورق 8 میل 1.5*2'
      ..['thickness'] = '8';
    final a = Quote.fromJson(j);
    expect(a.priceFor('sheet'), null);
    expect(a.priceFor('m'), null);
    expect(a.priceFor('m2'), null);
  });
  test('verified sheet area supports kg/metre/sheet/square metre', () {
    final a = q(
        category: 'ورق',
        unit: 'sheet',
        amount: 900,
        mass: 30,
        length: 2,
        area: 3);
    expect(a.priceFor('kg'), 30);
    expect(a.priceFor('m'), 450);
    expect(a.priceFor('m2'), 300);
    expect(a.priceFor('sheet'), 900);
  });
  test(
      'native square metre price converts only when explicit sheet area exists',
      () {
    final a = q(
        category: 'ورق', unit: 'm2', amount: 300, mass: 30, length: 2, area: 3);
    expect(a.priceFor('sheet'), 900);
    expect(a.priceFor('kg'), 30);
    expect(a.priceFor('m'), 450);
    expect(q(category: 'ورق', unit: 'm2', area: null).priceFor('kg'), null);
  });
  test('roll stays roll and is never labelled a branch', () {
    final a = q(
        category: 'ورق',
        unit: 'roll',
        amount: 1000000,
        mass: 1000,
        length: 100);
    expect(a.discreteUnit, 'roll');
    expect(a.displayUnits, contains('roll'));
    expect(a.priceFor('m'), 10000);
    expect(a.priceFor('kg'), 1000);
    expect(a.priceFor('piece'), null);
  });
  test('tonne conversion has exact SI ratio', () {
    expect(
        q(unit: 'ton', amount: 123456, mass: null, length: null).priceFor('kg'),
        123.456);
  });
  test('zero and nonfinite mass/length do not invent a valid conversion', () {
    for (final n in [0.0, -1.0, double.nan, double.infinity]) {
      expect(q(mass: n).priceFor('piece'), null);
      expect(q(length: n).priceFor('m'), null);
    }
    expect(q(amount: double.infinity).priceFor('original'), null);
  });
  test('conversion overflow is unknown, not infinity', () {
    expect(q(amount: 1e308).priceFor('ton'), null);
  });
  test('currency and tax basis remain unchanged; rials are not called tomans',
      () {
    final a = q(currency: 'ریال');
    expect(a.currency, 'ریال');
    expect(a.priceFor('m'), closeTo(208.58958333333334, 1e-9));
  });
  test('old payload without area remains readable and IDs unchanged', () {
    final j = q().toJson()..remove('areaM2');
    final a = Quote.fromJson(j);
    expect(a.id, 'q');
    expect(a.areaM2, null);
    expect(a.priceFor('m'), q().priceFor('m'));
  });
  test(
      'domestic directory separates contacts and channels; all entries have provenance',
      () {
    final j = jsonDecode(File('assets/registry.json').readAsStringSync());
    final rows = j['other_channels'] as List;
    expect(rows.length, greaterThan(5));
    expect(rows.any((x) => x['platform'] == 'ایتا'), true);
    expect(rows.any((x) => x['platform'] == 'روبیکا'), true);
    expect(rows.any((x) => x['platform'] == 'بله'), true);
    expect(rows.any((x) => x['kind'] == 'ارتباط فروش'), true);
    expect(
        rows.where((x) => x['city'] == 'مشهد').length, greaterThanOrEqualTo(7));
    expect(
        rows.every((x) =>
            Uri.parse(x['url']).scheme == 'https' &&
            x['provenance_url'].toString().isNotEmpty),
        true);
    expect(
        rows
            .map((x) => x['url']
                .toString()
                .toLowerCase()
                .replaceFirst(RegExp(r'/$'), ''))
            .toSet()
            .length,
        rows.length);
    expect(sellers.where((x) => x['city'] == 'مشهد').length, 9);
  });
  testWidgets(
      'main-feed conversion panel displays decimals with unknown units explicitly',
      (t) async {
    t.view.physicalSize = const Size(360, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: QuoteCard(q: q(), basis: 'original', onChart: () {})))));
    await t.pumpAndSettle();
    expect(find.byType(UnitPrices), findsOneWidget);
    expect(find.text('هر متر • تبدیل'), findsOneWidget);
    expect(find.text('هر شاخه • تبدیل'), findsOneWidget);
    expect(find.text('۲۰۸٫۵۹ تومان'), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: UnitPrices(q: q(mass: null, length: null)))));
    await t.pumpAndSettle();
    expect(find.text('نامشخص؛ داده کافی نیست'), findsNWidgets(2));
    expect(find.textContaining('تخمینی'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
