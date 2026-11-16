import '../domain/city_scope.dart';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:async';
import '../data/app_logger.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../domain/money.dart';
import '../domain/product_text.dart';
import '../data/controller.dart';
import '../domain/market.dart';
import 'common.dart';
import 'prices_page.dart';

class ChartPage extends StatefulWidget {
  final MarketController c;
  final String? selectedId;
  final Quote? selectedQuote;
  const ChartPage(
      {super.key, required this.c, this.selectedId, this.selectedQuote});
  @override
  State<ChartPage> createState() => _ChartPageState();
}

class _ChartPageState extends State<ChartPage> {
  String? selected;
  /// The chart's own window, inherited from the primary window until the user
  /// chooses one for this tab. `0` means the whole stored history.
  int get days => widget.c.chartWindow;
  Future<List<Quote>>? future;
  String lastSignature = '';
  String loadedKey = '';
  int historyLimit = 1000;

  /// 'price' draws every receipt; 'indicators' draws only the changes of the
  /// range tab's mean/high/low («فقط ثبت رکورد نموداری») — the chart of
  /// تغییرات تب رنج، نه هر رسید دریافتی.
  String mode = 'price';

  /// Which indicator lines are visible in the indicator mode.
  final indicatorOn = <String>{'mean', 'high', 'low'};
  String historyKey(String endpoint) =>
      '${widget.c.selectedCity}:${widget.c.historyEpoch}:${widget.c.endpointRevisions[endpoint] ?? 0}';
  @override
  void initState() {
    super.initState();
    selected = widget.selectedId;
  }

  @override
  void didUpdateWidget(ChartPage old) {
    super.didUpdateWidget(old);
    if (widget.selectedId != old.selectedId) {
      selected = widget.selectedId;
      future = null;
    }
  }

  void load(String id) {
    if (selected != id) historyLimit = 1000;
    selected = id;
    final quote = widget.c.quoteById(id);
    loadedKey = historyKey(quote?.endpoint ?? '');
    unawaited(AppLogger.instance.record('chart', 'series_selected'));
    future = widget.c.store.history(id,
        since: days == 0
            ? null
            : DateTime.now().toUtc().subtract(Duration(days: days)),
        limit: historyLimit);
    lastSignature = quote?.signature ?? '';
  }

  @override
  Widget build(BuildContext context) {
    // Every stored offer with a real price in the chart basis, not only the rows
    // of the current feed window: an older product keeps a chart.
    final options = widget.c.chartOptions;
    if (options.isEmpty && widget.selectedQuote == null) {
      if (widget.c.chartOptionsLoading) {
        return const Center(child: CircularProgressIndicator());
      }
      return Column(children: [
        Padding(
            padding: const EdgeInsets.all(18),
            child: OutlinedButton.icon(
                onPressed: () => showMarketFilters(context, widget.c),
                icon: const Icon(Icons.tune),
                label: const Text('فیلتر مشترک بازار و نمودار'))),
        Expanded(
            child: emptyState('سری قابل نمایش وجود ندارد',
                'ابتدا قیمت واقعی دریافت کنید یا فیلترها را تغییر دهید. گذشته ساختگی تولید نمی‌شود.',
                icon: Icons.show_chart))
      ]);
    }
    Quote? found;
    if (selected != null) {
      final candidate = widget.c.quoteById(selected!);
      if (candidate != null && options.contains(candidate)) {
        found = candidate;
      } else if (widget.selectedQuote?.id == selected) {
        found = widget.selectedQuote;
      } else {
        for (final q in options) {
          if (q.id == selected) {
            found = q;
            break;
          }
        }
      }
    }
    if (found == null) {
      if (options.isNotEmpty) {
        selected = options.first.id;
        future = null;
      } else if (widget.selectedQuote != null) {
        found = widget.selectedQuote;
        selected = found!.id;
        future = null;
      }
    }
    final Quote current = found ?? options.first;
    if (future == null ||
        lastSignature != current.signature ||
        loadedKey != historyKey(current.endpoint)) {
      load(current.id);
    }
    return ListView(padding: const EdgeInsets.all(18), children: [
      Row(children: [
        const Expanded(
            child: Text('تاریخچه قیمت',
                style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold))),
        IconButton(
            tooltip: 'فیلتر نمودار',
            onPressed: () => showMarketFilters(context, widget.c),
            icon: const Icon(Icons.tune))
      ]),
      const Text('همان کالا، همان فروشنده، همان محل بارگیری',
          style: TextStyle(fontSize: 12, color: muted)),
      const SizedBox(height: 20),
      OutlinedButton.icon(
          icon: const Icon(Icons.search),
          label: Text(faDigits('${current.title} • ${current.seller}'),
              maxLines: 2, overflow: TextOverflow.ellipsis),
          onPressed: () async {
            final q = await showSearch<Quote?>(
                context: context, delegate: QuoteSearch(options));
            if (q != null && mounted) setState(() => load(q.id));
          }),
      const SizedBox(height: 16),
      windowField('بازه ثبت روی دستگاه', widget.c.chartDays, (v) async {
        await widget.c.setTabDays('chart', v);
        if (!mounted) return;
        setState(() {
          historyLimit = 1000;
          load(current.id);
        });
      }, inherit: true, inherited: widget.c.discoveryDays),
      // Two views of the same real history: every receipt, or only the
      // recorded changes of the range tab's indicators — duplicates that did
      // not move a number create no point in either view.
      Row(children: [
        ChoiceChip(
            label: const Text('قیمت هر ثبت'),
            selected: mode == 'price',
            onSelected: (_) => setState(() => mode = 'price')),
        const SizedBox(width: 8),
        ChoiceChip(
            label: const Text('شاخص‌های رنج — فقط تغییرات'),
            selected: mode == 'indicators',
            onSelected: (_) => setState(() => mode = 'indicators')),
      ]),
      if (mode == 'indicators')
        Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(spacing: 6, runSpacing: 0, children: [
              for (final id in indicatorIds)
                FilterChip(
                    avatar: CircleAvatar(
                        backgroundColor: indicatorColors[id], radius: 6),
                    label: Text(indicatorLabels[id]!),
                    selected: indicatorOn.contains(id),
                    onSelected: (v) => setState(() {
                          v ? indicatorOn.add(id) : indicatorOn.remove(id);
                        }))
            ])),
      FutureBuilder<List<Quote>>(
          future: future,
          builder: (context, snap) {
            if (snap.hasError) {
              return infoBox('خطای خواندن تاریخچه',
                  'داده قابل خواندن نیست؛ اپ را دوباره باز کنید.',
                  color: Colors.red);
            }
            if (!snap.hasData) {
              return const Padding(
                  padding: EdgeInsets.all(50),
                  child: Center(child: CircularProgressIndicator()));
            }
            final f = widget.c.filter;
            final series = snap.data!.where((q) {
              final p = q.tomanFor(f.basis);
              return cityMatches(q, widget.c.selectedCity) &&
                  p != null &&
                  (days == 0 ||
                      DateTime.now().toUtc().difference(q.fetchedAt).inDays <=
                          days) &&
                  (f.minPrice == null || p >= f.minPrice!) &&
                  (f.maxPrice == null || p <= f.maxPrice!) &&
                  q.comparisonGroup(f.basis) ==
                      current.comparisonGroup(f.basis);
            }).toList();
            // The same rows, seen as recorded indicator changes instead of
            // receipts: one point per moment the mean/high/low actually moved,
            // under the range tab's own window.
            final indicatorData = mode == 'indicators'
                ? indicatorChanges(series,
                    basis: f.basis,
                    window: widget.c.rangeWindow > 0
                        ? Duration(days: widget.c.rangeWindow)
                        : null)
                : null;
            final visibleIndicators = [
              for (final id in indicatorIds)
                if (indicatorOn.contains(id)) id
            ];
            DateTime? firstChangeAt, lastChangeAt;
            if (indicatorData != null) {
              for (final id in visibleIndicators) {
                final points = indicatorData.changes[id]!;
                if (points.isEmpty) continue;
                final first = points.first.at, last = points.last.at;
                if (firstChangeAt == null || first.isBefore(firstChangeAt)) {
                  firstChangeAt = first;
                }
                if (lastChangeAt == null || last.isAfter(lastChangeAt)) {
                  lastChangeAt = last;
                }
              }
            }
            return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      'نمایش ${fmt(snap.data!.length)} ثبت خوانده‌شده؛ ابتدا حداکثر ${fmt(historyLimit)} ثبت آخر بارگذاری می‌شود.',
                      style: const TextStyle(fontSize: 11, color: muted)),
                  if (snap.data!.length >= historyLimit)
                    OutlinedButton(
                        onPressed: () => setState(() {
                              historyLimit += 1000;
                              load(current.id);
                            }),
                        child: const Text('خواندن ۱۰۰۰ ثبت قدیمی‌تر')),
                  infoBox('تاریخچه محلی و واقعی',
                      'نقطه‌ها از دریافت‌های همین دستگاه ساخته می‌شوند، نه آرشیو تاریخی بازار. محور افقی زمان ثبت در اپ است؛ تاریخ اعلام منبع کنار هر نقطه آمده. ثبت تکراری بدون تغییر، نقطه جدید نمی‌سازد.'),
                  if (series.length > 1000)
                    const Text(
                        'نمودار با حفظ کمینه/بیشینه خلاصه می‌شود؛ همه ثبت‌های خوانده‌شده در سری و آمار باقی می‌مانند.',
                        style: TextStyle(fontSize: 10, color: muted)),
                  if (series.isEmpty)
                    emptyState('نقطه‌ای در این بازه نیست',
                        'بازه یا محدودیت قیمت را تغییر دهید.')
                  else if (mode == 'indicators') ...[
                    if (visibleIndicators.isEmpty)
                      infoBox('هیچ شاخصی انتخاب نشده است',
                          'برای رسم تغییرات، دست‌کم یکی از میانگین/بالاترین/پایین‌ترین را روشن کنید.')
                    else if (indicatorData!.changes['mean']!.isEmpty)
                      emptyState('تغییری در این بازه ثبت نشده است',
                          'شاخص‌ها در این بازه عدد تازه‌ای پیدا نکرده‌اند؛ بازه زمانی را تغییر دهید.')
                    else
                      Card(
                          child: Padding(
                              padding: const EdgeInsets.all(18),
                              child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    for (final id in visibleIndicators)
                                      Text(
                                          '${indicatorLabels[id]}: ${fmt(indicatorData.changes[id]!.last.value, decimals: 2)} تومان${indicatorData.changes[id]!.length > 1 ? ' • ${fmt(indicatorData.changes[id]!.length)} تغییر ثبت شده' : ''}',
                                          style: TextStyle(
                                              color: indicatorColors[id],
                                              fontWeight: FontWeight.bold,
                                              fontSize: 15)),
                                    const SizedBox(height: 16),
                                    SizedBox(
                                        height: 220,
                                        width: double.infinity,
                                        child: RepaintBoundary(
                                            child: CustomPaint(
                                                painter: IndicatorChartPainter({
                                                  for (final id
                                                      in visibleIndicators)
                                                    id: [
                                                      for (final c
                                                          in indicatorData
                                                              .changes[id]!)
                                                        c.value
                                                    ]
                                                }, {
                                                  for (final id
                                                      in visibleIndicators)
                                                    id: [
                                                      for (final c
                                                          in indicatorData
                                                              .changes[id]!)
                                                        c.at
                                                            .millisecondsSinceEpoch
                                                            .toDouble()
                                                    ]
                                                }, {
                                                  for (final id
                                                      in visibleIndicators)
                                                    id: indicatorColors[id]!
                                                })))),
                                    Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          Text(
                                              dateLabel(firstChangeAt!,
                                                  time: false),
                                              style: const TextStyle(
                                                  fontSize: 10,
                                                  color: muted)),
                                          Text(
                                              dateLabel(lastChangeAt!,
                                                  time: false),
                                              style: const TextStyle(
                                                  fontSize: 10,
                                                  color: muted))
                                        ])
                                  ]))),
                  ] else
                    Card(
                        child: Padding(
                            padding: const EdgeInsets.all(18),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                      '${fmt(series.last.tomanFor(f.basis), decimals: 2)} تومان',
                                      style: const TextStyle(
                                          fontSize: 28,
                                          color: teal,
                                          fontWeight: FontWeight.bold)),
                                  Text(
                                      'به ازای ${current.unitName(f.basis == 'kg' ? 'kg' : current.unit)} • ${current.tax}',
                                      style: const TextStyle(
                                          fontSize: 12, color: muted)),
                                  const SizedBox(height: 20),
                                  SizedBox(
                                      height: 220,
                                      width: double.infinity,
                                      child: RepaintBoundary(
                                          child: CustomPaint(
                                              painter: PriceChartPainter(
                                                  series
                                                      .map((q) =>
                                                          q.tomanFor(f.basis)!)
                                                      .toList(),
                                                  series
                                                      .map((q) => q.fetchedAt
                                                          .millisecondsSinceEpoch
                                                          .toDouble())
                                                      .toList())))),
                                  Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                            dateLabel(series.first.fetchedAt,
                                                time: false),
                                            style: const TextStyle(
                                                fontSize: 10, color: muted)),
                                        Text(
                                            dateLabel(series.last.fetchedAt,
                                                time: false),
                                            style: const TextStyle(
                                                fontSize: 10, color: muted))
                                      ])
                                ]))),
                  if (series.length == 1)
                    infoBox('یک نقطه واقعی ثبت شده',
                        'برای رسم روند، حداقل دو اعلام متفاوت لازم است. با نوسازی‌های بعدی داده واقعی اضافه می‌شود.'),
                  const SizedBox(height: 16),
                  const Text('ثبت‌های این سری',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  for (final q in series.reversed.take(100))
                    ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                            '${fmt(q.tomanFor(f.basis), decimals: 2)} تومان',
                            style:
                                const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text(
                            'ثبت: ${dateLabel(q.fetchedAt)}\nاعلام: ${sourceDay(q)}',
                            style: const TextStyle(fontSize: 11, height: 1.8)),
                        trailing: IconButton(
                            onPressed: () => openLink(context, q.sourceUrl),
                            icon: const Icon(Icons.open_in_new, size: 18))),
                ]);
          }),
    ]);
  }
}

class PriceChartPainter extends CustomPainter {
  final List<double> values, times;
  PriceChartPainter(this.values, this.times);
  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final lo = values.reduce(math.min), hi = values.reduce(math.max);
    final pad = math.max((hi - lo) * .2, math.max(hi * .015, 1));
    final low = lo - pad, high = hi + pad;
    const left = 58.0, right = 12.0, top = 12.0, bottom = 14.0;
    final width = math.max(size.width - left - right, 1),
        height = size.height - top - bottom;
    final start = times.first, end = times.last;
    Offset point(int i) => Offset(
        left + (end == start ? .5 : (times[i] - start) / (end - start)) * width,
        top + (1 - (values[i] - low) / (high - low)) * height);
    final grid = Paint()
      ..color = const Color(0xffdce6eb)
      ..strokeWidth = 1;
    for (var i = 0; i < 4; i++) {
      final y = top + i * height / 3;
      canvas.drawLine(Offset(left, y), Offset(size.width - right, y), grid);
      final label = fmt(high - i * (high - low) / 3);
      final tp = TextPainter(
          text: TextSpan(
              text: label,
              style: const TextStyle(
                  color: muted, fontFamily: 'Vazirmatn', fontSize: 9)),
          textDirection: TextDirection.rtl)
        ..layout(maxWidth: 52);
      tp.paint(canvas, Offset(left - tp.width - 6, y - 6));
    }
    final indices = chartSampleIndices(values);
    final line = Path()..moveTo(point(0).dx, point(0).dy);
    for (var j = 1; j < indices.length; j++) {
      final i = indices[j], previous = indices[j - 1];
      line.lineTo(point(i).dx, point(previous).dy);
      line.lineTo(point(i).dx, point(i).dy);
    }
    if (indices.length > 1) {
      final lastPt = point(indices.last);
      final firstPt = point(0);
      final fill = Path.from(line)
        ..lineTo(lastPt.dx, top + height)
        ..lineTo(firstPt.dx, top + height)
        ..close();
      canvas.drawPath(
          fill,
          Paint()
            ..shader = LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [teal.withOpacity(.18), teal.withOpacity(.0)])
                .createShader(
                    Rect.fromLTWH(left, top, width.toDouble(), height)));
    }
    canvas.drawPath(
        line,
        Paint()
          ..color = teal
          ..strokeWidth = 2.5
          ..style = PaintingStyle.stroke);
    for (final i in indices) {
      canvas.drawCircle(point(i), 3.5, Paint()..color = teal);
    }
  }

  @override
  bool shouldRepaint(PriceChartPainter oldDelegate) =>
      !listEquals(values, oldDelegate.values) ||
      !listEquals(times, oldDelegate.times);
}

/// Which indicators the range tab defines, in drawing order, with the labels
/// and line colors the chart uses for them.
const indicatorIds = ['mean', 'high', 'low'];
const indicatorLabels = {
  'mean': 'میانگین',
  'high': 'بالاترین',
  'low': 'پایین‌ترین',
};
const indicatorColors = {
  'mean': Color(0xff0f7f7a),
  'high': Color(0xffc76b1d),
  'low': Color(0xff5a5fc4),
};

/// One recorded moment when an indicator value moved.
class IndicatorChange {
  /// The receipt whose evaluation produced the value (the point's x-axis).
  final DateTime at;
  final double value;

  /// Change against the previously recorded point, in percent; the first
  /// point of a series starts at 0.
  final double changePct;
  const IndicatorChange(this.at, this.value, this.changePct);
}

/// The recorded changes of one product's indicators: mean/high/low, each
/// emitting a point only when its value actually changed.
class IndicatorSeries {
  final int records;
  final Map<String, List<IndicatorChange>> changes;
  const IndicatorSeries(this.records, this.changes);
  bool get isEmpty => records == 0;
}

/// The range tab's own indicators, evaluated at every receipt.
///
/// At each record's `fetchedAt` the current set — every priced record up to
/// that moment, or the ones inside [window] when given (null = the whole
/// stored history, matching «همه زمان‌ها») — is projected to mean/high/low in
/// the chosen [basis], exactly like the range tab counts them. A point is
/// emitted only when the value differs from the last emitted one, so repeated
/// receipts that did not move a number register no change. Records without a
/// valid toman price never influence any indicator.
IndicatorSeries indicatorChanges(List<Quote> records,
    {required String basis, Duration? window}) {
  // Chronological evaluation order; equal timestamps keep the input order, so
  // the answer never depends on map or sort instability.
  final ordered = [
    for (var i = 0; i < records.length; i++) (records[i], i)
  ]..sort((a, b) {
      final c = a.$1.fetchedAt.compareTo(b.$1.fetchedAt);
      return c != 0 ? c : a.$2.compareTo(b.$2);
    });
  final changes = <String, List<IndicatorChange>>{
    'mean': <IndicatorChange>[],
    'high': <IndicatorChange>[],
    'low': <IndicatorChange>[],
  };
  final prices = <double>[];
  final times = <DateTime>[];
  for (final item in ordered) {
    final p = item.$1.tomanFor(basis);
    if (p != null && p.isFinite && p > 0) {
      prices.add(p);
      times.add(item.$1.fetchedAt);
    }
  }
  if (prices.isEmpty) return IndicatorSeries(records.length, changes);

  // Sliding window O(N): running sum + monotonic deques for window high/low.
  final maxQ = ListQueue<int>();
  final minQ = ListQueue<int>();
  var left = 0;
  var sum = 0.0;
  double? lastMean, lastHigh, lastLow;

  for (var i = 0; i < prices.length; i++) {
    final at = times[i];
    final price = prices[i];
    sum += price;
    while (maxQ.isNotEmpty && prices[maxQ.last] <= price) {
      maxQ.removeLast();
    }
    maxQ.addLast(i);
    while (minQ.isNotEmpty && prices[minQ.last] >= price) {
      minQ.removeLast();
    }
    minQ.addLast(i);

    if (window != null) {
      final cutoff = at.subtract(window);
      while (left <= i && !times[left].isAfter(cutoff)) {
        sum -= prices[left];
        if (maxQ.isNotEmpty && maxQ.first == left) maxQ.removeFirst();
        if (minQ.isNotEmpty && minQ.first == left) minQ.removeFirst();
        left++;
      }
    }
    final count = i - left + 1;
    if (count <= 0) continue;
    final mean = sum / count;
    final high = prices[maxQ.first];
    final low = prices[minQ.first];
    if (lastMean == null || mean != lastMean) {
      changes['mean']!.add(IndicatorChange(
          at, mean, lastMean == null ? 0 : (mean - lastMean) / lastMean * 100));
      lastMean = mean;
    }
    if (lastHigh == null || high != lastHigh) {
      changes['high']!.add(IndicatorChange(at, high,
          lastHigh == null ? 0 : (high - lastHigh) / lastHigh * 100));
      lastHigh = high;
    }
    if (lastLow == null || low != lastLow) {
      changes['low']!.add(IndicatorChange(
          at, low, lastLow == null ? 0 : (low - lastLow) / lastLow * 100));
      lastLow = low;
    }
  }
  return IndicatorSeries(records.length, changes);
}

/// Draws the selected indicator change-lines: one step-line per indicator,
/// sampled with the same chronological min/max rule as the price chart, never
/// smoothed and never interpolated between recorded points.
class IndicatorChartPainter extends CustomPainter {
  final Map<String, List<double>> values, times;
  final Map<String, Color> colors;
  IndicatorChartPainter(this.values, this.times, this.colors);
  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    var lo = double.infinity, hi = double.negativeInfinity;
    for (final list in values.values) {
      for (final v in list) {
        if (v < lo) lo = v;
        if (v > hi) hi = v;
      }
    }
    if (!lo.isFinite || !hi.isFinite) return;
    final pad = math.max((hi - lo) * .2, math.max(hi * .015, 1));
    final low = lo - pad, high = hi + pad;
    const left = 58.0, right = 12.0, top = 12.0, bottom = 14.0;
    final width = math.max(size.width - left - right, 1),
        height = math.max(size.height - top - bottom, 1);
    final grid = Paint()
      ..color = const Color(0xffdce6eb)
      ..strokeWidth = 1;
    for (var i = 0; i < 4; i++) {
      final y = top + i * height / 3;
      canvas.drawLine(Offset(left, y), Offset(size.width - right, y), grid);
      final label = fmt(high - i * (high - low) / 3);
      final tp = TextPainter(
          text: TextSpan(
              text: label,
              style: const TextStyle(
                  color: muted, fontFamily: 'Vazirmatn', fontSize: 9)),
          textDirection: TextDirection.rtl)
        ..layout(maxWidth: 52);
      tp.paint(canvas, Offset(left - tp.width - 6, y - 6));
    }
    for (final id in values.keys) {
      final list = values[id]!;
      if (list.isEmpty) continue;
      final timesOf = times[id]!;
      final color = colors[id] ?? teal;
      final start = timesOf.first, end = timesOf.last;
      Offset point(int i) => Offset(
          left + (end == start ? .5 : (timesOf[i] - start) / (end - start)) * width,
          top + (1 - (list[i] - low) / (high - low)) * height);
      final indices = chartSampleIndices(list);
      final line = Path()..moveTo(point(0).dx, point(0).dy);
      for (var j = 1; j < indices.length; j++) {
        final i = indices[j], previous = indices[j - 1];
        line.lineTo(point(i).dx, point(previous).dy);
        line.lineTo(point(i).dx, point(i).dy);
      }
      canvas.drawPath(
          line,
          Paint()
            ..color = color
            ..strokeWidth = 2.2
            ..style = PaintingStyle.stroke);
      for (final i in indices) {
        canvas.drawCircle(point(i), 3, Paint()..color = color);
      }
    }
  }

  @override
  bool shouldRepaint(IndicatorChartPainter oldDelegate) =>
      !mapEquals(values, oldDelegate.values) ||
      !mapEquals(times, oldDelegate.times) ||
      !mapEquals(colors, oldDelegate.colors);
}

class QuoteSearch extends SearchDelegate<Quote?> {
  final List<Quote> quotes;
  QuoteSearch(this.quotes)
      : super(searchFieldLabel: 'جستجوی کالا، سایز یا فروشنده');
  @override
  List<Widget> buildActions(BuildContext context) =>
      [IconButton(onPressed: () => query = '', icon: const Icon(Icons.clear))];
  @override
  Widget buildLeading(BuildContext context) => IconButton(
      onPressed: () => close(context, null),
      icon: const Icon(Icons.arrow_back));
  @override
  Widget buildResults(BuildContext context) => buildSuggestions(context);
  @override
  Widget buildSuggestions(BuildContext context) => _AsyncQuoteSearchView(
        quotes: quotes,
        query: query,
        onSelect: (q) => close(context, q),
      );
}

class _AsyncQuoteSearchView extends StatefulWidget {
  final List<Quote> quotes;
  final String query;
  final ValueChanged<Quote> onSelect;
  const _AsyncQuoteSearchView({
    required this.quotes,
    required this.query,
    required this.onSelect,
  });

  @override
  State<_AsyncQuoteSearchView> createState() => _AsyncQuoteSearchViewState();
}

class _AsyncQuoteSearchViewState extends State<_AsyncQuoteSearchView> {
  static const int _maxResults = 300;
  static const int _syncThreshold = 500;
  static final RegExp _numericTokenOnly = RegExp(r'^\d+(?:\.\d+)?$');

  Timer? _debounce;
  int _runSeq = 0;
  bool _searching = false;
  List<Quote> _items = const [];

  @override
  void initState() {
    super.initState();
    _schedule(widget.query, immediate: true, fromInit: true);
  }

  @override
  void didUpdateWidget(_AsyncQuoteSearchView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query ||
        !identical(oldWidget.quotes, widget.quotes)) {
      _schedule(widget.query,
          immediate: widget.quotes.length <= _syncThreshold);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _schedule(String rawQuery,
      {bool immediate = false, bool fromInit = false}) {
    _debounce?.cancel();
    final seq = ++_runSeq;
    if (widget.quotes.length <= _syncThreshold) {
      final results = _searchSync(widget.quotes, rawQuery);
      if (fromInit) {
        _items = results;
        _searching = false;
      } else {
        setState(() {
          _items = results;
          _searching = false;
        });
      }
      return;
    }
    if (fromInit) {
      if (rawQuery.trim().isEmpty) {
        _items = widget.quotes.take(_maxResults).toList(growable: false);
        _searching = false;
        return;
      }
      _searching = true;
    } else if (!_searching) {
      setState(() => _searching = true);
    }
    if (immediate) {
      unawaited(_runSliced(seq, rawQuery));
    } else {
      _debounce = Timer(const Duration(milliseconds: 120), () {
        if (!mounted || seq != _runSeq) return;
        unawaited(_runSliced(seq, rawQuery));
      });
    }
  }

  static List<Quote> _searchSync(List<Quote> quotes, String rawQuery) {
    final needle = ProductText.normalizeLower(rawQuery).trim();
    if (needle.isEmpty) {
      return quotes.take(_maxResults).toList(growable: false);
    }
    final isExactNumber = _numericTokenOnly.hasMatch(needle);
    final exactMatches = <Quote>[];
    final fallback = <Quote>[];
    final parsed = isExactNumber ? null : ProductQuery.parse(needle);

    for (final q in quotes) {
      if (isExactNumber) {
        if (_exactNumberMatch(q, needle)) {
          exactMatches.add(q);
          if (exactMatches.length >= _maxResults) break;
        } else if (fallback.length < _maxResults &&
            _substringNumberMatch(q, needle)) {
          fallback.add(q);
        }
      } else {
        if (_matchesQuery(parsed!, q, needle)) {
          exactMatches.add(q);
          if (exactMatches.length >= _maxResults) break;
        }
      }
    }
    if (isExactNumber && exactMatches.length < _maxResults) {
      for (final q in fallback) {
        exactMatches.add(q);
        if (exactMatches.length >= _maxResults) break;
      }
    }
    return exactMatches;
  }

  static bool _matchesQuery(ProductQuery parsed, Quote q, String needle) =>
      q.searchText.contains(needle) ||
      parsed.matches(
        text: q.searchText,
        category: q.category,
        material: q.material,
        size: q.sizeLabel,
        thickness: q.thicknessLabel,
        dimensions: q.dimensionsLabel,
        grade: q.gradeLabel,
        sellerCity: q.sellerCity,
        normalizedText: true,
      );

  static bool _exactNumberMatch(Quote q, String token) {
    final numVal = double.tryParse(token);
    if (numVal != null) {
      final sNum =
          q.sizeLabel.isEmpty ? null : double.tryParse(latin(q.sizeLabel));
      if (sNum != null && (sNum - numVal).abs() < 1e-6) return true;
      final tNum = q.thicknessLabel.isEmpty
          ? null
          : double.tryParse(latin(q.thicknessLabel));
      if (tNum != null && (tNum - numVal).abs() < 1e-6) return true;
      if (q.amount != null &&
          q.amount! > 0 &&
          (q.amount! - numVal).abs() < 1e-6) {
        return true;
      }
    }
    return _fieldHasNumberToken(q.title, token) ||
        _fieldHasNumberToken(q.specificationLabel, token) ||
        _fieldHasNumberToken(q.seller, token) ||
        _fieldHasNumberToken(q.loading, token);
  }

  static bool _fieldHasNumberToken(String field, String token) {
    if (field.isEmpty) return false;
    final norm = ProductText.normalizeLower(field);
    return ProductQuery.containsNumberToken(norm, token);
  }

  static bool _substringNumberMatch(Quote q, String token) =>
      (q.title.isNotEmpty &&
          ProductText.normalizeLower(q.title).contains(token)) ||
      (q.specificationLabel.isNotEmpty &&
          ProductText.normalizeLower(q.specificationLabel).contains(token)) ||
      (q.seller.isNotEmpty &&
          ProductText.normalizeLower(q.seller).contains(token)) ||
      (q.loading.isNotEmpty &&
          ProductText.normalizeLower(q.loading).contains(token));

  Future<void> _runSliced(int seq, String rawQuery) async {
    final quotes = widget.quotes;
    final needle = ProductText.normalizeLower(rawQuery).trim();
    if (needle.isEmpty) {
      final head = quotes.take(_maxResults).toList(growable: false);
      if (!mounted || seq != _runSeq) return;
      setState(() {
        _items = head;
        _searching = false;
      });
      return;
    }

    final isExactNumber = _numericTokenOnly.hasMatch(needle);
    final parsed = isExactNumber ? null : ProductQuery.parse(needle);
    final exactMatches = <Quote>[];
    final fallback = <Quote>[];

    var i = 0;
    while (i < quotes.length) {
      if (!mounted || seq != _runSeq) return;
      final sw = Stopwatch()..start();
      final sliceEnd = (i + 2500).clamp(0, quotes.length);
      while (i < sliceEnd) {
        final chunkEnd = (i + 64).clamp(0, sliceEnd);
        for (; i < chunkEnd; i++) {
          final q = quotes[i];
          if (isExactNumber) {
            if (_exactNumberMatch(q, needle)) {
              exactMatches.add(q);
              if (exactMatches.length >= _maxResults) break;
            } else if (fallback.length < _maxResults &&
                _substringNumberMatch(q, needle)) {
              fallback.add(q);
            }
          } else {
            if (_matchesQuery(parsed!, q, needle)) {
              exactMatches.add(q);
              if (exactMatches.length >= _maxResults) break;
            }
          }
        }
        if (exactMatches.length >= _maxResults) break;
        if (sw.elapsedMilliseconds >= 5) break;
      }
      if (exactMatches.length >= _maxResults) break;
      if (i < quotes.length) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    if (!mounted || seq != _runSeq) return;
    if (isExactNumber && exactMatches.length < _maxResults) {
      for (final q in fallback) {
        exactMatches.add(q);
        if (exactMatches.length >= _maxResults) break;
      }
    }
    setState(() {
      _items = exactMatches;
      _searching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_searching && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty) {
      return const Center(
          child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('موردی پیدا نشد.', style: TextStyle(color: muted))));
    }
    return Column(
      children: [
        if (_searching) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: ListView.builder(
              itemCount: _items.length + 1,
              itemBuilder: (ctx, i) {
                if (i == 0) {
                  return ListTile(
                      title: Text(_searching
                          ? 'در حال جستجو...'
                          : 'حداکثر ۳۰۰ نتیجه؛ برای انتخاب دقیق، نام و سایز را جستجو کنید.'),
                      dense: true);
                }
                final q = _items[i - 1];
                return ListTile(
                    title: Text(faDigits(q.title)),
                    subtitle: Text(faDigits(
                        '${q.specificationLabel} • ${q.seller} • ${q.loading}')),
                    onTap: () => widget.onSelect(q));
              }),
        ),
      ],
    );
  }
}

// At most 1000 real sample points, with chronological min/max in every bucket.
// No synthetic prices, averaging or changes to the underlying series.
List<int> chartSampleIndices(List<double> values, {int maxPoints = 1000}) {
  if (values.length <= maxPoints) return List.generate(values.length, (i) => i);
  final buckets = (maxPoints - 2) ~/ 2;
  if (buckets < 1) throw ArgumentError('maxPoints must be at least 4');
  final indices = <int>[0];
  for (var b = 0; b < buckets; b++) {
    final start = 1 + (values.length - 2) * b ~/ buckets;
    final end = 1 + (values.length - 2) * (b + 1) ~/ buckets;
    var minIndex = start, maxIndex = start;
    for (var i = start + 1; i < end; i++) {
      if (values[i] < values[minIndex]) minIndex = i;
      if (values[i] > values[maxIndex]) maxIndex = i;
    }
    if (minIndex == maxIndex) {
      indices.add(minIndex);
    } else if (minIndex < maxIndex) {
      indices.addAll([minIndex, maxIndex]);
    } else {
      indices.addAll([maxIndex, minIndex]);
    }
  }
  indices.add(values.length - 1);
  return indices;
}
