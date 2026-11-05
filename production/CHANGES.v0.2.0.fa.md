# تغییرات 0.1.0 → 0.2.0

این جدول مربوط به تغییرات نسبت به بسته تحویل قبلی است، نه نسبت به HEAD اولیه ریپو. حذف فایل یا تغییر وابستگی بیرون از محدوده انجام نشده است. runtime پس از build نهایی تغییر نکرد.

| فایل | تغییر |
|---|---|
| `README.md` | قابلیت‌ها/محدودیت‌های0.2.0، مسیر اسناد و لاگ |
| `android/app/src/main/kotlin/ir/ironpin/ironpin/MainActivity.kt` | پل پوشه اختصاصی و SAF؛ کپی روی executor و محدودیت canonical path |
| `assets/registry.json` | ۲۷ کانال و نتیجه ممیزی؛ بدون ادعای همه کانال‌ها |
| `lib/data/app_logger.dart` | صف appendMarkdown، تقسیم فایل، خروجی و hook خطا |
| `lib/data/controller.dart` | cache/isolate فیلتر، نوسازی بدون reload کامل در هر endpoint، مهاجرت منابع |
| `lib/data/sources.dart` | پارس درisolate، فروشندگان مشهد و۲۶مسیر شواهد کانال |
| `lib/data/store.dart` | schema2/index، batch، decode/planخارجUI، تصمیم ماهانه |
| `lib/domain/market.dart` | مشخصات مستقل و خواندنlegacy، گروه‌بندی دقیق، cacheتاریخ/جستجو |
| `lib/main.dart` | راه‌اندازی لاگ، سؤال ماهانه، ساختlazy تب و حفظstate |
| `lib/ui/calculator_page.dart` | رابط مبتدی و پیشرفته، تبدیل واحد صریح و رویداد محاسبه |
| `lib/ui/chart_page.dart` | انتخاب‌گرlazy جستجو به جای dropdownحجیم، بازخوانی پس ازپاک‌سازی |
| `lib/ui/common.dart` | رویداد لینک بیرونی بدون ذخیره شمارهتلفن |
| `lib/ui/info_page.dart` | مسیر/خروجی لاگ و توضیح نگهداری/نسخه |
| `lib/ui/prices_page.dart` | سایز/ضخامت/گرید و اطلاع فیلترasync و مسیر اعلام مشهد |
| `pubspec.yaml` | فقط افزایش نسخه؛ وابستگی جدید ندارد |
| `docs/CALCULATIONS.fa.md` | واحدهای ساده و مرز تبدیل به موتور |
| `docs/CHANNELS.fa.md` | ممیزی۲۷کانال، منشأ شهر و محدودیت داده مشهد |
| `docs/SOURCES.fa.md` | قرارداد جدید شبکه/مشخصات/نگهداری |
| `docs/TEST_REPORT.v0.2.0.fa.md` | گزارش اجرا و موارد آزموده‌نشده |
| `production/PRODUCTION.fa.md` | سند تولید دسته‌بندی‌شده و دستور بازتولید |
| `production/BASELINE-0.1.0.sha256.json` | hash۶۷فایل مبنای قبل ازاصلاح |
| `production/FILES.sha256` | hashفایل‌های runtime/آزمون/مواد ثابت |
| `production/CHANGES.v0.2.0.fa.md` | همین فهرست فایل‌به‌فایل |
| `research/apk-content-v020.json` | بررسی داخلAPK |
| `research/apk-verification-v020.txt` | aapt/apksigner هر دوABI |
| `research/live-smoke-v020.json` | گزارش شبکه واقعی۱۲مسیر |
| `research/live-smoke-v020-mock-http.json` | شاهد خطای harness اولیه، نه شکست منابع |
| `research/mashhad/channel-audit.json` | داده ممیزی مستقیم۲۷کانال |
| `research/mashhad/checks.json` | نتیجه اولیه دریافت صفحات/نمونه کانال‌های مشهد |
| `test/fixtures/mashhad_telegram.html` | fixture واقعی کپشن/تصویر مشهد |
| `test/revision_test.dart` | آزمون مشخصات، نگهداری/مهاجرت، logger، فشار و کانال‌ها |
| `test/widget_test.dart` | چهار آزمون جدیدlazy/حفظstate/ورق/جرم شاخه درکنار۳قبلی |
| `tool/live_sources.dart` | حفظ CLIقبلی با launcherFlutter برایcompute |
| `tool/live_sources_test.dart` | smokeواقعی اختیاری بدون HTTPoverrideتستwidget |
| `production/verification/*.txt` | خروجی analyze/test/AOT/build/network/APK پس از اجرای واقعی |

شواهد HTML خام بررسی کانال‌ها در workspace نگهداری شده‌اند؛ برای سبک‌بودن بسته سورس، گزارش ساختاریافته و fixture لازم کافی است و HTMLهای کامل تحقیق داخل ZIP نیامده‌اند. Patch فقط فایل‌های تغییرکرده/جدید را شامل می‌شود؛ سورس کامل جداست.

تست نهایی:۹۶آفلاین موفق،۱smokeشبکه موفق،analyzeبدونissue؛ ساخت/امضا دوABIتأیید؛ نصب گوشی/SAFواقعی آزموده‌نشده.
