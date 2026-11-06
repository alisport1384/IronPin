import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';
import '../domain/market.dart';
import 'app_logger.dart';
import 'sources.dart';
import 'store.dart';

const backupMaxBytes = 512 * 1024 * 1024;
const _tables = ['latest', 'history', 'settings', 'sync'];
const _channel = MethodChannel('ir.ironpin/storage');

class BackupResult {
  final int latest, history, settings, sync, skipped;
  const BackupResult(
      this.latest, this.history, this.settings, this.sync, this.skipped);
}

/// A streaming, versioned JSON-lines backup. A final count + FNV-1a checksum
/// detects truncation/accidental damage, NOT authenticity or a digital signature.
class MarketBackup {
  final MarketStore store;
  MarketBackup(this.store);

  Future<String?> exportToPicker() async {
    final dir = await _channel.invokeMethod<String>('backupDirectory');
    if (dir == null) {
      throw const FileSystemException('Backup directory unavailable');
    }
    final file =
        File('$dir/export-${DateTime.now().microsecondsSinceEpoch}.jsonl');
    try {
      await write(file);
      return await _channel.invokeMethod<String>('exportBackup', {
        'path': file.path,
        'name':
            'IronPin-${DateTime.now().toUtc().toIso8601String().replaceAll(':', '-')}.ironpin.jsonl'
      });
    } finally {
      if (await file.exists()) await file.delete();
    }
  }

  Future<BackupResult?> importFromPicker({bool restoreSettings = false}) async {
    final filePath = await _channel.invokeMethod<String>('importBackup');
    if (filePath == null) return null;
    final file = File(filePath);
    try {
      return await merge(file, restoreSettings: restoreSettings);
    } finally {
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> write(File file) async {
    var checksum = 2166136261, bytes = 0;
    final counts = {for (final t in _tables) t: 0};
    final sink = file.openWrite(encoding: utf8);
    Future<void> emit(List<Map<String, Object?>> records) async {
      final encoded =
          await compute(_encodeChunk, {'rows': records, 'checksum': checksum});
      checksum = encoded['checksum'] as int;
      bytes += encoded['bytes'] as int;
      if (bytes > backupMaxBytes) {
        throw const FormatException('بکاپ از سقف ۵۱۲ مگابایت بزرگ‌تر است.');
      }
      sink.write(encoded['text']);
      await sink.flush();
    }

    try {
      await emit([
        {
          'format': 'IronPin-backup',
          'version': 1,
          'schema': 3,
          'createdAt': DateTime.now().toUtc().toIso8601String()
        }
      ]);
      await store.db.transaction((tx) async {
        for (final table in _tables) {
          final key = table == 'history'
              ? 'seq'
              : table == 'settings'
                  ? 'key'
                  : table == 'sync'
                      ? 'endpoint'
                      : 'id';
          Object? after;
          while (true) {
            final rows = await tx.query(table,
                where: after == null ? null : '$key>?',
                whereArgs: after == null ? null : [after],
                orderBy: key,
                limit: 200);
            if (rows.isEmpty) break;
            await emit([
              for (final row in rows) {'table': table, 'row': row}
            ]);
            counts[table] = counts[table]! + rows.length;
            if (counts.values.fold<int>(0, (a, b) => a + b) > 1000000) {
              throw const FormatException(
                  'تعداد رکوردهای بکاپ بیش از حد مجاز است.');
            }
            after = rows.last[key];
          }
        }
      });
      sink.writeln(jsonEncode({
        'end': true,
        'counts': counts,
        'algorithm': 'fnv1a32',
        'checksum': checksum.toRadixString(16).padLeft(8, '0')
      }));
      await sink.flush();
      await AppLogger.instance
          .record('backup', 'export_prepared', {'rows': counts});
    } finally {
      await sink.close();
    }
  }

  Future<BackupResult> merge(File file, {bool restoreSettings = false}) async {
    if (await file.length() > backupMaxBytes) {
      throw const FormatException('بکاپ از سقف ۵۱۲ مگابایت بزرگ‌تر است.');
    }
    final result = await store.db.transaction((tx) async {
      final existing = <String, Map<String, Object?>>{};
      // Lightweight date/identity summaries; heavy JSON parsing is off-thread.
      String? after;
      while (true) {
        final rows = await tx.query('latest',
            where: after == null ? null : 'id>?',
            whereArgs: after == null ? null : [after],
            orderBy: 'id',
            limit: 200);
        if (rows.isEmpty) break;
        existing.addAll(await compute(_latestSummaries, rows));
        after = rows.last['id'] as String;
      }
      final settings = {
        for (final r in await tx.query('settings'))
          r['key'] as String: r['value'] as String
      };
      final sync = {
        for (final r in await tx.query('sync')) r['endpoint'] as String: r
      };
      final before = Sqflite.firstIntValue(
          await tx.rawQuery('SELECT COUNT(*) FROM history'))!;
      final seen = {for (final t in _tables) t: 0};
      var checksum = 2166136261, header = false, ended = false;
      var addedLatest = 0, addedSettings = 0, addedSync = 0, skipped = 0;
      Future<void> apply(List<String> lines) async {
        final parsed =
            await compute(_parseChunk, {'lines': lines, 'checksum': checksum});
        final oldChecksum = checksum;
        checksum = parsed['checksum'] as int;
        var runningChecksum = oldChecksum;
        final batch = tx.batch();
        final records = parsed['records'] as List<Map<String, dynamic>>;
        for (var i = 0; i < records.length; i++) {
          final record = records[i];
          if (ended) {
            throw const FormatException('رکورد پس از پایان بکاپ مجاز نیست.');
          }
          if (record['end'] == true) {
            if (!header ||
                record['algorithm'] != 'fnv1a32' ||
                record['checksum'] !=
                    runningChecksum.toRadixString(16).padLeft(8, '0') ||
                !mapEquals(
                    Map<String, dynamic>.from(record['counts'] as Map), seen)) {
              throw const FormatException(
                  'جمع کنترلی یا شمارش رکوردهای بکاپ معتبر نیست.');
            }
            ended = true;
            continue;
          }
          // Worker supplies the checksum at each boundary, without main-thread UTF-8 work.
          runningChecksum = (parsed['checksums'] as List<int>)[i];
          if (!header) {
            if (record['format'] != 'IronPin-backup' ||
                record['version'] != 1 ||
                record['schema'] != 3) {
              throw const FormatException(
                  'قالب یا نسخه بکاپ پشتیبانی نمی‌شود.');
            }
            header = true;
            continue;
          }
          final table = record['table'] as String;
          final row = Map<String, Object?>.from(record['row'] as Map);
          seen[table] = seen[table]! + 1;
          if (seen.values.fold<int>(0, (a, b) => a + b) > 1000000) {
            throw const FormatException(
                'تعداد رکوردهای بکاپ بیش از حد مجاز است.');
          }
          switch (table) {
            case 'history':
              row.remove('seq');
              batch.rawInsert(
                  'INSERT INTO history(id,captured_at,signature,payload,market_at) '
                  'SELECT ?,?,?,?,? WHERE NOT EXISTS '
                  '(SELECT 1 FROM history WHERE id=? AND captured_at=? AND signature=?)',
                  [
                    row['id'],
                    row['captured_at'],
                    row['signature'],
                    row['payload'],
                    row['market_at'],
                    row['id'],
                    row['captured_at'],
                    row['signature']
                  ]);
            case 'latest':
              final id = row['id'] as String;
              final summary =
                  Map<String, Object?>.from(record['summary'] as Map);
              final old = existing[id];
              if (old == null) {
                batch.insert('latest', row);
                existing[id] = summary;
                addedLatest++;
              } else if (old['endpoint'] == summary['endpoint'] &&
                  _newer(summary, old)) {
                row['active'] =
                    (old['active'] == 1 || row['active'] == 1) ? 1 : 0;
                batch.update('latest', row, where: 'id=?', whereArgs: [id]);
                existing[id] = {...summary, 'active': row['active']};
                addedLatest++;
              } else {
                skipped++;
              }
            case 'settings':
              final key = row['key'] as String;
              if (!settings.containsKey(key)) {
                batch.insert('settings', row);
                settings[key] = row['value'] as String;
                addedSettings++;
              } else if (key == 'discoveredSources') {
                final current =
                    (jsonDecode(settings[key]!) as List).cast<Map>();
                final urls = current.map((e) => e['url']).toSet();
                final incoming =
                    (jsonDecode(row['value'] as String) as List).cast<Map>();
                final joined = [
                  ...current,
                  ...incoming.where((e) => urls.add(e['url']))
                ];
                if (joined.length > 60) {
                  throw const FormatException(
                      'ظرفیت منابع افزوده‌شده بیش از ۶۰ کانال است.');
                }
                if (joined.length > current.length) {
                  settings[key] = jsonEncode(joined);
                  batch.update('settings', {'value': settings[key]},
                      where: 'key=?', whereArgs: [key]);
                  addedSettings++;
                } else {
                  skipped++;
                }
              } else if (restoreSettings &&
                  !{
                    'autoRefresh',
                    'lastRefresh',
                    'retentionMonth',
                    'sourcesVersion',
                    'analysisSourcesVersion',
                    'sheetSourcesVersion',
                    'allRegisteredSourcesEnabledVersion'
                  }.contains(key) &&
                  settings[key] != row['value']) {
                batch.update('settings', {'value': row['value']},
                    where: 'key=?', whereArgs: [key]);
                settings[key] = row['value'] as String;
                addedSettings++;
              } else {
                skipped++;
              }
            case 'sync':
              final id = row['endpoint'] as String;
              if (!sync.containsKey(id)) {
                batch.insert('sync', row);
                sync[id] = row;
                addedSync++;
              } else {
                skipped++;
              }
          }
        }
        await batch.commit(noResult: true);
      }

      var lines = <String>[];
      var bufferedChars = 0;
      await for (final line in _boundedLines(file)) {
        if (line.length > 2 * 1024 * 1024) {
          throw const FormatException('یک رکورد بکاپ بیش از حد بزرگ است.');
        }
        if (line.isEmpty) {
          throw const FormatException('رکورد خالی در بکاپ وجود دارد.');
        }
        lines.add(line);
        bufferedChars += line.length;
        if (lines.length >= 100 || bufferedChars >= 512 * 1024) {
          await apply(lines);
          lines = [];
          bufferedChars = 0;
        }
      }
      if (lines.isNotEmpty) await apply(lines);
      if (!header || !ended) {
        throw const FormatException(
            'فایل بکاپ ناقص است. هیچ داده‌ای بازیابی نشد.');
      }
      final afterCount = Sqflite.firstIntValue(
          await tx.rawQuery('SELECT COUNT(*) FROM history'))!;
      final addedHistory = afterCount - before;
      skipped += seen['history']! - addedHistory;
      // Even an older backup cannot re-enable network auto-refresh.
      await tx.insert('settings', {'key': 'autoRefresh', 'value': 'false'},
          conflictAlgorithm: ConflictAlgorithm.replace);
      return BackupResult(
          addedLatest, addedHistory, addedSettings, addedSync, skipped);
    });
    await AppLogger.instance.record('backup', 'import_merged', {
      'latest': result.latest,
      'history': result.history,
      'settings': result.settings,
      'sync': result.sync,
      'skipped': result.skipped
    });
    return result;
  }
}

bool _newer(Map<String, Object?> a, Map<String, Object?> b) {
  final dateA = a['market'] as String?, dateB = b['market'] as String?;
  if (dateA != dateB) {
    if (dateA == null) return false;
    if (dateB == null) return true;
    return dateA.compareTo(dateB) > 0;
  }
  return (a['fetched'] as String).compareTo(b['fetched'] as String) > 0;
}

Map<String, Object?> _summary(Quote q, Object? active) => {
      'endpoint': q.endpoint,
      'active': active,
      'market': q.marketAt?.toUtc().toIso8601String(),
      'fetched': q.fetchedAt.toUtc().toIso8601String()
    };
Map<String, Map<String, Object?>> _latestSummaries(
        List<Map<String, Object?>> rows) =>
    {
      for (final r in rows)
        r['id'] as String: _summary(
            Quote.fromJson(jsonDecode(r['payload'] as String)), r['active'])
    };
int _checksum(int state, String line) {
  for (final b in utf8.encode('$line\n')) {
    state = ((state ^ b) * 16777619) & 0xffffffff;
  }
  return state;
}

Map<String, Object> _encodeChunk(Map<String, Object> input) {
  var checksum = input['checksum'] as int;
  final text = StringBuffer();
  for (final r in input['rows'] as List<Map<String, Object?>>) {
    if (r.containsKey('table')) _validateRecord(Map<String, dynamic>.from(r));
    final line = jsonEncode(r);
    if (utf8.encode(line).length > 2 * 1024 * 1024) {
      throw const FormatException('یک رکورد بکاپ بیش از حد بزرگ است.');
    }
    checksum = _checksum(checksum, line);
    text.writeln(line);
  }
  final value = text.toString();
  return {
    'text': value,
    'checksum': checksum,
    'bytes': utf8.encode(value).length
  };
}

Map<String, Object> _parseChunk(Map<String, Object> input) {
  var checksum = input['checksum'] as int;
  final records = <Map<String, dynamic>>[], checksums = <int>[];
  for (final line in input['lines'] as List<String>) {
    final r = Map<String, dynamic>.from(jsonDecode(line) as Map);
    if (r['end'] != true) checksum = _checksum(checksum, line);
    checksums.add(checksum);
    if (r.containsKey('table')) _validateRecord(r);
    records.add(r);
  }
  return {'records': records, 'checksum': checksum, 'checksums': checksums};
}

void _validateRecord(Map<String, dynamic> record) {
  final table = record['table'];
  if (!_tables.contains(table)) {
    throw const FormatException('جدول ناشناخته در بکاپ.');
  }
  final row = Map<String, dynamic>.from(record['row'] as Map);
  void text(String k, {int max = 4096, bool nullable = false}) {
    final value = row[k];
    if (nullable && value == null) return;
    if (value is! String || value.length > max || value.contains('\u0000')) {
      throw FormatException('فیلد $k معتبر نیست.');
    }
  }

  void date(String k, {bool nullable = false}) {
    text(k, max: 50, nullable: nullable);
    if (nullable && row[k] == null) return;
    if (DateTime.tryParse(row[k] as String) == null) {
      throw const FormatException('تاریخ ثبت معتبر نیست.');
    }
    row[k] = DateTime.parse(row[k] as String).toUtc().toIso8601String();
  }

  switch (table) {
    case 'latest':
    case 'history':
      text('id', max: 512);
      text('payload', max: 1024 * 1024);
      if (utf8.encode(row['payload'] as String).length > 1024 * 1024) {
        throw const FormatException('payload کالای بکاپ بیش از حد بزرگ است.');
      }
      final json = Map<String, dynamic>.from(jsonDecode(row['payload']) as Map);
      // Missing currency must never become Quote's legacy default of toman.
      for (final k in [
        'id',
        'endpoint',
        'seller',
        'title',
        'category',
        'unit',
        'currency',
        'sourceUrl',
        'fetchedAt'
      ]) {
        if (json[k] is! String || (json[k] as String).length > 4096) {
          throw FormatException('فیلد کالا $k ناقص است.');
        }
      }
      if (json['details'] is! Map ||
          !(json['details'] as Map)
              .entries
              .every((e) => e.key is String && e.value is String)) {
        throw const FormatException('جزئیات کالا معتبر نیست.');
      }
      for (final k in ['amount', 'pieceKg', 'lengthM', 'areaM2']) {
        final v = json[k];
        if (v != null && (v is! num || !v.isFinite || v <= 0)) {
          throw const FormatException('عدد کالای بکاپ معتبر نیست.');
        }
      }
      final q = Quote.fromJson(json);
      final uri = Uri.tryParse(q.sourceUrl);
      if (q.sourceUrl.isNotEmpty &&
          (uri == null ||
              !['https', 'http'].contains(uri.scheme) ||
              uri.host.isEmpty ||
              uri.userInfo.isNotEmpty)) {
        throw const FormatException('پیوند منبع معتبر نیست.');
      }
      if (q.id != row['id']) {
        throw const FormatException('شناسه کالا ناسازگار است.');
      }
      if (table == 'latest') {
        text('endpoint', max: 512);
        if (row['endpoint'] != q.endpoint || ![0, 1].contains(row['active'])) {
          throw const FormatException('وضعیت کالای جاری ناسازگار است.');
        }
        record['summary'] = _summary(q, row['active']);
        record['row'] = {
          for (final k in ['id', 'endpoint', 'payload', 'active']) k: row[k]
        };
      } else {
        date('captured_at');
        if (row['captured_at'] != q.fetchedAt.toUtc().toIso8601String()) {
          throw const FormatException('زمان ثبت کالا ناسازگار است.');
        }
        record['row'] = {
          'id': q.id,
          'captured_at': row['captured_at'],
          'signature': q.signature,
          'payload': row['payload'],
          'market_at': q.marketAt?.toUtc().toIso8601String()
        };
      }
    case 'settings':
      text('key', max: 200);
      text('value', max: 200000);
      final key = row['key'], value = row['value'] as String;
      if (key == 'enabled') {
        final list = jsonDecode(value);
        if (list is! List ||
            list.length > 200 ||
            !list.every((e) => e is String && e.length <= 512)) {
          throw const FormatException('تنظیم منابع فعال معتبر نیست.');
        }
      }
      if (key == 'discoveredSources') {
        final list = jsonDecode(value);
        if (list is! List ||
            list.length > 60 ||
            !list.every((e) =>
                e is Map &&
                e['url'] is String &&
                (e['name'] == null || e['name'] is String) &&
                publicChannel(e['url'], name: e['name']) != null)) {
          throw const FormatException('تنظیم کانال‌های افزوده‌شده معتبر نیست.');
        }
      }
      if (key == 'autoRefresh' && !['true', 'false'].contains(value)) {
        throw const FormatException('تنظیم نوسازی معتبر نیست.');
      }
      record['row'] = {'key': key, 'value': value};
    case 'sync':
      text('endpoint', max: 512);
      date('attempted_at');
      date('success_at', nullable: true);
      text('message', max: 50000);
      record['row'] = {
        for (final k in ['endpoint', 'attempted_at', 'success_at', 'message'])
          k: row[k]
      };
  }
}

// Bound raw lines before decoding, including corrupt files without newlines.
Stream<String> _boundedLines(File file) async* {
  var builder = BytesBuilder(copy: false);
  var total = 0;
  await for (final raw in file.openRead()) {
    final chunk = raw is Uint8List ? raw : Uint8List.fromList(raw);
    total += chunk.length;
    if (total > backupMaxBytes) {
      throw const FormatException('فایل بکاپ بیش از حد بزرگ است.');
    }
    var start = 0;
    for (var i = 0; i < chunk.length; i++) {
      if (chunk[i] != 10) continue;
      if (builder.length + i - start > 2 * 1024 * 1024) {
        throw const FormatException('رکورد بکاپ بیش از حد بزرگ است.');
      }
      builder.add(Uint8List.sublistView(chunk, start, i));
      yield utf8.decode(builder.takeBytes());
      builder = BytesBuilder(copy: false);
      start = i + 1;
    }
    if (builder.length + chunk.length - start > 2 * 1024 * 1024) {
      throw const FormatException('رکورد بکاپ بیش از حد بزرگ است.');
    }
    if (start < chunk.length) builder.add(Uint8List.sublistView(chunk, start));
  }
  if (builder.isNotEmpty) yield utf8.decode(builder.takeBytes());
}
