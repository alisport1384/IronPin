import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Bounded product/source summaries only. Historical diagnostic logs are retired
/// on upgrade; market history and backups are not log files and remain untouched.
class AppLogger {
  static final instance = AppLogger();
  static const platform = MethodChannel('ir.ironpin/storage');
  Directory? _directory;
  Future<void> _pending = Future.value();
  String? lastError;
  bool enabled;
  Future<void> setEnabled(bool value) async {
    enabled = value;
    if (value && _directory == null) await initialize();
    if (!value) _recentProducts.clear();
    await flush();
  }

  String get directoryPath => _directory?.path ?? 'هنوز آماده نشده';
  Future<void> initialize({Directory? directory}) async {
    try {
      _directory = directory ??
          Directory(await platform.invokeMethod<String>('logDirectory') ?? '');
      if (_directory!.path.isEmpty) {
        throw const FileSystemException('Missing log directory');
      }
      await _directory!.create(recursive: true);
      // New retention policy applies to owned diagnostic files only. Prices,
      // source cache, backups and unrelated user files are never removed.
      for (final f in await _ownedFiles()) {
        if (!f.uri.pathSegments.last.startsWith('IronPin-products-') ||
            await f.length() > fileBytes) await f.delete();
      }
      await _budget();
    } catch (e) {
      lastError = '$e';
    }
  }

  static const _sourceSections = {'source', 'network', 'parser', 'discovery'};
  static const _fields = {
    'endpoint',
    'rows',
    'pages',
    'coverage',
    'sources',
    'completed',
    'cachedRows',
    'total',
    'errorType',
    'status',
    'changed',
    'products',
    'id',
    'category',
    'amount',
    'currency',
    'unit',
    'date',
    'size',
    'thickness'
  };
  final int maxBytes, fileBytes;
  AppLogger(
      {this.maxBytes = 1024 * 1024,
      this.fileBytes = 128 * 1024,
      this.enabled = false})
      : assert(fileBytes >= 512 && maxBytes >= fileBytes);
  File? _active;
  int _serial = 0;
  final _recentProducts = <String>[];
  bool _owned(File f) =>
      RegExp(r'^IronPin-[^/]+\.md$').hasMatch(f.uri.pathSegments.last);
  Future<List<File>> _ownedFiles() async => _directory == null
      ? []
      : await _directory!
          .list()
          .where((e) => e is File && _owned(e))
          .cast<File>()
          .toList();
  Future<void> _budget([int reserve = 0]) async {
    final files = await _ownedFiles();
    final stats = {for (final f in files) f: await f.stat()};
    files.sort((a, b) => stats[a]!.modified.compareTo(stats[b]!.modified));
    var size = stats.values.fold<int>(0, (a, s) => a + s.size);
    for (final f in files) {
      if (size + reserve <= maxBytes) break;
      size -= stats[f]!.size;
      await f.delete();
      if (_active?.path == f.path) _active = null;
    }
  }

  Future<void> record(String section, String event,
      [Map<String, Object?> fields = const {}]) {
    if (!enabled ||
        _directory == null ||
        (section != 'product' && !_sourceSections.contains(section))) {
      return Future.value();
    }
    final clean = <String, Object?>{
      for (final e in fields.entries)
        if (_fields.contains(e.key)) e.key: _safe(e.value)
    };
    final identity = jsonEncode([event, clean]);
    if (section == 'product') {
      if (_recentProducts.contains(identity)) return _pending;
      _recentProducts.add(identity);
      if (_recentProducts.length > 256) _recentProducts.removeAt(0);
    }
    final now = DateTime.now().toUtc();
    var block =
        '\n## ${now.toIso8601String()} | ${section == 'product' ? 'product' : 'source'} | ${_line(event).substring(0, event.length > 80 ? 80 : event.length)}\n${jsonEncode(clean)}\n';
    if (utf8.encode(block).length > fileBytes - 128) {
      block =
          '\n## ${now.toIso8601String()} | source | oversized_summary\n${jsonEncode({
            'endpoint': clean['endpoint'],
            'rows': clean['rows'],
            'status':
                'جزئیات بزرگ در لاگ تکرار نشد؛ داده کامل در آرشیو محصول است'
          })}\n';
    }
    if (utf8.encode(block).length > fileBytes - 128) {
      block =
          '\n## ${now.toIso8601String()} | source | oversized_summary\n{"status":"omitted"}\n';
    }
    final bytes = utf8.encode(block);
    _pending = _pending.then((_) async {
      if (!enabled) return;
      try {
        const header = '# IronPin — products and sources | 0.7.1\n';
        final newFile = _active == null ||
            !await _active!.exists() ||
            await _active!.length() + bytes.length > fileBytes;
        final reserve =
            bytes.length + (newFile ? utf8.encode(header).length : 0);
        await _budget(reserve);
        if (_active == null ||
            !await _active!.exists() ||
            await _active!.length() + bytes.length > fileBytes) {
          _active = File(
              '${_directory!.path}/IronPin-products-${DateTime.now().microsecondsSinceEpoch}-${_serial++}.md');
          await _active!.writeAsString(header);
        }
        await _active!.writeAsBytes(bytes, mode: FileMode.append);
        await _budget();
        lastError = null;
      } catch (e) {
        lastError = '$e';
      }
    });
    return _pending;
  }

  static Object? _safe(Object? value) {
    if (value is num) return value.isFinite ? value : null;
    if (value is bool || value == null) return value;
    if (value is List) return value.take(10).map(_safe).toList();
    if (value is Map) {
      return {
        for (final e in value.entries)
          if (_fields.contains(e.key)) e.key: _safe(e.value)
      };
    }
    final s = '$value'.replaceAll(
        RegExp(r'ghp_[A-Za-z0-9]+|github_pat_[A-Za-z0-9_]+'), '[redacted]');
    return s.length > 160 ? s.substring(0, 160) : s;
  }

  static String _line(String s) => s.replaceAll(RegExp(r'[\r\n`|]'), ' ');
  Future<void> flush() => _pending;
  Future<List<File>> files() async {
    await flush();
    if (_directory == null) return [];
    final result = await _directory!
        .list()
        .where((e) => e is File && _owned(e))
        .cast<File>()
        .toList();
    result.sort((a, b) => a.path.compareTo(b.path));
    return result;
  }

  Future<String?> export() async {
    await flush();
    final all = await files();
    if (all.isEmpty) {
      throw const FileSystemException('لاگی برای خروجی وجود ندارد.');
    }
    final result = await platform.invokeMethod<String>(
        'exportLogs', {'paths': all.map((f) => f.path).toList()});
    return result;
  }

  void capture(Object error, StackTrace stack, {String section = 'error'}) {
    unawaited(record(
        section, 'source_error', {'errorType': error.runtimeType.toString()}));
  }

  void installErrorHandlers() {
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      capture(details.exception, details.stack ?? StackTrace.current,
          section: 'flutter');
      previous?.call(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      capture(error, stack, section: 'platform');
      return true;
    };
  }
}
