import 'package:flutter/material.dart';
import '../data/app_logger.dart';
import '../data/controller.dart';
import '../data/sources.dart';
import '../domain/market.dart';
import 'common.dart';
import 'prices_page.dart';

class InfoPage extends StatefulWidget {
  final MarketController c;
  const InfoPage({super.key, required this.c});
  @override
  State<InfoPage> createState() => _InfoPageState();
}

class _InfoPageState extends State<InfoPage> {
  String city = '', query = '', platform = '';
  bool exporting = false;
  Future<void> exportLogs() async {
    setState(() => exporting = true);
    try {
      final destination = await AppLogger.instance.export();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(destination == null
                ? 'خروجی لغو شد.'
                : 'فایل‌های Markdown در پوشه انتخاب‌شده ذخیره شدند.')));
      }
    } catch (e, stack) {
      AppLogger.instance.capture(e, stack, section: 'export');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'خروجی ذخیره نشد؛ پوشه دیگری را انتخاب کنید و فضای خالی را بررسی کنید.')));
      }
    } finally {
      if (mounted) setState(() => exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final offices = sellers
        .where((s) =>
            (city.isEmpty || s['city'] == city) &&
            (query.isEmpty || latin(s.values.join(' ')).contains(latin(query))))
        .toList()
      ..sort((a, b) =>
          (a['city'] == 'مشهد' ? 0 : 1).compareTo(b['city'] == 'مشهد' ? 0 : 1));
    final sites = (c.registry['sources'] as List? ?? [])
        .where((s) =>
            query.isEmpty ||
            latin('${s['name']} ${s['coverage']}').contains(latin(query)))
        .toList();
    return ListView(padding: const EdgeInsets.all(20), children: [
      const Text('اطلاعات و منابع',
          style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      const Text('نشانی فروشنده، منشأ نرخ و سلامت اتصال',
          style: TextStyle(color: muted, fontSize: 12)),
      infoBox('بدون سرور دائمی',
          'قیمت هنگام بازکردن، نوسازی دستی و هر ۱۵ دقیقه در زمان فعال‌بودن اپ دریافت می‌شود. دریافت پس‌زمینه/اپ بسته تضمین نمی‌شود. تاریخچه فقط روی همین دستگاه و از شروع دریافت ساخته می‌شود.'),
      infoBox('ذخیره محلی و تصمیم ماهانه',
          'داده‌های قبلی با نوسازی یا قطع اینترنت حذف نمی‌شوند. ابتدای هر ماه شمسی، هنگام استفاده از اپ درباره حفظ یا پاک‌سازی تاریخچه ماه‌های قبل سؤال می‌شود. قیمت جاری و تنظیمات باقی می‌مانند. حذف برنامه یا پاک‌کردن داده برنامه توسط Android می‌تواند این اطلاعات را حذف کند.'),
      ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('لاگ Markdown و مسیر فایل‌ها'),
          children: [
            SelectableText(AppLogger.instance.directoryPath,
                style: const TextStyle(fontSize: 11)),
            const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                    'رویدادهای شبکه، تبدیل، پایگاه داده، فیلتر، پیشنهاد، نمودار، محاسبات و خطاها در حافظه اختصاصی برنامه ثبت می‌شوند. پاک‌سازی ماهانه تاریخچه، لاگ‌ها را حذف نمی‌کند. برای نگهداری خارج از برنامه از دکمه زیر خروجی بگیر.')),
            if (AppLogger.instance.lastError != null)
              const Text(
                  'ثبت لاگ با خطا روبه‌رو شده؛ فضای خالی و دسترسی پوشه را بررسی کنید.',
                  style: TextStyle(color: Colors.red)),
            OutlinedButton.icon(
                onPressed: exporting ? null : exportLogs,
                icon: const Icon(Icons.folder_open),
                label: Text(exporting
                    ? 'در حال خروجی…'
                    : 'ذخیره فایل‌های .md در پوشه دلخواه')),
          ]),
      SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('نوسازی خودکار در زمان استفاده'),
          value: c.autoRefresh,
          onChanged: c.setAuto),
      const SizedBox(height: 10),
      const Text('اتصال‌های قابل نوسازی',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
      const Text(
          'فعالسازی منبع به معنی موفقیت دریافت نیست. پیام تلگرام بدون واحد تاییدشده فقط در اعلام‌های بدون قیمت می‌آید.',
          style: TextStyle(fontSize: 11, color: muted, height: 1.8)),
      for (final e in endpoints)
        Card(
            child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: SwitchListTile(
                    title: Text(e.name,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.bold)),
                    subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                              '${c.states[e.id]?['message'] ?? 'هنوز آزموده نشده'}',
                              style: const TextStyle(fontSize: 11)),
                          if (c.states[e.id]?['success_at'] != null)
                            Text(
                                'آخرین دریافت موفق: ${dateLabel(DateTime.tryParse('${c.states[e.id]!['success_at']}'))}',
                                style: const TextStyle(
                                    fontSize: 10, color: muted)),
                          TextButton(
                              onPressed: () => openLink(context, e.url),
                              child: const Text('منبع اصلی',
                                  style: TextStyle(fontSize: 11)))
                        ]),
                    value: c.enabled.contains(e.id),
                    onChanged: c.busy ? null : (v) => c.setEnabled(e.id, v)))),
      const SizedBox(height: 25),
      const Text('فروشندگان بر اساس شهر',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      infoBox('دفتر فروش ≠ محل تولید',
          'فهرست شهرهای ایران قابل جستجو است؛ وضعیت هر مدخل، نشانی رسمی را از خوداظهاری کانال یا سرنخ احرازنشده جدا می‌کند. برای شهر بدون داده، فروشنده یا قیمت فرضی تولید نمی‌شود. شکفته به عنوان تولیدکننده مشهد معرفی شده، نه دفتر فروش احراز‌شده.'),
      TextField(
          decoration: const InputDecoration(
              labelText: 'جستجو در فروشندگان و منابع',
              prefixIcon: Icon(Icons.search)),
          onChanged: (v) => setState(() => query = v)),
      const SizedBox(height: 12),
      OutlinedButton.icon(
          onPressed: () async {
            final v = await showSearch<String>(
                context: context, delegate: CitySearch(c.cities));
            if (v != null) setState(() => city = v);
          },
          icon: const Icon(Icons.location_on_outlined),
          label: Text(city.isEmpty ? 'تمام شهرها • مشهد در اولویت' : city)),
      if (offices.isEmpty)
        infoBox('دفتر تاییدشده‌ای در این فیلتر ثبت نشده',
            'نبود داده، به معنی نبود فروشنده در شهر نیست. منابع با شهر نامشخص در فهرست عمومی منابع حفظ شده‌اند.'),
      for (final s in offices)
        Card(
            child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(
                            child: Text(s['name']!,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold))),
                        tag(s['city']!)
                      ]),
                      const SizedBox(height: 8),
                      Text(s['address']!,
                          style: const TextStyle(fontSize: 12, height: 1.8)),
                      Text(s['status']!,
                          style: const TextStyle(
                              fontSize: 11, color: muted, height: 1.8)),
                      Wrap(spacing: 4, children: [
                        TextButton.icon(
                            onPressed: () => openLink(context, s['url']!),
                            icon: const Icon(Icons.language, size: 17),
                            label: const Text('سایت')),
                        if (s['phone']!.isNotEmpty)
                          TextButton.icon(
                              onPressed: () =>
                                  openLink(context, 'tel:${s['phone']}'),
                              icon: const Icon(Icons.phone_outlined, size: 17),
                              label: Text(s['phone']!))
                      ])
                    ]))),
      const SizedBox(height: 24),
      Text('فهرست تحقیق منابع • ${fmt(sites.length)} مدخل',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      const Text(
          'ثبت در فهرست با اتصال خودکار یکسان نیست. تنها اتصال‌های بالای صفحه مبدل فعال دارند.',
          style: TextStyle(fontSize: 11, color: muted, height: 1.8)),
      for (final s in sites)
        Card(
            child: ExpansionTile(
                title: Text(s['name'],
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.bold)),
                subtitle: Text(s['priority'],
                    style: const TextStyle(fontSize: 11, color: muted)),
                childrenPadding: const EdgeInsets.all(16),
                children: [
              Align(
                  alignment: Alignment.centerRight,
                  child: Text(s['coverage'],
                      style: const TextStyle(fontSize: 12, height: 1.8))),
              const SizedBox(height: 8),
              Text(s['note'],
                  style: const TextStyle(fontSize: 12, height: 1.8)),
              TextButton.icon(
                  onPressed: () => openLink(context, s['url']),
                  icon: const Icon(Icons.open_in_new, size: 17),
                  label: const Text('بازکردن منبع'))
            ])),
      const SizedBox(height: 24),
      const Text('پیام‌رسان‌های ایران و راه‌های فروش',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      infoBox('کانال، حساب فروش و واسطه جدا هستند',
          'لینک معرفی‌شده با دریافت خودکار قیمت یکسان نیست. شهر نامشخص از روی شماره یا محل کارخانه حدس زده نمی‌شود. برخی لینک‌ها حساب تماس یا عضویت‌اند، نه کانال عمومی. فیلتر شهر و جستجوی همین صفحه روی فهرست زیر هم اعمال می‌شود.'),
      selectField(
          'پیام‌رسان',
          platform,
          {
            '': 'همه پیام‌رسان‌ها',
            for (final ch in c.registry['other_channels'] as List? ?? [])
              '${ch['platform']}': '${ch['platform']}'
          },
          (v) => setState(() => platform = v)),
      const SizedBox(height: 10),
      for (final ch in (c.registry['other_channels'] as List? ?? []).where(
          (x) =>
              (platform.isEmpty || x['platform'] == platform) &&
              (city.isEmpty || (x['city'] ?? 'نامشخص') == city) &&
              (query.isEmpty ||
                  latin('${x['owner']} ${x['url']}').contains(latin(query)))))
        Card(
            child: ListTile(
                isThreeLine: true,
                title: Text('${ch['owner']} • ${ch['platform']}',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.bold)),
                subtitle: Text(
                    '${ch['city'] ?? 'نامشخص'} • ${ch['kind'] ?? 'لینک معرفی‌شده'}\n${ch['status']}',
                    style: const TextStyle(fontSize: 11, height: 1.7)),
                trailing: const Icon(Icons.open_in_new, size: 18),
                onTap: () => openLink(context, ch['url']))),
      ExpansionTile(title: const Text('کانال‌های تلگرام تحقیق'), children: [
        for (final ch in c.registry['telegram_channels'] as List? ?? [])
          ListTile(
              title: Text('${ch['owner']} / ${ch['handle']}',
                  style: const TextStyle(fontSize: 12)),
              subtitle: Text(
                  '${ch['coverage']}\n${ch['status']} • مشاهده تحقیق: ${ch['latest_visible_date']}',
                  style: const TextStyle(fontSize: 10)),
              trailing: const Icon(Icons.open_in_new, size: 16),
              onTap: () => openLink(context, ch['url']))
      ]),
      ExpansionTile(title: const Text('لینک‌های محصول و کارخانه'), children: [
        for (final p in c.registry['product_pages'] as List? ?? [])
          ListTile(
              title: Text(p['title'], style: const TextStyle(fontSize: 12)),
              subtitle: Text(p['group'], style: const TextStyle(fontSize: 10)),
              trailing: const Icon(Icons.open_in_new, size: 16),
              onTap: () => openLink(context, p['url']))
      ]),
      const SizedBox(height: 20),
      infoBox('حریم خصوصی و اعتبار',
          'بدون ورود، بدون توکن GitHub، بدون ارسال تاریخچه به سرور پروژه. اتصال مستقیم به سایت‌ها IP دستگاه را در اختیار همان سایت می‌گذارد. برای خرید، واحد، مالیات، موجودی، تسویه و حمل را با فروشنده تایید کنید.'),
      TextButton(
          onPressed: () => showLicensePage(
              context: context,
              applicationName: 'IronPin',
              applicationVersion: '0.3.0'),
          child: const Text('مجوزهای نرم‌افزار و داده')),
      const Text('IronPin 0.3.0 • داده تحقیق: ۱۴ آبان ۱۴۰۵',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11, color: muted)),
      const SizedBox(height: 18),
    ]);
  }
}
