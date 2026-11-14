import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:ironpin/data/backup.dart';
import 'package:ironpin/data/controller.dart';
import 'package:ironpin/data/source_finder_io.dart';
import 'package:ironpin/data/sources.dart';
import 'package:ironpin/data/store.dart';
import 'package:ironpin/domain/source_finder.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// هوش جستجوگر ۲ stores its process state (queue, three lists, seen links,
/// `finder.enabled`, and the meta record) as `finder.*` settings. That state
/// must travel inside the JSONL backup and load back on every import — on a
/// phone that already has its own finder state as well as on a fresh
/// installation — including enabling accepted finder sources even when user
/// preference replacement (`restoreSettings`) is left unchecked.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test('searcher 2 process state round-trips through a backup file', () async {
    final dir = await Directory.systemTemp.createTemp('ironpin-finder-backup');
    addTearDown(() => dir.delete(recursive: true));
    final source = await MarketStore.open(
        dbPath: '${dir.path}/source.db', factory: databaseFactoryFfi);
    final target = await MarketStore.open(
        dbPath: '${dir.path}/target.db', factory: databaseFactoryFfi);
    try {
      // A finder run wrote its state through the very keys it persists with.
      final run = FinderState()
        ..round = 3
        ..searches = 17
        ..pages = 4;
      run.seen.add('abc12345');
      run.queue.add(FinderTask('S', 'میلگرد 16', FinderPart.sites));
      final written = run.toSettings();
      for (final key in FinderState.settingKeys) {
        await source.setSetting(key, written[key]!);
      }
      final file = File('${dir.path}/backup.jsonl');
      await MarketBackup(source).write(file);

      // The receiving phone already runs its own, older finder: without any
      // checkbox the file's process state must still be loaded.
      final mine = FinderState()
        ..round = 1
        ..searches = 2;
      mine.seen.add('zzz99999');
      for (final key in FinderState.settingKeys) {
        await target.setSetting(key, mine.toSettings()[key]!);
      }
      final result = await MarketBackup(target).merge(file);
      expect(result.settings, greaterThanOrEqualTo(3),
          reason: 'meta, queue and seen differ and must all be imported');
      for (final key in FinderState.settingKeys) {
        expect(await target.setting(key), await source.setting(key),
            reason: '$key must be loadable from the backup');
      }

      // A fresh installation receives the same state.
      final fresh = await MarketStore.open(
          dbPath: '${dir.path}/fresh.db', factory: databaseFactoryFfi);
      await MarketBackup(fresh).merge(file);
      for (final key in FinderState.settingKeys) {
        expect(await fresh.setting(key), await source.setting(key),
            reason: '$key must reach a fresh installation');
      }
      await fresh.close();

      // The state is real: the searcher reads it back unchanged. Loading
      // touches no network, so any request here is a failure.
      final loaded = SourceFinder(target,
          client: MockClient(
              (r) async => throw StateError('load() must not fetch')));
      await loaded.load(force: true);
      expect(loaded.state.round, 3);
      expect(loaded.state.searches, 17);
      expect(loaded.state.pages, 4);
    } finally {
      await source.close();
      await target.close();
    }
  });

  test('complete Smart Search 2 state, finder.enabled, and accepted sources restore via controller', () async {
    final dir = await Directory.systemTemp.createTemp('ironpin-finder-full');
    addTearDown(() => dir.delete(recursive: true));
    final source = await MarketStore.open(
        dbPath: '${dir.path}/source.db', factory: databaseFactoryFfi);
    final target = await MarketStore.open(
        dbPath: '${dir.path}/target.db', factory: databaseFactoryFfi);

    final noNet = SourceClient(
        client: MockClient(
            (r) async => throw StateError('backup/restore must stay offline')));

    final sourceCtrl = MarketController(source, client: noNet);
    final targetCtrl = MarketController(target, client: noNet);
    try {
      await sourceCtrl.init();
      await targetCtrl.init();

      // Populate rich Smart Search 2 state on source phone, including two
      // accepted sources that were already applied (`applied == true`), with
      // one kept enabled and one explicitly turned off by the user, plus
      // finder.enabled toggled off.
      final siteLink = classifyLink('https://steel-shop-example.ir/prices')!;
      final tgLink = classifyLink('https://t.me/foolad_custom_channel')!;
      final eitaaLink = classifyLink('https://eitaa.com/ahan_disabled_test')!;

      final st = sourceCtrl.finder.state
        ..round = 5
        ..searches = 42
        ..pages = 19
        ..seeded = true
        ..complete[FinderPart.sites] = true
        ..complete[FinderPart.social] = true
        ..completedAt[FinderPart.sites] = 1760000100
        ..completedAt[FinderPart.social] = 1760000200
        ..cooldown['ddg'] = 1760000900
        ..providerNote['bing'] = 'ok|1760000050'
        ..hostFails['slow.example.ir'] = 2;
      st.seen.addAll(['11223344', '55667788']);
      st.queue.add(FinderTask('S', 'قیمت ورق فولادی مشهد', FinderPart.sites, 1));

      final siteEntry = FinderEntry(
        url: siteLink.url,
        kind: siteLink.kind,
        key: siteLink.key,
        part: siteLink.part,
        site: 'فولاد نمونه',
        city: 'مشهد',
        table: true,
        state: 'ok',
        handoff: 'accepted',
        applied: true,
        at: 1760000010,
      );
      final tgEntry = FinderEntry(
        url: tgLink.url,
        kind: tgLink.kind,
        key: tgLink.key,
        part: tgLink.part,
        name: 'کانال فولاد سفارشی',
        city: 'تهران',
        state: 'ok',
        handoff: 'accepted',
        applied: true,
        at: 1760000020,
      );
      final disabledEntry = FinderEntry(
        url: eitaaLink.url,
        kind: eitaaLink.kind,
        key: eitaaLink.key,
        part: eitaaLink.part,
        name: 'کانال خاموش‌شده',
        state: 'ok',
        handoff: 'accepted',
        applied: true,
        at: 1760000030,
      );
      st.lists[FinderPart.sites].add(siteEntry);
      st.lists[FinderPart.social].add(tgEntry);
      st.lists[FinderPart.domestic].add(disabledEntry);

      await sourceCtrl.finder.save();
      final siteId = finderEndpointOf(siteEntry)!.id;
      final tgId = finderEndpointOf(tgEntry)!.id;
      final disabledId = finderEndpointOf(disabledEntry)!.id;

      sourceCtrl.finderSources = sourceCtrl.finder.acceptedEndpoints();
      await sourceCtrl.setEnabled(siteId, true);
      await sourceCtrl.setEnabled(tgId, true);
      await sourceCtrl.setEnabled(disabledId, false);
      await sourceCtrl.setFinderEnabled(false);

      await sourceCtrl.pauseForTransfer();
      final file = File('${dir.path}/full-finder.jsonl');
      await MarketBackup(source).write(file);
      sourceCtrl.transferState(false);

      // Target phone already initialized with finderEnabled == true and its own
      // enabled list, importing WITHOUT checking restoreSettings.
      expect(targetCtrl.finderEnabled, isTrue);
      expect(targetCtrl.enabled.contains(siteId), isFalse);
      expect(targetCtrl.enabled.contains(tgId), isFalse);

      await targetCtrl.pauseForTransfer();
      await MarketBackup(target).merge(file, restoreSettings: false);
      await targetCtrl.imported();
      targetCtrl.transferState(false);

      expect(targetCtrl.finderEnabled, isFalse,
          reason: 'finder.enabled must travel with Smart Search 2 state');
      expect(targetCtrl.finder.state.round, 5);
      expect(targetCtrl.finder.state.searches, 42);
      expect(targetCtrl.finder.state.pages, 19);
      expect(targetCtrl.finder.state.cooldown['ddg'], 1760000900);
      expect(targetCtrl.finder.state.providerNote['bing'], 'ok|1760000050');
      expect(targetCtrl.finder.state.hostFails['slow.example.ir'], 2);
      expect(targetCtrl.finderSources.map((e) => e.id).toSet(),
          containsAll([siteId, tgId, disabledId]));
      expect(targetCtrl.enabled, containsAll([siteId, tgId]),
          reason: 'accepted finder sources enabled on source must be ON on target');
      expect(targetCtrl.enabled.contains(disabledId), isFalse,
          reason: 'explicitly disabled finder source on source stays OFF');
    } finally {
      sourceCtrl.dispose();
      targetCtrl.dispose();
      await source.close();
      await target.close();
    }
  });

  test('malformed finder.* setting in backup rejects atomically', () async {
    final dir = await Directory.systemTemp.createTemp('ironpin-finder-corrupt');
    addTearDown(() => dir.delete(recursive: true));
    final source = await MarketStore.open(
        dbPath: '${dir.path}/source.db', factory: databaseFactoryFfi);
    final target = await MarketStore.open(
        dbPath: '${dir.path}/target.db', factory: databaseFactoryFfi);
    try {
      final written = FinderState().toSettings();
      for (final key in FinderState.settingKeys) {
        await source.setSetting(key, written[key]!);
      }
      await source.setSetting('finder.enabled', 'true');
      final file = File('${dir.path}/ok.jsonl');
      await MarketBackup(source).write(file);

      final lines = await file.readAsLines();
      final records = lines.map((l) => jsonDecode(l) as Map<String, dynamic>).toList();
      final metaRow = records.firstWhere(
          (r) => r['table'] == 'settings' && r['row']['key'] == 'finder.meta');
      metaRow['row']['value'] = '["not-a-map"]';
      // Recompute FNV-1a checksum so only _validateRecord catches the bad shape.
      var checksum = 2166136261;
      final out = StringBuffer();
      for (var i = 0; i < records.length - 1; i++) {
        final line = jsonEncode(records[i]);
        for (final b in utf8.encode('$line\n')) {
          checksum = ((checksum ^ b) * 16777619) & 0xffffffff;
        }
        out.writeln(line);
      }
      records.last['checksum'] = checksum.toRadixString(16).padLeft(8, '0');
      out.writeln(jsonEncode(records.last));

      final bad = File('${dir.path}/bad.jsonl');
      await bad.writeAsString(out.toString());
      await expectLater(
          MarketBackup(target).merge(bad), throwsFormatException);
      expect(await target.setting('finder.meta'), isNull);
    } finally {
      await source.close();
      await target.close();
    }
  });
}
