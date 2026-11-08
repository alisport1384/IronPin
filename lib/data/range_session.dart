import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/product_schema.dart';
import '../domain/range_projection.dart';
import 'app_logger.dart';
import 'store.dart';

/// Everything the range page talks to: one in-memory index of the archive, one
/// persistent worker, and a scope-keyed answer cache.
///
/// Invariants that make the speed honest:
///
/// * the index is derived from the payloads at **write time** (see
///   `MarketStore.saveSnapshot`) and rebuilt from them when missing, so the
///   numbers always come from stored source values;
/// * a cached answer is only reused for the *same* scope (family, city, unit,
///   non-empty constraints), the *same* data revision and the same clock bucket
///   — a different question always recalculates;
/// * the cache is memory only: it is dropped on any write, restore, refresh or
///   city change, and never survives the process.
class RangeSession {
  RangeSession(this.store) : _session = ++_sessions;

  final MarketStore store;

  /// Sessions are identified globally, so a standing worker can never believe a
  /// snapshot of another store (or of a previous run) is the one it holds.
  static int _sessions = 0;
  final int _session;

  List<Map<String, Object?>> _index = const [];
  String _token = 'none';

  /// Payload of the loaded index; the worker holds the very same rows.
  List<Map<String, Object?>> get indexRowsSnapshot => _index;
  int _epoch = 0;
  final Map<String, RangeAnswer> _answers = {};
  String _bucket = '';
  bool _loading = false;
  Future<void>? _loadingFuture;
  final Map<String, Future<RangeAnswer>> _inFlight = {};

  /// How many confirmations had to compute on a one-shot isolate, i.e. fell back
  /// from the standing worker. Used to prove the fast path is the one in use.
  int computeRuns = 0;

  /// Identity of the snapshot itself; changes only when the archive changes.
  /// The worker is bound to this, so a new clock minute never reloads the rows.
  String get dataToken => 's$_session.d$_epoch';

  /// Identity of the loaded answers; changes with the archive and the clock.
  String get token => _token;
  int get indexRows => _index.length;

  /// Drops every in-memory artefact. Called on write, restore and refresh.
  void invalidate() {
    _epoch++;
    _token = 'none';
    _index = const [];
    _answers.clear();
    _bucket = '';
  }

  static String _bucketOf(DateTime at) =>
      '${at.toUtc().millisecondsSinceEpoch ~/ Duration.millisecondsPerMinute}';

  String scopeKey({
    required String family,
    required Map<String, String> fields,
    required String basis,
    required String city,
  }) =>
      [
        family,
        basis,
        city.trim(),
        for (final key in productFields[family]?.keys ?? const <String>[])
          if ((fields[key] ?? '').trim().isNotEmpty)
            '$key=${specNorm(fields[key]!)}'
      ].join('\u0001');

  RangeAnswer? cached(String key, DateTime at) =>
      _bucket == _bucketOf(at) ? _answers[key] : null;

  /// Loads the index once per data revision. Concurrent callers share one read.
  Future<void> ensureIndex(DateTime at) async {
    if (_loadingFuture != null) {
      await _loadingFuture;
      _advanceBucket(at);
      if (_token != 'none') return;
    }
    if (_token != 'none') {
      // A new clock bucket only changes which announcements are inside the
      // 48-hour window; the derived rows themselves are unchanged, so the index
      // is not read again. The previous answers are dropped, never reused.
      _advanceBucket(at);
      return;
    }
    _loading = true;
    final future = _load(at);
    _loadingFuture = future;
    try {
      await future;
    } finally {
      _loading = false;
      _loadingFuture = null;
    }
  }

  bool get loading => _loading;

  Future<void> _load(DateTime at) async {
    final watch = Stopwatch()..start();
    final rows = await store.rangeIndexRows(at);
    final bucket = _bucketOf(at);
    _index = rows;
    _epoch++;
    _token = 'i$_epoch-$bucket';
    _bucket = bucket;
    _answers.clear();
    await AppLogger.instance.record('range', 'index_ready', {
      'rows': rows.length,
      'elapsedMs': watch.elapsedMilliseconds
    });
  }

  /// The archive's time window, kept while the data is unchanged: the minute
  /// bucket is refreshed without re-reading the index.
  void _advanceBucket(DateTime at) {
    if (_token == 'none') return;
    _bucket = _bucketOf(at);
    _token = 'i$_epoch-$_bucket';
    _answers.clear();
  }

  /// One confirmation. Answers the same scope of the same snapshot from memory;
  /// otherwise computes it from the index, off the UI isolate.
  Future<RangeAnswer> confirm({
    required String family,
    required Map<String, String> fields,
    required String basis,
    required String city,
    required DateTime at,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final key = scopeKey(family: family, fields: fields, basis: basis, city: city);
    final hit = cached(key, at);
    if (hit != null) {
      await AppLogger.instance.record('range', 'served_from_memory',
          {'kept': hit.keptRows, 'rows': hit.inputRows});
      return hit.asMemory();
    }
    // The same confirmation asked twice at once is computed once.
    final pending = _inFlight[key];
    if (pending != null) return pending;
    final future = _confirm(key, family, fields, basis, city, at, timeout);
    _inFlight[key] = future;
    try {
      return await future;
    } finally {
      _inFlight.remove(key);
    }
  }

  /// Remembers an answer the persistent worker built, keyed by the same scope key
  /// a repeated confirmation uses, so it is served from memory next time.
  RangeAnswer answerFromWorker(
    RangeAnswer answer, {
    required String family,
    required Map<String, String> fields,
    required String basis,
    required String city,
  }) {
    _answers[scopeKey(
        family: family, fields: fields, basis: basis, city: city)] = answer;
    return answer;
  }

  Future<RangeAnswer> _confirm(String key, String family,
      Map<String, String> fields, String basis, String city, DateTime at,
      Duration timeout) async {
    await ensureIndex(at);
    final again = cached(key, at);
    if (again != null) return again.asMemory();
    final watch = Stopwatch()..start();
    final input = {
      'rows': _index,
      'family': family,
      'fields': fields,
      'basis': basis,
      'city': city,
      'now': at.millisecondsSinceEpoch
    };
    // The projection is CPU-bound over the whole index: run it off the isolate
    // that draws frames, and keep one implementation for both paths.
    computeRuns++;
    final answer = await compute(_answerInBackground, input).timeout(timeout);
    _answers[key] = answer;
    await AppLogger.instance.record('range', 'confirmed_from_index', {
      'rows': input['rows'] is List ? (input['rows'] as List).length : 0,
      'kept': answer.keptRows,
      'elapsedMs': watch.elapsedMilliseconds
    });
    return answer;
  }
}

/// Background entry point; identical code to the synchronous projection.
RangeAnswer _answerInBackground(Map<String, Object?> input) {
  final rows = (input['rows'] as List).cast<Map<String, Object?>>();
  final at = DateTime.fromMillisecondsSinceEpoch(input['now'] as int, isUtc: true);
  final projected = project(rows,
      family: input['family'] as String,
      fields: Map<String, String>.from(input['fields'] as Map),
      basis: input['basis'] as String,
      city: input['city'] as String,
      nowMs: at.millisecondsSinceEpoch);
  return buildAnswer(projected,
      basis: input['basis'] as String, at: at, inputRows: rows.length);
}

