import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'market.dart';
import 'price_range.dart';
import 'product_schema.dart';
import 'city_scope.dart';

class RangeCancelled implements Exception {}

/// One cancellable worker per confirmed snapshot. Only primitive data crosses
/// the boundary, not controllers, cached reports, DB handles or widget state.
class RangeTask {
  Isolate? _isolate;
  ReceivePort? _port;
  Timer? _timer;
  Completer<Map<String, Object?>>? _done;
  bool get running => _done != null && !_done!.isCompleted;
  void cancel() {
    if (running) _done!.completeError(RangeCancelled());
    _close();
  }

  void _close() {
    _timer?.cancel();
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _port?.close();
    _port = null;
  }

  Future<RangeSelection> run(Map<String, Object?> input,
      {Duration timeout = const Duration(seconds: 45),
      void Function(String stage, int done, int total)? onProgress}) async {
    if (running) throw StateError('Range job already running');
    final completed = Completer<Map<String, Object?>>();
    _done = completed;
    final port = ReceivePort();
    _port = port;
    port.listen((message) {
      if (completed.isCompleted) return;
      if (message is Map && message['type'] == 'progress') {
        onProgress?.call(message['stage'] as String, message['done'] as int,
            message['total'] as int);
      } else if (message is Map && message['type'] == 'result') {
        completed.complete(Map<String, Object?>.from(message['data'] as Map));
      } else {
        completed.completeError(
            StateError('Range worker exited without a valid result'));
      }
    });
    _timer = Timer(timeout, () {
      if (!completed.isCompleted) {
        completed.completeError(
            TimeoutException('Range calculation timed out', timeout));
      }
      _close();
    });
    // Observe the future immediately, including cancellation during spawn.
    final result = completed.future;
    unawaited(Isolate.spawn<List<Object>>(_rangeWorker, [port.sendPort, input],
            onError: port.sendPort, onExit: port.sendPort)
        .then((isolate) {
      if (completed.isCompleted) {
        isolate.kill(priority: Isolate.immediate);
      } else {
        _isolate = isolate;
      }
    }).catchError((Object error, StackTrace stack) {
      if (!completed.isCompleted) completed.completeError(error, stack);
    }));
    try {
      return RangeSelection.fromMessage(await result);
    } finally {
      _close();
    }
  }
}

class RangeSelection {
  final ProductRangeResult result;
  final List<RangeProduct> catalog;
  final int inputRows;
  const RangeSelection(this.result, this.catalog, this.inputRows);
  factory RangeSelection.fromMessage(Map<String, Object?> data) {
    final rows = (data['rows'] as List)
        .map((j) => Quote.fromJson(Map<String, dynamic>.from(j as Map)))
        .toList();
    List<Quote> select(Object? indices) =>
        (indices as List).map((i) => rows[i as int]).toList();
    final ranges = (data['ranges'] as List).map((item) {
      final m = item as Map, values = select(m['indices']);
      return PriceRange.computed(
          m['key'] as String, m['basis'] as String, values.first, values,
          minimum: m['min'] as double,
          maximum: m['max'] as double,
          mean: m['mean'] as double,
          roundedMean: m['rounded'] as int,
          sellers: m['sellers'] as int);
    }).toList();
    final result = ProductRangeResult(
        select(data['announcements']),
        ranges,
        Map<String, int>.from(data['excluded'] as Map),
        DateTime.fromMillisecondsSinceEpoch(data['at'] as int, isUtc: true));
    final catalog = <RangeProduct>[];
    final indices = data['catalog'] as List,
        texts = data['catalogSearch'] as List;
    for (var i = 0; i < indices.length; i++) {
      final q = rows[indices[i] as int];
      catalog.add(RangeProduct('${q.endpoint}:${q.id}:$i', q, null, const [],
          preparedSearch: texts[i] as String));
    }
    return RangeSelection(result, catalog, data['inputRows'] as int);
  }
}

void _rangeWorker(List<Object> arguments) {
  final port = arguments[0] as SendPort, data = arguments[1] as Map;
  final payloads = data['payloads'] as List<String>;
  final query = ProductRangeQuery(data['family'] as String,
      fields: Map<String, String>.from(data['fields'] as Map),
      basis: data['basis'] as String,
      city: data['city'] as String);
  final now =
      DateTime.fromMillisecondsSinceEpoch(data['now'] as int, isUtc: true);
  void progress(String stage, int done, int total) => port
      .send({'type': 'progress', 'stage': stage, 'done': done, 'total': total});
  final matching = <Quote>[], catalog = <String, Quote>{};
  for (var i = 0; i < payloads.length; i++) {
    final q = Quote.fromJson(jsonDecode(payloads[i]));
    if (cityMatches(q, query.city)) {
      final facts = ProductFacts.of(q);
      if ((facts.family.isEmpty ? 'سایر' : facts.family) == query.family &&
          facts.matches(query.fields)) {
        matching.add(q);
        final key = jsonEncode([q.endpoint, q.id, facts.identity, q.unit]);
        final previous = catalog[key];
        if (previous == null || !q.fetchedAt.isBefore(previous.fetchedAt)) {
          catalog[key] = q;
        }
      }
    }
    if (i % 200 == 0 || i + 1 == payloads.length) {
      progress('تطبیق شهر و مشخصات', i + 1, payloads.length);
    }
  }
  progress('محاسبه اعلام‌های معتبر ۴۸ ساعت', matching.length, matching.length);
  final result =
      calculateProductRange({'query': query, 'now': now, 'quotes': matching});
  final catalogRows = catalog.values.toList()
    ..sort((a, b) => a.title.compareTo(b.title));
  final pool = <Quote, int>{};
  for (final q in [...result.announcements, ...catalogRows]) {
    pool.putIfAbsent(q, () => pool.length);
  }
  List<int> indices(Iterable<Quote> quotes) =>
      quotes.map((q) => pool[q]!).toList();
  progress('آماده‌سازی نتیجه', pool.length, pool.length);
  port.send({
    'type': 'result',
    'data': {
      'rows': pool.keys.map((q) => q.toJson()).toList(),
      'announcements': indices(result.announcements),
      'catalog': indices(catalogRows),
      'catalogSearch':
          catalogRows.map((q) => ProductTextForRange.search(q)).toList(),
      'ranges': [
        for (final r in result.ranges)
          {
            'key': r.key,
            'basis': r.basis,
            'indices': indices(r.announcements),
            'min': r.minimum,
            'max': r.maximum,
            'mean': r.mean,
            'rounded': r.roundedMean,
            'sellers': r.sellers,
          }
      ],
      'excluded': result.excluded,
      'at': now.millisecondsSinceEpoch,
      'inputRows': payloads.length,
    }
  });
}

class ProductTextForRange {
  static String search(Quote q) =>
      specNorm('${q.title} ${q.specificationLabel} ${q.seller}');
}
