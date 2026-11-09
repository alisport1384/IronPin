import '../domain/city_scope.dart';
import 'dart:math' as math;
import 'dart:async';
import '../data/app_logger.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../domain/money.dart';
import '../data/controller.dart';
import '../domain/market.dart';
import 'common.dart';
import 'prices_page.dart';

class ChartPage extends StatefulWidget {
  final MarketController c;
  final String? selectedId;
  const ChartPage({super.key, required this.c, this.selectedId});
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
    final quote = widget.c.quotes.where((q) => q.id == id).firstOrNull;
    loadedKey = historyKey(quote?.endpoint ?? '');
    unawaited(AppLogger.instance.record('chart', 'series_selected'));
    future = widget.c.store.history(id,
        since: days == 0
            ? null
            : DateTime.now().toUtc().subtract(Duration(days: days)),
        limit: historyLimit);
    lastSignature =
        widget.c.quotes.where((q) => q.id == id).firstOrNull?.signature ?? '';
  }

  @override
  Widget build(BuildContext context) {
    // Every stored offer with a real price in the chart basis, not only the rows
    // of the current feed window: an older product keeps a chart.
    final options = widget.c.chartOptions;
    if (options.isEmpty) {
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
    if (!options.any((q) => q.id == selected)) {
      selected = options.first.id;
      future = null;
    }
    final current = options.firstWhere((q) => q.id == selected);
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
                  else
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
                                                  .toList()))),
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
  Widget buildSuggestions(BuildContext context) {
    final needle = latin(query).toLowerCase();
    final items =
        quotes.where((q) => q.searchText.contains(needle)).take(300).toList();
    return ListView.builder(
        itemCount: items.length + 1,
        itemBuilder: (ctx, i) {
          if (i == 0) {
            return const ListTile(
                title: Text(
                    'حداکثر ۳۰۰ نتیجه؛ برای انتخاب دقیق، نام و سایز را جستجو کنید.'),
                dense: true);
          }
          final q = items[i - 1];
          return ListTile(
              title: Text(faDigits(q.title)),
              subtitle: Text(faDigits(
                  '${q.specificationLabel} • ${q.seller} • ${q.loading}')),
              onTap: () => close(context, q));
        });
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
