import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../data/app_logger.dart';
import '../data/backup.dart';
import '../data/controller.dart';
import 'common.dart';

class BackupPanel extends StatefulWidget {
  final MarketController c;
  const BackupPanel({super.key, required this.c});
  @override
  State<BackupPanel> createState() => _BackupPanelState();
}

class _BackupPanelState extends State<BackupPanel> {
  String? status;
  bool working = false;
  Future<void> run(bool importing) async {
    final c = widget.c;
    if (working || c.busy || c.transferring) return;
    var restoreSettings = false;
    if (importing) {
      final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => StatefulBuilder(
              builder: (ctx, update) => AlertDialog(
                    title: const Text('بازیابی ادغامی بکاپ'),
                    content: SingleChildScrollView(
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                      const Text(
                          'قیمت‌ها و تاریخچه بدون حذف داده‌های فعلی ادغام می‌شوند؛ تکراری‌ها دوباره ثبت نمی‌شوند. '
                          'قیمت جدیدتر مقدم است. پیش‌فرض، حفظ تنظیمات موجود و بازیابی تنظیمات غایب است؛ کانال‌ها ادغام می‌شوند. '
                          'برای بازیابی انتخاب‌های گوشی قبلی، گزینه زیر را روشن کنید. فایل نامعتبر هیچ تغییری ایجاد نمی‌کند.'),
                      CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: restoreSettings,
                          title: const Text(
                              'تنظیمات کاربری بکاپ، از جمله روشن/خاموش بودن منابع، جایگزین شوند. وضعیت هوش جستجوگر ۲ در هر حالت از فایل برمی‌گردد.',
                              style: TextStyle(fontSize: 12)),
                          onChanged: (v) =>
                              update(() => restoreSettings = v ?? false)),
                    ])),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('انصراف')),
                      FilledButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('انتخاب فایل'))
                    ],
                  )));
      if (ok != true || !mounted || c.busy || c.transferring) return;
    }
    c.transferState(true);
    setState(() {
      working = true;
      status = importing
          ? 'در حال انتخاب و بررسی بکاپ…'
          : 'در حال آماده‌سازی بکاپ کامل…';
    });
    try {
      final backup = MarketBackup(c.store);
      if (importing) {
        final result =
            await backup.importFromPicker(restoreSettings: restoreSettings);
        if (result != null) await c.imported();
        if (mounted) {
          setState(() => status = result == null
              ? 'بازیابی لغو شد؛ داده تغییری نکرد.'
              : 'ادغام انجام شد: ${fmt(result.latest)} قیمت افزوده/به‌روز، ${fmt(result.history)} ثبت تاریخی، '
                  '${fmt(result.settings)} تنظیم و ${fmt(result.sync)} وضعیت منبع. ${fmt(result.skipped)} رکورد تکراری/مقدم‌نبودن کنار گذاشته شد.');
        }
      } else {
        final destination = await backup.exportToPicker();
        if (mounted) {
          setState(() => status = destination == null
              ? 'خروجی لغو شد.'
              : 'بکاپ کامل در فایل انتخاب‌شده ذخیره شد.');
        }
      }
    } catch (e, stack) {
      AppLogger.instance.capture(e, stack, section: 'backup');
      if (mounted) {
        setState(() => status = e is FormatException
            ? e.message
            : e is PlatformException
                ? 'انتخاب یا خواندن/نوشتن فایل انجام نشد؛ فایل معتبر، فضای خالی و دسترسی پوشه را بررسی کنید.'
                : 'عملیات بکاپ انجام نشد؛ داده‌های قبلی حذف نمی‌شوند. فضای خالی و سلامت فایل را بررسی کنید.');
      }
    } finally {
      c.transferState(false);
      if (mounted) setState(() => working = false);
    }
  }

  @override
  Widget build(BuildContext context) => ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('ورود و خروج بکاپ کامل'),
          children: [
            const Text(
                'قیمت‌های جاری، تمام تاریخچه موجود، منابع، تنظیمات، وضعیت دریافت و وضعیت هوش جستجوگر ۲. '
                'فایل محلی ironpin.jsonl؛ بدون حساب، سرور یا ارسال داده. لاگ‌های Markdown خروجی مستقل دارند. '
                'سقف هر فایل ۵۱۲ مگابایت و یک میلیون رکورد است؛ فایل را ویرایش نکنید. '
                'این بکاپ رمزگذاری‌شده نیست؛ در جای امن نگه دارید.',
                style: TextStyle(fontSize: 11, height: 1.9)),
            const SizedBox(height: 8),
            OutlinedButton.icon(
                onPressed: working || widget.c.busy || widget.c.transferring
                    ? null
                    : () => run(false),
                icon: const Icon(Icons.save_alt),
                label: const Text('خروجی بکاپ کامل')),
            OutlinedButton.icon(
                onPressed: working || widget.c.busy || widget.c.transferring
                    ? null
                    : () => run(true),
                icon: const Icon(Icons.restore),
                label: const Text('ورود و ادغام بکاپ')),
            if (working) const LinearProgressIndicator(),
            if (status != null)
              Padding(
                  padding: const EdgeInsets.all(10),
                  child: Text(status!,
                      style: const TextStyle(fontSize: 12, height: 1.8))),
          ]);
}
