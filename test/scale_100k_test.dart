import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:ironpin/data/controller.dart';
import 'package:ironpin/data/sources.dart';
import 'package:ironpin/data/store.dart';
import 'package:ironpin/domain/market.dart';
import 'package:ironpin/main.dart';
import 'package:ironpin/ui/prices_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Quote _makeQuote(String ep, int i, DateTime now) {
  const families = [
    ('میلگرد', 'میلگرد 16 A3 نیشابور', '16', ''),
    ('تیرآهن', 'تیرآهن 14 ذوب آهن اصفهان', '14', ''),
    ('ورق', 'ورق سیاه 3 مبارکه', '', '3'),
    ('پروفیل', 'قوطی 40*40 ضخامت 2', '', '2'),
    ('نبشی', 'نبشی 50*50 ضخامت 5', '50', '5'),
  ];
  final f = families[i % families.length];
  final hoursAgo = i % 36;
  final published = now.subtract(Duration(hours: hoursAgo));
  return Quote(
    id: '$ep/$i',
    endpoint: ep,
    seller: 'فولاد $ep',
    sellerCity: i.isEven ? 'مشهد' : 'اصفهان',
    title: f.$2,
    category: f.$1,
    material: 'فولاد کربنی',
    brand: 'مبارکه',
    size: f.$3.isEmpty ? null : f.$3,
    thickness: f.$4.isEmpty ? null : f.$4,
    unit: 'kg',
    currency: 'تومان',
    amount: 28000.0 + (i % 5000),
    sourceDateRaw: published.toIso8601String(),
    fetchedAt: published,
    sourceUrl: 'https://example.com/$ep/$i',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test('15,000 and 100,000 archive rows load, filter, sort, and confirm ranges smoothly', () async {
    final now = DateTime.now().toUtc();
    final noNet = SourceClient(
        client: MockClient((r) async => throw StateError('offline benchmark')));

    for (final totalArchiveRows in [15000, 100000]) {
      final latestCount = totalArchiveRows ~/ 2;
      final dir = await Directory.systemTemp.createTemp('ironpin-scale-$totalArchiveRows');
      addTearDown(() => dir.delete(recursive: true));
      final store = await MarketStore.open(
          dbPath: '${dir.path}/scale.db', factory: databaseFactoryFfi);
      try {
        // Populate latestCount offers across batches of 2500 (writes latestCount
        // to `latest` + latestCount to `history` = totalArchiveRows total).
        const perSource = 2500;
        final sources = latestCount ~/ perSource;
        for (var s = 0; s < sources; s++) {
          final ep = 'ep-$s';
          await store.saveSnapshot(ep, [
            for (var i = 0; i < perSource; i++)
              _makeQuote(ep, s * perSource + i, now)
          ]);
        }

        final c = MarketController(store, client: noNet);
        try {
          final swInit = Stopwatch()..start();
          await c.init();
          await c.prepareCandidates();
          swInit.stop();

          expect(c.quotes.length, latestCount);
          expect(c.rangeSession.indexRows, totalArchiveRows);
          expect(c.candidateCount, latestCount);
          expect(c.candidateRows.length, 60);

          // Price ascending sort across the entire 7,500 / 50,000 offer scope:
          final swSort = Stopwatch()..start();
          c.filter.sort = 'asc';
          c.changed();
          final ascRows = c.candidateRows;
          final cheapest = ascRows.first.amount;
          swSort.stop();
          expect(ascRows.length, latestCount);
          expect(cheapest, isNotNull);

          // Semantic search over 100k archive («یک ورق آهن فولادی» vs «قرص آهن یک ورق»):
          final swSearch = Stopwatch()..start();
          c.filter
            ..sort = 'latest'
            ..query = 'یک ورق آهن فولادی';
          c.changed();
          await c.prepareCandidates();
          final sheetCount = c.candidateCount;
          c.filter.query = 'قرص آهن یک ورق';
          c.changed();
          await c.prepareCandidates();
          final pillCount = c.candidateCount;
          swSearch.stop();

          expect(sheetCount, latestCount ~/ 5);
          expect(pillCount, 0);

          // Range confirmation over the 100k archive:
          final swRange = Stopwatch()..start();
          final answer = await c.rangeSession.confirm(
            family: 'ورق',
            fields: const {'thickness': '3'},
            basis: 'kg',
            city: '',
            at: now,
            windowDays: 30,
          );
          swRange.stop();
          expect(answer.inputRows, totalArchiveRows);
          expect(answer.result.ranges, isNotEmpty);

          // Keep generous CI bounds while proving 100k never stalls or OOMs.
          expect(swInit.elapsedMilliseconds, lessThan(8000),
              reason: '$totalArchiveRows init+candidates took ${swInit.elapsedMilliseconds}ms');
          expect(swSort.elapsedMilliseconds, lessThan(3000),
              reason: '$totalArchiveRows price sort took ${swSort.elapsedMilliseconds}ms');
          expect(swRange.elapsedMilliseconds, lessThan(4000),
              reason: '$totalArchiveRows range confirm took ${swRange.elapsedMilliseconds}ms');
          // ignore: avoid_print
          print('SCALE_$totalArchiveRows '
              'initMs=${swInit.elapsedMilliseconds} '
              'sortAscMs=${swSort.elapsedMilliseconds} '
              'searchMs=${swSearch.elapsedMilliseconds} '
              'rangeConfirmMs=${swRange.elapsedMilliseconds} '
              'rssMb=${ProcessInfo.currentRss ~/ (1024 * 1024)}');
        } finally {
          c.dispose();
        }
      } finally {
        await store.close();
      }
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  group('UI rendering at 15,000 archive scale', () {
    late Directory uiDir;
    late MarketStore uiStore;
    late MarketController uiController;

    setUp(() async {
      final now = DateTime.now().toUtc();
      uiDir = await Directory.systemTemp.createTemp('ironpin-ui-15k');
      uiStore = await MarketStore.open(
          dbPath: '${uiDir.path}/ui15k.db', factory: databaseFactoryFfi);
      final noNet = SourceClient(
          client: MockClient((r) async => throw StateError('offline')));
      for (var s = 0; s < 3; s++) {
        await uiStore.saveSnapshot('ui-$s', [
          for (var i = 0; i < 2500; i++)
            _makeQuote('ui-$s', s * 2500 + i, now)
        ]);
      }
      await uiStore.decideRetention(clearOld: false, now: now);
      uiController = MarketController(uiStore, client: noNet);
      await uiController.init();
      await uiController.prepareCandidates();
    });

    tearDown(() async {
      uiController.dispose();
      await uiStore.close();
      await uiDir.delete(recursive: true);
    });

    testWidgets(
        'PricesPage renders and scrolls 15,000 archive rows smoothly without overflow',
        (tester) async {
      final swFrame = Stopwatch()..start();
      await tester.pumpWidget(IronPinApp(controller: uiController));
      await tester.pump(const Duration(milliseconds: 50));
      swFrame.stop();

      expect(find.byType(QuoteCard), findsWidgets);
      expect(tester.takeException(), isNull);

      await tester.drag(find.byType(ListView).first, const Offset(0, -1200));
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.takeException(), isNull);
      expect(swFrame.elapsedMilliseconds, lessThan(1500));
    });
  });
}
