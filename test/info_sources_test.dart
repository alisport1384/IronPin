import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ironpin/data/controller.dart';
import 'package:ironpin/data/store.dart';
import 'package:ironpin/ui/info_page.dart';

/// The info tab: «همه خاموش» and «همه روشن» act on every source the list
/// shows — registered, added and found by هوش جستجوگر ۲ — and sources that
/// share one name are shown under that single name, each route with its own
/// switch underneath.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  testWidgets('all-off and all-on cover every listed source; one name groups '
      'its routes under a single card', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    // Real database work runs outside the fake-async test zone.
    final store = await t.runAsync(() => MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi));
    final c = MarketController(store!);
    c.autoRefresh = false;
    addTearDown(() async {
      c.dispose();
      await store.close();
    });
    await t.pumpWidget(MaterialApp(home: Scaffold(body: InfoPage(c: c))));
    await t.pumpAndSettle();

    final allIds = c.availableEndpoints.map((e) => e.id).toSet();
    expect(allIds, isNotEmpty);

    Future<void> drain() => t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));

    // همه خاموش: every listed source goes off, and the choice is stored.
    final off = find.text('همه خاموش');
    await t.scrollUntilVisible(off, 250,
        scrollable: find.byType(Scrollable).first, maxScrolls: 40);
    await t.tap(off);
    await t.pumpAndSettle();
    await drain();
    expect(c.enabled, isEmpty,
        reason: 'all-off must reach every available endpoint');
    final storedOff =
        jsonDecode(await t.runAsync(() async => (await store.setting('enabled')) ?? '') ?? '') as List;
    expect(storedOff, isEmpty);

    // همه روشن: the same list back on — registered, added and finder-found.
    final on = find.text('همه روشن');
    await t.ensureVisible(on);
    await t.pumpAndSettle();
    await t.tap(on);
    await t.pumpAndSettle();
    await drain();
    expect(c.enabled.toSet(), allIds,
        reason: 'all-on must reach every available endpoint');
    final storedOn =
        jsonDecode(await t.runAsync(() async => (await store.setting('enabled')) ?? '') ?? '') as List;
    expect(storedOn.toSet(), allIds);

    // Sources sharing a name are one card, named once, with both routes.
    final sameName = find.text('بنیان فولاد قوام مشهد');
    await t.scrollUntilVisible(sameName, 300,
        scrollable: find.byType(Scrollable).first, maxScrolls: 100);
    expect(sameName, findsOneWidget,
        reason: 'same-named sources must be displayed under one name');
    await t.tap(sameName);
    await t.pumpAndSettle();
    expect(find.textContaining('منبع با همین نام'), findsOneWidget);
    expect(find.textContaining('t.me/s/BonyanFouladGhavam'), findsOneWidget);
    expect(find.textContaining('eitaa.com/bonyanfouladghavam2'), findsOneWidget);
    expect(find.text('دریافت از این منبع'), findsNWidgets(2),
        reason: 'each route keeps its own switch under the shared name');
    expect(t.takeException(), isNull);
  });
}
