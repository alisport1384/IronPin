import 'dart:async';
import 'dart:isolate';

import 'range_projection.dart';

/// A long-lived worker over the derived index of the local archive.
///
/// The index rows are handed over **once per data change**. After that every
/// confirmation — other product, other city, other unit — is answered from the
/// same in-memory rows, so a new question costs one message round trip plus a
/// single pass over the rows, instead of a SQLite read, a JSON decode and a
/// specification extraction per row.
///
/// The worker answers with indices into the row list the caller also holds, so
/// nothing large crosses the isolate boundary again.
class RangeWorker {
  static final RangeWorker shared = RangeWorker();

  Isolate? _isolate;
  ReceivePort? _from;
  SendPort? _to;
  StreamSubscription? _subscription;
  final _waiting = <String, Completer<Map<String, Object?>>>{};
  final _progress = <String, void Function(int done, int total)>{};
  String? _loadedToken;
  int _rows = 0;
  int _sequence = 0;

  bool get isLoaded => _isolate != null;
  int get rowCount => _rows;

  /// True when the worker already holds exactly this snapshot.
  bool holdsToken(String token) => _loadedToken == token;

  Future<void> _start() async {
    if (_isolate != null) return;
    final from = ReceivePort();
    _from = from;
    final ready = Completer<SendPort>();
    _subscription = from.listen((message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
        return;
      }
      if (message is! Map) return;
      final id = message['id'] as String?;
      if (id == null) return;
      switch (message['type']) {
        case 'progress':
          _progress[id]?.call(message['done'] as int, message['total'] as int);
        case 'result':
          _waiting.remove(id)?.complete(
              Map<String, Object?>.from(message['data'] as Map));
        case 'error':
          _waiting.remove(id)?.completeError(StateError('${message['message']}'));
      }
    });
    final errors = ReceivePort();
    final isolate = await Isolate.spawn<List<Object>>(_workerMain,
        [from.sendPort, errors.sendPort], onError: errors.sendPort);
    errors.listen((message) {
      if (message is! List) return;
      // An isolate crash invalidates the snapshot: everything pending fails and
      // the caller retries on a fresh worker.
      if (!ready.isCompleted) {
        ready.completeError(StateError('Range worker failed to start'));
      }
      _reset('کارگر رنج متوقف شد؛ دوباره تلاش کنید.');
    });
    _isolate = isolate;
    _to = await ready.future.timeout(const Duration(seconds: 10), onTimeout: () {
      _reset('کارگر رنج پاسخ نداد');
      throw TimeoutException(
          'Range worker start timed out', const Duration(seconds: 10));
    });
  }

  void _reset(String message) {
    _subscription?.cancel();
    _subscription = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _to = null;
    _from?.close();
    _from = null;
    _loadedToken = null;
    _rows = 0;
    for (final completer in _waiting.values) {
      if (!completer.isCompleted) completer.completeError(StateError(message));
    }
    _waiting.clear();
    _progress.clear();
  }

  /// Hands the caller's index rows to the worker, once per snapshot token.
  Future<void> load(String token, List<Map<String, Object?>> rows,
      {void Function(int done, int total)? onProgress}) async {
    if (holdsToken(token)) return;
    await _start();
    final id = 'load:${++_sequence}';
    final completer = Completer<Map<String, Object?>>();
    _waiting[id] = completer;
    if (onProgress != null) {
      _progress[id] = (done, total) => onProgress(done, total);
    }
    _to!.send({'type': 'load', 'id': id, 'token': token, 'rows': rows});
    try {
      await completer.future
          .timeout(const Duration(seconds: 60), onTimeout: () {
        _waiting.remove(id);
        throw TimeoutException(
            'بارگذاری فهرست محلی طول کشید', const Duration(seconds: 60));
      });
      _loadedToken = token;
      _rows = rows.length;
    } finally {
      _waiting.remove(id);
      _progress.remove(id);
    }
  }

  /// One confirmation over the loaded snapshot. A newer call supersedes the
  /// older one; only the newest answer is published.
  Future<Map<String, Object?>> run({
    required String token,
    required String family,
    required Map<String, String> fields,
    required String basis,
    required String city,
    required int nowMs,
    Duration timeout = const Duration(seconds: 45),
    void Function(int done, int total)? onProgress,
  }) async {
    await _start();
    if (!holdsToken(token)) throw StateError('Range worker lost its snapshot');
    final id = 'run:${++_sequence}';
    final completer = Completer<Map<String, Object?>>();
    _waiting[id] = completer;
    if (onProgress != null) _progress[id] = onProgress;
    _to!.send({
      'type': 'run',
      'id': id,
      'family': family,
      'fields': fields,
      'basis': basis,
      'city': city,
      'now': nowMs,
    });
    try {
      return await completer.future.timeout(timeout, onTimeout: () {
        _to?.send({'type': 'cancel', 'id': id});
        throw TimeoutException('Range calculation timed out', timeout);
      });
    } finally {
      _waiting.remove(id);
      _progress.remove(id);
    }
  }

  /// Frees the isolate; the next call starts a fresh worker and reloads. A
  /// worker that failed once must not poison every later confirmation.
  void dispose() => _reset('کارگر رنج بسته شد');
}

Future<void> _workerMain(List<Object> arguments) async {
  final out = arguments[0] as SendPort, errors = arguments[1] as SendPort;
  final inbox = ReceivePort();
  final pending = <Map>[];
  final cancelled = <String>{};
  inbox.listen((message) {
    if (message is Map) pending.add(message);
  });
  out.send(inbox.sendPort);
  var index = PreparedIndex(const [], const []);

  Future<void> yieldNow() => Future<void>.delayed(Duration.zero);

  try {
    while (true) {
      if (pending.isEmpty) {
        await yieldNow();
        continue;
      }
      final message = pending.removeAt(0);
      final id = message['id'] as String?;
      switch (message['type']) {
        case 'cancel':
          cancelled.add('${message['id']}');
          continue;
        case 'load':
          // Expanded once, here: later questions only filter this list.
          index = prepare((message['rows'] as List).cast<Map<String, Object?>>());
          out.send({'type': 'result', 'id': id, 'data': {'rows': index.length}});
          continue;
        case 'run':
          break;
        default:
          continue;
      }
      if (id == null) continue;
      final total = index.length;
      out.send({'type': 'progress', 'id': id, 'done': 0, 'total': total});
      await yieldNow();
      if (cancelled.remove(id)) continue;
      final result = projectPrepared(index,
          family: message['family'] as String,
          fields: Map<String, String>.from(message['fields'] as Map),
          basis: message['basis'] as String,
          city: message['city'] as String,
          nowMs: message['now'] as int);
      if (cancelled.remove(id)) continue;
      // The answer is assembled here, in the worker, and sent back as domain
      // objects, so the UI isolate only receives the rows it will draw.
      out.send({
        'type': 'result',
        'id': id,
        'data': {
          'answer': buildAnswer(result,
              basis: message['basis'] as String,
              at: DateTime.fromMillisecondsSinceEpoch(message['now'] as int,
                  isUtc: true),
              inputRows: total),
        }
      });
    }
  } catch (error, stack) {
    errors.send([error.toString(), stack.toString()]);
  }
}
