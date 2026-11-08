import 'dart:async';
import 'package:flutter/material.dart';
import '../data/app_logger.dart';
import '../data/controller.dart';
import '../domain/range_projection.dart';
import '../domain/range_worker.dart';
import '../domain/calculator.dart';
import '../domain/market.dart';
import '../domain/money.dart';
import '../domain/price_range.dart';
import '../domain/product_schema.dart';
import 'calculator_page.dart';
import 'common.dart';

class RangePage extends StatefulWidget {
  final MarketController c;
  final Duration taskTimeout, readTimeout;
  const RangePage(
      {super.key,
      required this.c,
      this.taskTimeout = const Duration(seconds: 45),
      this.readTimeout = const Duration(seconds: 20)});
  @override
  State<RangePage> createState() => _RangePageState();
}

class _RangePageState extends State<RangePage> {
  int revision = -1, generation = 0, visible = 40, catalogVisible = 40;

  /// Answer of the confirmed scope. Built from the persisted index, so a second
  /// question costs one pass over derived rows instead of a full re-read.
  RangeAnswer? selection;
  String scopeCity = '', stage = '';
  int processed = 0, totalRows = 0;
  @override
  void initState() {
    super.initState();
    scopeCity = widget.c.selectedCity;
  }

  String? family;
  String mode = 'mean', basis = '', error = '';
  bool calculating = false;
  ProductRangeResult? result;
  final fields = <String, TextEditingController>{};
  final search = TextEditingController();
  @override
  void dispose() {
    generation++;
    for (final c in [...fields.values, search]) {
      c.dispose();
    }
    super.dispose();
  }

  void invalidate() {
    generation++;
    selection = null;
    result = null;
    calculating = false;
    error = '';
    visible = 40;
    catalogVisible = 40;
  }

  void select(String? value) {
    for (final c in fields.values) {
      c.dispose();
    }
    fields.clear();
    family = value;
    for (final key in productFields[value]?.keys ?? <String>[]) {
      fields[key] = TextEditingController();
    }
    basis = '';
    search.clear();
    invalidate();
  }

  Future<void> confirm() async {
    final token = ++generation;
    final at = DateTime.now().toUtc();
    revision = widget.c.historyRevision;
    final city = widget.c.selectedCity;
    final constraints = {
      for (final e in fields.entries) e.key: e.value.text.trim()
    };
    // The same scope of the same snapshot is answered from memory: no spinner,
    // no recomputation, and nothing is guessed — it is the answer already shown.
    final session = widget.c.rangeSession;
    final key = session.scopeKey(
        family: family!, fields: constraints, basis: basis, city: city);
    final cached = session.cached(key, at);
    setState(() {
      calculating = cached == null;
      error = '';
      result = cached?.result;
      selection = cached;
      visible = 40;
      catalogVisible = 40;
      stage = cached != null ? '' : 'آماده‌سازی فهرست محلی';
      processed = 0;
      totalRows = cached?.inputRows ?? 0;
    });
    if (cached != null) {
      unawaited(AppLogger.instance
          .record('range', 'served_from_memory', {'kept': cached.keptRows}));
      return;
    }
    try {
      // The index is handed to a persistent worker once per snapshot; afterwards
      // a new product/city/unit question is answered inside it without another
      // read or copy. Any worker problem falls back to the exact same computation
      // on a one-shot isolate, so the answer never depends on the fast path.
      final worker = RangeWorker.shared;
      RangeAnswer answer;
      try {
        await session.ensureIndex(at);
        if (worker.isLoaded && !worker.holdsToken(session.dataToken)) {
          worker.dispose();
        }
        await worker.load(session.dataToken, session.indexRowsSnapshot,
            onProgress: (done, total) {
          if (mounted && token == generation) {
            setState(() {
              stage = 'بارگذاری فهرست محلی در حافظه';
              processed = done;
              totalRows = total;
            });
          }
        });
        if (!mounted || token != generation) return;
        final message = await worker.run(
            token: session.dataToken,
            family: family!,
            fields: constraints,
            basis: basis,
            city: city,
            nowMs: at.millisecondsSinceEpoch,
            timeout: widget.taskTimeout * 6);
        if (!mounted || token != generation) return;
        answer = session.answerFromWorker(message['answer'] as RangeAnswer,
            family: family!,
            fields: constraints,
            basis: basis,
            city: city);
      } catch (workerFailure) {
        if (workerFailure is TimeoutException) rethrow;
        AppLogger.instance.capture(workerFailure, StackTrace.current,
            section: 'range_worker');
        worker.dispose();
        if (!mounted || token != generation) return;
        answer = await session.confirm(
            family: family!,
            fields: constraints,
            basis: basis,
            city: city,
            at: at,
            timeout: widget.taskTimeout * 6);
      }
      if (!mounted || token != generation) return;
      setState(() {
        selection = answer;
        result = answer.result;
        calculating = false;
        stage = '';
        processed = answer.keptRows;
        totalRows = answer.inputRows;
      });
    } on TimeoutException {
      if (mounted && token == generation) {
        setState(() {
          calculating = false;
          error = 'محاسبه بیش از حد طول کشید؛ داده حذف نشده است. '
              'دوباره تأیید کنید یا مشخصات را محدودتر کنید.';
        });
      }
    } catch (failure, stack) {
      AppLogger.instance.capture(failure, stack, section: 'range');
      if (mounted && token == generation) {
        setState(() {
          calculating = false;
          error = 'محاسبه کامل نشد؛ داده قبلی حفظ شد. دوباره تلاش کنید.';
        });
      }
    }
  }

  Widget input(String key) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: TextField(
          key: ValueKey('$family:$key'),
          controller: fields[key],
          decoration: InputDecoration(
              labelText: productFields[family]![key],
              hintText: 'اختیاری؛ خالی یعنی همه',
              helperText: 'عدد و واحد طبق منبع؛ مقدار نامعلوم حدس زده نمی‌شود'),
          onChanged: (_) => setState(invalidate)));
  @override
  Widget build(BuildContext context) {
    // Refresh notifications never restart or starve a confirmed calculation.
    // A changed city is a changed query, so stale/cross-city results disappear.
    if (scopeCity != widget.c.selectedCity) {
      scopeCity = widget.c.selectedCity;
      invalidate();
    }
    final entries = productFields[family]?.keys.toList() ?? <String>[];
    final needle = specNorm(search.text);
    final shown = result?.announcements
            .where((q) =>
                specNorm('${q.title} ${q.specificationLabel} ${q.seller}')
                    .contains(needle))
            .toList() ??
        <Quote>[];
    final catalog = selection?.catalog
            .where((p) => p.searchText.contains(needle))
            .toList() ??
        <CatalogueItem>[];
    return ListView(padding: const EdgeInsets.all(14), children: [
      const Text('رنج‌گیری ۴۸ ساعت',
          style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
      const Text('نوع محصول ← مشخصات ← مود قیمت ← تأیید',
          style: TextStyle(color: muted)),
      const Text(
          'مبنای تازگی: تاریخ اعلام نرخ/انتشار منبع؛ نه زمان دریافت. شهر سراسری از بخش اطلاعات اعمال می‌شود؛ دریافت منابع مستقل است.',
          style: TextStyle(fontSize: 12, height: 1.8)),
      Text(
          'شهر سراسری: ${widget.c.selectedCity.isEmpty ? 'همه شهرها' : widget.c.selectedCity}'),
      if (family == null) ...[
        const Text('انتخاب نوع محصول',
            style: TextStyle(fontWeight: FontWeight.bold)),
        for (final name in [...productFields.keys, 'سایر'])
          ListTile(
              title: Text(name == 'ورق' ? 'ورق / پلیت / صفحه فولادی' : name),
              trailing: const Icon(Icons.chevron_left),
              onTap: () => setState(() => select(name))),
      ] else ...[
        Row(children: [
          Expanded(
              child: Text(
                  family == 'ورق' ? 'ورق / پلیت / صفحه فولادی' : family!,
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.bold))),
          TextButton(
              onPressed: () => setState(() => select(null)),
              child: const Text('تغییر محصول'))
        ]),
        const Text(
            'پیش‌فرض حداقلی است؛ فقط فیلدهایی را که می‌خواهید محدود شوند تکمیل کنید. مشخصات خالی شامل همه انواع و کارخانه‌هاست.',
            style: TextStyle(fontSize: 12)),
        if (family == 'بولت')
          infoBox('مقایسه تخصصی بولت و انکربولت',
              'مشخصات ناقص در اعلام‌ها می‌ماند ولی وارد میانگین نمی‌شود. نوع، قطر، طول، طول و گام رزوه، جنس، گرید، پوشش و شمول متعلقات لازم است؛ انکر مکانیکی/شیمیایی به مدل و عمق کاشت صریح هم نیاز دارد. اختلاف مشخصات در گروه‌های جدا محاسبه می‌شود. این رنج، ظرفیت باربری یا مجوز جایگزینی انکرها نیست.'),
        for (final key in entries.take(3)) input(key),
        if (entries.length > 3)
          ExpansionTile(
              title: const Text('مشخصات بیشتر'),
              children: [for (final key in entries.skip(3)) input(key)]),
        selectField(
            'واحد مقایسه',
            basis,
            {
              '': 'همه واحدها؛ جداگانه',
              'kg': 'کیلوگرم',
              'ton': 'تن',
              'sheet': 'برگ',
              'piece': family == 'بولت' ? 'عدد / ست' : 'شاخه',
              'roll': 'رول',
              'm': 'متر',
              'm2': 'مترمربع'
            },
            (v) => setState(() {
                  basis = v;
                  invalidate();
                })),
        selectField(
            'مود قیمت',
            mode,
            {
              'min': 'پایین‌ترین قیمت',
              'max': 'بالاترین قیمت',
              'mean': 'میانگین قیمت'
            },
            (v) => setState(() {
                  mode = v;
                  invalidate();
                })),
        FilledButton.icon(
            onPressed: calculating ? null : confirm,
            icon: const Icon(Icons.check),
            label: const Text('تأیید و نمایش رنج')),
        if (calculating) ...[
          const LinearProgressIndicator(),
          Text('$stage • ${fmt(processed)} / ${fmt(totalRows)}'),
          TextButton(
              onPressed: () => setState(invalidate),
              child: const Text('لغو محاسبه')),
        ],
        if (error.isNotEmpty) infoBox('خطا', error, color: Colors.red),
        if (result != null) ...[
          if (revision != widget.c.historyRevision)
            infoBox('داده جدید رسیده است',
                'این نتیجه snapshot زمان تأیید است. برای محاسبه داده تازه دوباره تأیید کنید.'),
          Text(
              'تا ${dateLabel(result!.at)} • ${fmt(result!.announcements.length)} اعلام یکتای مرتبط'),
          infoBox('نرخ‌های اعلامی مطابق فیلتر شما',
              'برند و محل تولید شرط نیستند. مشخصات تعیین‌نشده بدون محدودیت‌اند؛ مالیات، شرایط و نوع‌های مختلف ممکن است متفاوت باشند. واحدهای نامرتبط با هم میانگین نمی‌شوند. این نتیجه تضمین همسانی تمام مشخصات یا فاکتور نهایی نیست.'),
          if (result!.ranges.isEmpty)
            infoBox('رنج عددی قابل مقایسه نداریم',
                'اعلام‌های مرتبط در پایین باقی می‌مانند. مبلغ/واحد/ارز نامعلوم با حدس وارد آمار نمی‌شود.'),
          for (final range in result!.ranges)
            Card(
                child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text({
                            'min': 'پایین‌ترین قیمت',
                            'max': 'بالاترین قیمت',
                            'mean': 'میانگین قیمت'
                          }[mode]!),
                          Text(
                              '${fmt(range.rate(mode), decimals: mode == 'mean' ? 0 : 2)} تومان / ${range.example.unitName(range.basis)}',
                              style: const TextStyle(
                                  fontSize: 21,
                                  fontWeight: FontWeight.bold,
                                  color: teal)),
                          Text(
                              '${moneyWords(range.rate(mode))} • ${fmt(range.announcements.length)} اعلام',
                              style: const TextStyle(fontSize: 11)),
                          ExpansionTile(
                              title: Text(
                                  'محاسبه هزینه • ${range.example.unitName(range.basis)}'),
                              children: [
                                RangeCost(
                                    key: ValueKey(
                                        '${range.key}:$mode:${result!.at}'),
                                    range: range,
                                    rate: range.rate(mode),
                                    allowGeometry: false)
                              ]),
                        ]))),
          TextField(
              controller: search,
              decoration: const InputDecoration(
                  labelText: 'جستجو در تمام اعلام‌های نتیجه'),
              onChanged: (_) => setState(() {
                    visible = 40;
                    catalogVisible = 40;
                  })),
          for (final q in shown.take(visible))
            ListTile(
                dense: true,
                title: Text(faDigits(q.title)),
                subtitle: Text(
                    '${q.amount == null ? (q.details['مبلغ استخراج‌شده'] ?? 'تماس / مبلغ نامعلوم') : fmt(toman(q.amount, q.currency) ?? q.amount, decimals: 2)} ${toman(q.amount, q.currency) == null ? q.currency : 'تومان'} / ${q.unitName(q.unit)}\n${faDigits(q.specificationLabel)}\n${dateLabel(q.marketAt)} • ${faDigits(q.seller)}\n${faDigits(q.tax)} • ${faDigits(q.terms)}',
                    style: const TextStyle(fontSize: 11)),
                onTap: q.sourceUrl.isEmpty
                    ? null
                    : () => openLink(context, q.sourceUrl)),
          Text(
              'نمایش ${fmt(shown.length < visible ? shown.length : visible)} از ${fmt(shown.length)} اعلام'),
          if (shown.length > visible)
            OutlinedButton(
                onPressed: () => setState(() => visible += 40),
                child: const Text('نمایش ۴۰ اعلام بعدی')),
          if (shown.isEmpty)
            const Text(
                'اعلامی مطابق این جستجو/مشخصات در ۴۸ ساعت گذشته موجود نیست.'),
          ExpansionTile(
            title: Text('فهرست کامل محلی • ${fmt(catalog.length)} کالا'),
            subtitle: const Text(
                'شامل قدیمی، بی‌تاریخ و بی‌قیمت؛ خارج از آمار ۴۸ ساعت'),
            children: [
              for (final p in catalog.take(catalogVisible))
                ListTile(
                  title: Text(faDigits(p.example.title)),
                  subtitle: Text(faDigits(
                      '${p.example.specificationLabel} • ${p.example.seller}\n${p.unavailableReasons.join('؛ ')}')),
                  onTap: () => showDialog<void>(
                      context: context,
                      builder: (context) => AlertDialog(
                            title: Text(faDigits(p.example.title)),
                            content: SingleChildScrollView(
                                child: Text(faDigits(
                                    '${p.example.specificationLabel}\n${p.example.seller}\n${dateLabel(p.example.marketAt)}\n${p.unavailableReasons.join('؛ ')}\nاین نمایش از آرشیو محلی است؛ انتخاب آن نرخ قدیمی یا نامعتبر را وارد آمار نمی‌کند.'))),
                            actions: [
                              TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: const Text('بستن'))
                            ],
                          )),
                ),
              Text(
                  'نمایش ${fmt(catalog.length < catalogVisible ? catalog.length : catalogVisible)} از ${fmt(catalog.length)} کالای محلی'),
              if (catalog.length > catalogVisible)
                TextButton(
                    onPressed: () => setState(() => catalogVisible += 40),
                    child: const Text('نمایش ۴۰ کالای محلی بعدی')),
            ],
          ),
          if (result!.excluded.isNotEmpty)
            ExpansionTile(title: const Text('علت نبودن در آمار'), children: [
              for (final e in result!.excluded.entries)
                ListTile(title: Text(e.key), trailing: Text(fmt(e.value)))
            ]),
        ],
      ],
    ]);
  }
}

class RangeCost extends StatefulWidget {
  final PriceRange range;
  final double rate;
  final bool allowGeometry;
  const RangeCost(
      {super.key,
      required this.range,
      required this.rate,
      this.allowGeometry = true});
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
      'ورق' => 'plate',
      'تسمه' => 'flat',
      'بولت' || 'انکربولت' || 'انکر بولت' => 'anchorMeasured',
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
    if (['piece', 'anchorMeasured'].contains(shape) && q.pieceKg != null) {
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
                ['bulk', 'piece', 'mesh', 'anchorMeasured'].contains(shape)
                    ? 1
                    : read(length));
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
        if (widget.allowGeometry)
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
            if (!['piece', 'anchorMeasured'].contains(shape))
              field('طول هر شاخه/برگ/قطعه (متر)', length),
            selectField(
                'واحد مقدار درخواستی',
                inputUnit,
                {
                  'kg': 'کیلوگرم',
                  if (!['piece', 'anchorMeasured'].contains(shape))
                    'm': 'متر طول',
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
                ? 'مقدار مورد نیاز (${widget.range.example.unitName(inputUnit)})'
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
