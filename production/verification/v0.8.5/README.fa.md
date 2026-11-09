# شواهد قابل ممیزی ۰.۸.۵

## وضعیت

این فایل‌ها خروجی واقعی مرحلهٔ ساخت APK پذیرفته‌شده هستند، نه اجرای دوباره در مرحلهٔ پوش. در مرحلهٔ پوش فقط سندها/شواهد تکمیل شده‌اند؛ SHA-256 تمام ورودی‌های اجراییِ ثبت‌شده در `release-metadata.json` با سورس جاری تطبیق داده شد. کد APK پس از تأیید مثبت کاربر تغییر نکرده است.

`acceptance.json` تأیید «عالی شد» کاربر را ثبت می‌کند. دستگاه پیش‌تر Android 10 و RAM حدود ۳–۴ GB توصیف شده بود. آزمون مستقل دستگاه، سنجهٔ FPS/heap اندروید و تأیید تمام گوشی‌ها انجام نشده‌اند.

## فایل‌ها

| فایل | معنا |
| --- | --- |
| `analyze.txt` | تحلیل بدون ایراد |
| `tests.txt` | مجموعهٔ نهایی، ۳۶۲ تست موفق |
| `aot-armeabi-v7a.txt` | کامپایل جداگانهٔ AOT برای پرهیز از رقابت RAM با Gradle |
| `build-armeabi-v7a.txt` | بیلد موفق APK release؛ شامل آماده‌سازی SDK موردنیاز Gradle |
| `apk-badging.txt` | application ID، versionCode 1021، نسخهٔ ۰.۸.۵، minSdk 21، targetSdk 35 و تنها ABI برابر armeabi-v7a |
| `apk-signature.txt` | تأیید امضای APK و گواهی عمومی؛ کلید خصوصی نیست |
| `release-metadata.json` | SHA فایل APK، ورودی‌های اجرایی و حدود تأیید در زمان ساخت |
| `acceptance.json` | به‌روزرسانی پذیرشِ گزارش‌شده پس از تحویل، جدا از نتایج ساخت |
| `memory-comparison.json` | میانهٔ سه فرایند تازهٔ هر نسخه |
| `cold-before-{1,2,3}.json` | دادهٔ خام سه اجرای نسخهٔ تحویل ۰.۸.۴ |
| `cold-after-{1,2,3}.json` | دادهٔ خام سه اجرای ۰.۸.۵ |
| `memory-before.json` / `memory-after.json` | اجرای اولیه در همان فرایند seed؛ کاهش قابل اتکا نشان نداد |
| `memory-in-seed-process-*.txt` | لاگ همان اجرای اولیه؛ برای پرهیز از پنهان‌کردن نتیجهٔ نامطلوب |
| `baseline-0.8.4.patch` | بازسازی سورس نسخهٔ میانی از main مبنا، برای مقایسهٔ قبل/بعد |

فایل‌های `.txt` نسخهٔ نام‌گذاری‌شدهٔ لاگ‌های اصلی هستند؛ محتوای نتیجه‌ها بازنویسی نشده است. `release-metadata.json` وضعیت زمان بیلد، مانند `deviceTested:false`، را نگه می‌دارد؛ تأیید بعدی کاربر در `acceptance.json` آمده و آن را به آزمون دستگاه توسط عامل تبدیل نمی‌کند.

## تکرار آزمون و بیلد

Flutter 3.24.5، Dart 3.5.4، JDK 17، SDK 35؛ وابستگی‌ها از lockfile:

```sh
flutter pub get
flutter analyze
flutter test --concurrency=1 --reporter expanded
flutter build apk --release --split-per-abi --target-platform android-arm
```

روی میزبان کم‌حافظه، AOT را ابتدا بدون Gradle بسازید:

```sh
flutter --quiet assemble --no-version-check \
  --depfile build/app/intermediates/flutter/release/flutter_build.d \
  --output build/app/intermediates/flutter/release \
  -dTargetFile=lib/main.dart -dTargetPlatform=android -dBuildMode=release \
  -dTrackWidgetCreation=true -dTreeShakeIcons=true -dFlavor= \
  -dAndroidArchs=android-arm -dMinSdkVersion=21 \
  android_aot_bundle_release_android-arm
flutter build apk --release --split-per-abi --target-platform android-arm
```

این دستورات هم‌زمان با مجموعهٔ تست یا یک بیلد دیگر اجرا نشوند. برای آپدیت نصب موجود، کلید صحیح را از مسیر امن خارج ریپو به Gradle بدهید. در نبود متغیرهای امضا، بیلد به debug برمی‌گردد و الزاماً روی نسخهٔ نصب‌شده آپدیت نمی‌شود. کلید، رمز و توکن را در فرمان‌های ثبت‌شدنی/گزارش عمومی نگذارید.

## تکرار مقایسهٔ حافظه

ابزار: `tool/perf_refresh_memory.dart`، ۶۰۰۰ پیشنهاد، ۶۰۰۰ history، شاهد حدود ۲ KiB و ۱۲۰۰۰ ورودی انتخاب ایندکس؛ بدون شبکه.

۱. یک مسیر موقت **تازه و خالی** برای دیتابیس انتخاب کنید؛ seed روی دیتابیس موجود دوباره اجرا نشود:

```sh
IRONPIN_MEMORY_DB=/absolute/tmp/ironpin-memory.db \
IRONPIN_MEMORY_MODE=seed \
flutter test tool/perf_refresh_memory.dart --concurrency=1 --reporter expanded
```

۲. برای ۰.۸.۵، هر اجرا را در فرایند تازه روی همان دیتابیس انجام دهید؛ این مثال را سه بار با نام خروجی متفاوت اجرا کنید:

```sh
IRONPIN_MEMORY_DB=/absolute/tmp/ironpin-memory.db \
IRONPIN_PERF_OUTPUT=/absolute/tmp/after-1.json \
flutter test tool/perf_refresh_memory.dart --concurrency=1 --reporter expanded
```

۳. نسخهٔ تحویل ۰.۸.۴ را در worktree جدا از مبنای `03b4f04c6d97f83311fa907bb90356dd9e82e5cc` بازسازی کنید:

```sh
git worktree add --detach /absolute/tmp/ironpin-084 03b4f04c6d97f83311fa907bb90356dd9e82e5cc
git -C /absolute/tmp/ironpin-084 apply /absolute/path/to/production/verification/v0.8.5/baseline-0.8.4.patch
```

ابزار جاری `tool/perf_refresh_memory.dart` را به همان مسیر در worktree کپی و `flutter pub get` اجرا کنید. برای هر یک از سه فرایند نسخهٔ قبل، علاوه بر مسیر همان دیتابیس و خروجی JSON، `IRONPIN_EXPECT_WORKER=1` تنظیم شود. این گزینه فقط به ابزار می‌گوید منتظر آماده‌شدن کارگر خودکار نسخهٔ قبلی بماند؛ رفتار برنامه را تغییر نمی‌دهد. بدون این گزینه ممکن است اندازه‌گیری نسخهٔ قبل پیش از پایان کار خودکار تمام شود.

خروجی ابزار نوسان‌پذیر است و assertion نسبت کاهش ندارد. نمونه‌برداری RSS هر ۵ ms می‌تواند قلهٔ کوتاه را از دست بدهد؛ maxRSS نیز ثبت شده است. این روش خواندن سرد + پایان نوسازی را می‌سنجد، نه تمام refresh شبکه‌ای یا حافظهٔ دستگاه Android. تعداد ردیف‌ها در هر دو نسخه باید یکسان بماند.

## امضا و APK

- نام فایل تحویلی: `IronPin-0.8.5-armeabi-v7a-release.apk`.
- SHA-256: `c97c09447d98b4bedbeb907c425935f4fd3be7868a3d4200b5fc37b3a4eb1e28`.
- SHA-256 گواهی عمومی: `d1198166b1c478cf961f0b1a3df21b2ed8e4f454298d51d5685948585cef33a9`؛ با APK تحویل ۰.۸.۴ برابر بررسی شد.
- باینری APK و کلید خصوصی عمداً در Git نیستند. صرف پوش سورس به معنی ساخت GitHub Release یا انتشار فروشگاهی نیست.
