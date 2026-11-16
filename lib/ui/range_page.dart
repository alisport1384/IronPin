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

/// The amount a candidate really carries, in the unit it announced, so the list
/// can never show an entry without a price.
///
/// Order: the comparable basis the row can prove, then the amount exactly as the
/// source announced it (even when the source named no unit), and only then the
/// raw extracted text of a row that has no number at all. Zero is not a price:
/// sources that publish «۰ تومان» mean "I have no price", so every step treats
/// a non-positive amount as absent and the row reads «بدون قیمت» instead.
String candidatePriceText(CatalogueItem p) => candidatePriceTextOf(p.example);

String candidatePriceTextOf(Quote q) {
  final basis = rangeBasis(q);
  final comparable = q.tomanFor(basis);
  if (comparable != null && comparable > 0) {
    return '${fmt(comparable)} تومان / ${q.unitName(basis)}';
  }
  final own = q.tomanFor('original');
  if (own != null && own > 0) return '${fmt(own)} تومان • واحد نامشخص';
  final amount = q.amount;
  if (amount != null && amount > 0) return '${fmt(amount)} ${faDigits(q.currency)}';
  return faDigits(q.details['مبلغ استخراج‌شده'] ?? 'بدون قیمت');
}

class RangePage extends StatefulWidget {
  final MarketController c;
  final Duration taskTimeout, readTimeout;
  final ValueChanged<Quote>? onChart;
  const RangePage(
      {super.key,
      required this.c,
      this.onChart,
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

  /// One indicator card per product that has candidates — built from the
  /// candidates themselves (Bug A), so a product can never be counted without
  /// its own card, and a price-less product never gets one.
  List<_CatalogEntry> cards = const [];

  /// Cards whose candidates the user asked to see: the candidate list is never
  /// on screen until «نمایش کاندیدها» is pressed for that product.
  final showCandidateCards = <String>{};
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
  ProductRangeResult? _filteredForResult;
  String _filteredForNeedle = '';
  List<Quote> _shownCache = const [];
  int _hiddenUnpricedCache = 0;
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
    _filteredForResult = null;
    _shownCache = const [];
    _hiddenUnpricedCache = 0;
    calculating = false;
    error = '';
    visible = 40;
    catalogVisible = 40;
    cards = const [];
    showCandidateCards.clear();
  }

  /// The candidates of one product card, revealed only on request. Same rows,
  /// prices and dialogs as the tab always showed — scoped to the product the
  /// user asked about.
  Widget _candidateSection(BuildContext context, _CatalogEntry entry,
      String needle) {
    final catalog = entry.candidates
        .where((p) => p.searchText.contains(needle))
        .toList();
    return ExpansionTile(
      title: Text('کاندیدهای همان کالا • ${fmt(catalog.length)} مورد'),
      children: [
        for (final p in catalog.take(catalogVisible))
          ListTile(
            title: Text(faDigits(p.example.title)),
            // Every candidate carries the price the archive actually holds
            // for it, in the unit that price was announced with: a row is
            // never offered without its number.
            trailing: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Flexible(
                  child: Text(candidatePriceText(p),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: teal)),
                ),
                if (widget.onChart != null)
                  IconButton(
                    tooltip: 'نمایش نمودار',
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 36, minHeight: 36),
                    icon: const Icon(Icons.show_chart, size: 20),
                    onPressed: () => widget.onChart!(p.example),
                  ),
              ]),
            ),
            subtitle: Text(faDigits(
                '${p.example.specificationLabel} • ${p.example.seller}\n'
                '${dateLabel(p.example.marketAt, time: false)}\n'
                '${p.counted ? 'در آمار همین واحد حساب شده است' : p.unavailableReasons.join('؛ ')}')),
            onTap: () => showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                      title: Text(faDigits(p.example.title)),
                      content: SingleChildScrollView(
                          child: Text(faDigits(
                              '${p.example.specificationLabel}\n${p.example.seller}\n${dateLabel(p.example.marketAt)}\n${p.counted ? 'در آمار همین واحد حساب شده است؛ میانگین، بالاترین و پایین‌ترین از همین فهرست گرفته می‌شود' : rangeUnavailableReasons(p.example, result!.at).join('؛ ')}\nاین نمایش از آرشیو محلی است؛ برای بازهٔ انتخاب‌شده محاسبه شده است.'))),
                      actions: [
                        if (widget.onChart != null)
                          TextButton.icon(
                              onPressed: () {
                                Navigator.pop(context);
                                widget.onChart!(p.example);
                              },
                              icon: const Icon(Icons.show_chart),
                              label: const Text('نمایش نمودار')),
                        TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('بستن'))
                      ],
                    )),
          ),
        Text(
            'نمایش ${fmt(catalog.length < catalogVisible ? catalog.length : catalogVisible)} از ${fmt(catalog.length)} کاندید'),
        if (catalog.length > catalogVisible)
          TextButton(
              onPressed: () => setState(() => catalogVisible += 40),
              child: const Text('نمایش ۴۰ کاندید بعدی')),
      ],
    );
  }

  /// Rebuilds the product cards from the candidates of the current answer —
  /// never from the raw announcement list — so cards, candidates and statistics
  /// are one set (Bug A). Called from every setState that installs an answer.
  void _recomputeCards() {
    final answer = selection;
    if (answer == null || answer.candidates.isEmpty) {
      cards = const [];
      showCandidateCards.clear();
      return;
    }
    final quotes = [for (final p in answer.candidates) p.example];
    final (ranges, _) = buildProductRanges(quotes, answer.at, basis: basis);
    showCandidateCards.clear();
    cards = [
      for (final range in ranges)
        _CatalogEntry(
            range,
            [
              for (final p in answer.candidates)
                if (range.announcements.any((q) => identical(q, p.example)))
                  p
            ])
    ];
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
    // The range tab's own window; `0` (همه زمان‌ها) means no date limit, and the
    // session's default (48 hours) is used only when no window is given at all.
    final rangeWindow = widget.c.rangeWindow;
    final windowDays = rangeWindow == 0 ? -1 : rangeWindow;
    final key = session.scopeKey(
        family: family!,
        fields: constraints,
        basis: basis,
        city: city,
        windowDays: windowDays);
    final cached = session.cached(key, at);
    setState(() {
      calculating = cached == null;
      error = '';
      result = cached?.result;
      selection = cached;
      _recomputeCards();
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
        await session.ensureIndex(at, windowDays: windowDays);
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
            windowMs: windowMsFor(windowDays),
            timeout: widget.taskTimeout * 6);
        if (!mounted || token != generation) return;
        answer = session.answerFromWorker(message['answer'] as RangeAnswer,
            family: family!,
            fields: constraints,
            basis: basis,
            city: city,
            windowDays: windowDays);
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
            windowDays: windowDays,
            timeout: widget.taskTimeout * 6);
      }
      if (!mounted || token != generation) return;
      setState(() {
        selection = answer;
        result = answer.result;
        _recomputeCards();
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
    // «اعلام‌های نتیجه» lists offers the user can act on: a row without a real
    // number has nothing to compare and is left out here — zero is not a price
    // (Bug B), so a «۰ تومان» row counts as price-less too. It is still counted
    // — and named — under the footer line, so a shorter list is always
    // explained rather than silent.
    bool hasPrice(Quote q) => q.amount != null && q.amount! > 0;
    if (!identical(_filteredForResult, result) || _filteredForNeedle != needle) {
      _filteredForResult = result;
      _filteredForNeedle = needle;
      final list = result?.announcements ?? const <Quote>[];
      final shownList = <Quote>[];
      var unpricedCount = 0;
      for (final q in list) {
        if (needle.isNotEmpty &&
            !specNorm('${q.title} ${q.specificationLabel} ${q.seller}')
                .contains(needle)) {
          continue;
        }
        if (hasPrice(q)) {
          shownList.add(q);
        } else {
          unpricedCount++;
        }
      }
      _shownCache = shownList;
      _hiddenUnpricedCache = unpricedCount;
    }
    final hiddenUnpriced = _hiddenUnpricedCache;
    final shown = _shownCache;
    return ListView(padding: const EdgeInsets.all(14), children: [
      Text('رنج‌گیری ${windowText(widget.c.rangeWindow)}',
          style: const TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
      const Text('نوع محصول ← مشخصات ← مود قیمت ← تأیید',
          style: TextStyle(color: muted)),
      const Text(
          'مبنای تازگی: تاریخ اعلام نرخ/انتشار منبع؛ نه زمان دریافت. شهر سراسری از بخش اطلاعات اعمال می‌شود؛ دریافت منابع مستقل است.',
          style: TextStyle(fontSize: 12, height: 1.8)),
      Text(
          'شهر سراسری: ${widget.c.selectedCity.isEmpty ? 'همه شهرها' : widget.c.selectedCity}'),
      windowChip('بازه زمانی', widget.c.rangeDays, (v) {
        unawaited(widget.c.setTabDays('range', v));
        if (mounted) setState(invalidate);
      }, inherit: true, inherited: widget.c.discoveryDays),
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
          // One card per product that has candidates, built from the same
          // candidate set as the statistics (Bug A): the product's own three
          // indicators (میانگین/بالاترین/پایین‌ترین), its own cost calculator —
          // and its candidates, which stay off screen until «نمایش کاندیدها»
          // is pressed for this product. The cards sit above «اعلام‌های نتیجه».
          for (final entry in cards)
            Card(
                child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_cardIdentity(entry.range.example)),
                          const Text('شاخص‌های همین کالا',
                              style: TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 15)),
                          Text(
                              '${fmt(entry.range.rate(mode), decimals: mode == 'mean' ? 0 : 2)} تومان / ${entry.range.example.unitName(entry.range.basis)}',
                              style: const TextStyle(
                                  fontSize: 21,
                                  fontWeight: FontWeight.bold,
                                  color: teal)),
                          // The product's three indicators, each taken from
                          // this product's own rows only.
                          Text(
                              'میانگین: ${fmt(entry.range.mean)} تومان / ${entry.range.example.unitName(entry.range.basis)}'),
                          Text(
                              'بالاترین: ${fmt(entry.range.maximum, decimals: 2)} تومان / ${entry.range.example.unitName(entry.range.basis)}'),
                          Text(
                              'پایین‌ترین: ${fmt(entry.range.minimum, decimals: 2)} تومان / ${entry.range.example.unitName(entry.range.basis)}'),
                          ExpansionTile(
                              title: Text(
                                  'محاسبه هزینه • ${entry.range.example.unitName(entry.range.basis)}'),
                              children: [
                                RangeCost(
                                    key: ValueKey(
                                        '${entry.range.key}:$mode:${result!.at}'),
                                    range: entry.range,
                                    rate: entry.range.rate(mode),
                                    allowGeometry: false)
                              ]),
                          // The section sits above its button on purpose: when
                          // the user asks for the candidates, the list opens
                          // exactly where the button just was, in the part of
                          // the card already brought into view.
                          if (showCandidateCards.contains(entry.range.key))
                            _candidateSection(context, entry, needle),
                          Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: FilledButton.tonal(
                                  onPressed: () => setState(() {
                                        if (!showCandidateCards
                                            .remove(entry.range.key)) {
                                          showCandidateCards
                                              .add(entry.range.key);
                                        }
                                      }),
                                  child: Text(showCandidateCards
                                          .contains(entry.range.key)
                                      ? 'پنهان کردن کاندیدها'
                                      : 'نمایش کاندیدها'))),
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
          if (hiddenUnpriced > 0)
            Text(
                '${fmt(hiddenUnpriced)} اعلام بدون قیمت نمایش داده نمی‌شود؛ در «علت نبودن در آمار» شمرده شده است',
                style: const TextStyle(fontSize: 10, color: muted)),
          if (shown.length > visible)
            OutlinedButton(
                onPressed: () => setState(() => visible += 40),
                child: const Text('نمایش ۴۰ اعلام بعدی')),
          if (shown.isEmpty)
            const Text(
                'اعلامی مطابق این جستجو/مشخصات در ۴۸ ساعت گذشته موجود نیست.'),
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

/// The plain-text identity line at the top of a product card: title plus its
/// technical specification — never a ListTile, and never the bare title either,
/// so it can never be mistaken for an announcement row of the list below.
String _cardIdentity(Quote q) {
  final spec = q.specificationLabel;
  final parts = <String>[
    q.title,
    if (spec.isNotEmpty) spec,
    if (q.seller.isNotEmpty) q.seller,
    if (spec.isEmpty && q.seller.isEmpty) q.category,
  ];
  return faDigits(parts.join(' • '));
}

/// One product's card state: its range (the same min/max/mean the statistics
/// hold) and exactly the candidates that were counted in it.
class _CatalogEntry {
  final PriceRange range;
  final List<CatalogueItem> candidates;
  const _CatalogEntry(this.range, this.candidates);
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
