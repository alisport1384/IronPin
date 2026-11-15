import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/controller.dart';
import '../domain/market.dart';
import '../domain/money.dart';
import '../domain/source_finder.dart';
import 'common.dart';

/// هوش جستجوگر ۲ on the information tab: its switch, where it stands, and the
/// three lists it is building. Nothing here decides anything — it shows what
/// was found, where it was found and what هوش جستجوگر ۱ answered.
class FinderPanel extends StatefulWidget {
  final MarketController c;
  const FinderPanel({super.key, required this.c});
  @override
  State<FinderPanel> createState() => _FinderPanelState();
}

class _FinderPanelState extends State<FinderPanel> {
  final visible = [40, 40, 40];
  bool working = false;

  static int _rank(FinderEntry e) => switch (e.handoff) {
        'accepted' => 0,
        'wait' => 1,
        'rejected' => 5,
        _ => switch (e.state) { 'ok' => 2, 'new' => 3, _ => 4 }
      };

  static String status(FinderEntry e) {
    final note = e.note.isEmpty ? '' : ' • ${e.note}';
    switch (e.handoff) {
      case 'accepted':
        return 'پذیرفته‌شده و روشن${e.city.isEmpty ? '' : ' • ${e.city} (${e.cityBasis})'}$note';
      case 'wait':
        return e.handoffTries == 0
            ? 'تحویل به برنامه: در نوبت هوش جستجوگر ۱'
            : 'تلاش ${e.handoffTries} بی‌نتیجه؛ دوباره بررسی می‌شود$note';
      case 'rejected':
        return 'ردیف معتبر نداشت$note';
    }
    return switch (e.state) {
      'new' => 'در صف بررسی',
      'unreachable' => 'در دسترس نبود$note',
      'unreadable' => 'فقط در فهرست؛ خواندن بدون ورود ممکن نیست',
      _ => e.kind == 'site' && !e.table
          ? 'فروشنده در فهرست؛ جدول قیمتی در این صفحه دیده نشد$note'
          : 'تأییدشده؛ منتظر تکمیل فهرست$note'
    };
  }

  /// Compact summary of the public search engines and their latest answers.
  static String searchPages(MarketController c) {
    final s = c.finder.state;
    final ok = <String>[];
    var readyCount = 0, restingCount = 0;
    for (final p in c.finder.providers) {
      switch ((s.providerNote[p.id] ?? '').split('|').first) {
        case 'ok':
          ok.add(p.title);
        case 'net':
        case 'refused':
        case 'unreadable':
          restingCount++;
        default:
          readyCount++;
      }
    }
    return [
      if (ok.isNotEmpty) 'پاسخ‌گو: ${ok.join('، ')}',
      if (readyCount > 0) 'آماده: $readyCount موتور',
      if (restingCount > 0) 'موقتاً غیرفعال: $restingCount',
    ].join(' • ');
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final s = c.finder.state;
    final questions = s.queue.where((t) => t.type == 'S').length;
    final unread = s.entries.where((e) => e.state == 'new').length;
    final online = s.lastOnlineAt == 0
        ? 'هنوز اتصالی ثبت نشده'
        : dateLabel(
            DateTime.fromMillisecondsSinceEpoch(s.lastOnlineAt * 1000));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('هوش جستجوگر ۲ — یافتن منابع تازه',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
      const Text(
          'سه فهرست می‌سازد: وب‌سایت‌ها، کانال‌ها و صفحه‌های شبکه‌های اجتماعی، و کانال‌ها و صفحه‌های شبکه‌های داخلی که کالا می‌فروشند یا پخش می‌کنند. '
          'با هر اتصال به اینترنت بلافاصله فعال می‌شود، منابع تأییدشده را بدون معطلی در نوبت هوش جستجوگر ۱ قرار می‌دهد، و هر زمان فهرست «در نوبت» به صفر برسد خودکار دور جستجوی تازه را آغاز می‌کند. '
          'فقط منبعی که دست‌کم یک ردیف معتبر بدهد و تکراری نباشد به اتصال‌ها افزوده و روشن می‌شود. از چند موتور جستجوی مستقل به نوبت استفاده می‌شود تا در دسترس‌نبودن یکی کار را متوقف نکند. '
          'فقط صفحه‌های عمومی خوانده می‌شوند؛ ورود، کلید یا دورزدن محدودیت در کار نیست.',
          style: TextStyle(fontSize: 11, color: muted, height: 1.8)),
      SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('جستجوی خودکار منابع تازه'),
          subtitle: const Text(
              'با خاموش‌کردن، فهرست‌ها و منابع پذیرفته‌شده سر جایشان می‌مانند',
              style: TextStyle(fontSize: 11)),
          value: c.finderEnabled,
          onChanged: (v) async {
            await c.setFinderEnabled(v);
            if (mounted) setState(() {});
          }),
      Text(
          faDigits('دور ${s.round + 1} • پرسش باقی‌مانده: $questions • '
              'در صف بررسی: $unread • صفحه خوانده‌شده: ${s.pages} • '
              'پرسش پاسخ‌گرفته: ${s.searches}\nآخرین اتصال موفق: $online\n'
              'صفحه‌های جستجو — ${searchPages(c)}'),
          style: const TextStyle(fontSize: 11, height: 1.8)),
      if (s.lastError.isNotEmpty)
        Text(faDigits(s.lastError),
            style: const TextStyle(fontSize: 11, color: Colors.deepOrange)),
      OutlinedButton.icon(
          onPressed: working || c.busy || !c.finderEnabled
              ? null
              : () async {
                  setState(() => working = true);
                  if (c.finder.handoffBatch(limit: 1).isNotEmpty) {
                    await c.deliverFinderNow(limit: 8);
                  }
                  await c.runFinderNow(maxSteps: 12);
                  await c.deliverFinderNow(limit: 8);
                  if (mounted) setState(() => working = false);
                },
          icon: working
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.travel_explore),
          label: Text(working ? 'در حال جستجو…' : 'ادامه جستجو و تحویل، همین حالا')),
      TextButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: c.finder.report()));
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('گزارش هوش جستجوگر ۲ کپی شد.')));
          },
          icon: const Icon(Icons.copy, size: 16),
          label: const Text('کپی گزارش وضعیت (برای رفع اشکال)',
              style: TextStyle(fontSize: 12))),
      for (final part in FinderPart.all) _part(context, part),
      const SizedBox(height: 12),
    ]);
  }

  Widget _part(BuildContext context, int part) {
    final s = widget.c.finder.state;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final list = [...s.lists[part]]..sort((a, b) {
        final r = _rank(a).compareTo(_rank(b));
        return r != 0 ? r : b.at.compareTo(a.at);
      });
    final accepted = s.handed(part, 'accepted'),
        waiting = s.waitingInPart(part, now),
        deferred = s.handed(part, 'wait') - waiting;
    return Card(
        margin: const EdgeInsets.only(bottom: 3),
        child: ExpansionTile(
            dense: true,
            title: Text(
                faDigits('${FinderPart.titles[part]} • ${list.length} مورد'),
                style: const TextStyle(fontSize: 12)),
            subtitle: Text(
                faDigits(
                    '${s.complete[part] ? 'فهرست کامل شد؛ تحویل به برنامه آغاز شده' : 'در حال تکمیل و تحویل هم‌زمان'}'
                    ' • پذیرفته: $accepted • در نوبت: $waiting'
                    '${deferred > 0 ? ' • بررسی مجدد بعدی: $deferred' : ''}'
                    '${s.unanswered(part) == 0 ? '' : ' • پرسش منتظر صفحه جستجو: ${s.unanswered(part)}'}'),
                style: const TextStyle(fontSize: 11, color: muted)),
            children: [
              if (list.isEmpty)
                const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('هنوز موردی پیدا نشده است.',
                        style: TextStyle(fontSize: 11))),
              for (final e in list.take(visible[part]))
                ListTile(
                    dense: true,
                    title: Text(faDigits(e.title),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12)),
                    subtitle: Text(
                        '${e.url}\n${faDigits(status(e))}'
                        '${e.from.isEmpty ? '' : '\nیافته از: ${e.from}'}',
                        style: const TextStyle(fontSize: 10, height: 1.7)),
                    onTap: () => openLink(context, e.url)),
              if (list.length > visible[part])
                TextButton(
                    onPressed: () => setState(() => visible[part] += 40),
                    child: const Text('نمایش ۴۰ مورد بعدی')),
            ]));
  }
}
