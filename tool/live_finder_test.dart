import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ironpin/data/source_finder_io.dart';
import 'package:ironpin/data/sources.dart';
import 'package:ironpin/data/store.dart';
import 'package:ironpin/domain/source_finder.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Explicit opt-in only; excluded from the normal offline test/ directory.
//
//   flutter test tool/live_finder_test.dart --concurrency=1 \
//     --dart-define=IRONPIN_FINDER_SLICES=8 \
//     --dart-define=IRONPIN_FINDER_REPORT=research/finder-v094/live.json
//
// Runs هوش جستجوگر ۲ against the real network for a few slices and hands what
// its completed lists hold to هوش جستجوگر ۱, exactly as the app does. It is a
// measurement of this network at this hour, not a promise about the phone's
// network.
void main() {
  test('live list builder smoke', () async {
    sqfliteFfiInit();
    final store = await MarketStore.open(
        dbPath: inMemoryDatabasePath, factory: databaseFactoryFfi);
    final web = http.Client();
    final client = SourceClient(client: web, maxChannelPages: 1);
    // IRONPIN_FINDER_NOSEARCH=true measures the case the user reported: no
    // public search page can be reached at all. The lists then start only
    // from what the app ships with, exactly as `MarketController` seeds them.
    const noSearch = bool.fromEnvironment('IRONPIN_FINDER_NOSEARCH');
    final finder = SourceFinder(store,
        client: web, providers: noSearch ? const [] : finderProviders);
    if (noSearch) {
      final registry = jsonDecode(
          File('assets/registry.json').readAsStringSync()) as Map<String, dynamic>;
      await finder.seed(candidates: [
        for (final key in const ['telegram_channels', 'other_channels', 'sources'])
          for (final row in (registry[key] as List? ?? const []))
            if (row is Map && row['url'] is String) row['url'] as String
      ], pages: {
        for (final e in endpoints)
          if (!const {'telegram', 'eitaa', 'bale', 'rubika'}.contains(e.parser))
            Uri(scheme: 'https', host: Uri.parse(e.url).host, path: '/').toString()
      });
    }
    const slices = int.fromEnvironment('IRONPIN_FINDER_SLICES', defaultValue: 6);
    const deliver =
        int.fromEnvironment('IRONPIN_FINDER_DELIVER', defaultValue: 12);
    final log = <Map<String, Object?>>[];
    try {
      var handed = 0, accepted = 0;
      for (var i = 0; i < slices; i++) {
        final r = await finder.runSlice(
            maxSteps: 14, budget: const Duration(seconds: 60));
        // Like the app: after every slice, a few waiting entries are handed
        // to the first searcher.
        final waiting = finder.handoffBatch(limit: 50).length;
        if (waiting > 0 && handed < deliver) {
          final take = deliver - handed < 4 ? deliver - handed : 4;
          accepted += await deliverFinderBatch(store, client, finder,
              windowDays: 30, limit: take);
          handed += take < waiting ? take : waiting;
        }
        final s = finder.state;
        log.add({
          'slice': i + 1,
          'steps': r.steps,
          'offline': r.offline,
          'searches': s.searches,
          'pages': s.pages,
          'complete': [...s.complete],
          'lists': [for (final p in FinderPart.all) s.lists[p].length],
          'confirmed': [for (final p in FinderPart.all) s.count(p, 'ok')],
          'waiting': waiting,
          'acceptedSoFar': accepted,
          'providers': {...s.providerNote},
          'accepted': [for (final p in FinderPart.all) s.handed(p, 'accepted')],
          'tried': s.entries.where((e) => e.handoffTries > 0 || e.handoff == 'accepted').length,
          'error': s.lastError
        });
        if (r.offline) break;
      }
      final s = finder.state;
      final report = {
        'at': DateTime.now().toUtc().toIso8601String(),
        'slices': log,
        'report': finder.report(),
        'entries': [
          for (final e in s.entries)
            {
              'part': e.part,
              'kind': e.kind,
              'url': e.url,
              'state': e.state,
              'handoff': e.handoff,
              'tries': e.handoffTries,
              'name': e.name,
              'city': e.city,
              'cityBasis': e.cityBasis,
              'note': e.note,
              'from': e.from,
              'depth': e.depth
            }
        ],
      };
      const path = String.fromEnvironment('IRONPIN_FINDER_REPORT');
      if (path.isNotEmpty) {
        File(path)
          ..createSync(recursive: true)
          ..writeAsStringSync(const JsonEncoder.withIndent(' ').convert(report));
      }
      // ignore: avoid_print
      print(finder.report());
    } finally {
      web.close();
      await store.close();
    }
  }, timeout: const Timeout(Duration(minutes: 25)));
}
