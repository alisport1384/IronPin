import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ironpin/data/backup.dart';
import 'package:ironpin/data/source_finder_io.dart';
import 'package:ironpin/data/store.dart';
import 'package:ironpin/domain/source_finder.dart';

/// هوش جستجوگر ۲ stores its process state (queue, three lists, seen links and
/// the meta record) as `finder.*` settings. That state must travel inside the
/// JSONL backup and load back on every import — on a phone that already has
/// its own finder state as well as on a fresh installation — because a backup
/// that carries the searcher's progress must be able to restore it.
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
}
