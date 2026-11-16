import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../domain/market.dart';
import '../domain/product_schema.dart';
import '../domain/product_text.dart';
import '../domain/row_facts.dart';
import '../domain/range_projection.dart';
import 'app_logger.dart';
import 'store.dart';

/// How many rows of a candidate list are built up front. The rest are built when
/// the list scrolls to them, so a long archive costs the rows on screen.
const int candidatePrebuild = 60;

/// Immutable virtual list over stored index rows that materialises [Quote]
/// objects lazily per accessed index, so sorting 50,000+ offers never builds
/// off-screen cards up front.
class LazyQuoteList extends ListBase<Quote> {
  final List<Map<String, Object?>> _rows;
  final List<Quote?> _cache;
  LazyQuoteList(this._rows) : _cache = List<Quote?>.filled(_rows.length, null);

  @override
  int get length => _rows.length;

  @override
  set length(int newLength) =>
      throw UnsupportedError('LazyQuoteList is immutable');

  @override
  Quote operator [](int index) =>
      _cache[index] ??= quoteFromStoredRow(_rows[index]);

  @override
  void operator []=(int index, Quote value) =>
      throw UnsupportedError('LazyQuoteList is immutable');
}

/// The selectable rows of the stored archive for one basis and one search word.
class CandidateSet {
  /// The newest rows, already built; the rest follow as the list grows.
  final List<Quote> quotes;
  final List<Map<String, Object?>> pending;
  final List<Map<String, Object?>> wires;
  int _cursor = 0;

  /// Counted, not hidden: how many stored rows were withheld, and why.
  final int undated, unpriced, indexRows;
  final DateTime at;
  final int total;
  CandidateSet(this.quotes, this.undated, this.unpriced, this.indexRows, this.at,
      {this.pending = const [], List<Map<String, Object?>>? wires, int? total})
      : wires = wires ?? const [],
        total = total ?? quotes.length;
  int get withheld => undated + unpriced;

  /// One more page of rows, in the same order, built on demand. The list shows
  /// what it has built and grows when the user scrolls, so a scope of ten
  /// thousand rows never costs ten thousand objects on the first frame.
  void extend([int rows = candidatePrebuild]) {
    // Row by row through [at_], so the pending list is consumed in O(1) per
    // row via [_cursor] instead of O(N) list shifting.
    while (rows-- > 0 && quotes.length < total) {
      if (at_(quotes.length) == null) return;
    }
  }

  /// Row [index] of the whole set, built on first use and kept afterwards.
  Quote? at_(int index) {
    if (index < quotes.length) return quotes[index];
    if (index != quotes.length || _cursor >= pending.length) return null;
    final built = quoteFromStoredRow(pending[_cursor++]);
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
  Int32List _offerSlots = Int32List(0);
  Uint8List _nonMetalFlags = Uint8List(0);
  int _offerCount = 0;
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
    _offerSlots = Int32List(0);
    _nonMetalFlags = Uint8List(0);
    _offerCount = 0;
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
    _offerSlots = Int32List(0);
    _nonMetalFlags = Uint8List(0);
    _offerCount = 0;
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
    // Sorted once, here, instead of on every selection: index rows are kept
    // newest-first (`market_at DESC, id ASC`). On large archives (>4,000 rows),
    // sort indices in a background isolate so the UI isolate stays smooth.
    final List<Map<String, Object?>> sortedRows;
    if (rows.length <= candidateSyncLimit) {
      final keys = [
        for (final r in rows)
          (at: (r['market_at'] as int?) ?? 0, id: '${r['id']}', row: r)
      ]..sort((a, b) {
          final byDate = b.at.compareTo(a.at);
          return byDate != 0 ? byDate : a.id.compareTo(b.id);
        });
      sortedRows = [for (final k in keys) k.row];
    } else {
      final sortPayload = [
        for (var i = 0; i < rows.length; i++)
          (
            idx: i,
            at: (rows[i]['market_at'] as int?) ?? 0,
            id: rows[i]['id'] as String? ?? ''
          )
      ];
      final order = await compute(_sortedOrderInBackground, sortPayload);
      if (generation != _generation) {
        throw StateError('Archive invalidated during index read');
      }
      sortedRows = [for (final idx in order) rows[idx]];
    }

    // Build lightweight typed slot/nonMetal arrays (~1 MB total for 200k rows)
    // in yielding 5ms slices so candidate selection avoids nested HashMaps
    // and repeated `isNonMetal` RegExps without increasing GC pressure.
    final offerSlots = <String, Map<String, int>>{};
    var nextOfferSlot = 0;
    final slots = Int32List(sortedRows.length);
    final nonMetalFlags = Uint8List(sortedRows.length);
    if (sortedRows.length <= candidateSyncLimit) {
      for (var i = 0; i < sortedRows.length; i++) {
        final raw = sortedRows[i];
        final ep = raw['endpoint'] as String? ?? '';
        final id = raw['id'] as String? ?? '';
        final byId = offerSlots[ep] ??= {};
        slots[i] = byId[id] ??= nextOfferSlot++;
        if (ProductText.isNonMetal(raw['title'] as String? ?? '')) {
          nonMetalFlags[i] = 1;
        }
      }
    } else {
      var i = 0;
      while (i < sortedRows.length) {
        if (generation != _generation) {
          throw StateError('Archive invalidated during index read');
        }
        final sw = Stopwatch()..start();
        final sliceEnd = (i + candidateSliceRows).clamp(0, sortedRows.length);
        while (i < sliceEnd) {
          final chunkEnd = (i + 64).clamp(0, sliceEnd);
          for (; i < chunkEnd; i++) {
            final raw = sortedRows[i];
            final ep = raw['endpoint'] as String? ?? '';
            final id = raw['id'] as String? ?? '';
            final byId = offerSlots[ep] ??= {};
            slots[i] = byId[id] ??= nextOfferSlot++;
            if (ProductText.isNonMetal(raw['title'] as String? ?? '')) {
              nonMetalFlags[i] = 1;
            }
          }
          if (sw.elapsedMilliseconds >= candidateSliceBudgetMs) break;
        }
        if (i < sortedRows.length) {
          await Future<void>.delayed(Duration.zero);
        }
      }
    }
    if (generation != _generation) {
      throw StateError('Archive invalidated during index read');
    }

    _index = sortedRows;
    _offerSlots = slots;
    _nonMetalFlags = nonMetalFlags;
    _offerCount = nextOfferSlot;
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
    final index = _index;
    final useSlots = _offerSlots.length == index.length && _offerCount > 0;
    final selector = CandidateSelector(
        scope: scope,
        nowMs: at.millisecondsSinceEpoch,
        offerCount: useSlots ? _offerCount : 0);
    if (useSlots) {
      for (var i = 0; i < index.length; i++) {
        selector.addWithSlot(index[i], _offerSlots[i], _nonMetalFlags[i] != 0);
      }
    } else {
      for (final raw in index) {
        selector.add(raw);
      }
    }
    return _buildSet(selector.finish(), at);
  }

  CandidateSet _buildSet(
      ({List<Map<String, Object?>> wires, int withheld, int undated, int unpriced})
          picked,
      DateTime at) {
    // The index is kept newest-first (see [_load]), and selection preserves
    // that order, so the wires need no sort here.
    final wires = picked.wires;
    final built = wires.take(candidatePrebuild).toList();
    final quotes = <Quote>[for (final row in built) quoteFromStoredRow(row)];
    return CandidateSet(
        quotes, picked.undated, picked.unpriced, _index.length, at,
        pending: wires.length > built.length
            ? wires.sublist(built.length)
            : const [],
        wires: wires,
        total: wires.length);
  }

  /// Rows per slice of a chunked candidate selection.
  static const int candidateSliceRows = 1200;

  /// Wall-clock budget of one slice of a chunked candidate selection.
  ///
  /// A fixed row count is the wrong unit on purpose-built hardware: 1,200
  /// rows that take 4 ms on a desktop can take 40 ms on a 32-bit phone,
  /// which is several dropped frames. Slices therefore end by time, not by
  /// count, so the longest synchronous block stays near one frame
  /// everywhere; the row count above remains only as a hard cap.
  static const int candidateSliceBudgetMs = 5;

  /// Archives up to this size are selected in one synchronous pass; beyond
  /// it the selection is sliced (see [candidates]).
  static const int candidateSyncLimit = 4000;

  /// The same selection as [candidatesNow], sliced on large archives.
  /// Throws [StateError] when the archive is invalidated mid-scan.
  Future<CandidateSet> candidatesSliced(
      {required CandidateScope scope,
      required DateTime at,
      bool Function()? cancelled}) async {
    final generation = _generation;
    final index = _index;
    final useSlots = _offerSlots.length == index.length && _offerCount > 0;
    final selector = CandidateSelector(
        scope: scope,
        nowMs: at.millisecondsSinceEpoch,
        offerCount: useSlots ? _offerCount : 0);
    var i = 0;
    while (i < index.length) {
      if (generation != _generation || (cancelled?.call() ?? false)) {
        throw StateError('Archive invalidated during candidate selection');
      }
      final watch = Stopwatch()..start();
      final sliceEnd = (i + candidateSliceRows).clamp(0, index.length);
      if (useSlots) {
        final slots = _offerSlots;
        final nonMetals = _nonMetalFlags;
        while (i < sliceEnd) {
          final chunkEnd = (i + 64).clamp(0, sliceEnd);
          for (; i < chunkEnd; i++) {
            selector.addWithSlot(index[i], slots[i], nonMetals[i] != 0);
          }
          if (watch.elapsedMilliseconds >= candidateSliceBudgetMs) break;
        }
      } else {
        while (i < sliceEnd) {
          final chunkEnd = (i + 64).clamp(0, sliceEnd);
          for (; i < chunkEnd; i++) {
            selector.add(index[i]);
          }
          if (watch.elapsedMilliseconds >= candidateSliceBudgetMs) break;
        }
      }
      if (i < index.length) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    if (generation != _generation || (cancelled?.call() ?? false)) {
      throw StateError('Archive invalidated during candidate selection');
    }
    return _buildSet(selector.finish(), at);
  }

  Future<CandidateSet> candidates(
      {required CandidateScope scope,
      required DateTime at,
      int? windowDays,
      bool Function()? cancelled}) async {
    if (windowDays == null) {
      await ensureIndexAt(at);
    } else {
      await ensureIndex(at, windowDays: windowDays);
    }
    final watch = Stopwatch()..start();
    final set = _index.length <= candidateSyncLimit
        ? _candidateSet(scope, at)
        : await candidatesSliced(scope: scope, at: at, cancelled: cancelled);
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
    // Only rows of the requested family can ever pass `admits(family, ...)`:
    // pre-filtering here avoids copying 90%+ unrelated rows across the isolate
    // boundary on 100k+ archives while keeping `inputRows` exact.
    final familyRows = <Map<String, Object?>>[
      for (final r in _index)
        if (r['family'] == family) r
    ];
    final input = {
      'rows': familyRows,
      'inputRows': _index.length,
      'family': family,
      'fields': fields,
      'basis': basis,
      'city': city,
      'windowMs': windowMsFor(windowDays),
      'now': at.millisecondsSinceEpoch
    };
    // The projection is CPU-bound over the matching family: run it off the
    // isolate that draws frames, and keep one implementation for both paths.
    computeRuns++;
    final answer = await compute(_answerInBackground, input).timeout(timeout);
    _answers[key] = answer;
    await AppLogger.instance.record('range', 'confirmed_from_index', {
      'rows': _index.length,
      'kept': answer.keptRows,
      'elapsedMs': watch.elapsedMilliseconds
    });
    return answer;
  }
}

/// Background entry point; identical code to the synchronous projection.
RangeAnswer _answerInBackground(Map<String, Object?> input) {
  final rows = (input['rows'] as List).cast<Map<String, Object?>>();
  final inputRows = (input['inputRows'] as int?) ?? rows.length;
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
      basis: input['basis'] as String, at: at, inputRows: inputRows);
}

List<int> _sortedOrderInBackground(
    List<({int idx, int at, String id})> items) {
  items.sort((a, b) {
    final byDate = b.at.compareTo(a.at);
    return byDate != 0 ? byDate : a.id.compareTo(b.id);
  });
  return [for (final item in items) item.idx];
}
