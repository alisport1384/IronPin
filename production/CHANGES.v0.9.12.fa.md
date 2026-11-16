# تغییرات نسخهٔ ۰.۹.۱۲ (build 34) — سرعت خواندن و کش ۲۰۰هزارتایی، رفع فریز نمودار و «نمایش نمودار» در رنج

تمرکز این نسخه به‌طور مشخص روی **سرعت خواندن و بارگذاری آرشیوهای بزرگ (۲۰۰٬۰۰۰+ رکورد)**، رفع فریز جستجوی عددی دقیق در تب نمودار، و افزودن دسترسی مستقیم از کاندیدهای تب رنج به نمودار همان کالا بوده است.

## عیب‌یابی

۱. **هزینهٔ خواندن سرد و گرم SQLite در آرشیوهای بزرگ**: بازگشایی مجدد برنامه در آرشیوهای ۱۰۰٬۰۰۰ تا ۲۰۰٬۰۰۰ ردیفی مستلزم خواندن کامل جدول‌های `latest` و `range_index`، دیکد کردن JSON و تخصیص ده‌ها هزار نگاشت (`Map`) و رشته بود. همچنین تنظیمات خواندن SQLite فاقد `WAL` سازگار با `sqflite` (`rawQuery`)، `mmap_size` و `wal_autocheckpoint` بود.
۲. **فشار حافظه در کش‌سازی و جستجوی رنج**: نگهداری هم‌زمان رپّرهای `CandidateEntry` و رشته‌های الحاق‌شدهٔ جستجو در کنار ایندکس رنج، و ارسال داده‌های تکراری `payload` به Isolate در مقیاس ۱۰۰k–۲۰۰k مصرف رم و فشار GC را بالا می‌برد.
۳. **فریز در تب نمودار هنگام جستجوی دقیق با عدد**: ساخت همگام فهرست `chartOptions` روی آرشیوهای بزرگ و اسکن پیوسته با الحاق چند فیلد داخل دیالوگ جستجوی تب نمودار باعث قفل شدن ترد UI در هنگام تایپ یا جستجوی عددی می‌شد.
۴. **نبود مسیر مستقیم از تب رنج به نمودار**: کاربر برای دیدن روند نمودار یک کاندید در تب رنج ناچار بود به تب نمودار برود و دوباره نام محصول را جستجو کند.

## اصلاح‌ها

- **کش باینری مستقیم (`lib/data/fast_cache.dart` و `lib/data/store.dart`)**:
  - افزودن `FastArchiveCache` برای ذخیره و بازیابی باینری `latest()` و `rangeIndexRows()` روی دیسک (`readLatest` / `writeLatest` و `readRangeHeaderAndDecode` / `writeRange`) با حفظ دقت میکروثانیه‌ای `fetchedAt`.
  - اعتبارسنجی کش از طریق جدول `cache_state` و تریگرهای تغییر داده در SQLite؛ در صورت دستکاری دستی یا پاک شدن `range_index` (بررسی `r.payload IS NULL` در `LEFT JOIN range_index`) مسیر SQL بازسازی کامل را انجام می‌دهد.
  - در `writeRange`، ردیف‌های یکتای `payload` قبل از ارسال به ایزولیت (`compute`) با `Int32List`/`Uint8List`/`Int64List` فشرده و یکتا می‌شوند و هنگام خواندن (`fastRows`) مرجع `Map` مشترک بر اساس `payload` به اشتراک گذاشته می‌شود.
- **بهینه‌سازی PRAGMAهای SQLite و دامینه‌ای (`store.dart`, `market.dart`, `product_text.dart`, `range_projection.dart`, `range_session.dart`)**:
  - اعمال `PRAGMA journal_mode=WAL` (از طریق `rawQuery`)، `synchronous=NORMAL`، `temp_store=MEMORY`، `cache_size=-8192`، `mmap_size=16777216` و `wal_autocheckpoint=200`.
  - تک‌پاس شدن `latin()` و `normalize`/`normalizeLower`، مسیر سریع ISO با اعتبارسنجی تقویمی (`DateTime.utc`) در `sourceDate()`، استفاده از `const {}` در `details`، و تطبیق بدون الحاق رشته در `ProductQuery.matchesRow` / `containsNumberToken`.
  - جایگزینی ساختار نگهداری کاندیدها در `RangeSession` با `Int32List _offerSlots` و `Uint8List _nonMetalFlags` و ساخت تنبل شاخص هر خانواده (`PreparedIndex.forFamily`).
- **رفع فریز تب نمودار (`lib/ui/chart_page.dart` و `lib/data/controller.dart`)**:
  - آماده‌سازی برش‌خورده و غیرمسدودکنندهٔ `chartOptions` بالای آستانهٔ ۱۰٬۰۰۰ ردیف همراه با وضعیت `chartOptionsLoading` و ریست پنجره با `_windowChanged`.
  - پیاده‌سازی جستجوی غیرهمزمان و بودجه‌محور در `_AsyncQuoteSearchView` (همراه با `LinearProgressIndicator` حین پردازش و بررسی فیلدبه‌فیلد برای جستجوی عددی دقیق) و بهینه‌سازی `indicatorChanges` به `O(N)`.
- **گزینهٔ «نمایش نمودار» در تب رنج (`lib/ui/range_page.dart` و `lib/main.dart`)**:
  - افزودن اکشن «نمایش نمودار» در انتهای کارت هر کاندید تب رنج (با محدودیت عرض `ConstrainedBox` و دکمهٔ فشرده برای جلوگیری از overflow در صفحه‌های باریک) و ناوبری مستقیم به تب نمودار با `ChartPage.selectedQuote`.

## سنجش

- `flutter analyze` — بدون مسئله (`No issues found!`).
- `flutter test --concurrency=1` — **۵۱۳ از ۵۱۳ تست سبز** (شامل تست‌های تازهٔ `fast_cache_test.dart` و `ui_fixes_test.dart` و تست مقیاس `scale_100k_test.dart`).
- بنچمارک‌های محلی (`tool/perf_archive.dart`, `test/scale_100k_test.dart`, `tool/perf_200k.dart`):
  - ۱۵٬۰۰۰ ردیف: `initMs=744`, `sortAscMs=32`, `searchMs=266`, `rangeConfirmMs=132`, `rssMb=331`.
  - ۱۰۰٬۰۰۰ ردیف: `initMs=3874`, `sortAscMs=376`, `searchMs=575`, `rangeConfirmMs=711`, `rssMb=675`.
  - ۲۰۰٬۰۰۰ ردیف (`latest` ۱۰۰k + `history` ۱۰۰k): `store.latest() cold = 1822ms` ← **`store.latest() CACHED = 311ms`**.

## امضا و انتشار

هر دو معماری (`armeabi-v7a` و `arm64-v8a`) همراه `SHA256SUMS.txt` در GitHub Actions از یک درخت، یک نسخهٔ Flutter و با کلید ثابت پروژه (`16fe4f741ea3ac5c54612fa0361a29f389ac535a9400b202329ce4bde494c4ee`) ساخته و در ریلیز `v0.9.12` منتشر می‌شوند تا مستقیماً روی نسخه‌های قبلی (`0.9.6` تا `0.9.11`) بدون نیاز به حذف نصب شوند.
