import 'package:flutter/material.dart';
import 'dart:async';
import '../data/app_logger.dart';
import '../data/controller.dart';
import '../domain/market.dart';
import 'common.dart';

class PricesPage extends StatelessWidget {
  final MarketController c;
  final ValueChanged<Quote> onChart;
  const PricesPage({super.key, required this.c, required this.onChart});
  @override
  Widget build(BuildContext context) {
    final list = c.filtered;
    return Column(children: [
      if (c.filtering) ...[
        const LinearProgressIndicator(minHeight: 2),
        const Text('در حال به‌روزرسانی پیشنهادها؛ نمایش موقت نتایج قبلی',
            style: TextStyle(fontSize: 10, color: muted))
      ],
      Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 0),
          child: Row(children: [
            Expanded(
                child: TextField(
                    decoration: const InputDecoration(
                        hintText: 'جستجوی کالا، کارخانه یا فروشنده',
                        prefixIcon: Icon(Icons.search)),
                    onChanged: (v) {
                      c.filter.query = v;
                      c.changed();
                    })),
            const SizedBox(width: 10),
            IconButton.filledTonal(
                tooltip: 'فیلتر قیمت و شهر',
                onPressed: () => showMarketFilters(context, c),
                icon: const Icon(Icons.tune))
          ])),
      Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: Row(children: [
            Expanded(
                child: Text('${fmt(list.length)} پیشنهاد',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold))),
            TextButton.icon(
                onPressed: () {
                  c.filter.sort = c.filter.sort == 'asc' ? 'desc' : 'asc';
                  c.changed();
                },
                icon: Icon(c.filter.sort == 'asc' ? Icons.south : Icons.north,
                    size: 16),
                label: Text(
                    c.filter.sort == 'asc' ? 'ارزان به گران' : 'گران به ارزان'))
          ])),
      if (c.filter.mashhadFirst)
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Align(
                alignment: Alignment.centerRight,
                child: tag('مشهد در ابتدای هر گروه قابل‌مقایسه'))),
      Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
          child: Align(
              alignment: Alignment.centerRight,
              child: ActionChip(
                  avatar: const Icon(Icons.forum_outlined, size: 17),
                  label: const Text('اعلام کانال‌های فروشندگان مشهد'),
                  onPressed: () {
                    c.filter.city = 'مشهد';
                    c.filter.cityKind = 'seller';
                    c.filter.includeUnpriced = true;
                    c.filter.onlyFresh = false;
                    c.changed();
                  }))),
      Expanded(
          child: RefreshIndicator(
              onRefresh: c.refresh,
              child: list.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                          const SizedBox(height: 55),
                          emptyState(
                              c.filtering
                                  ? 'در حال آماده‌سازی پیشنهادها'
                                  : c.quotes.isEmpty
                                      ? 'هنوز قیمتی دریافت نشده'
                                      : 'نتیجه‌ای با این فیلتر نیست',
                              c.quotes.isEmpty
                                  ? 'نوسازی را بزنید. اعداد فقط از منابع واقعی خوانده می‌شوند؛ در صورت خطا، وضعیت اتصال را در تب اطلاعات ببینید.'
                                  : 'فیلتر شهر، بازه قیمت یا «فقط نرخ تازه» را تغییر دهید. نبود نتیجه به معنی نبود فروشنده در آن شهر نیست.')
                        ])
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
                      itemCount: list.length,
                      itemBuilder: (ctx, i) {
                        final q = list[i];
                        final group = q.comparisonGroup(c.filter.basis);
                        final showHead = i == 0 ||
                            list[i - 1].comparisonGroup(c.filter.basis) !=
                                group;
                        return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (showHead)
                                Padding(
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 12),
                                    child: Text(
                                        '${q.category} • ${q.specificationLabel} • ${c.filter.basis == 'kg' ? '${q.currency} / کیلوگرم' : '${q.currency} / ${unitLabel(q.unit)}'} • ${q.tax} • ${q.terms == 'نامشخص' ? 'شرایط تسویه نامشخص' : q.terms}',
                                        style: const TextStyle(
                                            fontSize: 11, color: muted))),
                              QuoteCard(
                                  q: q,
                                  basis: c.filter.basis,
                                  onChart: () => onChart(q))
                            ]);
                      }))),
    ]);
  }
}

class QuoteCard extends StatelessWidget {
  final Quote q;
  final String basis;
  final VoidCallback onChart;
  const QuoteCard(
      {super.key, required this.q, required this.basis, required this.onChart});
  @override
  Widget build(BuildContext context) {
    final price = q.priceFor(basis);
    final fresh = q.isFresh(DateTime.now());
    return Card(
        margin: const EdgeInsets.only(bottom: 11),
        child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () {
              unawaited(AppLogger.instance.record('offer', 'details_opened', {
                'category': q.category,
                'size': q.sizeLabel,
                'thickness': q.thicknessLabel
              }));
              showQuoteDetails(context, q, onChart);
            },
            child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(
                            child: Text(q.title,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                    height: 1.7))),
                        const SizedBox(width: 8),
                        Icon(Icons.chevron_left, color: muted.withOpacity(.5))
                      ]),
                      const SizedBox(height: 10),
                      Wrap(spacing: 6, runSpacing: 6, children: [
                        tag(q.category),
                        if (q.sizeLabel.isNotEmpty) tag('سایز ${q.sizeLabel}'),
                        if (q.thicknessLabel.isNotEmpty)
                          tag('${q.thicknessLabel} میلی‌متر'),
                        if (q.gradeLabel.isNotEmpty) tag(q.gradeLabel),
                        if (q.dimensionsLabel.isNotEmpty)
                          tag(q.dimensionsLabel),
                        tag(q.sellerCity,
                            color: q.sellerCity == 'مشهد' ? teal : muted),
                        tag(
                            q.endpoint.startsWith('telegram-')
                                ? 'پیام کانال؛ خارج مقایسه عددی'
                                : fresh
                                    ? 'نرخ تازه'
                                    : 'قدیمی / تاریخ نامشخص',
                            color: fresh ? teal : const Color(0xffb26f15))
                      ]),
                      const SizedBox(height: 16),
                      Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Expanded(
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                  Text(q.seller,
                                      style: const TextStyle(
                                          fontSize: 12, color: muted)),
                                  Text('بارگیری: ${q.loading}',
                                      style: const TextStyle(
                                          fontSize: 11, color: muted))
                                ])),
                            Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                      price == null
                                          ? 'نیازمند بررسی'
                                          : fmt(price, decimals: 2),
                                      style: TextStyle(
                                          fontSize: 22,
                                          fontWeight: FontWeight.bold,
                                          color: price == null ? muted : teal)),
                                  Text(
                                      '${q.currency} / ${unitLabel(basis == 'kg' ? 'kg' : q.unit)}',
                                      style: const TextStyle(
                                          fontSize: 10, color: muted))
                                ])
                          ]),
                      const SizedBox(height: 12),
                      UnitPrices(q: q),
                      const Divider(height: 24),
                      Text('اعلام منبع: ${sourceDay(q)}',
                          style: const TextStyle(fontSize: 10, color: muted)),
                    ]))));
  }
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
                                    : '${fmt(q.priceFor(unit), decimals: 2)} ${q.currency}',
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: q.priceFor(unit) == null
                                        ? muted
                                        : ink)),
                          ])),
              ])),
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
                    Text(q.title,
                        style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            height: 1.7)),
                    const SizedBox(height: 16),
                    Text(
                        '${fmt(q.amount, decimals: 2)} ${q.currency} / ${unitLabel(q.unit)}',
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
                                    child: SelectableText(e.value,
                                        style: const TextStyle(
                                            fontSize: 12, height: 1.8)))
                              ])),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                        onPressed: () => openLink(context, q.sourceUrl),
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
                      selectField(
                          'شهر بر اساس',
                          f.cityKind,
                          {
                            'seller': 'شهر دفتر فروشنده',
                            'loading': 'شهر بارگیری'
                          },
                          (v) => update(() => f.cityKind = v)),
                      const SizedBox(height: 14),
                      OutlinedButton.icon(
                          onPressed: () async {
                            final city = await showSearch<String>(
                                context: ctx, delegate: CitySearch(c.cities));
                            if (city != null) update(() => f.city = city);
                          },
                          icon: const Icon(Icons.location_city),
                          label: Text(
                              f.city.isEmpty ? 'تمام شهرهای ایران' : f.city)),
                      const SizedBox(height: 14),
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
                          subtitle: const Text(
                              'در هر گروه، ابتدا دفترهای مشهد؛ سپس ترتیب قیمت'),
                          value: f.mashhadFirst,
                          onChanged: (v) => update(() => f.mashhadFirst = v)),
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

class CitySearch extends SearchDelegate<String> {
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
      onPressed: () => close(context, ''), icon: const Icon(Icons.arrow_back));
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
