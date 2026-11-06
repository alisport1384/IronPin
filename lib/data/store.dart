import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'app_logger.dart';
import 'package:path/path.dart' as path;
import 'package:shamsi_date/shamsi_date.dart';
import 'package:sqflite/sqflite.dart';
import '../domain/market.dart';

class MarketStore {
  final Database db;
  MarketStore(this.db);
  static Future<MarketStore> open(
      {String? dbPath, DatabaseFactory? factory}) async {
    final f = factory ?? databaseFactory;
    final p = dbPath ?? path.join(await getDatabasesPath(), 'ironpin.db');
    final db = await f.openDatabase(p,
        options: OpenDatabaseOptions(
            version: 2,
            onCreate: (db, version) async {
              await db.execute(
                  'CREATE TABLE latest (id TEXT PRIMARY KEY, endpoint TEXT NOT NULL, payload TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 1)');
              await db.execute(
                  'CREATE TABLE history (seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL, captured_at TEXT NOT NULL, signature TEXT NOT NULL, payload TEXT NOT NULL)');
              await db.execute(
                  'CREATE INDEX history_id_time ON history(id,captured_at)');
              await db
                  .execute('CREATE INDEX history_id_seq ON history(id,seq)');
              await db.execute(
                  'CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
              await db.execute(
                  'CREATE TABLE sync (endpoint TEXT PRIMARY KEY, attempted_at TEXT NOT NULL, success_at TEXT, message TEXT NOT NULL)');
            },
            onUpgrade: (db, oldVersion, newVersion) async {
              if (oldVersion < 2) {
                await db.execute(
                    'CREATE INDEX IF NOT EXISTS history_id_seq ON history(id,seq)');
              }
            }));
    return MarketStore(db);
  }

  Future<List<Quote>> latest() async => compute(
      _decodeQuotes,
      (await db.query('latest', where: 'active=1'))
          .map((r) => r['payload'] as String)
          .toList());
  Future<List<Quote>> history(String id, {DateTime? since}) async {
    final rows = await db.query('history',
        where: since == null ? 'id=?' : 'id=? AND captured_at>=?',
        whereArgs: since == null ? [id] : [id, since.toUtc().toIso8601String()],
        orderBy: 'captured_at ASC, seq ASC');
    final result = await compute(
        _decodeQuotes, rows.map((r) => r['payload'] as String).toList());
    await AppLogger.instance
        .record('chart', 'history_read', {'points': result.length});
    return result;
  }

  Future<void> saveSnapshot(String endpoint, List<Quote> quotes,
      {bool replaceMissing = true}) async {
    if (quotes.isEmpty) {
      throw ArgumentError('Empty snapshot is not a successful refresh.');
    }
    if (quotes.any((q) => q.endpoint != endpoint)) {
      throw ArgumentError('Endpoint mismatch');
    }
    await db.transaction((tx) async {
      // Missing rows disappear from current offers, but their real history stays intact.
      if (replaceMissing) {
        await tx.update('latest', {'active': 0},
            where: 'endpoint=?', whereArgs: [endpoint]);
      }
      final current = await tx.query('latest',
          columns: ['id', 'payload'],
          where: 'endpoint=?',
          whereArgs: [endpoint]);
      final previous = await tx.rawQuery(
          'SELECT l.id,(SELECT h.signature FROM history h WHERE h.id=l.id ORDER BY h.seq DESC LIMIT 1) AS signature FROM latest l WHERE l.endpoint=?',
          [endpoint]);
      final plan = await compute(_snapshotPlan,
          {'quotes': quotes, 'current': current, 'previous': previous});
      final batch = tx.batch();
      for (final item in plan) {
        if (item['retire'] == true) {
          batch.update('latest', {'active': 0},
              where: 'id=?', whereArgs: [item['id']]);
        } else if (item['keep'] == true) {
          batch.update('latest', {'active': 1},
              where: 'id=?', whereArgs: [item['id']]);
        } else {
          batch.insert(
              'latest',
              {
                'id': item['id'],
                'endpoint': endpoint,
                'payload': item['payload'],
                'active': 1
              },
              conflictAlgorithm: ConflictAlgorithm.replace);
          if (item['changed'] == true) {
            batch.insert('history', {
              'id': item['id'],
              'captured_at': item['time'],
              'signature': item['signature'],
              'payload': item['payload']
            });
          }
        }
      }
      await batch.commit(noResult: true);
      final now = DateTime.now().toUtc().toIso8601String();
      await tx.insert(
          'sync',
          {
            'endpoint': endpoint,
            'attempted_at': now,
            'success_at': now,
            'message':
                '${quotes.length} ردیف دریافت شد${replaceMissing ? '' : '؛ پوشش محدود/ورودی دستی؛ موارد قبلی حفظ شدند'}'
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    });
    await AppLogger.instance.record('storage', 'snapshot_saved',
        {'endpoint': endpoint, 'rows': quotes.length});
  }

  Future<void> failure(String endpoint, String message) async {
    final old =
        await db.query('sync', where: 'endpoint=?', whereArgs: [endpoint]);
    await db.insert(
        'sync',
        {
          'endpoint': endpoint,
          'attempted_at': DateTime.now().toUtc().toIso8601String(),
          'success_at': old.firstOrNull?['success_at'],
          'message': message
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, Map<String, Object?>>> syncStates() async =>
      {for (final r in await db.query('sync')) r['endpoint'] as String: r};
  Future<String?> setting(String key) async =>
      (await db.query('settings', where: 'key=?', whereArgs: [key]))
          .firstOrNull?['value'] as String?;
  Future<void> setSetting(String key, String value) async =>
      db.insert('settings', {'key': key, 'value': value},
          conflictAlgorithm: ConflictAlgorithm.replace);
  // Calendar-month decision. No implicit deletion and no deletion of latest/settings.
  Future<bool> retentionDue(DateTime now) async =>
      await setting('retentionMonth') != retentionMonth(now);
  static Jalali _month(DateTime now) => Jalali.fromDateTime(
      now.toUtc().add(const Duration(hours: 3, minutes: 30)));
  static String retentionMonth(DateTime now) {
    final j = _month(now);
    return '${j.year}-${j.month.toString().padLeft(2, '0')}';
  }

  static DateTime retentionCutoff(DateTime now) {
    final j = _month(now);
    final g = Jalali(j.year, j.month, 1).toGregorian();
    return DateTime.utc(g.year, g.month, g.day)
        .subtract(const Duration(hours: 3, minutes: 30));
  }

  Future<int> decideRetention(
      {required bool clearOld, required DateTime now}) async {
    final deleted = await db.transaction((tx) async {
      final count = clearOld
          ? await tx.delete('history',
              where: 'captured_at<?',
              whereArgs: [retentionCutoff(now).toIso8601String()])
          : 0;
      await tx.insert(
          'settings', {'key': 'retentionMonth', 'value': retentionMonth(now)},
          conflictAlgorithm: ConflictAlgorithm.replace);
      return count;
    });
    await AppLogger.instance.record(
        'retention',
        clearOld ? 'old_history_cleared' : 'history_kept',
        {'deleted': deleted, 'month': retentionMonth(now)});
    return deleted;
  }

  Future<int> historyCount() async =>
      Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM history')) ??
      0;
  Future<void> close() => db.close();
}

List<Quote> _decodeQuotes(List<String> payloads) =>
    payloads.map((s) => Quote.fromJson(jsonDecode(s))).toList();
List<Map<String, Object?>> _snapshotPlan(Map<String, Object> input) {
  final quotes = input['quotes'] as List<Quote>;
  final current = {
    for (final r in input['current'] as List<Map<String, Object?>>)
      r['id']: r['payload'] as String
  };
  final previous = {
    for (final r in input['previous'] as List<Map<String, Object?>>)
      r['id']: r['signature']
  };
  final receivedIds = quotes.map((q) => q.id).toSet();
  final upgradedPosts = quotes
      .where((q) => q.details['تحلیل متن'] == 'محلی v2')
      .map((q) => _publicPostPrefix(q.id))
      .whereType<String>()
      .toSet();
  final retired = <Map<String, Object?>>[];
  if (upgradedPosts.isNotEmpty) {
    for (final entry in current.entries) {
      final id = entry.key as String;
      if (receivedIds.contains(id) ||
          !upgradedPosts.contains(_publicPostPrefix(id))) continue;
      final old = Quote.fromJson(jsonDecode(entry.value));
      // Only supersede v1 rows from a message actually reread by v2. Never
      // delete their history or retire unread messages on bounded refreshes.
      if (old.details['تحلیل متن'] == 'محلی v1') {
        retired.add({'id': id, 'retire': true});
      }
    }
  }
  return [
    ...retired,
    ...quotes.map((q) {
      final old = current[q.id];
      final oldDate =
          old == null ? null : Quote.fromJson(jsonDecode(old)).announcedAt;
      if (oldDate != null &&
          q.announcedAt != null &&
          q.announcedAt!.isBefore(oldDate)) {
        return <String, Object?>{'id': q.id, 'keep': true};
      }
      final signature = q.signature;
      return <String, Object?>{
        'id': q.id,
        'payload': jsonEncode(q.toJson()),
        'signature': signature,
        'changed': previous[q.id] != signature,
        'time': q.fetchedAt.toUtc().toIso8601String()
      };
    })
  ];
}

final _publicPostPattern = RegExp(r'^([^:]+:[A-Za-z0-9_]+/\d+)(?::|$)');
String? _publicPostPrefix(String id) => _publicPostPattern.firstMatch(id)?[1];
