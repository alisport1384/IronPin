import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/market.dart';
import '../domain/product_schema.dart';
import '../domain/row_facts.dart';
import '../domain/range_projection.dart';
import 'app_logger.dart';
import 'store.dart';

/// How many rows of a candidate list are built up front. The rest are built when
/// the list scrolls to them, so a long archive costs the rows on screen.
const int candidatePrebuild = 60;

/// The selectable rows of the stored archive for one basis and one search word.
class CandidateSet {
  /// The newest rows, already built; the rest follow as the list grows.
  final List<Quote> quotes;
  final List<Map<String, Object?>> pending;

  /// Counted, not hidden: how many stored rows were withheld, and why.
  final int undated, unpriced, indexRows;
  final DateTime at;
  final int total;
  const CandidateSet(
      this.quotes, this.undated, this.unpriced, this.indexRows, this.at,
      {this.pending = const [], int? total})
      : total = total ?? quotes.length;
  int get withheld => undated + unpriced;

  /// One more page of rows, in the same order, built on demand. The list shows
  /// what it has built and grows when the user scrolls, so a scope of ten
  /// thousand rows never costs ten thousand objects on the first frame.
  void extend([int rows = candidatePrebuild]) {
    // Row by row through [at_], so the pending list is consumed exactly once: a
    // page never skips a row and never returns one twice.
    while (rows-- > 0 && quotes.length < total) {
      if (at_(quotes.length) == null) return;
    }
  }

  /// Row [index] of the whole set, built on first use and kept afterwards.
  ///
  /// Rows are always built in order (`index == quotes.length`), so the pending
  /// list is consumed from its head: no row is skipped, none is returned twice.
  Quote? at_(int index) {
    if (index < quotes.length) return quotes[index];
    if (index != quotes.length || pending.isEmpty) return null;
    final built = quoteFromStoredRow(pending.removeAt(0));
    quotes.add(built);
    return built;
  }
}

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

  /// Sessions are identified globally, so a standing worker can never believe a
  /// snapshot of another store (or of a previous run) is the one it holds.
  static int _sessions = 0;
  final int _session;

  final MarketStore store;

  List<Map<String, Object?>> _index = const [];
  String _token = 'none';

  /// The window the loaded index was read for (0 = the archive's own window).
  /// A different window is a different snapshot, so the rows are read again.
  int _windowDays = -1;

  /// Payload of the loaded index; the worker holds the very same rows.
  List<Map<String, Object?>> get indexRowsSnapshot => _index;
  int _epoch = 0;
  int _generation = 0;
  final Map<String, RangeAnswer> _answers = {};
  String _bucket = '';
  bool _loading = false;
  Future<void>? _loadingFuture;
  int _loadingGeneration = -1;
  final Map<String, Future<RangeAnswer>> _inFlight = {};

  /// How many confirmations had to compute on a one-shot isolate, i.e. fell back
  /// from the standing worker. Used to prove the fast path is the one in use.
  int computeRuns = 0;

  /// Identity of the snapshot itself; changes only when the archive changes.
  /// The worker is bound to this, so a new clock minute never reloads the rows.
  String get dataToken => 's$_session.d$_epoch.w$_windowDays';

  /// Identity of the loaded answers; changes with the archive and the clock.
  String get token => _token;
  int get indexRows => _index.length;

  /// Drops every in-memory artefact. Called on write, restore and refresh.
  void invalidate() {
    _generation++;
    _epoch++;
    _token = 'none';
    _index = const [];
    _answers.clear();
    _bucket = '';
    _windowDays = -1;
  }

  static String _bucketOf(DateTime at) =>
      '${at.toUtc().millisecondsSinceEpoch ~/ Duration.millisecondsPerMinute}';

  String scopeKey({
    required String family,
    required Map<String, String> fields,
    required String basis,
    required String city,
    int windowDays = 0,
  }) =>
      [
        family,
        basis,
        'w$windowDays',
        city.trim(),
        for (final key in productFields[family]?.keys ?? const <String>[])
          if ((fields[key] ?? '').trim().isNotEmpty)
            '$key=${specNorm(fields[key]!)}'
      ].join('\u0001');

  RangeAnswer? cached(String key, DateTime at) =>
      _bucket == _bucketOf(at) ? _answers[key] : null;

  /// Loads the index once per data revision. Concurrent callers share one read.
  Future<void> ensureIndex(DateTime at, {int windowDays = 0}) async {
    // Wait BEFORE changing the requested window. Otherwise a second caller
    // labels an in-flight 48-hour read as a 30-day snapshot and accepts it.
    final generation = _generation;
    while (_loadingFuture != null) {
      final loadingGeneration = _loadingGeneration;
      try {
        await _loadingFuture;
      } catch (_) {
        // A caller of the new archive may wait for an obsolete read to stop;
        // that obsolete read must not poison the new request.
        if (loadingGeneration == generation || generation != _generation) {
          rethrow;
        }
      }
      if (generation != _generation) {
        throw StateError('Archive invalidated during index read');
      }
    }
    if (_windowDays == windowDays && _token != 'none') {
      _advanceBucket(at);
      return;
    }
    _windowDays = windowDays;
    _token = 'none';
    _index = const [];
    _answers.clear();
    _loading = true;
    _loadingGeneration = generation;
    final future = _load(at, windowDays, generation);
    _loadingFuture = future;
    try {
      await future;
    } finally {
      _loading = false;
      _loadingFuture = null;
    }
  }

  bool get loading => _loading;

  Future<void> _load(DateTime at, int windowDays, int generation) async {
    final watch = Stopwatch()..start();
    final rows = await store.rangeIndexRows(at, windowDays: windowDays);
    if (generation != _generation) {
      throw StateError('Archive invalidated during index read');
    }
    final bucket = _bucketOf(at);
    _index = rows;
    _epoch++;
    _token = 'i$_epoch-$bucket';
    _bucket = bucket;
    _answers.clear();
    await AppLogger.instance.record('range', 'index_ready',
        {'rows': rows.length, 'elapsedMs': watch.elapsedMilliseconds});
  }

  /// The archive's time window, kept while the data is unchanged: the minute
  /// bucket is refreshed without re-reading the index.
  void _advanceBucket(DateTime at) {
    if (_token == 'none') return;
    final bucket = _bucketOf(at);
    if (_bucket == bucket) return;
    _bucket = bucket;
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
    int windowDays = 0,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final key = scopeKey(
        family: family,
        fields: fields,
        basis: basis,
        city: city,
        windowDays: windowDays);
    final hit = cached(key, at);
    if (hit != null) {
      await AppLogger.instance.record('range', 'served_from_memory',
          {'kept': hit.keptRows, 'rows': hit.inputRows});
      return hit.asMemory();
    }
    // The same confirmation asked twice at once is computed once.
    final pending = _inFlight[key];
    if (pending != null) return pending;
    final future =
        _confirm(key, family, fields, basis, city, at, windowDays, timeout);
    _inFlight[key] = future;
    try {
      return await future;
    } finally {
      _inFlight.remove(key);
    }
  }

  /// Selectable candidates of the stored archive for the prices tab.
  ///
  /// Reads the same derived index the range flow uses — no payload decode, no
  /// spec extraction, no `Quote` for the rows that stay off screen. Rows without
  /// a real announcement date or without a comparable price are withheld and
  /// counted, never shown as if they were candidates.

  /// Reads the index for a scope that already names its own window.
  Future<void> ensureIndexAt(DateTime at) =>
      ensureIndex(at, windowDays: _windowDays < 0 ? 0 : _windowDays);

  /// True when the derived index is already in memory.
  bool get hasIndex => _token != 'none';
  bool hasIndexFor(int windowDays) => hasIndex && _windowDays == windowDays;

  /// The same selection as [candidates], for an index that is already loaded.
  CandidateSet candidatesNow(
          {required CandidateScope scope, required DateTime at}) =>
      _candidateSet(scope, at);

  CandidateSet _candidateSet(CandidateScope scope, DateTime at) {
    final picked = selectCandidates(_index,
        scope: scope, nowMs: at.millisecondsSinceEpoch);
    // Sorted before any object is built: the newest-first order is a numeric
    // order, so ordering maps is enough and the sort never touches Quote.
    final wires = picked.wires.toList()
      ..sort((a, b) {
        final byDate = ((b['market_at'] as int?) ?? 0)
            .compareTo((a['market_at'] as int?) ?? 0);
        return byDate != 0 ? byDate : '${a['id']}'.compareTo('${b['id']}');
      });
    // Only the rows the list will actually draw become objects; the rest stay as
    // plain maps until the user scrolls to them.
    final built = wires.take(candidatePrebuild).toList();
    // Built from the stored row, never from the raw index map: the columns of the
    // index are snake_case and a `Quote` reads camelCase, so the conversion is
    // what keeps the date, the receipt time and the source link on the card.
    final quotes = <Quote>[for (final row in built) quoteFromStoredRow(row)];
    return CandidateSet(
        quotes, picked.undated, picked.unpriced, _index.length, at,
        pending: wires.length > built.length
            ? wires.sublist(built.length)
            : const [],
        total: wires.length);
  }

  Future<CandidateSet> candidates(
      {required CandidateScope scope,
      required DateTime at,
      int? windowDays}) async {
    if (windowDays == null) {
      await ensureIndexAt(at);
    } else {
      await ensureIndex(at, windowDays: windowDays);
    }
    final watch = Stopwatch()..start();
    final set = _candidateSet(scope, at);
    await AppLogger.instance.record('prices', 'candidates_ready', {
      'indexRows': set.indexRows,
      'candidates': set.total,
      'undated': set.undated,
      'unpriced': set.unpriced,
      'built': set.quotes.length,
      'elapsedMs': watch.elapsedMilliseconds
    });
    return set;
  }

  /// Remembers an answer the persistent worker built, keyed by the same scope key
  /// a repeated confirmation uses, so it is served from memory next time.
  RangeAnswer answerFromWorker(
    RangeAnswer answer, {
    required String family,
    required Map<String, String> fields,
    required String basis,
    required String city,
    int windowDays = 0,
  }) {
    _answers[scopeKey(
      family: family,
      fields: fields,
      basis: basis,
      city: city,
      windowDays: windowDays,
    )] = answer;
    return answer;
  }

  Future<RangeAnswer> _confirm(
      String key,
      String family,
      Map<String, String> fields,
      String basis,
      String city,
      DateTime at,
      int windowDays,
      Duration timeout) async {
    await ensureIndex(at, windowDays: windowDays);
    final again = cached(key, at);
    if (again != null) return again.asMemory();
    final watch = Stopwatch()..start();
    final input = {
      'rows': _index,
      'family': family,
      'fields': fields,
      'basis': basis,
      'city': city,
      'windowMs': windowMsFor(windowDays),
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
  final at =
      DateTime.fromMillisecondsSinceEpoch(input['now'] as int, isUtc: true);
  final projected = project(rows,
      family: input['family'] as String,
      fields: Map<String, String>.from(input['fields'] as Map),
      basis: input['basis'] as String,
      city: input['city'] as String,
      nowMs: at.millisecondsSinceEpoch,
      windowMs: input['windowMs'] as int? ?? 48 * 3600 * 1000);
  return buildAnswer(projected,
      basis: input['basis'] as String, at: at, inputRows: rows.length);
}
