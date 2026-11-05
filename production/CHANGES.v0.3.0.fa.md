# تغییرات0.2.0 → 0.3.0

مبنا **ZIPسورس تحویلی0.2.0** است؛ HEAD/indexاولیه ریپو مبنا نیست. حذف فایل و تغییر معماری/وابستگی انجام نشده است. runtimeپس از buildنهایی عوض نشده است. رکورد کانال، لینک تماس و مبدل عددی با هم یکی نیستند؛ دریافت خودکار عددی ایتا/بله/روبیکا تحویل نشده است.

| فایل تغییرکرده/جدید | نقش |
|---|---|
| `README.md` | وضعیت/قرارداد0.3.0 و دستورات |
| `assets/registry.json` | ۳۲تلگرام/۳۹پیوند دیگر با نوع و منشأ |
| `docs/CALCULATIONS.fa.md` | قرارداد/گزارش به‌روز همین نسخه؛ گزارش قدیمی حذف نشده |
| `docs/CHANNELS.fa.md` | قرارداد/گزارش به‌روز همین نسخه؛ گزارش قدیمی حذف نشده |
| `docs/SOURCES.fa.md` | قرارداد/گزارش به‌روز همین نسخه؛ گزارش قدیمی حذف نشده |
| `docs/TEST_REPORT.v0.3.0.fa.md` | قرارداد/گزارش به‌روز همین نسخه؛ گزارش قدیمی حذف نشده |
| `lib/data/app_logger.dart` | فقط برچسب نسخه0.3.0 |
| `lib/data/sources.dart` | پنج تلگرام اختیاری و چهارمدخل تماس مشهد با سطح احراز |
| `lib/domain/market.dart` | areaM2nullable، گراف تبدیل verified_only، واحد مرتبط و مبنا |
| `lib/ui/info_page.dart` | دایرکتوری پیام‌رسان با فیلتر نام/شهر/platform و Wrapتماس |
| `lib/ui/prices_page.dart` | UnitPricesدر فید/جزئیات، دو اعشار، اصلی/تبدیل/نامشخص |
| `production/BASELINE-0.2.0.sha256.json` | manifestدقیقZIPمبنای0.2.0 |
| `production/CHANGES.v0.3.0.fa.md` | همین فهرست تغییرات |
| `production/FILES.sha256` | hashفایل‌های runtime/test |
| `production/PRODUCTION.fa.md` | ثبت دسته‌بندی‌شده0.3.0 و حفظ تاریخچه قبلی |
| `production/REQUEST-v0.3.0.fa.md` | انتخاب verified_only و وضعیت نهایی |
| `production/verification/v0.3.0/analyze.txt` | شاهد اجرای واقعی ابزارهای همین نسخه |
| `production/verification/v0.3.0/aot.txt` | شاهد اجرای واقعی ابزارهای همین نسخه |
| `production/verification/v0.3.0/apk.txt` | شاهد اجرای واقعی ابزارهای همین نسخه |
| `production/verification/v0.3.0/build.txt` | شاهد اجرای واقعی ابزارهای همین نسخه |
| `production/verification/v0.3.0/exit-status.json` | شاهد اجرای واقعی ابزارهای همین نسخه |
| `production/verification/v0.3.0/live-network.txt` | شاهد اجرای واقعی ابزارهای همین نسخه |
| `production/verification/v0.3.0/tests.txt` | شاهد اجرای واقعی ابزارهای همین نسخه |
| `pubspec.yaml` | فقط نسخه0.3.0+3؛ بدون تغییر وابستگی |
| `research/apk-content-v030.json` | بررسی واقعی APKهای0.3.0 |
| `research/apk-verification-v030.txt` | بررسی واقعی APKهای0.3.0 |
| `research/iran-channels-v030/audit.py` | ممیزی محدود لینک‌های عمومی؛ بدونAPIحدسی |
| `research/iran-channels-v030/browser-reviewed.json` | شواهد ساختاریافته یا خلاصه مشاهده منابع عمومی |
| `research/iran-channels-v030/discovery.json` | شواهد ساختاریافته یا خلاصه مشاهده منابع عمومی |
| `research/iran-channels-v030/published-links.json` | شواهد ساختاریافته یا خلاصه مشاهده منابع عمومی |
| `research/iran-channels-v030/verified.json` | شواهد ساختاریافته یا خلاصه مشاهده منابع عمومی |
| `research/live-smoke-v030.json` | نتیجه شبکه واقعی۱۷مسیر و نمونه تبدیل‌ها |
| `test/unit_prices_test.dart` | ۱۶آزمون تازه مدل/رابط/فهرست و سازگاری |
| `test/widget_test.dart` | یک‌آزمون تازه فیلترنام/شهر/پیام‌رسان |
| `tool/live_sources_test.dart` | سوئیچ opt-inپنج مسیر و ثبت قابلیت تبدیل/نمونه |

35فایل تغییرکرده/جدید؛ بدون حذف.۱۱۳آفلاینpass، analyzeپاک،۱۷/۱۷smokeپارس،هر دوAPKو امضا تأیید؛ گوشی/SAFواقعی و commit/pushانجام نشده‌اند. patchروی مبنا و برابری byteهمه فایل‌ها هنگام بسته‌بندی بررسی می‌شود؛ نتیجه واقعی درPACKAGING.jsonثبت است.
