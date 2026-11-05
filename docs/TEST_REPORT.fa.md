# گزارش ساخت و آزمون IronPin 0.1.0

**تاریخ: ۱۴ آبان ۱۴۰۵ / 2026-11-05**

## نتیجه آزمون‌ها

- `flutter analyze`: بدون issue.
- `flutter test --concurrency=1`: **۷۸ آزمون موفق**؛ بدون آزمون ردشده.
- ساخت release برای `armeabi-v7a` و `arm64-v8a`: موفق.
- بررسی APK با `aapt`: نام بسته، حداقل/هدف SDK و ABI جداگانه تایید شد.
- بررسی امضا با `apksigner verify`: هر دو APK معتبر؛ امضای آزمایشی Android Debug با v1 و v2.
- **نصب/اجرا روی گوشی فیزیکی یا شبیه‌ساز اندروید انجام نشده است.** آزمون رابط، Flutter widget test بوده؛ بررسی APK، آزمون نصب دستگاه نیست.

## دامنه ۷۸ آزمون

فرمول‌های ۱۵ روش وزن، متراژ، سطح، پوشش، مش و هزینه؛ ورودی نامعتبر؛ تبدیل تومان/کیلو بر اساس وزن صریح؛ فیلتر شهر فروشنده در مقابل بارگیری؛ اولویت مشهد؛ ترتیب قیمت؛ تازگی تاریخ؛ round-trip داده؛ پارسرهای دسکتاپ/موبایل واقعی؛ قرنطینه مبلغ ناسازگار؛ عدم تبدیل قیمت حداقل دسته به پیشنهاد کالا؛ ناموجود؛ پیام تلگرام با واحد نامشخص؛ HTTP ناموفق؛ SQLite، تاریخچه، snapshot و حفظ داده در خطا؛ جلوگیری از تنزل به نرخ قدیمی‌تر؛ چهار تب RTL و چیدمان باریک؛ محاسبه واقعی با رابط.

## آزمون شبکه زنده

در آخرین آزمون، **هر ۹ مسیر عددی** پاسخ قابل پارس داشتند. شمار ردیف با تعداد قیمت عددی متفاوت است؛ ردیف تماس/ناموجود هم حفظ می‌شود. این نتیجه نمونه همان زمان و همان محیط است، نه تضمین دسترسی همیشگی از شبکه گوشی.

| مسیر | ردیف دریافت‌شده | ردیف قیمت عددی | نتیجه |
| --- | --- | --- | --- |
| [melal-rebar](https://ahanmelal.com/rebar/ribbed-rebar-price) | 440 | 351 | parsed |
| [melal-sheet](https://ahanmelal.com/steel-sheet) | 335 | 279 | parsed |
| [melal-beam](https://ahanmelal.com/beam/ipe-beam-price) | 82 | 65 | parsed |
| [melal-angle](https://ahanmelal.com/steel-t-bars-studs-angles/steel-angle-price) | 196 | 144 | parsed |
| [melal-channel](https://ahanmelal.com/steel-t-bars-studs-angles/steel-stud-price) | 93 | 76 | parsed |
| [melal-profile](https://ahanmelal.com/steel-profile-square-tube) | 296 | 294 | parsed |
| [melal-pipe](https://ahanmelal.com/metal-pipe) | 290 | 255 | parsed |
| [asre-esfahan](https://asreahan.com/rebar/esfahan-steel) | 11 | 8 | parsed |
| [asre-khorasan](https://asreahan.com/rebar/khorasan-steel) | 10 | 8 | parsed |

جمع نمونه: **1753 ردیف**، شامل **1480 ردیف قیمت عددی**. عددی بودن، اثبات تازه‌بودن امروز یا تایید موجودی قطعی نیست؛ تاریخ خود نرخ در اپ حفظ می‌شود.

## مشخصات فایل نصب

| فایل | اندازه | ABI | versionCode | SHA-256 |
| --- | --- | --- | --- | --- |
| IronPin-0.1.0-arm64-v8a.apk | 7.90 MiB | arm64-v8a | 2001 | `dabcb355b2623d7c5e0a685d15a43fc55eead04378c8ef1e6b8568e0812b7725` |
| IronPin-0.1.0-armeabi-v7a.apk | 7.52 MiB | armeabi-v7a | 1001 | `2781b19468bfac0e70b49402452cd4b184dcb0e34249c91f1a98bcb9d1ccf6d9` |

بسته: `ir.ironpin.ironpin`؛ versionName: `0.1.0`؛ minSdk: `21`؛ target/compile SDK: `35`. اختلاف versionCode دو APK، رفتار تفکیک ABI در Flutter است.

## حدود تحویل

- بدون بک‌اند و بدون ادعای دریافت دائمی هنگام بسته‌بودن اپ.
- تاریخچه از دریافت روی همین دستگاه ساخته می‌شود؛ داده گذشته ساختگی ندارد.
- فهرست تحقیق ۳۷ منبع، به معنی ۳۷ اتصال عددی نیست؛ پوشش خودکار این نسخه ۹ مسیر از دو مجموعه است.
- اتصال عددی خودکار فروشندگان مشهد و همه شهرها کامل نشده است؛ اولویت، فیلتر و اطلاعات تماس مشهد آماده است. شهر بدون داده، با پیام صریح نمایش داده می‌شود.
- تلگرام اختیاری، پیش‌فرض خاموش و برای پیام‌های فاقد واحد تاییدشده غیرعددی است.
- این APKها برای **آزمون** با کلید آزمایشی امضا شده‌اند؛ انتشار عمومی به کلید امضای مالک نیاز دارد.
- workflow به پروژه اضافه شده، اما روی GitHub اجرا نشده؛ هیچ push انجام نشده است.

## مدارک قابل تکرار

کد آزمون‌ها در `test/`، نمونه‌های واقعیِ محدودشده در `test/fixtures/`، گزارش شبکه در `research/live-smoke.json`، خلاصه بررسی APK در `research/apk-verification.txt` و workflow ساخت در `.github/workflows/android.yml` قرار دارد.
