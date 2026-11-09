import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'app_logger.dart';
import '../domain/price_range.dart';
import 'package:path/path.dart' as path;
import 'package:shamsi_date/shamsi_date.dart';
import 'package:sqflite/sqflite.dart';
import '../domain/market.dart';
import '../domain/row_facts.dart';

/// Derived, payload-addressed index of the local archive (schema 5).
///
/// Deliberately not part of the backup: it is reproducible from the payloads and
/// a restore rebuilds it on first read (verified in the backup tests). Keeping it
/// out of the backup also keeps `schema: 3` backups readable.
const _rangeIndexSchema = [
  'CREATE TABLE IF NOT EXISTS range_index (payload TEXT PRIMARY KEY, '
      'family TEXT NOT NULL, facts TEXT NOT NULL, prices TEXT NOT NULL, '
      'announce_key TEXT NOT NULL, product_key TEXT, seller_norm TEXT NOT NULL, '
      'id TEXT NOT NULL, endpoint TEXT NOT NULL, title TEXT NOT NULL, '
      'category TEXT NOT NULL, seller TEXT NOT NULL, seller_city TEXT NOT NULL, '
      'unit TEXT NOT NULL, brand TEXT NOT NULL, material TEXT NOT NULL, '
      'tax TEXT NOT NULL, terms TEXT NOT NULL, status TEXT NOT NULL, '
      'specification TEXT NOT NULL, search TEXT NOT NULL, source_url TEXT NOT NULL, '
      'haystack TEXT NOT NULL, '
      "size_label TEXT NOT NULL DEFAULT '', thickness_label TEXT NOT NULL DEFAULT '', "
      "dimensions_label TEXT NOT NULL DEFAULT '', grade_label TEXT NOT NULL DEFAULT '', "
      'size_num REAL, thickness_num REAL, '
      "source_date_raw TEXT NOT NULL DEFAULT '', "
      "amount_raw TEXT NOT NULL DEFAULT '', "
      "derive TEXT NOT NULL DEFAULT '', amount REAL, currency TEXT NOT NULL, "
      'market_at INTEGER, '
      'fetched_at INTEGER NOT NULL)',
  'CREATE INDEX IF NOT EXISTS range_index_family ON range_index(family, market_at)',
  // The prices tab filters on these columns, so they are indexed rather than
  // tested row by row; the window is a range on `market_at`, so it goes last.
  'CREATE INDEX IF NOT EXISTS range_index_category ON range_index(category, market_at)',
];

class MarketStore {
  final Database db;
  MarketStore(this.db);
  static Future<MarketStore> open(
      {String? dbPath, DatabaseFactory? factory}) async {
    final f = factory ?? databaseFactory;
    final p = dbPath ?? path.join(await getDatabasesPath(), 'ironpin.db');
    final db = await f.openDatabase(p,
        options: OpenDatabaseOptions(
            version: 7,
            onCreate: (db, version) async {
              await db.execute(
                  'CREATE TABLE latest (id TEXT PRIMARY KEY, endpoint TEXT NOT NULL, payload TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 1)');
              await db.execute(
                  'CREATE INDEX latest_endpoint_active ON latest(endpoint,active)');
              await db.execute(
                  'CREATE TABLE history (seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL, captured_at TEXT NOT NULL, signature TEXT NOT NULL, payload TEXT NOT NULL, market_at TEXT)');
              await db.execute(
                  'CREATE INDEX IF NOT EXISTS history_market_time ON history(market_at)');
              await db.execute(
                  'CREATE INDEX history_id_time ON history(id,captured_at)');
              await db
                  .execute('CREATE INDEX history_id_seq ON history(id,seq)');
              await db.execute(
                  'CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
              await db.execute(
                  'CREATE TABLE sync (endpoint TEXT PRIMARY KEY, attempted_at TEXT NOT NULL, success_at TEXT, message TEXT NOT NULL)');
              for (final sql in _rangeIndexSchema) {
                await db.execute(sql);
              }
            },
            onUpgrade: (db, oldVersion, newVersion) async {
              if (oldVersion < 7) {
                await db.execute(
                    'CREATE INDEX IF NOT EXISTS latest_endpoint_active ON latest(endpoint,active)');
              }
              if (oldVersion < 2) {
                await db.execute(
                    'CREATE INDEX IF NOT EXISTS history_id_seq ON history(id,seq)');
              }
              if (oldVersion < 3) {
                final columns = await db.rawQuery('PRAGMA table_info(history)');
                if (!columns.any((r) => r['name'] == 'market_at')) {
                  await db
                      .execute('ALTER TABLE history ADD COLUMN market_at TEXT');
                }
                var after = 0;
                while (true) {
                  final rows = await db.query('history',
                      columns: ['seq', 'payload'],
                      where: 'seq>?',
                      whereArgs: [after],
                      orderBy: 'seq',
                      limit: 300);
                  if (rows.isEmpty) break;
                  final dates = await compute(_historyDates, rows);
                  final batch = db.batch();
                  for (final r in dates) {
                    batch.update('history',
                        {'market_at': r['date'], 'signature': r['signature']},
                        where: 'seq=?', whereArgs: [r['seq']]);
                  }
                  await batch.commit(noResult: true);
                  after = rows.last['seq'] as int;
                }
                await db.execute(
                    'CREATE INDEX IF NOT EXISTS history_market_time ON history(market_at)');
              }
              if (oldVersion >= 4 && oldVersion < 5) {
                // Schema 5 only adds the two derivation columns. Existing rows
                // keep their payload key and are re-derived lazily, once, by the
                // reader — no history row is touched and no payload is rewritten.
                final columns =
                    await db.rawQuery('PRAGMA table_info(range_index)');
                // `labels` is left behind by the first form of these columns; it is
                // no longer read, and dropping it would rewrite every row.
                for (final column in [
                  'derive',
                  'source_date_raw',
                  'size_label',
                  'thickness_label',
                  'dimensions_label',
                  'grade_label',
                  'size_num',
                  'thickness_num',
                ]) {
                  if (!columns.any((r) => r['name'] == column)) {
                    await db.execute(
                        'ALTER TABLE range_index ADD COLUMN $column '
                        // A numeric column is added as a number; every other
                        // column of this table is text with an empty default.
                        '${column.endsWith('_num') ? 'REAL' : "TEXT NOT NULL DEFAULT ''"}');
                  }
                }
                for (final sql in _rangeIndexSchema.skip(1)) {
                  await db.execute(sql);
                }
              }
              if (oldVersion < 4) {
                // Only the index table is added. Rows are derived lazily from the
                // payloads that are already stored, so no history is rewritten.
                for (final sql in _rangeIndexSchema) {
                  await db.execute(sql);
                }
              }
              if (oldVersion < 6) {
                // Schema 6 adds `amount_raw`: the amount exactly as the source
                // wrote it, so a range/candidate card rebuilt from the index can
                // print a price for an offer whose currency or single amount the
                // source never stated. Derived state only — the rows keep their
                // payload key and are re-derived lazily, once, by the reader.
                // Runs after the block that creates the table: a pre-4 archive
                // has no `range_index` yet, so the column is only added once the
                // table exists.
                final columns =
                    await db.rawQuery('PRAGMA table_info(range_index)');
                if (!columns.any((r) => r['name'] == 'amount_raw')) {
                  await db
                      .execute("ALTER TABLE range_index ADD COLUMN amount_raw "
                          "TEXT NOT NULL DEFAULT ''");
                }
              }
            }));
    return MarketStore(db);
  }

  Future<List<Quote>> latest() => _readLatest();

  /// Decode bounded pages inside one consistent SQLite snapshot. A large
  /// archive no longer crosses the platform channel as one giant JSON list.
  Future<List<Quote>> _readLatest({String? endpoint}) =>
      db.transaction((tx) async {
        final result = <Quote>[];
        var after = 0;
        while (true) {
          final rows = await tx.query('latest',
              columns: ['rowid', 'payload'],
              where:
                  'rowid>? AND active=1${endpoint == null ? '' : ' AND endpoint=?'}',
              whereArgs: [after, if (endpoint != null) endpoint],
              orderBy: 'rowid',
              limit: _indexChunk);
          if (rows.isEmpty) break;
          result.addAll(await compute(_decodeQuotes,
              [for (final row in rows) row['payload'] as String]));
          after = rows.last['rowid'] as int;
        }
        return result;
      });

  Future<List<Quote>> latestFor(String endpoint) =>
      _readLatest(endpoint: endpoint);
  Future<List<Quote>> history(String id, {DateTime? since, int? limit}) async {
    final rows = await db.query('history',
        columns: ['payload'],
        where: since == null ? 'id=?' : 'id=? AND captured_at>=?',
        whereArgs: since == null ? [id] : [id, since.toUtc().toIso8601String()],
        orderBy: 'captured_at DESC, seq DESC',
        limit: limit);
    final result = await compute(_decodeQuotes,
        rows.reversed.map((r) => r['payload'] as String).toList());
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
    final changedProducts = <Map<String, Object?>>[];
    var changedCount = 0;
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
          'SELECT l.id,(SELECT h.signature FROM history h WHERE h.id=l.id ORDER BY h.captured_at DESC,h.seq DESC LIMIT 1) AS signature FROM latest l WHERE l.endpoint=?',
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
            changedCount++;
            if (changedProducts.length < 10) {
              final q = Quote.fromJson(jsonDecode(item['payload'] as String));
              changedProducts.add({
                'id': q.id,
                'category': q.category,
                'amount': q.amount,
                'unit': q.unit,
                'currency': q.currency,
                'date': q.sourceDateRaw,
                'size': q.sizeLabel,
                'thickness': q.thicknessLabel
              });
            }
            batch.insert('history', {
              'id': item['id'],
              'captured_at': item['time'],
              'signature': item['signature'],
              'payload': item['payload'],
              'market_at': item['market_at']
            });
          }
        }
      }
      await batch.commit(noResult: true);
      // Derive the range index now, inside the same transaction: the heavy work
      // happens once per received row, at write time, so reading the archive for
      // a range confirmation never parses payloads again.
      await _indexPayloads(tx, [
        for (final item in plan)
          if (item['payload'] is String)
            (
              payload: item['payload'] as String,
              hash: payloadFingerprint(item['payload'] as String)
            )
      ]);
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
    await AppLogger.instance.record('source', 'snapshot_saved',
        {'endpoint': endpoint, 'rows': quotes.length, 'changed': changedCount});
    if (changedCount > 0) {
      await AppLogger.instance.record('product', 'snapshot_changes', {
        'endpoint': endpoint,
        'changed': changedCount,
        'products': changedProducts
      });
    }
  }

  Future<List<String>> rangePayloads(DateTime now, {int windowDays = 0}) async {
    final rows = await db.rawQuery(
        'SELECT payload FROM history WHERE market_at>=? AND market_at<=? '
        // Include every retained product, even inactive/old/undated rows, for
        // selection only. Statistical eligibility remains strictly 48 hours.
        'UNION ALL SELECT payload FROM latest '
        // Backups may retain history with no corresponding latest entry. One
        // representative per missing offer makes that catalogue selectable too.
        'UNION ALL SELECT h.payload FROM history h JOIN '
        '(SELECT MAX(seq) AS seq FROM history '
        'WHERE id NOT IN (SELECT id FROM latest) GROUP BY id) orphan '
        'ON h.seq=orphan.seq',
        [
          // The index holds everything the tab may show: the archive rows of the
          // selected window (48 hours when no window is chosen).
          now.toUtc().subtract(windowFor(windowDays)).toIso8601String(),
          now.toUtc().toIso8601String()
        ]);
    return rows.map((r) => r['payload'] as String).toList();
  }

  /// Index rows of the current archive, derived **at write time**.
  ///
  /// `latest`/`history` stay the only source of truth for money; this table only
  /// removes repeated parsing. Each row is keyed by the fingerprint of the
  /// payload it was derived from, so a rewritten payload is re-derived and an
  /// untouched one is never parsed again — even after a restart.
  Future<void> _indexPayloads(DatabaseExecutor tx,
      Iterable<({String payload, String hash})> rows) async {
    // One entry per payload key: the same payload can reach here from more than
    // one row of one snapshot, and deriving it twice would only rewrite itself.
    final unique = <String, String>{};
    for (final item in rows) {
      unique[item.hash] = item.payload;
    }
    if (unique.isEmpty) return;
    final hashes = unique.keys.toList();

    // Which keys already hold a current derivation?
    //
    // This used to be one `SELECT … WHERE payload=?` per row, awaited. On a
    // 12,000-row archive that measured 3.2 s against 0.03 s for the same
    // lookups as chunked `IN (…)` queries — and every one of those round trips
    // is a platform-channel hop on a device, where it costs more than it does
    // here. This is the read that made a refresh with a large archive stall.
    final current = <String>{};
    for (final chunk in _chunks(hashes)) {
      final found = await tx.query('range_index',
          columns: ['payload', 'derive', 'source_date_raw', 'amount_raw'],
          where: 'payload IN (${List.filled(chunk.length, '?').join(',')})',
          whereArgs: chunk);
      for (final row in found) {
        // An up-to-date row is never parsed again; a row written by an older
        // derivation is rebuilt once, in place, under the same payload key.
        if (RowFacts.isCurrent(row)) current.add(row['payload'] as String);
      }
    }
    final todo = [
      for (final hash in hashes)
        if (!current.contains(hash)) unique[hash]!
    ];
    if (todo.isEmpty) return;

    // Deriving a row parses its payload, extracts its spec and builds its keys.
    // That is CPU work belonging to the archive, not to the frame being drawn,
    // so it runs on a worker isolate and only the finished rows come back.
    for (final chunk in _chunks(todo)) {
      // Bound native-channel arguments and derived maps to one chunk. The
      // enclosing transaction still makes all chunks atomic.
      final batch = tx.batch();
      for (final row in await compute(_deriveIndexRows, chunk)) {
        batch.insert('range_index', row,
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    }
  }

  /// Index rows for the same selection `rangePayloads` returns, as the minimum
  /// the range engine needs: no payload parsing, no `Quote` construction.
  Future<List<Map<String, Object?>>> rangeIndexRows(DateTime now,
          {int windowDays = 0}) =>
      db.transaction((tx) async {
        // Keep a snapshot of row identifiers in SQLite, NOT every JSON payload in
        // Dart. A keyset avoids repeated OFFSET scans and bounds each channel read.
        await tx.execute('CREATE TEMP TABLE ironpin_range_read ('
            'position INTEGER PRIMARY KEY, kind INTEGER NOT NULL, source_row INTEGER NOT NULL)');
        try {
          await tx.rawInsert(
              'INSERT INTO ironpin_range_read(kind,source_row) '
              'SELECT 0,seq FROM history WHERE market_at>=? AND market_at<=? '
              'UNION ALL SELECT 1,rowid FROM latest NOT INDEXED '
              'UNION ALL SELECT 0,h.seq FROM history h JOIN '
              '(SELECT MAX(seq) AS seq FROM history '
              'WHERE id NOT IN (SELECT id FROM latest) GROUP BY id) orphan '
              'ON h.seq=orphan.seq',
              [
                now.toUtc().subtract(windowFor(windowDays)).toIso8601String(),
                now.toUtc().toIso8601String()
              ]);
          final indexed = <String, Map<String, Object?>>{};
          final result = <Map<String, Object?>>[];
          var after = 0;
          while (true) {
            final page = await tx.rawQuery(
                'SELECT s.position, CASE WHEN s.kind=0 THEN h.payload ELSE l.payload END AS payload '
                'FROM ironpin_range_read s '
                'LEFT JOIN history h ON s.kind=0 AND h.seq=s.source_row '
                'LEFT JOIN latest l ON s.kind=1 AND l.rowid=s.source_row '
                'WHERE s.position>? ORDER BY s.position LIMIT ?',
                [after, _indexChunk]);
            if (page.isEmpty) break;
            final ordered = <String>[];
            final payloads = <String, String>{};
            for (final row in page) {
              final payload = row['payload'] as String;
              final hash = payloadFingerprint(payload);
              ordered.add(hash);
              if (!indexed.containsKey(hash)) payloads[hash] = payload;
            }
            if (payloads.isNotEmpty) {
              final hashes = payloads.keys.toList();
              final marks = List.filled(hashes.length, '?').join(',');
              var found = await tx.query('range_index',
                  where: 'payload IN ($marks)', whereArgs: hashes);
              final missing = payloads.keys.toSet();
              for (final row in found) {
                if (RowFacts.isCurrent(row)) {
                  final hash = row['payload'] as String;
                  indexed[hash] = row;
                  missing.remove(hash);
                }
              }
              if (missing.isNotEmpty) {
                await _indexPayloads(tx, [
                  for (final hash in missing)
                    (payload: payloads[hash]!, hash: hash)
                ]);
                found = await tx.query('range_index',
                    where: 'payload IN ($marks)', whereArgs: hashes);
                for (final row in found) {
                  indexed.putIfAbsent(row['payload'] as String, () => row);
                }
              }
            }
            for (final hash in ordered) {
              final row = indexed[hash];
              if (row != null) result.add(row);
            }
            after = page.last['position'] as int;
          }
          return result;
        } finally {
          await tx.execute('DROP TABLE IF EXISTS temp.ironpin_range_read');
        }
      });

  Future<RangeReport> rangeReport(DateTime now) async {
    final watch = Stopwatch()..start();
    final rows = await rangePayloads(now);
    final report =
        await compute(_rangesInBackground, {'payloads': rows, 'now': now});
    await AppLogger.instance.record('range', 'computed', {
      'rows': rows.length,
      'groups': report.ranges.length,
      'elapsedMs': watch.elapsedMilliseconds
    });
    return report;
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

/// Rows per database round trip and per worker-isolate call.
const int _indexChunk = 400;

Iterable<List<T>> _chunks<T>(List<T> items) sync* {
  for (var start = 0; start < items.length; start += _indexChunk) {
    yield items.sublist(start, (start + _indexChunk).clamp(0, items.length));
  }
}

/// Derives index rows on a worker isolate.
///
/// A payload that cannot be parsed is simply not indexed, exactly as before:
/// the fallback path still reads it, so no row is lost. A storage error, in
/// contrast, surfaces instead of silently leaving the index incomplete.
List<Map<String, Object?>> _deriveIndexRows(List<String> payloads) {
  final out = <Map<String, Object?>>[];
  for (final payload in payloads) {
    try {
      out.add(RowFacts.ofPayload(payload).toRow(payloadFingerprint(payload)));
    } catch (_) {
      continue;
    }
  }
  return out;
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
        // Current payload, not insertion order of imported old history, is the
        // baseline for detecting an actual change. Empty history starts a point.
        'changed': previous[q.id] == null ||
            old == null ||
            Quote.fromJson(jsonDecode(old)).signature != signature,
        'market_at': q.marketAt?.toUtc().toIso8601String(),
        'time': q.fetchedAt.toUtc().toIso8601String()
      };
    })
  ];
}

final _publicPostPattern = RegExp(r'^([^:]+:[A-Za-z0-9_]+/\d+)(?::|$)');
String? _publicPostPrefix(String id) => _publicPostPattern.firstMatch(id)?[1];

List<Map<String, Object?>> _historyDates(List<Map<String, Object?>> rows) => [
      for (final row in rows)
        {
          'seq': row['seq'],
          'signature':
              Quote.fromJson(jsonDecode(row['payload'] as String)).signature,
          'date': Quote.fromJson(jsonDecode(row['payload'] as String))
              .marketAt
              ?.toUtc()
              .toIso8601String()
        }
    ];
RangeReport _rangesInBackground(Map<String, Object> input) => calculateRanges(
    (input['payloads'] as List<String>)
        .map((s) => Quote.fromJson(jsonDecode(s))),
    input['now'] as DateTime);
