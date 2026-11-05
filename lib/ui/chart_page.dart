import 'dart:math' as math;
import 'dart:async';
import '../data/app_logger.dart';
import 'package:flutter/material.dart';
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
  int days = 30;
  Future<List<Quote>>? future;
  String lastSignature = '';
  int loadedRevision = -1;
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
    selected = id;
    loadedRevision = widget.c.historyRevision;
    unawaited(AppLogger.instance.record('chart', 'series_selected'));
    future = widget.c.store.history(id);
    lastSignature =
        widget.c.quotes.where((q) => q.id == id).firstOrNull?.signature ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final options = widget.c.filtered
        .where((q) => q.priceFor(widget.c.filter.basis) != null)
        .toList();
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
        loadedRevision != widget.c.historyRevision) {
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
          label: Text('${current.title} • ${current.seller}',
              maxLines: 2, overflow: TextOverflow.ellipsis),
          onPressed: () async {
            final q = await showSearch<Quote?>(
                context: context, delegate: QuoteSearch(options));
            if (q != null && mounted) setState(() => load(q.id));
          }),
      const SizedBox(height: 16),
      selectField(
          'بازه ثبت روی دستگاه',
          '$days',
          {
            '7': '۷ روز',
            '30': '۳۰ روز',
            '90': '۹۰ روز',
            '0': 'همه تاریخچه دستگاه'
          },
          (v) => setState(() => days = int.parse(v))),
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
              final p = q.priceFor(f.basis);
              return p != null &&
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
                  infoBox('تاریخچه محلی و واقعی',
                      'نقطه‌ها از دریافت‌های همین دستگاه ساخته می‌شوند، نه آرشیو تاریخی بازار. محور افقی زمان ثبت در اپ است؛ تاریخ اعلام منبع کنار هر نقطه آمده. ثبت تکراری بدون تغییر، نقطه جدید نمی‌سازد.'),
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
                                      '${fmt(series.last.priceFor(f.basis))} ${current.currency}',
                                      style: const TextStyle(
                                          fontSize: 28,
                                          color: teal,
                                          fontWeight: FontWeight.bold)),
                                  Text(
                                      'به ازای ${unitLabel(f.basis == 'kg' ? 'kg' : current.unit)} • ${current.tax}',
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
                                                      q.priceFor(f.basis)!)
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
                        title: Text('${fmt(q.priceFor(f.basis))} ${q.currency}',
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
    final line = Path()..moveTo(point(0).dx, point(0).dy);
    for (var i = 1; i < values.length; i++) {
      line.lineTo(point(i).dx, point(i - 1).dy);
      line.lineTo(point(i).dx, point(i).dy);
    }
    canvas.drawPath(
        line,
        Paint()
          ..color = teal
          ..strokeWidth = 2.5
          ..style = PaintingStyle.stroke);
    for (var i = 0; i < values.length; i++) {
      canvas.drawCircle(point(i), 3.5, Paint()..color = teal);
    }
  }

  @override
  bool shouldRepaint(PriceChartPainter oldDelegate) => true;
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
              title: Text(q.title),
              subtitle:
                  Text('${q.specificationLabel} • ${q.seller} • ${q.loading}'),
              onTap: () => close(context, q));
        });
  }
}
