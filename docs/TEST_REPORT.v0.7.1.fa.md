# گزارش آزمون۰.۷.۱+۱۰

تاریخ:۱۶آبان۱۴۰۵ /2026-11-07؛ Flutter3.24.5، Dart3.5.4، JDK17؛ مبنا۰.۷.۰+۹.

## اجرای واقعی میزبان
- `flutter test --concurrency=1 --reporter expanded`: **۲۶۲آزمون موفق**،۴۰ثانیه؛ `offline-final.log`.
- `flutter analyze`: **No issues found**؛ `analyze.log` نهایی. هشدار style ابزار smoke اصلاح شد؛ runtime پس از capture ورودی ساخت تغییر نکرده است.
-۱۶آزمون جدید: شهر همه نقش‌های صریح/مرزواژه/نبود حدس؛ persistence و shielding؛ logging defaultOFF/optin/OFF و persistence؛ equivalence worker و آمار domain/واحد مجزا/ابهام/کاتالوگ/عدم رأی refetch؛ empty terminal؛ خطای worker، deadline، retry و cancel؛ heartbeat۸۷۳۰ردیف؛ عدم duplicate endpoint؛ متن واقعی مشاهده‌شده فاقد ارز/واحد و نرخ قدیمی؛ رد خرید/خدمات؛ دریافت هر دو شهر با scope مشهد؛ پایداری رنج در۳۰revision و پاک‌شدن با شهر جدید؛ deadline UI خواندن و حفظ DB/retry؛ Back انتخاب‌گر شهر بدون پاک‌کردن scope و انتخاب صریح همه شهرها.
- تست UI deadline از timeout خواندن SQL استفاده می‌کند؛ kill deadline خود worker جدا در unit test واقعی isolate بررسی شد. لاگ‌های تلاش اول و دوم شکست assertionهای قدیمی/طراحی تست را نگه می‌دارند و مدرک قبولی نهایی نیستند.
- رگرسیون کامل خانواده‌ها، مشخصات اختیاری،۴۸ساعت/market_date، ریال→تومان، واحدهای نامعلوم، dedup اعلام، backup/admission/schema/history، فارسی، overflow صفحه باریک و نوسازی فقط دستی نیز گذشت.

## کارایی میزبان، نه گوشی
`RANGE071_METRIC rows=8730 selected=4365 elapsedMs=780 mainTimerTicks=719 progress=47`.
فیلتر۸۰۰۰→۴۰۰۰ردیف۲۱۲ms و۱۹۱tick. نتیجه synthetic هم‌اندازه cache لاگ است؛ DB کاربر یا FPS/حافظه/پاسخ‌گویی گوشی با آن جایگزین نشده است. deadlineها حدود انتظار UI هستند و اگر سیستم خود برنامه را suspend/terminate کند اجرای timer تضمین نمی‌شود.

## شبکه واقعی، جدا از آفلاین
SourceClient یک صفحه تلگرام بنیان: parsed۳۱ردیف/۲۷شاهد مبلغ،۱۶۳۰ms،۰رنج تازه قابل مقایسه. ایتا: timeout۲۲ثانیه؛ مشاهده fetch_page عمومی آن موفق ولی قدیمی۱۴۰۴ بود. نتیجه همه۷۴منبع یا دستگاه تأیید نشده است. `live-bonyan.json` و `live-bonyan.log` شاهدند؛ خروج موفق smoke فقط کامل‌بودن ثبت تلاش‌هاست.

## لاگ کاربر
۷۲دریافت با۸۷۳۰cache تمام شده؛ رویداد range ندارد؛ علت قطعی فریز در فایل ثبت نیست. رفع مسیر تعویض/انتظار بی‌پایان با تست رگرسیون میزبان بررسی شده، ولی بازآزمایی روی گوشی کاربر باقی است.

## ساخت/امضا
دو ABI جدا و ترتیبی با حافظه‌بان روی میزبان۲GiB و precompile AOT بدون رقابت Gradle ساخته می‌شوند. نتیجه نهایی فقط پس از موفقیت ابزارها در `build-summary.json`، `apk-metadata.json` و `input-verification.json` معتبر است؛ توصیف روش، خودِ مدرک موفقیت نیست. همان گواهی AndroidDebug پیشین، نه کلید انتشار فروشگاهی؛ package ثابت/min21/target35 و codes1010/2010. APKها با aapt، apksigner v1/v2، ABI/ELF، hash registry، markerهای جدید AOT و SAF/dex بررسی می‌شوند.

## آرشیو مستقل
چهار APK۰.۵/۰.۵.۱ در آرشیو۱۲۳۲۰۲۴۴بایتی؛ decode مستقل Python، SHA و مقایسه بایت‌برابر پیش از حذف مسیر مستقیم **موفق**. هر دو پایه۰.۷.۰ دست‌نخورده‌اند. `archive-result.json`.

## آزموده‌نشده
نصب/ارتقا بدون uninstall روی گوشی، SAF واقعی، عملکرد روی RAM کم گوشی، FPS، رفتار pause سیستم، دریافت همه۷۴مسیر روی شبکه ایران و داده واقعی خصوصی رنج کاربر. پیش از ارتقا بکاپ کامل بگیرید؛ داده با uninstall حفظ نمی‌شود. وضعیت پوش جدا و فقط پس از تأیید ریموت گزارش می‌شود؛ credential قبلی بازاستفاده نمی‌شود.


### ثبت ساخت و ممیزی نهایی۰.۷.۱
هر دو ساخت نهایی exit۰: ARM32، AOT۲۴.۴۵s وGradle۵۶.۱s؛ ARM64، AOT۲۷.۲۸s وGradle۵۹.۷۲s. حداقل حافظه آزاد حینGradle۳۹۶.۲MiB؛ حافظه‌بان فعال بود و این بار توقفی نداشت. دو APK با aapt/apksigner/ABI/ELF/AOT/SAF بررسی شدند و ورودی runtime قبل/بعد ساخت بایت‌برابر بود. codes۱۰۱۰/۲۰۱۰ و همان cert `360dabf5f2cf2ee39c9dc90bcb093a381e93a17d6a4f87d978a41d9ecff588b4`، v1/v2 تأیید شدند؛ نصب واقعی گوشی همچنان آزموده نشده است. جزئیات اندازه/SHA در `apk-metadata.json` نسخه قرار دارد.
