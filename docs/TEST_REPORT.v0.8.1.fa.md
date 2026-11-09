# گزارش آزمون IronPin 0.8.1

تاریخ ساخت: ۱۸ آبان ۱۴۰۵ (2026-11-09) • Flutter 3.24.5 / Dart 3.5.4 • JDK 17 (Temurin 17.0.21)
• Android SDK 35 / build-tools 35.0.0.

## تحلیل ایستا

```
flutter analyze
No issues found!
```

## آزمون‌های واحد و ویجت

```
flutter test --concurrency=1
+341: All tests passed!
```

| گروه | شمار |
| --- | --- |
| آزمون‌های پیشین (۰.۸.۰) | ۳۳۹ |
| تازه: قیمت کاندید | ۲ |

تازه‌ها در `test/range_candidate_price_test.dart`:

1. «مبلغ اعلام‌شده، قیمت اصلی است حتی بدون واحد» — `priceFor('original')` برای ردیف بی‌واحد
   عدد را برمی‌گرداند، `priceFor('kg')` همچنان `null` است، و برای ردیف با ارز نامعلوم قیمت تومانی
   ساخته نمی‌شود.
2. «هر کارت کاندید یک قیمت چاپ می‌کند» — چهار حالت: واحددار (قیمت هم‌مبنا)، بی‌واحد (مبلغ +
   «واحد نامشخص»)، بی‌واحد و بی‌ارز (عدد + ارز نامعلوم)، و بی‌مبلغ (تنها حالت «بدون قیمت»).

## بازتولید علت روی داده واقعی مخزن

پیش از اصلاح، با `SourceParser.parse` روی fixtureهای واقعی و پرسش رنج «تیرآهن»:

| fixture | کاندید | state پیش از اصلاح | پس از اصلاح |
| --- | --- | --- | --- |
| `telegram.html` | ۸ | `amount=20181000`, `currency=تومان`, `unit=unknown`, `tomanFor('original')=null` → «بدون قیمت» | `tomanFor('original')=20181000` → «۲۰٬۱۸۱٬۰۰۰ تومان • واحد نامشخص» |
| `hayper_sheets_observed.html` | ۱۹ | `amount=475000`, `currency=ریال`, `unit=unknown`, `tomanFor('original')=null` | `tomanFor('original')=47500` → «۴۷٬۵۰۰ تومان • واحد نامشخص» |
| `khabazzade_*` (ارز نامعلوم) | — | «بدون قیمت» | «۱۸۴٬۰۰۰ نامشخص» |

علت: `_unitPrices` برای ردیف با `unit=unknown` خالی ساخته می‌شد و `priceFor('original')` هم از
همان نقشه می‌خواند؛ پس مبلغ ذخیره‌شده هیچ‌گاه به کارت نمی‌رسید.

## منابع

- `enabled` از اولین اجرا شامل همهٔ ۸۲ مسیر ثبت‌شده است.
- مهاجرت `allRegisteredSourcesEnabledVersion` → `'4'`: روی نصب موجود یک‌بار همه روشن می‌شوند و
  opt-out بعدی محفوظ می‌ماند (آزمون‌های `revision_test` و `release_v072_test` همین قرارداد را
  با نشانگر تازه بررسی می‌کنند).

## ساخت APK

```
flutter build apk --release --target-platform android-arm
✓ Built build/app/outputs/flutter-apk/app-release.apk (8.2MB)
```

| مشخصه | مقدار |
| --- | --- |
| فایل تحویل | `/home/user/deliverables/IronPin-armeabi-v7a-release.apk` |
| اندازه | ۸٬۲۳۷٬۵۲۴ بایت |
| SHA-256 | `676d02193f0b712f257f05763e3aab4f0001556ef009368c42e064baa41a650f` |
| package | `ir.ironpin.ironpin` |
| versionName / versionCode | `0.8.1` / `17` |
| min / target SDK | ۲۱ / ۳۵ |
| ABI | فقط `armeabi-v7a` |
| امضا | v1+v2 با کلید **debug** (برای آزمون دستگاهی، نه انتشار در فروشگاه) |

آزمون روی گوشی واقعی انجام نشده است؛ این APK برای همان آزمون تحویل داده می‌شود.
