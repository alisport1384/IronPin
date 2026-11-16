import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../domain/market.dart';

/// Compact, string-interned binary snapshot cache for large local archives.
///
/// Why this exists alongside SQLite:
/// - SQLite remains the single source of truth for durability, queries,
///   backups, and retention.
/// - On 100k–200k+ row archives, reading 100k JSON payloads via `sqflite` +
///   `jsonDecode` (`store.latest()`) or transferring 200k x 36-column Maps across
///   Android's MethodChannel (`store.rangeIndexRows()`) takes seconds and
///   allocates millions of duplicate `String` copies (`'فولاد کربنی'`, `'تومان'`,
///   `'kg'`, city names, etc.).
/// - This cache writes a compact binary file with a deduplicated UTF-8 string
///   pool next to the `.db` file (never used for `:memory:` DBs), validated
///   against an O(1) SQLite archive token (`cache_state.rev` + row counts +
///   max rowids + `RowFacts.derive`). Any insert, update, delete, retention
///   prune, or derivation upgrade invalidates the token immediately.
class FastArchiveCache {
  static const int _magicLatest = 0x49504E4C; // IPNL
  static const int _magicRange = 0x49504E52; // IPNR
  static const int _formatVersion = 1;
  static const int minRowsToCache = 200;

  static bool isDiskPath(String dbPath) =>
      dbPath.isNotEmpty &&
      dbPath != ':memory:' &&
      !dbPath.startsWith('file::memory:');

  static String latestPathFor(String dbPath) => '$dbPath.latest.bin';
  static String rangePathFor(String dbPath) => '$dbPath.range.bin';

  /// Reads cached `latest()` quotes if the file exists and its archive token
  /// matches [expectedToken]. Returns `null` on miss or corruption.
  static Future<List<Quote>?> readLatest(
      String dbPath, String expectedToken) async {
    if (!isDiskPath(dbPath)) return null;
    final file = File(latestPathFor(dbPath));
    if (!await file.exists()) return null;
    try {
      final bytes = await file.readAsBytes();
      if (bytes.lengthInBytes < 16) return null;
      if (!_headerMatches(bytes, _magicLatest, expectedToken)) return null;
      return compute(_decodeLatestBytes, bytes);
    } catch (_) {
      return null;
    }
  }

  /// Writes the `latest()` binary cache atomically via `.tmp` + rename.
  static Future<void> writeLatest(
      String dbPath, String token, List<Quote> quotes) async {
    if (!isDiskPath(dbPath) || quotes.length < minRowsToCache) return;
    final target = latestPathFor(dbPath);
    final tmp = '$target.tmp';
    try {
      final bytes = await compute(
          _encodeLatestBytes, {'token': token, 'quotes': quotes});
      final f = File(tmp);
      await f.writeAsBytes(bytes, flush: false);
      await f.rename(target);
    } catch (_) {
      try {
        final f = File(tmp);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  /// Reads cached `rangeIndexRows` if the file exists, [expectedToken] and
  /// [windowDays] match, and the time window is covered without missing rows.
  ///
  /// When [newNowIso] > `cachedNowIso`, the caller must verify via SQLite that
  /// no `history` row has `market_at` inside `(cachedNowIso, newNowIso]`.
  static Future<
          ({
            String cachedNowIso,
            List<Map<String, Object?>> rows,
          })?>
      readRangeHeaderAndDecode(
    String dbPath, {
    required String expectedToken,
    required int windowDays,
    required String newSinceIso,
    required String newNowIso,
    required Future<bool> Function(String cachedNowIso, String newNowIso)
        hasFutureHistoryBetween,
  }) async {
    if (!isDiskPath(dbPath)) return null;
    final file = File(rangePathFor(dbPath));
    if (!await file.exists()) return null;
    try {
      final bytes = await file.readAsBytes();
      if (bytes.lengthInBytes < 32) return null;
      final meta = _readRangeHeader(bytes, expectedToken, windowDays);
      if (meta == null) return null;
      if (newSinceIso.compareTo(meta.cachedSinceIso) < 0) return null;
      if (newNowIso.compareTo(meta.cachedNowIso) > 0) {
        final changed =
            await hasFutureHistoryBetween(meta.cachedNowIso, newNowIso);
        if (changed) return null;
      }
      final rows = await compute(_decodeRangeBytes, {
        'bytes': bytes,
        'sinceUs': DateTime.parse(newSinceIso).toUtc().microsecondsSinceEpoch,
        'nowUs': DateTime.parse(newNowIso).toUtc().microsecondsSinceEpoch,
      });
      return (cachedNowIso: meta.cachedNowIso, rows: rows);
    } catch (_) {
      return null;
    }
  }

  /// Writes the `rangeIndexRows` binary cache atomically via `.tmp` + rename.
  static Future<void> writeRange(
    String dbPath, {
    required String token,
    required int windowDays,
    required String sinceIso,
    required String nowIso,
    required List<({Map<String, Object?> row, bool isHistory, int marketAtMs})>
        items,
  }) async {
    if (!isDiskPath(dbPath) || items.length < minRowsToCache) return;
    final target = rangePathFor(dbPath);
    final tmp = '$target.tmp';
    try {
      final uniqueRows = <Map<String, Object?>>[];
      final rowIds = Map<Map<String, Object?>, int>.identity();
      final byPayload = <String, int>{};
      final n = items.length;
      final refIndices = Int32List(n);
      final isHistFlags = Uint8List(n);
      final histAtList = Int64List(n);
      for (var i = 0; i < n; i++) {
        final item = items[i];
        var idx = rowIds[item.row];
        if (idx == null) {
          final payload = item.row['payload'] as String? ?? '';
          idx = byPayload[payload];
          if (idx == null) {
            idx = uniqueRows.length;
            uniqueRows.add(item.row);
            if (payload.isNotEmpty) byPayload[payload] = idx;
          }
          rowIds[item.row] = idx;
        }
        refIndices[i] = idx;
        if (item.isHistory) {
          isHistFlags[i] = 1;
          histAtList[i] = item.marketAtMs;
        }
      }
      final bytes = await compute(_encodeRangeBytes, {
        'token': token,
        'windowDays': windowDays,
        'sinceIso': sinceIso,
        'nowIso': nowIso,
        'uniqueRows': uniqueRows,
        'refIndices': refIndices,
        'isHistFlags': isHistFlags,
        'histAtList': histAtList,
      });
      final f = File(tmp);
      await f.writeAsBytes(bytes, flush: false);
      await f.rename(target);
    } catch (_) {
      try {
        final f = File(tmp);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  static bool _headerMatches(
      Uint8List bytes, int expectedMagic, String expectedToken) {
    final bd = ByteData.sublistView(bytes);
    if (bd.getUint32(0, Endian.little) != expectedMagic) return false;
    if (bd.getUint32(4, Endian.little) != _formatVersion) return false;
    final tokenLen = bd.getUint32(8, Endian.little);
    if (12 + tokenLen > bytes.lengthInBytes) return false;
    final token =
        utf8.decode(bytes.sublist(12, 12 + tokenLen), allowMalformed: true);
    return token == expectedToken;
  }

  static ({String cachedSinceIso, String cachedNowIso})? _readRangeHeader(
      Uint8List bytes, String expectedToken, int expectedWindowDays) {
    final bd = ByteData.sublistView(bytes);
    if (bd.getUint32(0, Endian.little) != _magicRange) return null;
    if (bd.getUint32(4, Endian.little) != _formatVersion) return null;
    var off = 8;
    String? readStr() {
      if (off + 4 > bytes.lengthInBytes) return null;
      final len = bd.getUint32(off, Endian.little);
      off += 4;
      if (off + len > bytes.lengthInBytes) return null;
      final s = utf8.decode(Uint8List.sublistView(bytes, off, off + len),
          allowMalformed: true);
      off += len;
      return s;
    }

    final token = readStr();
    if (token == null || token != expectedToken) return null;
    if (off + 4 > bytes.lengthInBytes) return null;
    final windowDays = bd.getInt32(off, Endian.little);
    off += 4;
    if (windowDays != expectedWindowDays) return null;
    final sinceIso = readStr();
    final nowIso = readStr();
    if (sinceIso == null || nowIso == null) return null;
    return (cachedSinceIso: sinceIso, cachedNowIso: nowIso);
  }
}

class _ByteWriter {
  Uint8List _buf;
  int _len = 0;

  _ByteWriter([int initialCapacity = 65536])
      : _buf = Uint8List(initialCapacity);

  void _ensure(int extra) {
    final needed = _len + extra;
    if (needed <= _buf.length) return;
    var cap = _buf.length * 2;
    while (cap < needed) {
      cap *= 2;
    }
    final next = Uint8List(cap);
    next.setRange(0, _len, _buf);
    _buf = next;
  }

  void writeUint32(int v) {
    _ensure(4);
    final bd = ByteData.sublistView(_buf, _len, _len + 4);
    bd.setUint32(0, v, Endian.little);
    _len += 4;
  }

  void writeInt32(int v) {
    _ensure(4);
    final bd = ByteData.sublistView(_buf, _len, _len + 4);
    bd.setInt32(0, v, Endian.little);
    _len += 4;
  }

  void writeInt64(int v) {
    _ensure(8);
    final bd = ByteData.sublistView(_buf, _len, _len + 8);
    bd.setInt64(0, v, Endian.little);
    _len += 8;
  }

  void writeFloat64(double v) {
    _ensure(8);
    final bd = ByteData.sublistView(_buf, _len, _len + 8);
    bd.setFloat64(0, v, Endian.little);
    _len += 8;
  }

  void writeByte(int v) {
    _ensure(1);
    _buf[_len++] = v;
  }

  void writeVarUint(int v) {
    _ensure(5);
    var x = v;
    while (x >= 0x80) {
      _buf[_len++] = (x & 0x7F) | 0x80;
      x >>= 7;
    }
    _buf[_len++] = x;
  }

  void writeUtf8WithLen(String s) {
    final bytes = utf8.encode(s);
    writeUint32(bytes.length);
    _ensure(bytes.length);
    _buf.setRange(_len, _len + bytes.length, bytes);
    _len += bytes.length;
  }

  void writeBytes(Uint8List data, int length) {
    _ensure(length);
    _buf.setRange(_len, _len + length, data);
    _len += length;
  }

  Uint8List takeBytes() => Uint8List.sublistView(_buf, 0, _len);
}

class _ByteReader {
  final Uint8List _buf;
  final ByteData _bd;
  int position = 0;

  _ByteReader(this._buf) : _bd = ByteData.sublistView(_buf);

  int readUint32() {
    final v = _bd.getUint32(position, Endian.little);
    position += 4;
    return v;
  }

  int readInt32() {
    final v = _bd.getInt32(position, Endian.little);
    position += 4;
    return v;
  }

  int readInt64() {
    final v = _bd.getInt64(position, Endian.little);
    position += 8;
    return v;
  }

  double readFloat64() {
    final v = _bd.getFloat64(position, Endian.little);
    position += 8;
    return v;
  }

  int readByte() => _buf[position++];

  int readVarUint() {
    var result = 0;
    var shift = 0;
    while (true) {
      final b = _buf[position++];
      result |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) return result;
      shift += 7;
    }
  }

  String readUtf8WithLen() {
    final len = readUint32();
    final s = utf8.decode(Uint8List.sublistView(_buf, position, position + len));
    position += len;
    return s;
  }

  void skipUtf8WithLen() {
    final len = readUint32();
    position += len;
  }
}

class _StringPoolWriter {
  final Map<String, int> _ids = {};
  final _ByteWriter _poolBytes = _ByteWriter(65536);
  int _count = 0;

  /// Encodes: 0 = null, 1 = "", >=2 = pool index + 2.
  int internNullable(String? s) {
    if (s == null) return 0;
    if (s.isEmpty) return 1;
    final existing = _ids[s];
    if (existing != null) return existing;
    final id = _count + 2;
    _count++;
    _ids[s] = id;
    final bytes = utf8.encode(s);
    _poolBytes.writeVarUint(bytes.length);
    _poolBytes.writeBytes(Uint8List.fromList(bytes), bytes.length);
    return id;
  }

  int intern(String s) => internNullable(s);

  int get count => _count;
  Uint8List get encodedPool => _poolBytes.takeBytes();
}

List<String> _readStringPool(_ByteReader r) {
  final count = r.readUint32();
  final pool = List<String>.filled(count, '', growable: false);
  final buf = r._buf;
  for (var i = 0; i < count; i++) {
    final len = r.readVarUint();
    final start = r.position;
    r.position = start + len;
    pool[i] = utf8.decode(Uint8List.sublistView(buf, start, start + len));
  }
  return pool;
}

@pragma('vm:prefer-inline')
String? _poolNullable(List<String> pool, int code) =>
    code == 0 ? null : (code == 1 ? '' : pool[code - 2]);

@pragma('vm:prefer-inline')
String _poolStr(List<String> pool, int code) => code <= 1 ? '' : pool[code - 2];

Uint8List _encodeLatestBytes(Map<String, Object?> arg) {
  final token = arg['token'] as String;
  final quotes = arg['quotes'] as List<Quote>;
  final pool = _StringPoolWriter();
  final body = _ByteWriter(quotes.length * 48);

  void writeDouble(double? v) {
    if (v == null) {
      body.writeByte(0);
    } else {
      body.writeByte(1);
      body.writeFloat64(v);
    }
  }

  body.writeUint32(quotes.length);
  for (final q in quotes) {
    body.writeVarUint(pool.intern(q.id));
    body.writeVarUint(pool.intern(q.endpoint));
    body.writeVarUint(pool.intern(q.seller));
    body.writeVarUint(pool.intern(q.sellerCity));
    body.writeVarUint(pool.intern(q.title));
    body.writeVarUint(pool.intern(q.category));
    body.writeVarUint(pool.intern(q.material));
    body.writeVarUint(pool.intern(q.brand));
    body.writeVarUint(pool.intern(q.loading));
    body.writeVarUint(pool.intern(q.loadingCity));
    body.writeVarUint(pool.intern(q.unit));
    body.writeVarUint(pool.intern(q.tax));
    body.writeVarUint(pool.intern(q.currency));
    body.writeVarUint(pool.intern(q.terms));
    body.writeVarUint(pool.intern(q.sourceUrl));
    body.writeVarUint(pool.intern(q.sourceDateRaw));
    body.writeVarUint(pool.intern(q.status));
    body.writeVarUint(pool.internNullable(q.size));
    body.writeVarUint(pool.internNullable(q.thickness));
    body.writeVarUint(pool.internNullable(q.dimensions));
    body.writeVarUint(pool.internNullable(q.grade));
    writeDouble(q.amount);
    writeDouble(q.pieceKg);
    writeDouble(q.lengthM);
    writeDouble(q.areaM2);
    body.writeInt64(q.fetchedAt.toUtc().microsecondsSinceEpoch);
    final d = q.details;
    body.writeVarUint(d.length);
    if (d.isNotEmpty) {
      for (final e in d.entries) {
        body.writeVarUint(pool.intern(e.key));
        body.writeVarUint(pool.intern(e.value));
      }
    }
  }

  final poolBytes = pool.encodedPool;
  final bodyBytes = body.takeBytes();
  final out = _ByteWriter(64 + poolBytes.length + bodyBytes.length);
  out.writeUint32(FastArchiveCache._magicLatest);
  out.writeUint32(FastArchiveCache._formatVersion);
  out.writeUtf8WithLen(token);
  out.writeUint32(pool.count);
  out.writeBytes(poolBytes, poolBytes.length);
  out.writeBytes(bodyBytes, bodyBytes.length);
  return out.takeBytes();
}

List<Quote> _decodeLatestBytes(Uint8List bytes) {
  final r = _ByteReader(bytes);
  r.readUint32(); // magic
  r.readUint32(); // version
  r.skipUtf8WithLen(); // token
  final pool = _readStringPool(r);
  final count = r.readUint32();

  double? readDouble() => r.readByte() == 0 ? null : r.readFloat64();

  return List<Quote>.generate(count, (_) {
    final id = _poolStr(pool, r.readVarUint());
    final endpoint = _poolStr(pool, r.readVarUint());
    final seller = _poolStr(pool, r.readVarUint());
    final sellerCity = _poolStr(pool, r.readVarUint());
    final title = _poolStr(pool, r.readVarUint());
    final category = _poolStr(pool, r.readVarUint());
    final material = _poolStr(pool, r.readVarUint());
    final brand = _poolStr(pool, r.readVarUint());
    final loading = _poolStr(pool, r.readVarUint());
    final loadingCity = _poolStr(pool, r.readVarUint());
    final unit = _poolStr(pool, r.readVarUint());
    final tax = _poolStr(pool, r.readVarUint());
    final currency = _poolStr(pool, r.readVarUint());
    final terms = _poolStr(pool, r.readVarUint());
    final sourceUrl = _poolStr(pool, r.readVarUint());
    final sourceDateRaw = _poolStr(pool, r.readVarUint());
    final status = _poolStr(pool, r.readVarUint());
    final size = _poolNullable(pool, r.readVarUint());
    final thickness = _poolNullable(pool, r.readVarUint());
    final dimensions = _poolNullable(pool, r.readVarUint());
    final grade = _poolNullable(pool, r.readVarUint());
    final amount = readDouble();
    final pieceKg = readDouble();
    final lengthM = readDouble();
    final areaM2 = readDouble();
    final fetchedAt =
        DateTime.fromMicrosecondsSinceEpoch(r.readInt64(), isUtc: true);
    final detailCount = r.readVarUint();
    final details = detailCount == 0
        ? const <String, String>{}
        : <String, String>{
            for (var i = 0; i < detailCount; i++)
              _poolStr(pool, r.readVarUint()): _poolStr(pool, r.readVarUint())
          };
    return Quote(
      id: id,
      endpoint: endpoint,
      seller: seller,
      sellerCity: sellerCity,
      title: title,
      category: category,
      material: material,
      brand: brand,
      loading: loading,
      loadingCity: loadingCity,
      unit: unit,
      tax: tax,
      currency: currency,
      terms: terms,
      sourceUrl: sourceUrl,
      sourceDateRaw: sourceDateRaw,
      status: status,
      size: size,
      thickness: thickness,
      dimensions: dimensions,
      grade: grade,
      amount: amount,
      pieceKg: pieceKg,
      lengthM: lengthM,
      areaM2: areaM2,
      fetchedAt: fetchedAt,
      details: details,
    );
  }, growable: false);
}

Uint8List _encodeRangeBytes(Map<String, Object?> arg) {
  final token = arg['token'] as String;
  final windowDays = arg['windowDays'] as int;
  final sinceIso = arg['sinceIso'] as String;
  final nowIso = arg['nowIso'] as String;
  final uniqueRows =
      (arg['uniqueRows'] as List).cast<Map<String, Object?>>();
  final refIndices = arg['refIndices'] as Int32List;
  final isHistFlags = arg['isHistFlags'] as Uint8List;
  final histAtList = arg['histAtList'] as Int64List;

  final pool = _StringPoolWriter();
  final refs = _ByteWriter(refIndices.length * 11);

  refs.writeUint32(refIndices.length);
  for (var i = 0; i < refIndices.length; i++) {
    refs.writeVarUint(refIndices[i]);
    final isHist = isHistFlags[i] != 0;
    refs.writeByte(isHist ? 1 : 0);
    if (isHist) {
      refs.writeInt64(histAtList[i]);
    }
  }

  final rowsWriter = _ByteWriter(uniqueRows.length * 64);
  void writeStr(Object? v) =>
      rowsWriter.writeVarUint(pool.intern(v as String? ?? ''));
  void writeNullableStr(Object? v) =>
      rowsWriter.writeVarUint(pool.internNullable(v as String?));
  void writeDouble(Object? v) {
    if (v == null) {
      rowsWriter.writeByte(0);
    } else {
      rowsWriter.writeByte(1);
      rowsWriter.writeFloat64((v as num).toDouble());
    }
  }

  void writeInt(Object? v) {
    if (v == null) {
      rowsWriter.writeByte(0);
    } else {
      rowsWriter.writeByte(1);
      rowsWriter.writeInt64(v as int);
    }
  }

  rowsWriter.writeUint32(uniqueRows.length);
  for (final r in uniqueRows) {
    writeStr(r['payload']);
    writeStr(r['derive']);
    writeStr(r['family']);
    writeStr(r['facts']);
    writeStr(r['prices']);
    writeStr(r['announce_key']);
    writeStr(r['seller_norm']);
    writeNullableStr(r['product_key']);
    writeStr(r['id']);
    writeStr(r['endpoint']);
    writeStr(r['title']);
    writeStr(r['category']);
    writeStr(r['seller']);
    writeStr(r['seller_city']);
    writeStr(r['unit']);
    writeStr(r['brand']);
    writeStr(r['material']);
    writeStr(r['tax']);
    writeStr(r['terms']);
    writeStr(r['status']);
    writeStr(r['specification']);
    writeStr(r['search']);
    writeStr(r['source_url']);
    writeStr(r['haystack']);
    writeStr(r['size_label']);
    writeStr(r['thickness_label']);
    writeDouble(r['size_num']);
    writeDouble(r['thickness_num']);
    writeStr(r['dimensions_label']);
    writeStr(r['grade_label']);
    writeStr(r['source_date_raw']);
    writeStr(r['amount_raw']);
    writeDouble(r['amount']);
    writeStr(r['currency']);
    writeInt(r['market_at']);
    rowsWriter.writeInt64((r['fetched_at'] as int?) ?? 0);
  }

  final poolBytes = pool.encodedPool;
  final rowsBytes = rowsWriter.takeBytes();
  final refsBytes = refs.takeBytes();
  final out =
      _ByteWriter(128 + poolBytes.length + rowsBytes.length + refsBytes.length);
  out.writeUint32(FastArchiveCache._magicRange);
  out.writeUint32(FastArchiveCache._formatVersion);
  out.writeUtf8WithLen(token);
  out.writeInt32(windowDays);
  out.writeUtf8WithLen(sinceIso);
  out.writeUtf8WithLen(nowIso);
  out.writeUint32(pool.count);
  out.writeBytes(poolBytes, poolBytes.length);
  out.writeBytes(rowsBytes, rowsBytes.length);
  out.writeBytes(refsBytes, refsBytes.length);
  return out.takeBytes();
}

List<Map<String, Object?>> _decodeRangeBytes(Map<String, Object?> arg) {
  final bytes = arg['bytes'] as Uint8List;
  final sinceUs = arg['sinceUs'] as int;
  final nowUs = arg['nowUs'] as int;
  final r = _ByteReader(bytes);
  r.readUint32(); // magic
  r.readUint32(); // version
  r.skipUtf8WithLen(); // token
  r.readInt32(); // windowDays
  r.skipUtf8WithLen(); // sinceIso
  r.skipUtf8WithLen(); // nowIso
  final pool = _readStringPool(r);
  final uniqueCount = r.readUint32();

  String rs() => _poolStr(pool, r.readVarUint());
  String? rns() => _poolNullable(pool, r.readVarUint());
  double? rd() => r.readByte() == 0 ? null : r.readFloat64();
  int? ri() => r.readByte() == 0 ? null : r.readInt64();

  final uniqueRows = List<Map<String, Object?>>.generate(uniqueCount, (_) {
    return <String, Object?>{
      'payload': rs(),
      'derive': rs(),
      'family': rs(),
      'facts': rs(),
      'prices': rs(),
      'announce_key': rs(),
      'seller_norm': rs(),
      'product_key': rns(),
      'id': rs(),
      'endpoint': rs(),
      'title': rs(),
      'category': rs(),
      'seller': rs(),
      'seller_city': rs(),
      'unit': rs(),
      'brand': rs(),
      'material': rs(),
      'tax': rs(),
      'terms': rs(),
      'status': rs(),
      'specification': rs(),
      'search': rs(),
      'source_url': rs(),
      'haystack': rs(),
      'size_label': rs(),
      'thickness_label': rs(),
      'size_num': rd(),
      'thickness_num': rd(),
      'dimensions_label': rs(),
      'grade_label': rs(),
      'source_date_raw': rs(),
      'amount_raw': rs(),
      'amount': rd(),
      'currency': rs(),
      'market_at': ri(),
      'fetched_at': r.readInt64(),
    };
  }, growable: false);

  final totalRefs = r.readUint32();
  final out = <Map<String, Object?>>[];
  for (var i = 0; i < totalRefs; i++) {
    final idx = r.readVarUint();
    final isHistory = r.readByte() != 0;
    if (isHistory) {
      final atUs = r.readInt64();
      if (atUs < sinceUs || atUs > nowUs) continue;
    }
    out.add(uniqueRows[idx]);
  }
  return out;
}
