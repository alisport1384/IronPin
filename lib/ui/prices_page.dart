import 'package:flutter/material.dart';
import 'dart:async';
import '../data/app_logger.dart';
import '../data/controller.dart';
import '../domain/market.dart';
import 'common.dart';
import '../domain/money.dart';

class PricesPage extends StatelessWidget {
  final MarketController c;
  final ValueChanged<Quote> onChart;
  const PricesPage({super.key, required this.c, required this.onChart});
  @override
  Widget build(BuildContext context) {
    final list = c.filtered;
    final intent = c.filter.intent;
    final interpreted = [
      if (intent.spec.category.isNotEmpty) intent.spec.category,
      if (intent.spec.thickness.isNotEmpty)
        'ضخامت ${intent.spec.thickness} میلی‌متر',
      if (intent.spec.size.isNotEmpty) 'سایز ${intent.spec.size}',
      if (intent.spec.grade.isNotEmpty) intent.spec.grade,
      if (intent.city.isNotEmpty) 'دفتر ${intent.city}'
    ].join(' • ');
    return Column(children: [
      if (c.filtering) const LinearProgressIndicator(minHeight: 2),
      Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
          child: Row(children: [
            Expanded(
                child: TextField(
                    style: const TextStyle(fontSize: 12),
                    decoration: const InputDecoration(
                        isDense: true,
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                        hintText: 'مثلاً ورق ۳، میلگرد ۱۶ نیشابور',
                        prefixIcon: Icon(Icons.search, size: 20)),
                    onChanged: (v) {
                      c.filter.query = v;
                      c.changed();
                    })),
            IconButton(
                tooltip: 'فیلتر قیمت و مشخصات',
                onPressed: () => showMarketFilters(context, c),
                icon: const Icon(Icons.tune, size: 21))
          ])),
      Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(children: [
            Expanded(
                child: Text(
                    '${fmt(list.length)} پیشنهاد${c.filter.recentWeek ? ' • هفته اخیر' : ''}',
                    style: const TextStyle(fontSize: 10, color: muted),
                    overflow: TextOverflow.ellipsis)),
            PopupMenuButton<String>(
                tooltip: 'ترتیب نمایش',
                initialValue: c.filter.sort,
                onSelected: (v) {
                  c.filter.sort = v;
                  c.changed();
                },
                itemBuilder: (_) => const [
                      PopupMenuItem(
                          value: 'latest', child: Text('جدیدترین اول')),
                      PopupMenuItem(
                          value: 'asc', child: Text('ارزان به گران؛ هم‌مبنا')),
                      PopupMenuItem(
                          value: 'desc', child: Text('گران به ارزان؛ هم‌مبنا'))
                    ],
                child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    child: Text(
                        c.filter.sort == 'latest'
                            ? 'جدیدترین اول'
                            : c.filter.sort == 'asc'
                                ? 'ارزان به گران'
                                : 'گران به ارزان',
                        style: const TextStyle(fontSize: 11))))
          ])),
      if (c.filter.query.isNotEmpty && interpreted.isNotEmpty)
        Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Align(
                alignment: Alignment.centerRight,
                child: Text(interpreted,
                    style: const TextStyle(fontSize: 10, color: teal)))),
      Expanded(
          child: list.isEmpty
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                      const SizedBox(height: 45),
                      emptyState(
                          c.filtering
                              ? 'در حال آماده‌سازی پیشنهادها'
                              : c.quotes.isEmpty
                                  ? 'هنوز قیمتی دریافت نشده'
                                  : 'نتیجه‌ای با این فیلتر نیست',
                          c.quotes.isEmpty
                              ? 'نوسازی را بزنید؛ تحلیل منابع خودکار داخل اپ انجام می‌شود. وضعیت دریافت در اطلاعات است.'
                              : 'فیلتر شهر، بازه تاریخ یا مشخصات را بررسی کنید. داده بی‌تاریخ/قدیمی با برداشتن هفته اخیر قابل بررسی است؛ نبود نتیجه به معنی نبود فروشنده نیست.')
                    ])
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 14),
                  itemCount: list.length,
                  itemBuilder: (ctx, i) {
                    final q = list[i];
                    String day(Quote q) => q.marketAt == null
                        ? 'تاریخ نامشخص'
                        : dateLabel(q.marketAt, time: false);
                    final showDate = c.filter.sort == 'latest' &&
                        (i == 0 || day(q) != day(list[i - 1]));
                    return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (showDate)
                            Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 4, vertical: 5),
                                child: Text(day(q),
                                    style: const TextStyle(
                                        fontSize: 10, color: muted))),
                          QuoteCard(
                              key: ValueKey('${q.id}:$i'),
                              q: q,
                              basis: c.filter.basis,
                              onChart: () => onChart(q))
                        ]);
                  }))
    ]);
  }
}

double? _visibleRawAmount(Quote q) {
  if (q.amount != null) return q.amount;
  final raw = latin(q.details['مبلغ استخراج‌شده'] ?? '');
  if (!RegExp(r'^(?:\d+(?:[.٫]\d+)?|\d{1,3}(?:[,٬]\d{3})+(?:[.٫]\d+)?)$')
      .hasMatch(raw)) return null;
  final n = number(raw);
  return n != null && n.isFinite && n > 0 ? n : null;
}

String _offerAmount(Quote q, String basis) {
  final value = q.priceFor(basis) ?? _visibleRawAmount(q);
  return value != null
      ? fmt(toman(value, q.currency) ?? value, decimals: 2)
      : faDigits(q.details['مبلغ استخراج‌شده'] ?? 'نیازمند بررسی');
}

String _offerUnit(Quote q, String basis) {
  final currency =
      toman(_visibleRawAmount(q), q.currency) == null ? q.currency : 'تومان';
  return q.priceFor(basis) == null && q.hasTextAmount
      ? '$currency • واحد: ${q.unitName(q.unit)}'
      : '$currency / ${q.unitName(basis == 'original' ? q.unit : basis)}';
}

class QuoteCard extends StatelessWidget {
  final Quote q;
  final String basis;
  final VoidCallback onChart;
  const QuoteCard(
      {super.key, required this.q, required this.basis, required this.onChart});
  @override
  Widget build(BuildContext context) => Card(
      margin: const EdgeInsets.only(bottom: 4),
      child: ExpansionTile(
          dense: true,
          tilePadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          onExpansionChanged: (expanded) {
            if (expanded) {
              unawaited(AppLogger.instance.record(
                  'offer', 'specifications_opened', {
                'category': q.category,
                'size': q.sizeLabel,
                'thickness': q.thicknessLabel
              }));
            }
          },
          title: Text(faDigits(q.title),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600, height: 1.45)),
          trailing: SizedBox(
              width: 143,
              child: Row(children: [
                Expanded(
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                      FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(_offerAmount(q, basis),
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: q.priceFor(basis) == null
                                      ? muted
                                      : teal))),
                      FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(_offerUnit(q, basis),
                              style:
                                  const TextStyle(fontSize: 9, color: muted)))
                    ])),
                const SizedBox(width: 5),
                const Icon(Icons.expand_more, size: 17, color: muted)
              ])),
          children: [
            Align(
                alignment: Alignment.centerRight,
                child: Text('${q.seller} • دفتر ${q.sellerCity}',
                    style: const TextStyle(fontSize: 11))),
            const SizedBox(height: 6),
            Wrap(spacing: 5, runSpacing: 4, children: [
              if (q.specificationLabel.isNotEmpty) tag(q.specificationLabel),
              tag(q.tax),
              if (q.hasTextAmount && q.priceFor('original') == null)
                tag('مبلغ استخراج‌شده؛ مبنای ناقص'),
              if (q.details['ورودی دستی'] == 'بله') tag('ورودی دستی نسخه قبل')
            ]),
            const SizedBox(height: 6),
            Align(
                alignment: Alignment.centerRight,
                child: Text(
                    'نرخ: ${sourceDay(q)}${q.publishedAt != null ? ' • انتشار: ${dateLabel(q.publishedAt)}' : ''}',
                    style: const TextStyle(fontSize: 10, color: muted))),
            Align(
                alignment: Alignment.centerRight,
                child: Text('بارگیری: ${q.loading}',
                    style: const TextStyle(fontSize: 10, color: muted))),
            const SizedBox(height: 6),
            UnitPrices(q: q),
            Align(
                alignment: Alignment.centerRight,
                child: Text(q.status,
                    style: const TextStyle(fontSize: 10, color: muted))),
            Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                    onPressed: () {
                      unawaited(AppLogger.instance.record(
                          'offer', 'details_opened', {'category': q.category}));
                      showQuoteDetails(context, q, onChart);
                    },
                    icon: const Icon(Icons.chevron_left, size: 18),
                    label: const Text('جزئیات بیشتر',
                        style: TextStyle(fontSize: 11))))
          ]));
}

class UnitPrices extends StatelessWidget {
  final Quote q;
  const UnitPrices({super.key, required this.q});
  @override
  Widget build(BuildContext context) {
    if (q.priceFor('original') == null) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('قیمت در واحدهای مرتبط',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      LayoutBuilder(
          builder: (context, box) => Wrap(spacing: 8, runSpacing: 8, children: [
                for (final unit in q.displayUnits)
                  Container(
                      width: (box.maxWidth - 8) / 2,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                          color: unit == q.unit
                              ? teal.withOpacity(.08)
                              : const Color(0xfff3f6f8),
                          borderRadius: BorderRadius.circular(9)),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                                'هر ${q.unitName(unit)}${unit == q.unit ? ' • اصلی' : q.priceFor(unit) != null ? ' • تبدیل' : ''}',
                                style: const TextStyle(
                                    fontSize: 11, color: muted)),
                            const SizedBox(height: 4),
                            Text(
                                q.priceFor(unit) == null
                                    ? 'نامشخص؛ داده کافی نیست'
                                    : '${fmt(q.tomanFor(unit) ?? q.priceFor(unit), decimals: 2)} ${q.tomanFor(unit) == null ? q.currency : 'تومان'}',
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: q.priceFor(unit) == null
                                        ? muted
                                        : ink)),
                          ])),
              ])),
      if (q.tomanFor('original') != null)
        Text(
            '${moneyWords(q.tomanFor('original')!)}؛ نوشتار به نزدیک‌ترین تومان',
            style: const TextStyle(fontSize: 11)),
      if (q.currency == 'ریال')
        Text(
            'نرخ اصلی: ${fmt(q.amount, decimals: 2)} ریال؛ هر ۱۰ ریال = ۱ تومان',
            style: const TextStyle(fontSize: 10, color: muted)),
      const SizedBox(height: 8),
      const Text(
          'فقط تبدیل با مشخصات منبع؛ بدون وزن تخمینی. مالیات و شرایط همان نرخ اصلی است.',
          style: TextStyle(fontSize: 10, color: muted)),
      if (q.conversionBasis(q.unit == 'ton' ? 'kg' : 'ton').isNotEmpty)
        Text(q.conversionBasis(q.unit == 'ton' ? 'kg' : 'ton'),
            style: const TextStyle(fontSize: 10, color: muted)),
    ]);
  }
}

void showQuoteDetails(BuildContext context, Quote q, VoidCallback onChart) {
  showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: .8,
          minChildSize: .35,
          maxChildSize: .95,
          builder: (ctx, scroll) => ListView(
                  controller: scroll,
                  padding: const EdgeInsets.all(22),
                  children: [
                    UnitPrices(q: q),
                    const SizedBox(height: 12),
                    Text(faDigits(q.title),
                        style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            height: 1.7)),
                    const SizedBox(height: 16),
                    Text(
                        '${_offerAmount(q, 'original')} ${_offerUnit(q, 'original')}',
                        style: const TextStyle(
                            fontSize: 24,
                            color: teal,
                            fontWeight: FontWeight.bold)),
                    infoBox('نرخ اعلامی؛ نه پیش‌فاکتور قطعی', q.status),
                    for (final e in {
                      'فروشنده': q.seller,
                      'شهر دفتر فروشنده': q.sellerCity,
                      'برند / کارخانه': q.brand,
                      'جنس': q.material,
                      'بارگیری': q.loading,
                      'شهر بارگیری': q.loadingCity,
                      'مالیات': q.tax,
                      'تسویه': q.terms,
                      'تاریخ خام اعلام': sourceDay(q),
                      'زمان دریافت اپ': dateLabel(q.fetchedAt),
                      'وزن شاخه اعلامی': q.pieceKg == null
                          ? 'نامشخص'
                          : '${fmt(q.pieceKg, decimals: 3)} کیلوگرم',
                      ...q.details
                    }.entries)
                      Padding(
                          padding: const EdgeInsets.symmetric(vertical: 7),
                          child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                    width: 120,
                                    child: Text(e.key,
                                        style: const TextStyle(
                                            color: muted, fontSize: 12))),
                                Expanded(
                                    child: SelectableText(faDigits(e.value),
                                        style: const TextStyle(
                                            fontSize: 12, height: 1.8)))
                              ])),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                        onPressed: q.sourceUrl.isEmpty
                            ? null
                            : () => openLink(context, q.sourceUrl),
                        icon: const Icon(Icons.open_in_new),
                        label: const Text('بازکردن منبع اصلی')),
                    OutlinedButton.icon(
                        onPressed: () {
                          Navigator.pop(ctx);
                          onChart();
                        },
                        icon: const Icon(Icons.show_chart),
                        label: const Text('نمودار همین پیشنهاد')),
                  ])));
}

Future<void> showMarketFilters(BuildContext context, MarketController c) async {
  final f = c.filter;
  await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
            void update(VoidCallback fn) {
              setLocal(fn);
              c.changed();
            }

            final cats = c.quotes.map((q) => q.category).toSet().toList()
              ..sort();
            final mats = c.quotes.map((q) => q.material).toSet().toList()
              ..sort();
            return Padding(
                padding: EdgeInsets.only(
                    bottom: MediaQuery.viewInsetsOf(ctx).bottom),
                child: SizedBox(
                    height: MediaQuery.sizeOf(ctx).height * .86,
                    child:
                        ListView(padding: const EdgeInsets.all(22), children: [
                      Row(children: [
                        const Text('فیلتر بازار',
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 22)),
                        const Spacer(),
                        TextButton(
                            onPressed: () {
                              update(() {
                                f.category = '';
                                f.material = '';
                                f.size = '';
                                f.thickness = '';
                                f.grade = '';
                                f.city = '';
                                f.unit = '';
                                f.minPrice = null;
                                f.maxPrice = null;
                                f.onlyFresh = false;
                                f.basis = 'original';
                                f.includeUnpriced = false;
                              });
                              Navigator.pop(ctx);
                            },
                            child: const Text('پاک‌کردن'))
                      ]),
                      const SizedBox(height: 18),
                      selectField(
                          'نوع کالا',
                          f.category,
                          {'': 'همه کالاها', for (final v in cats) v: v},
                          (v) => update(() => f.category = v)),
                      const SizedBox(height: 14),
                      for (final item
                          in <(String, String, ValueChanged<String>)>[
                        (
                          'سایز دقیق (مثلاً 14)',
                          f.size,
                          (v) => update(() => f.size = v)
                        ),
                        (
                          'ضخامت دقیق — میلی‌متر (مثلاً 8)',
                          f.thickness,
                          (v) => update(() => f.thickness = v)
                        ),
                        (
                          'گرید / استاندارد (مثلاً A3)',
                          f.grade,
                          (v) => update(() => f.grade = v)
                        ),
                      ])
                        Padding(
                            padding: const EdgeInsets.only(bottom: 14),
                            child: TextFormField(
                                initialValue: item.$2,
                                decoration: InputDecoration(labelText: item.$1),
                                onChanged: item.$3)),
                      selectField(
                          'جنس / متریال',
                          f.material,
                          {'': 'همه جنس‌ها', for (final v in mats) v: v},
                          (v) => update(() => f.material = v)),
                      const SizedBox(height: 14),
                      Text(
                          'شهر سراسری: ${c.selectedCity.isEmpty ? 'همه شهرها' : c.selectedCity}؛ تغییر فقط در اطلاعات'),
                      selectField(
                          'واحد فروش در منبع',
                          f.unit,
                          {
                            '': 'همه واحدها',
                            'kg': 'کیلوگرم',
                            'piece': 'شاخه',
                            'm': 'متر',
                            'm2': 'مترمربع',
                            'ton': 'تن',
                            'sheet': 'برگ',
                            'roll': 'رول',
                            'unknown': 'نامشخص'
                          },
                          (v) => update(() => f.unit = v)),
                      const SizedBox(height: 14),
                      selectField(
                          'مبنای قیمت و مرتب‌سازی',
                          f.basis,
                          {
                            'original': 'واحد اصلی — گروه‌بندی جدا',
                            'kg': 'تبدیل به تومان/کیلو با وزن صریح'
                          },
                          (v) => update(() => f.basis = v)),
                      const SizedBox(height: 14),
                      Row(children: [
                        Expanded(
                            child: TextFormField(
                                initialValue: f.minPrice?.toStringAsFixed(0),
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                    labelText: 'حداقل قیمت (تومان)'),
                                onChanged: (v) =>
                                    update(() => f.minPrice = number(v)))),
                        const SizedBox(width: 12),
                        Expanded(
                            child: TextFormField(
                                initialValue: f.maxPrice?.toStringAsFixed(0),
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                    labelText: 'حداکثر قیمت (تومان)'),
                                onChanged: (v) =>
                                    update(() => f.maxPrice = number(v))))
                      ]),
                      if (f.minPrice != null &&
                          f.maxPrice != null &&
                          f.minPrice! > f.maxPrice!)
                        const Text('حداقل نباید بیشتر از حداکثر باشد.',
                            style: TextStyle(color: Colors.red)),
                      SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('اولویت با مشهد'),
                          subtitle: Text(f.sort == 'latest'
                              ? 'اول تاریخ جدیدتر؛ مشهد فقط در تاریخ برابر'
                              : 'در هر گروه، ابتدا دفترهای مشهد؛ سپس ترتیب قیمت'),
                          value: f.mashhadFirst,
                          onChanged: (v) => update(() => f.mashhadFirst = v)),
                      SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('فقط هفته اخیر'),
                          subtitle: const Text(
                              '۷×۲۴ساعت گذشته؛ تاریخ نرخ مقدم بر انتشار؛ بی‌تاریخ/آینده خارج این نماست'),
                          value: f.recentWeek,
                          onChanged: (v) => update(() => f.recentWeek = v)),
                      SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('فقط نرخ تازه'),
                          subtitle: const Text('اعلام منبع در ۳۰ ساعت گذشته'),
                          value: f.onlyFresh,
                          onChanged: (v) => update(() => f.onlyFresh = v)),
                      SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('نمایش اعلام‌های بدون قیمت معتبر'),
                          subtitle: const Text(
                              'پیام کانال، تماس یا ناموجود؛ خارج رتبه‌بندی عددی'),
                          value: f.includeUnpriced,
                          onChanged: (v) =>
                              update(() => f.includeUnpriced = v)),
                      infoBox('مقایسه هم‌مبنا',
                          'شاخه و کیلو، مالیات متفاوت و شرایط تسویه متفاوت در یک رتبه قیمتی ادغام نمی‌شوند. وزن تخمینی برای ارزان‌سازی پیشنهاد استفاده نمی‌شود.'),
                      FilledButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('نمایش نتایج')),
                    ])));
          }));
}

class CitySearch extends SearchDelegate<String?> {
  final List<String> cities;
  CitySearch(this.cities) : super(searchFieldLabel: 'جستجوی تمام شهرها');
  @override
  List<Widget> buildActions(BuildContext context) => [
        IconButton(
            onPressed: () {
              query = '';
            },
            icon: const Icon(Icons.clear))
      ];
  @override
  Widget buildLeading(BuildContext context) => IconButton(
      onPressed: () => close(context, null),
      icon: const Icon(Icons.arrow_back));
  @override
  Widget buildResults(BuildContext context) => buildSuggestions(context);
  @override
  Widget buildSuggestions(BuildContext context) {
    final filtered =
        cities.where((s) => latin(s).contains(latin(query))).take(100).toList();
    return ListView(children: [
      ListTile(
          title: const Text('تمام شهرهای ایران'),
          leading: const Icon(Icons.public),
          onTap: () => close(context, '')),
      if (latin('نامشخص').contains(latin(query)))
        ListTile(
            title: const Text('نامشخص'), onTap: () => close(context, 'نامشخص')),
      if (query.trim().isNotEmpty && !cities.contains(query.trim()))
        ListTile(
            title: Text('شهر واردشده: ${query.trim()}'),
            subtitle: const Text('برای نام‌های جدید یا خارج از فهرست'),
            onTap: () => close(context, query.trim())),
      for (final city in filtered)
        ListTile(
            title: Text(city),
            leading: Icon(
                city == 'مشهد' ? Icons.star : Icons.location_on_outlined,
                color: city == 'مشهد' ? teal : muted),
            onTap: () => close(context, city))
    ]);
  }
}
