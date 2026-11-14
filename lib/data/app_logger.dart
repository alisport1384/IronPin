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

  /// The last important events, kept in memory whatever the log switch says.
  /// They are written into the export file, so a report can always be sent even
  /// when the persistent log was switched off during the run.
  final List<String> _recentErrors = <String>[];
  List<String> get recentErrors => List.unmodifiable(_recentErrors);

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
        if ((!f.uri.pathSegments.last.startsWith('IronPin-products-') &&
                f.uri.pathSegments.last != 'IronPin-runtime.md') ||
            await f.length() > fileBytes) await f.delete();
      }
      await _budget();
    } catch (e) {
      lastError = '$e';
      // An empty path is not a place to write to: leave the directory unknown so
      // the caller reports the real reason instead of writing to '/'.
      if (_directory?.path.isEmpty ?? false) _directory = null;
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
      [Map<String, Object?> fields = const {}]) async {
    if (!enabled) return;
    if (_directory == null ||
        (section != 'product' && !_sourceSections.contains(section))) {
      return;
    }
    final clean = <String, Object?>{
      for (final e in fields.entries)
        if (_fields.contains(e.key)) e.key: _safe(e.value)
    };
    final identity = jsonEncode([event, clean]);
    if (section == 'product') {
      if (_recentProducts.contains(identity)) return;
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
        const header = '# IronPin — session log | 0.9.6\n';
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

  /// Opens the log directory once, whatever the switch says: the export button
  /// and every later record then have a real place to write to.
  Future<void> ensureReady() async {
    if (_directory == null) await initialize();
  }

  String? _previousCheckpoint;
  bool _checkpointRead = false;

  /// A single small, overwritten file. No prices, URLs, device identifiers or
  /// unlimited logs. It survives a process kill and needs no ADB to export.
  /// RSS is the whole process, NOT the Java heap or a diagnosis of OOM.
  Future<void> checkpoint(String stage, {int rows = 0}) async {
    try {
      await ensureReady();
      if (_directory == null) return;
      final file = File('${_directory!.path}/IronPin-runtime.md');
      if (!_checkpointRead) {
        _checkpointRead = true;
        if (await file.exists() && await file.length() < 4096) {
          _previousCheckpoint = await file.readAsString();
        }
      }
      final text = '# IronPin runtime | 0.9.6\n${jsonEncode({
            'at': DateTime.now().toUtc().toIso8601String(),
            'stage': stage,
            'rows': rows,
            'rssBytes': ProcessInfo.currentRss,
            'maxRssBytes': ProcessInfo.maxRss,
          })}\n';
      _pending = _pending.then((_) async {
        try {
          await file.writeAsString(text, flush: true);
        } catch (e) {
          lastError = '$e';
        }
      });
      await _pending;
    } catch (e) {
      lastError = '$e';
    }
  }

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

  /// Writes the files to the folder the user picks.
  ///
  /// A report is always produced: when the log switch was off (or nothing was
  /// written yet) a session summary — the events kept in memory, the directory
  /// and the last error — is written first, so the export button never fails
  /// with "there is nothing to export".
  Future<String?> export({Map<String, Object?> summary = const {}}) async {
    await flush();
    if (_directory == null) await initialize();
    if (_directory == null) {
      throw FileSystemException('پوشه لاگ باز نشد: ${lastError ?? 'نامشخص'}');
    }
    // Existing product logs do not contain the error ring. Always include a
    // bounded diagnostic summary, even when normal source logs already exist.
    await _writeSummary(summary);
    final all = await files();
    final result = await platform.invokeMethod<String>(
        'exportLogs', {'paths': all.map((f) => f.path).toList()});
    return result;
  }

  /// One small file describing this run, written whatever the switch says.
  Future<void> _writeSummary(Map<String, Object?> summary) async {
    final file = File('${_directory!.path}/IronPin-session-'
        '${DateTime.now().microsecondsSinceEpoch}-${_serial++}.md');
    final buffer = StringBuffer('# IronPin — session summary | 0.9.6\n')
      ..writeln('generated: ${DateTime.now().toUtc().toIso8601String()}')
      ..writeln('log switch: ${enabled ? 'on' : 'off'}')
      ..writeln('directory: ${_directory!.path}');
    for (final e in summary.entries) {
      buffer.writeln('${e.key}: ${_safe(e.value)}');
    }
    if (_previousCheckpoint != null) {
      buffer.writeln(
          '\n## checkpoint from previous process\n$_previousCheckpoint');
    }
    if (_recentErrors.isNotEmpty) {
      buffer.writeln('\n## recent errors');
      for (final line in _recentErrors) {
        buffer.writeln('- $line');
      }
    }
    try {
      await file.writeAsString(buffer.toString());
      _active = file;
      lastError = null;
    } catch (e) {
      lastError = '$e';
      rethrow;
    }
    await _budget();
  }

  void capture(Object error, StackTrace stack, {String section = 'error'}) {
    // Kept in memory only: the persistent log keeps its documented scope, and
    // the export writes this ring into a summary file even when the switch is
    // off, so a failure is never lost and never leaks UI/raw content.
    final trace = stack.toString().split('\n').take(20).join('\n');
    final line = '${DateTime.now().toUtc().toIso8601String()} | '
        '$section | ${error.runtimeType}: $error\n$trace';
    _recentErrors
        .add(_line(line.length > 4000 ? line.substring(0, 4000) : line));
    if (_recentErrors.length > 100) _recentErrors.removeAt(0);
    lastError = '$error';
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
