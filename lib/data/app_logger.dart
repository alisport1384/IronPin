import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Local append-only Markdown diagnostics. Never records HTML, credentials or phones.
class AppLogger {
  static final instance = AppLogger();
  static const platform = MethodChannel('ir.ironpin/storage');
  Directory? _directory;
  Future<void> _pending = Future.value();
  String? lastError;
  String get directoryPath => _directory?.path ?? 'هنوز آماده نشده';
  Future<void> initialize({Directory? directory}) async {
    try {
      _directory = directory ??
          Directory(await platform.invokeMethod<String>('logDirectory') ?? '');
      if (_directory!.path.isEmpty) {
        throw const FileSystemException('Missing log directory');
      }
      await _directory!.create(recursive: true);
      await record('lifecycle', 'logger_ready', {'version': '0.3.0'});
    } catch (e) {
      lastError = '$e';
    }
  }

  Future<void> record(String section, String event,
      [Map<String, Object?> fields = const {}]) {
    if (_directory == null) return Future.value();
    final now = DateTime.now().toUtc();
    final clean = fields.map((key, value) => MapEntry(key, _safe(value)));
    final block =
        '\n## ${now.toIso8601String()} | ${_line(section)} | ${_line(event)}\n\n```json\n${const JsonEncoder.withIndent('  ').convert(clean)}\n```\n';
    _pending = _pending.then((_) async {
      try {
        final day = now.toIso8601String().substring(0, 10);
        var i = 0;
        File file;
        do {
          file =
              File('${_directory!.path}/IronPin-$day${i == 0 ? '' : '-$i'}.md');
          i++;
        } while (await file.exists() && await file.length() > 1024 * 1024);
        if (!await file.exists()) {
          await file.writeAsString(
              '# IronPin — local diagnostics\n\nUTC timestamps; version 0.3.0. No raw responses or secrets.\n');
        }
        await file.writeAsString(block, mode: FileMode.append, flush: false);
        lastError = null;
      } catch (e) {
        lastError = '$e';
      }
    });
    return _pending;
  }

  static Object? _safe(Object? value) {
    if (value is num || value is bool || value == null) return value;
    final s = '$value';
    return s.length > 1500 ? s.substring(0, 1500) : s;
  }

  static String _line(String s) => s.replaceAll(RegExp(r'[\r\n`|]'), ' ');
  Future<void> flush() => _pending;
  Future<List<File>> files() async {
    await flush();
    if (_directory == null) return [];
    final result = await _directory!
        .list()
        .where((e) => e is File && e.path.endsWith('.md'))
        .cast<File>()
        .toList();
    result.sort((a, b) => a.path.compareTo(b.path));
    return result;
  }

  Future<String?> export() async {
    await record('storage', 'log_export_requested');
    await flush();
    final all = await files();
    if (all.isEmpty) {
      throw const FileSystemException('لاگی برای خروجی وجود ندارد.');
    }
    final result = await platform.invokeMethod<String>(
        'exportLogs', {'paths': all.map((f) => f.path).toList()});
    await record(
        'storage',
        result == null ? 'log_export_cancelled' : 'log_export_complete',
        {'files': all.length});
    return result;
  }

  void capture(Object error, StackTrace stack, {String section = 'error'}) {
    unawaited(record(section, 'exception', {
      'type': error.runtimeType.toString(),
      'message': 'See exception type and stack; raw values redacted',
      'stack': '$stack'
    }));
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
