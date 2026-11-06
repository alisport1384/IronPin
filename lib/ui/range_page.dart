import 'dart:async';
import 'package:flutter/material.dart';
import '../data/app_logger.dart';
import '../data/controller.dart';
import '../domain/calculator.dart';
import '../domain/market.dart';
import '../domain/money.dart';
import '../domain/price_range.dart';
import 'calculator_page.dart';
import 'common.dart';

class RangePage extends StatefulWidget {
  final MarketController c;
  const RangePage({super.key, required this.c});
  @override
  State<RangePage> createState() => _RangePageState();
}

class _RangePageState extends State<RangePage> {
  Future<RangeReport>? future;
  int revision = -1;
  String? selected;
  String choice = 'mean', query = '';
  int visibleProducts = 40;
  final search = TextEditingController();
  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  void load() {
    revision = widget.c.historyRevision;
    future = widget.c.store.rangeReport(DateTime.now());
  }

  @override
  Widget build(BuildContext context) {
    if (future == null || revision != widget.c.historyRevision) load();
    return FutureBuilder<RangeReport>(
        future: future,
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(
                child: infoBox('خطای خواندن رنج',
                    'داده محلی خوانده نشد. بدون حذف داده، برنامه را دوباره باز کنید.',
                    color: Colors.red));
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final report = snap.data!;
          final needle = latin(query).toLowerCase();
          final options = report.products
              .where((r) => r.searchText.contains(needle))
              .toList();
          final product =
              report.products.where((p) => p.key == selected).firstOrNull;
          final range = product?.range;
          if (product == null) selected = null;
          return ListView(padding: const EdgeInsets.all(14), children: [
            const Text('رنج‌گیری ۴۸ ساعت',
                style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text(
                'همه اعلام‌های واقعی، از همه فروشندگان و شهرها؛ نه فقط آخرین نرخ هر فروشنده.',
                style: TextStyle(fontSize: 12, height: 1.8)),
            Text('تا ${dateLabel(report.at)} • فقط داده موجود روی دستگاه',
                style: const TextStyle(color: muted, fontSize: 10)),
            Text(
                '${fmt(report.products.length)} کالا در فهرست • ${fmt(report.ranges.length)} گروه دارای رنج معتبر',
                style: const TextStyle(color: muted, fontSize: 11)),
            const SizedBox(height: 12),
            TextField(
                controller: search,
                decoration: const InputDecoration(
                    labelText: 'انتخاب کالای دقیق؛ عنوان، برند و مشخصات',
                    prefixIcon: Icon(Icons.search)),
                onChanged: (v) => setState(() {
                      query = v;
                      visibleProducts = 40;
                    })),
            const SizedBox(height: 8),
            if (product != null)
              Card(
                  child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(faDigits(product.label)))),
            if (selected == null || query.isNotEmpty) ...[
              for (final r in options.take(visibleProducts))
                ListTile(
                    dense: true,
                    title: Text(faDigits(r.label),
                        style: const TextStyle(fontSize: 12)),
                    subtitle: Text(r.range == null
                        ? 'رنج فعلاً در دسترس نیست • ${r.unavailableReasons.join('؛ ')}'
                        : '${fmt(r.range!.announcements.length)} اعلام • ${fmt(r.range!.sellers)} فروشنده'),
                    trailing: const Icon(Icons.chevron_left),
                    onTap: () => setState(() {
                          selected = r.key;
                          query = '';
                          search.clear();
                          choice = 'mean';
                          FocusScope.of(context).unfocus();
                        })),
              Text(
                  'نمایش ${fmt(options.length < visibleProducts ? options.length : visibleProducts)} از ${fmt(options.length)} کالا',
                  style: const TextStyle(color: muted, fontSize: 11)),
              if (options.length > visibleProducts)
                OutlinedButton(
                    onPressed: () => setState(() => visibleProducts += 40),
                    child: const Text('نمایش ۴۰ کالای بعدی')),
              if (options.isEmpty && report.products.isNotEmpty)
                infoBox('کالایی با این جستجو پیدا نشد',
                    'عنوان، دسته یا مشخصات را کوتاه‌تر جستجو کنید. نبود رنج معتبر باعث حذف کالا از فهرست نمی‌شود.'),
            ],
            if (product != null) ...[
              TextButton(
                  onPressed: () => setState(() {
                        selected = null;
                        query = '';
                        search.clear();
                      }),
                  child: const Text('انتخاب کالای دیگر')),
            ],
            if (product != null && range == null)
              infoBox('برای این کالا فعلاً رنج معتبر نداریم',
                  '${product.unavailableReasons.join('\n')}\nکالا از فهرست حذف نشده است. بدون تاریخ، ارز، واحد و مشخصات معتبر، قیمت و میانگین ساختگی نمایش داده نمی‌شود.'),
            if (range != null) ...[
              for (final item in [
                ('کمترین نرخ', range.minimum),
                ('بیشترین نرخ', range.maximum),
                ('میانگین گرد‌شده', range.roundedMean.toDouble())
              ])
                Card(
                    child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(item.$1,
                                  style: const TextStyle(
                                      color: muted, fontSize: 11)),
                              Text(
                                  '${fmt(item.$2, decimals: item.$1 == 'میانگین گرد‌شده' ? 0 : 2)} تومان / ${range.example.unitName(range.basis)}',
                                  style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                      color: teal)),
                              Text(
                                  '${moneyWords(item.$2)}${item.$2 == item.$2.roundToDouble() ? '' : '؛ نوشتار به نزدیک‌ترین تومان'}',
                                  style: const TextStyle(fontSize: 10)),
                            ]))),
              infoBox(
                  'مبنای آمار',
                  '${fmt(range.announcements.length)} اعلام یکتا از ${fmt(range.sellers)} فروشنده. '
                      'هر اعلام یک وزن دارد؛ تکرار دریافت یا تغییر توضیحات، اعلام تازه نیست. میانگین به نزدیک‌ترین یک تومان گرد می‌شود. '
                      'ریالِ صریح بر ده تقسیم می‌شود؛ ارز/واحد نامعلوم حذف می‌شود. مالیات و شرایط در گروه‌های جدا هستند.'),
              ExpansionTile(
                  title: const Text('اعلام‌های تشکیل‌دهنده رنج'),
                  children: [
                    for (final q in range.announcements.take(100))
                      ListTile(
                          dense: true,
                          title: Text(
                              '${faDigits(q.seller)} • ${fmt(toman(q.priceFor(range.basis), q.currency), decimals: 2)} تومان'),
                          subtitle: Text(
                              '${dateLabel(q.marketAt)} • دفتر ${faDigits(q.sellerCity)}'),
                          onTap: q.sourceUrl.isEmpty
                              ? null
                              : () => openLink(context, q.sourceUrl)),
                    if (range.announcements.length > 100)
                      Text(
                          'نمایش ۱۰۰ مورد از ${fmt(range.announcements.length)} اعلام؛ آمار بر پایه همه آن‌هاست.'),
                  ]),
              const Divider(height: 30),
              selectField(
                  'مبنای هزینه همان کالا',
                  choice,
                  {
                    'min': 'کمترین نرخ',
                    'max': 'بیشترین نرخ',
                    'mean': 'میانگین گرد‌شده'
                  },
                  (v) => setState(() => choice = v)),
              RangeCost(
                  key: ValueKey(range.key),
                  range: range,
                  rate: range.rate(choice)),
            ] else if (report.products.isEmpty)
              infoBox('هنوز کالایی روی دستگاه ذخیره نشده',
                  'دکمه نوسازی را بزنید یا بکاپ را وارد کنید. همه کالاهای ذخیره‌شده در این فهرست قابل انتخاب‌اند؛ رنج فقط از اعلام‌های معتبر ۴۸ ساعت گذشته محاسبه می‌شود.'),
            ExpansionTile(
                title: const Text('دقت، محدودیت و موارد کنارگذاشته‌شده'),
                children: [
                  const Text(
                      'فهرست انتخاب شامل همه کالاهای محفوظ محلی است؛ کالای قدیمی، بدون نرخ یا با مشخصات ناقص حذف نمی‌شود و دلیل نداشتن رنج نشان داده می‌شود. رنج فقط آرشیو محلی را پوشش می‌دهد، نه تمام بازار یا زمان خاموش‌بودن اپ. '
                      'همسانی محافظه‌کارانه است: عنوان، برند، جنس، سایز، ضخامت، ابعاد، گرید، طول و شرایط ثبت‌شده باید یکسان باشند؛ '
                      'نام‌های متفاوت خودکار یکی فرض نمی‌شوند. مشخصات اعلام‌نشده تضمین همسانی واقعی نیست. '
                      'تاریخ نرخ و در نبودش انتشار ملاک است، نه زمان دریافت. تاریخ روزانه بدون ساعت، آغاز همان روز در ایران محسوب می‌شود. '
                      'ویرایش‌های یک پیام با تاریخ اعلام یکسان، یک اعلام‌اند. در جدول بدون شناسه انتشار، نرخ یکسانِ همان ردیف و تاریخ یک اعلام محسوب می‌شود. '
                      'محاسبه نظری وزن فقط در بخش هزینه انجام می‌شود؛ در آمار و فید به کار نمی‌رود.',
                      style: TextStyle(fontSize: 11, height: 1.9)),
                  for (final e in report.excluded.entries)
                    ListTile(
                        dense: true,
                        title: Text(e.key),
                        trailing: Text(fmt(e.value))),
                  const Text(
                      'شمارش موارد کنارگذاشته‌شده مربوط به رکوردهای خوانده‌شده است؛ نه تعداد اعلام یکتا.',
                      style: TextStyle(fontSize: 10, color: muted)),
                ]),
          ]);
        });
  }
}

class RangeCost extends StatefulWidget {
  final PriceRange range;
  final double rate;
  const RangeCost({super.key, required this.range, required this.rate});
  @override
  State<RangeCost> createState() => _RangeCostState();
}

class _RangeCostState extends State<RangeCost> {
  bool geometry = false, confirmed = false;
  late String shape, inputUnit;
  final quantity = TextEditingController(text: '۱'),
      length = TextEditingController(),
      density = TextEditingController(text: '۷۸۵۰');
  final fields = <String, TextEditingController>{};
  double? total;
  WeightResult? weight;
  String? error;
  Shape get spec => shapes.firstWhere((s) => s.id == shape);
  @override
  void initState() {
    super.initState();
    final q = widget.range.example;
    if (q.material != 'فولاد کربنی') density.clear();
    shape = switch (q.category) {
      'میلگرد' || 'مفتول' => 'round',
      'ورق' || 'تسمه' => 'plate',
      'لوله' => 'pipe',
      'پروفیل' => 'rhs',
      'نبشی' => 'angle',
      'تیرآهن' || 'ناودانی' || 'هاش' || 'سپری' => 'catalog',
      _ => widget.range.basis == 'kg' ? 'bulk' : 'piece'
    };
    inputUnit = shape == 'bulk' ? 'kg' : 'piece';
    for (final f in spec.fields) {
      fields[f.key] = TextEditingController(text: f.key == 'coat' ? '۰' : '');
    }
    if (q.lengthM != null) length.text = fmt(q.lengthM, decimals: 6);
    if (shape == 'round' && singleSpecNumber(q.sizeLabel) != null) {
      fields['d']!.text = faDigits(q.sizeLabel);
    }
    if (fields.containsKey('t') && singleSpecNumber(q.thicknessLabel) != null) {
      fields['t']!.text = faDigits(q.thicknessLabel);
    }
    if (shape == 'plate' &&
        q.areaM2 != null &&
        q.lengthM != null &&
        q.lengthM! > 0) {
      fields['b']!.text = fmt(q.areaM2! / q.lengthM! * 1000, decimals: 6);
    }
    if (shape == 'catalog' &&
        q.pieceKg != null &&
        q.lengthM != null &&
        q.lengthM! > 0) {
      fields['kgm']!.text = fmt(q.pieceKg! / q.lengthM!, decimals: 6);
    }
    if (shape == 'piece' && q.pieceKg != null) {
      fields['kgpiece']!.text = fmt(q.pieceKg, decimals: 6);
    }
    if (shape == 'piece' && q.areaM2 != null) {
      fields['pieceArea']!.text = fmt(q.areaM2, decimals: 6);
    }
  }

  void clearResult() {
    total = null;
    weight = null;
    error = null;
  }

  @override
  void didUpdateWidget(RangeCost old) {
    super.didUpdateWidget(old);
    if (old.rate != widget.rate || old.range != widget.range) clearResult();
  }

  @override
  void dispose() {
    for (final c in [quantity, length, density, ...fields.values]) {
      c.dispose();
    }
    super.dispose();
  }

  double read(TextEditingController c) {
    final n = number(c.text);
    if (n == null || !n.isFinite) {
      throw const FormatException('ورودی‌های لازم را با عدد معتبر تکمیل کنید.');
    }
    return n;
  }

  Widget field(String label, TextEditingController c) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: TextField(
          controller: c,
          decoration: InputDecoration(labelText: label),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) => setState(clearResult)));
  void calculate() {
    try {
      final amount = read(quantity);
      if (amount <= 0 ||
          (!geometry &&
              ['sheet', 'roll', 'piece'].contains(widget.range.basis) &&
              amount != amount.roundToDouble())) {
        throw const FormatException(
            'مقدار باید مثبت و تعداد برگ/رول/قطعه عدد صحیح باشد.');
      }
      WeightResult? r;
      double cost;
      if (geometry) {
        if (!confirmed) {
          throw const FormatException(
              'تطبیق ابعاد و جنس با کالای انتخابی را تأیید کنید.');
        }
        final q = widget.range.example;
        if (shape == 'round' &&
            singleSpecNumber(q.sizeLabel) != null &&
            read(fields['d']!) != singleSpecNumber(q.sizeLabel)) {
          throw const FormatException(
              'قطر با کالای رنج‌گیری یکسان نیست. کالای درست را انتخاب کنید.');
        }
        if (fields.containsKey('t') &&
            singleSpecNumber(q.thicknessLabel) != null &&
            read(fields['t']!) != singleSpecNumber(q.thicknessLabel)) {
          throw const FormatException('ضخامت با کالای رنج‌گیری یکسان نیست.');
        }
        r = SteelCalculator.calculate(
            shape: shape,
            values: fields.map((k, c) => MapEntry(k, read(c))),
            density: read(density),
            inputUnit: inputUnit,
            quantity: amount,
            lengthPerPiece:
                ['bulk', 'piece', 'mesh'].contains(shape) ? 1 : read(length));
        cost = SteelCalculator.cost(
            r,
            ['sheet', 'roll'].contains(widget.range.basis)
                ? 'piece'
                : widget.range.basis,
            widget.rate);
      } else {
        cost = amount * widget.rate;
      }
      if (!cost.isFinite || cost > 9000000000000000) {
        throw const FormatException('مبلغ خارج از محدوده محاسبه است.');
      }
      setState(() {
        weight = r;
        total = cost;
        error = null;
      });
      unawaited(AppLogger.instance.record('calculation', 'range_cost', {
        'shape': geometry ? shape : 'direct',
        'basis': widget.range.basis,
        'geometry': geometry
      }));
    } catch (e) {
      setState(() {
        total = null;
        weight = null;
        error = e is FormatException ? e.message : 'ورودی معتبر نیست.';
      });
    }
  }

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SizedBox(height: 16),
        Row(children: [
          const Expanded(
              child: Text('محاسبات همان کالا',
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold))),
          IconButton(
              tooltip: 'فرمول‌ها و منابع',
              onPressed: () => showCalculationSources(context),
              icon: const Icon(Icons.menu_book_outlined))
        ]),
        Text(
            'نرخ انتخابی: ${fmt(widget.rate, decimals: 2)} تومان / ${widget.range.example.unitName(widget.range.basis)}'),
        SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('محاسبه وزن از ابعاد'),
            subtitle: const Text(
                'خاموش: ورود مستقیم مقدار؛ روشن: طول، عرض، ارتفاع یا وزن واحد متناسب با کالا'),
            value: geometry,
            onChanged: (v) => setState(() {
                  geometry = v;
                  clearResult();
                })),
        if (geometry) ...[
          infoBox(spec.label,
              '${spec.note}\nوزن نظری فقط برای برآورد هزینه است؛ وارد رنج قیمت یا فید نمی‌شود.'),
          if (shape != 'bulk') ...[
            field('چگالی جنس (کیلوگرم بر مترمکعب؛ فولاد کربنی ۷۸۵۰)', density),
            for (final f in spec.fields) field(f.label, fields[f.key]!),
            if (shape != 'piece') field('طول هر شاخه/برگ/قطعه (متر)', length),
            selectField(
                'واحد مقدار درخواستی',
                inputUnit,
                {
                  'kg': 'کیلوگرم',
                  if (shape != 'piece') 'm': 'متر طول',
                  'piece': 'تعداد شاخه / برگ / قطعه',
                  if (['plate', 'piece'].contains(shape)) 'm2': 'مترمربع'
                },
                (v) => setState(() {
                      inputUnit = v;
                      clearResult();
                    })),
          ],
          CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: confirmed,
              title: const Text(
                  'ابعاد، جنس و وزن واحد را با همان کالای انتخابی تطبیق داده‌ام.',
                  style: TextStyle(fontSize: 12)),
              onChanged: (v) => setState(() {
                    confirmed = v ?? false;
                    clearResult();
                  })),
        ],
        field(
            geometry
                ? 'مقدار مورد نیاز (${unitLabel(inputUnit)})'
                : 'مقدار مورد نیاز (${widget.range.example.unitName(widget.range.basis)})',
            quantity),
        FilledButton.icon(
            onPressed: calculate,
            icon: const Icon(Icons.calculate_outlined),
            label: const Text('محاسبه هزینه')),
        if (error != null)
          infoBox('ورودی نیازمند اصلاح است', error!, color: Colors.red),
        if (total != null)
          infoBox(
              'هزینه برآوردی: ${fmt(total)} تومان',
              '${moneyWords(total!)}'
                  '${weight == null ? '' : '\nوزن: ${fmt(weight!.kg, decimals: 3)} کیلوگرم • متراژ: ${fmt(weight!.metres, decimals: 3)} متر'}'),
        infoBox(
            'مبلغ کالا، نه فاکتور نهایی',
            'مبلغ = مقدار × نرخ انتخابی. همان شرایط مالیات نرخ منبع حفظ می‌شود؛ '
                'حمل، برش، خدمات و مالیات اضافه خودکار افزوده نمی‌شوند. وزن واقعی کارخانه/باسکول مبنای تسویه است. '
                'تغییر مشخصات، قیمت کالای تازه تولید نمی‌کند.'),
      ]);
}
