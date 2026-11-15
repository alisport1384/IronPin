# گزارش تست نسخهٔ ۰.۹.۱۱ (build 33)

تاریخ اجرا: ۲۵ آبان ۱۴۰۵ (2026-11-15)

```
flutter analyze --no-pub     -> No issues found!
flutter test --concurrency=1 -> 510 passed, 0 failed
```

## چه چیزی سنجیده شد

- مجموعهٔ کامل ۰.۹.۱۰ (۵۰۹ تست) بدون شکست، به‌همراه تست تازهٔ
  `packedPriceOf reads exactly what unpackPrices reads` (برابری روی
  جدول‌های فشردهٔ خالی، تک‌واحدی، چندواحدی، مقدار نامعتبر و اعشاری).
- برابری خروجی مسیرهای تازه با قدیم از همان تست‌های قبلی قفل است:
  `CandidateSelector` = `selectCandidates`، و ترتیب جدیدترین‌اول +
  اولویت مشهد در تست‌های تب قیمت و `scale_100k_test`.
- بنچمارک مقیاس (محیط ساخت x86، JIT — عدد گوشی نیست):
  `SCALE_100000 initMs=4343 sortAscMs=405 searchMs=934 rangeConfirmMs=1035`

## ساخت APK (armeabi-v7a)

- `versionName='0.9.11'`, `versionCode='33'`, `minSdk=21`, `targetSdk=35`.
- فقط `lib/armeabi-v7a/*` و هر دو مدل OCR؛ بررسی با `aapt` و `apksigner`.
- ساخت محلیِ مرحلهٔ تست با کلید پایدار محلی این محیط بررسی شد؛ ریلیز رسمی
  را GitHub Actions با کلید ثابت پروژه می‌سازد و امضایش با
  `apksigner verify --print-certs` روی فایل‌های ریلیز راستی‌آزمایی می‌شود
  (جزئیات: `production/CHANGES.v0.9.11.fa.md`).

## آزمایش‌نشده

- سنجش فریم روی گوشی واقعی ۳۲بیتی انجام نشده؛ ادعای این نسخه (سقف
  ~۵ms برای هر بلاک همگامِ اسکن و خطی‌شدن مرتب‌سازی پیش‌فرض) در کد و
  تست قفل است، اما تجربهٔ نهایی اسکرول روی سخت‌افزار کاربر سنجیده نشده.
