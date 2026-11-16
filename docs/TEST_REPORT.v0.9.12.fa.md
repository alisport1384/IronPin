# گزارش تست نسخهٔ ۰.۹.۱۲ (build 34)

تاریخ اجرا: ۲۶ آبان ۱۴۰۵ (2026-11-16)

```
flutter analyze              -> No issues found!
flutter test --concurrency=1 -> 513 passed, 0 failed
```

## چه چیزی سنجیده شد

- مجموعهٔ کامل قبلی (۵۱۰ تست) بدون شکست، به‌همراه آزمون‌های تازه:
  - `test/fast_cache_test.dart`: صحت دوررفت کش باینری `latest` و `rangeIndexRows`، حفظ دقت میکروثانیه‌ای `fetchedAt`، ابطال خودکار با تغییر/پاک‌شدن داده‌ها و `range_index`.
  - `test/ui_fixes_test.dart`: جستجوی غیرمسدودکنندهٔ عددی دقیق در تب نمودار و رفتار اکشن «نمایش نمودار» در کاندیدهای تب رنج بدون سرریز چیدمان در عرض ۴۲۰px.
- بنچمارک آرشیو و مقیاس (محیط x86):
  - `test/scale_100k_test.dart`:
    - `SCALE_15000`: `initMs=744 sortAscMs=32 searchMs=266 rangeConfirmMs=132 rssMb=331`
    - `SCALE_100000`: `initMs=3874 sortAscMs=376 searchMs=575 rangeConfirmMs=711 rssMb=675`
  - `tool/perf_archive.dart` (۱۲٬۰۰۰–۱۹٬۵۹۲ ردیف): `write=3067ms`, `rangeIndexRows cold=2210ms`, `warm=429ms`, `selectCandidates=33ms`, `store.latest()=351ms`, `peakRss=366 MB`.
  - `tool/perf_200k.dart` (۲۰۰٬۰۰۰ ردیف، ۳۹۶ MB DB): `200K write=32170ms`, `store.latest() cold=1822ms`, `store.latest() CACHED=311ms`, `rangeIndexRows sql-warm=7006ms` (ادامهٔ انتهایی بنچمارک ۲۰۰k در محیط کانتینر ۱٬۹۸۲ مگابایتی با محدودیت RAM میزبان متوقف شد).

## ساخت APK و انتشار دو معماری

- `versionName='0.9.12'`, `versionCode='34'`, `minSdk=21`, `targetSdk=35`.
- بیلد محلی `armeabi-v7a` بررسی و با `apksigner` و `unzip` (تک‌معماری `lib/armeabi-v7a/*` و هر دو مدل OCR `fas.traineddata` / `eng.traineddata`) تایید شد.
- بیلد رسمی هر دو معماری (`armeabi-v7a` و `arm64-v8a`) توسط GitHub Actions با کلید ثابت پروژه امضا و در ریلیز `v0.9.12` منتشر می‌شود تا ارتقای مستقیم روی `v0.9.6` تا `v0.9.11` بدون حذف داده انجام شود.

## آزمایش‌نشده

- تست تعاملی روی گوشی واقعی اندرویدی پس از دریافت فایل نهایی GitHub Release با کاربر است.
