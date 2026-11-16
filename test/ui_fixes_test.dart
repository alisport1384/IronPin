import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironpin/data/controller.dart';
import 'package:ironpin/data/store.dart';
import 'package:ironpin/domain/market.dart';
import 'package:ironpin/ui/chart_page.dart';
import 'package:ironpin/ui/range_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Quote _q(String id, String title, double amount, DateTime now,
        {String? size,
        String? seller,
        Map<String, String> details = const {}}) =>
    Quote(
      id: id,
      endpoint: 'e',
      seller: seller ?? 'فروشنده',
      title: title,
      category: title.contains('میلگرد') ? 'میلگرد' : 'ورق',
      unit: 'kg',
      size: size,
      amount: amount,
      sourceDateRaw: now.subtract(const Duration(hours: 1)).toIso8601String(),
      fetchedAt: now,
      sourceUrl: 'https://example.com/$id',
      details: details,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  testWidgets(
      'Chart QuoteSearch prioritizes exact number over substring/metadata and runs sliced async above 2000 quotes',
      (t) async {
    final now = DateTime.now().toUtc();
    final quotes = <Quote>[
      for (var i = 0; i < 2400; i++)
        _q('m_$i', 'ورق سیاه 3 نورد', 25000 + (i % 10).toDouble(), now,
            details: const {'زمان انتشار پیام': '1405/08/25 10:00'}),
      _q('sub', 'تسمه 140 میلیمتر', 30000, now),
      _q('exact', 'میلگرد 14 نیشابور', 25000, now, size: '14'),
    ];

    Quote? picked;
    await t.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () async {
              picked = await showSearch<Quote?>(
                context: context,
                delegate: QuoteSearch(quotes),
              );
            },
            child: const Text('search'),
          ),
        ),
      ),
    ));

    await t.tap(find.text('search'));
    await t.pumpAndSettle();

    await t.enterText(find.byType(TextField), '14');
    await t.pump(const Duration(milliseconds: 180));
    await t.pumpAndSettle();

    // Exact 'میلگرد ۱۴' must appear above substring 'تسمه ۱۴۰', and metadata
    // '1405/...' must NOT match '14'.
    expect(find.text('میلگرد ۱۴ نیشابور'), findsOneWidget);
    expect(find.text('تسمه ۱۴۰ میلیمتر'), findsOneWidget);
    expect(find.text('ورق سیاه ۳ نورد'), findsNothing);

    final exactTop = t.getTopLeft(find.text('میلگرد ۱۴ نیشابور')).dy;
    final subTop = t.getTopLeft(find.text('تسمه ۱۴۰ میلیمتر')).dy;
    expect(exactTop, lessThan(subTop));

    await t.tap(find.text('میلگرد ۱۴ نیشابور'));
    await t.pumpAndSettle();
    expect(picked?.id, 'exact');
    expect(t.takeException(), isNull);
  });

  testWidgets(
      'RangePage candidate row and details dialog trigger onChart with selected candidate Quote',
      (t) async {
    t.view.physicalSize = const Size(420, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);

    final now = DateTime.now().toUtc();
    final store = await t.runAsync(() => MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi));
    await t.runAsync(() => store!.saveSnapshot('e', [
          _q('r14', 'میلگرد 14 نیشابور', 25000, now, size: '14'),
        ]));
    final c = MarketController(store!);
    Quote? charted;
    addTearDown(() async {
      c.dispose();
      await store.close();
    });

    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RangePage(
          c: c,
          onChart: (q) => charted = q,
        ),
      ),
    ));
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)));
    await t.pumpAndSettle();

    // Select 'میلگرد' and confirm range calculation.
    await t.tap(find.text('میلگرد').first);
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('تأیید و نمایش رنج'), 250,
        scrollable: find.byType(Scrollable).first);
    await t.tap(find.text('تأیید و نمایش رنج'));
    for (var i = 0; i < 120; i++) {
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)));
      await t.pump();
      if (find.byType(LinearProgressIndicator).evaluate().isEmpty) break;
    }
    await t.pumpAndSettle();

    // Show candidates and expand candidate section.
    await t.scrollUntilVisible(find.text('نمایش کاندیدها'), 250,
        scrollable: find.byType(Scrollable).first);
    await t.ensureVisible(find.text('نمایش کاندیدها'));
    await t.pumpAndSettle();
    await t.tap(find.text('نمایش کاندیدها'));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.textContaining('کاندیدهای همان کالا'), 250,
        scrollable: find.byType(Scrollable).first);
    await t.ensureVisible(find.textContaining('کاندیدهای همان کالا'));
    await t.pumpAndSettle();
    await t.tap(find.textContaining('کاندیدهای همان کالا'));
    await t.pumpAndSettle();

    // Candidate tile must expose the chart icon button.
    final chartIcon = find.byTooltip('نمایش نمودار').first;
    await t.ensureVisible(chartIcon);
    await t.tap(chartIcon);
    await t.pumpAndSettle();
    expect(charted?.id, 'r14');

    // Opening candidate details dialog must also expose 'نمایش نمودار' action.
    charted = null;
    final candidateTile = find.descendant(
      of: find.widgetWithText(ExpansionTile, 'کاندیدهای همان کالا • ۱ مورد'),
      matching: find.text('میلگرد ۱۴ نیشابور'),
    );
    await t.ensureVisible(candidateTile);
    await t.tap(candidateTile);
    await t.pumpAndSettle();
    final dialogChartBtn = find.text('نمایش نمودار');
    expect(dialogChartBtn, findsOneWidget);
    await t.tap(dialogChartBtn);
    await t.pumpAndSettle();
    expect(charted?.id, 'r14');
    expect(t.takeException(), isNull);
  });
}
