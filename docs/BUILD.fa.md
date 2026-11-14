# سند ساخت آیرون‌پین — نسخهٔ ۰.۹.۴

این سند دقیقاً همان مراحلی است که برای ساخت APKهای تحویلی اجرا شده؛ اگر روی ماشین دیگری
تکرار شود باید همان دو فایل با همان اجزا ساخته شود.

## ۱) زنجیرهٔ ابزار قفل‌شده

| ابزار | نسخه | یادداشت |
| --- | --- | --- |
| Flutter | ۳.۲۴.۵ (stable) | `flutter --version` باید همین باشد |
| Dart | ۳.۵.۴ | همراه همان Flutter |
| JDK | Temurin ۱۷.۰.۱۳+۱۱ | `JAVA_HOME` باید به آن اشاره کند |
| Android SDK | platform 35 + build-tools 35.0.0 | `compileSdk = 35`، `targetSdk = 35` |
| AGP / Kotlin / Gradle | ۸.۱.۰ / ۱.۸.۲۲ / ۸.۳ | از `android/settings.gradle` و wrapper |
| minSdk | ۲۱ | اندروید ۵ به بالا |

بازسازی زنجیره در یک محیط تازه:

```bash
bash tool/bootstrap_toolchain.sh          # Flutter + JDK17 + Android SDK 35 + pub get
export PATH=/home/user/sdk/flutter/bin:$PATH
export JAVA_HOME=/home/user/sdk/jdk17
export ANDROID_SDK_ROOT=/home/user/sdk/android-sdk
```

## ۲) وابستگی‌های ساخت

- `pubspec.yaml` → `html`, `http`, `sqflite`, `path`, `url_launcher`, `shamsi_date`, `workmanager`.
- OCR: `cz.adaptech.tesseract4android:tesseract4android:4.8.0` (Tesseract 5.5) از **JitPack**؛
  برای همین `android/build.gradle` مخزن `https://jitpack.io` را دارد.
- مدل‌های زبان داخل APK: `android/app/src/main/assets/tessdata/fas.traineddata` (۴۳۱KB)
  و `eng.traineddata` (۴.۱MB) از `tesseract-ocr/tessdata_fast`.
  برای به‌روزکردن عمدی:

  ```bash
  curl -sSL -o android/app/src/main/assets/tessdata/fas.traineddata \
    https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/main/fas.traineddata
  ```

## ۳) دو معماری، دو فایل

`android/app/build.gradle` فیلتر ABI را از `-Ptarget-platform` خودِ Flutter می‌خواند، پس هر
ساخت فقط کتابخانه‌های یک معماری را برمی‌دارد (نبود همین فیلتر باعث می‌شد کتابخانهٔ OCR
نسخهٔ ۶۴بیتی را هم داخل APK ۳۲بیتی بگذارد و بستهٔ «مخلوط» بسازد).

```bash
# ۳۲ بیتی — گوشی‌های قدیمی‌تر
flutter build apk --release --target-platform android-arm
cp build/app/outputs/flutter-apk/app-release.apk \
   releases/app-armeabi-v7a-release.apk

# ۶۴ بیتی — اکثر گوشی‌های امروز
flutter build apk --release --target-platform android-arm64
cp build/app/outputs/flutter-apk/app-release.apk \
   releases/app-arm64-v8a-release.apk
```

خروجی‌های تحویلی در `releases/` و با همین نام‌ها هستند؛ `.apk` در گیت ignore است و فقط
فایل `SHA256SUMS` کامیت می‌شود.

### تحویل ۰.۹.۶ — ۲۳ آبان ۱۴۰۵ (از GitHub Actions، با یک کلید)

از این نسخه، **هر دو** فایل در GitHub Actions و از همان کامیت ساخته می‌شوند؛ ساخت دستی
فقط برای عیب‌یابی است. مراحل همان بخش ۳ است، به‌علاوهٔ امضا با کلید ثابت:

| secret | مقدار |
| --- | --- |
| `IRONPIN_KEYSTORE_BASE64` | خروجی `base64 -w0` از فایل PKCS12 |
| `IRONPIN_STORE_PASSWORD` | رمز keystore |
| `IRONPIN_KEY_ALIAS` | `ironpin-release` |
| `IRONPIN_KEY_PASSWORD` | رمز کلید |

کلید در `$RUNNER_TEMP/ironpin-release.jks` باز می‌شود و از راه متغیرهای محیطی
(`IRONPIN_KEYSTORE` و سه تای دیگر) به `android/app/build.gradle` می‌رسد — همان قراردادی
که `tool/sign_env.sh` در ساخت دستی می‌گذارد. اگر secret نباشد، Gradle به کلید آزمایشی
برمی‌گردد و اجرا هشدار می‌دهد (برای forkها).

با push تگ `v*` همان اجرا هر دو فایل را در ریلیز منتشر می‌کند:

```bash
git tag v0.9.6 && git push origin v0.9.6
```

فایل‌های ریلیز: `IronPin-0.9.6-armeabi-v7a-release.apk`،
`IronPin-0.9.6-arm64-v8a-release.apk` و `SHA256SUMS.txt`. یادداشت ریلیز (اندازه، هش‌ها،
اثر انگشت گواهی) خودکار از همان فایل‌ها ساخته می‌شود.

### تحویل ۰.۹.۵ — ۲۱ آبان ۱۴۰۵ (سه اصلاح کاربر)

| فایل | معماری | حجم | sha256 |
| --- | --- | ---: | --- |
| `IronPin-0.9.5-armeabi-v7a-release.apk` | ۳۲ بیتی (`armeabi-v7a`) | ۱۳.۸MB (۱۳٬۸۰۹٬۸۳۹ بایت) | `34baec4202c3dd4fbbfc4850ebb12d7a3603cf6588c71b4f0fd1b920b39bfaed` |
| `IronPin-0.9.5-arm64-v8a-release.apk` | ۶۴ بیتی (`arm64-v8a`) | ۱۴.۴MB (۱۴٬۴۳۸٬۵۲۰ بایت) | `48aa863b6d74fca0ee40868187ad3b9037ad56005751f149132f550507f056e8` |

امضا با کلید پایدار `tool/sign_env.sh` (`CN=IronPin Local Sideload`، SHA-256
گواهی `78ea381de95813163696c9592b9b2123eb2ebaffab200daa6df79a91b9299caf`)؛ چون
کلید تحویل‌های قبلی در این محیط نیست، این فایل روی نسخهٔ نصب‌شدهٔ قبلی **ارتقایی
نصب نمی‌شود**: اول «خروجی بکاپ کامل» از داخل برنامه، بعد حذف نسخهٔ قبلی و نصب این.
هر دو فایل در [ریلیز v0.9.5](https://github.com/alisport1384/IronPin/releases/tag/v0.9.5)
هستند. بررسی‌شده: `versionName 0.9.5`، `versionCode 27`، `minSdk 21`، `targetSdk 35`؛ هر
فایل فقط کتابخانه‌های معماری خودش را دارد (`lib/armeabi-v7a/*` یا `lib/arm64-v8a/*`)
و `assets/tessdata/{fas,eng}`؛ `flutter analyze` تمیز، ۴۸۲ آزمون موفق و همان ۴۸۲ با
`test_on_another_day.sh 45` هم سبز.

### تحویل ۰.۹.۴ — ۲۱ آبان ۱۴۰۵ (اصلاح هوش جستجوگر ۲)

| فایل | معماری | حجم | sha256 |
| --- | --- | ---: | --- |
| `IronPin-0.9.4-armeabi-v7a-release.apk` | ۳۲ بیتی (`armeabi-v7a`) | ۱۳.۲MB (۱۳٬۸۰۸٬۱۰۸ بایت) | `83565bef37fe923099f6be5450a5b217558bb363e9272f9d203831b15d22201f` |
| `IronPin-0.9.4-arm64-v8a-release.apk` | ۶۴ بیتی (`arm64-v8a`) | ۱۳.۸MB (۱۴٬۴۳۶٬۹۱۰ بایت) | `71a79ef3324ec07b08a4893ca7f22e69a5ec941063f9336bd0fb2f28e2196291` |

هر دو فایل در [ریلیز v0.9.4](https://github.com/alisport1384/IronPin/releases/tag/v0.9.4)
هستند و **هر دو با همان کلید ثابت** امضا شده‌اند.

بررسی‌شده روی هر دو فایل: `versionName 0.9.4`، `versionCode 26`، `minSdk 21`،
`targetSdk 35`؛ هر فایل فقط کتابخانه‌های معماری خودش را دارد (شش کتابخانه)؛
`assets/tessdata/fas`+`eng`؛ امضای v1 و v2 معتبر؛ نشانه‌های کد تازه (`gerdoo.me`،
`site-table`، `mychannels.ir`) در `libapp.so`.

- **همان کلید ۰.۹.۳** (`CN=IronPin Local Sideload`، اثر انگشت SHA-256
  `dd80c370…597ddf7a`) و `versionCode` بالاتر: روی ۰.۹.۳ نصب می‌شود و داده‌ها می‌مانند. روی
  نسخه‌های پیش از ۰.۹.۳ (کلید دیگر) باید اول پشتیبان گرفت و نسخهٔ قبلی را حذف کرد.
- ساخت با `bash tool/build_low_memory.sh android-arm` و
  `bash tool/build_low_memory.sh android-arm64`. در محیط تازه، بار اول نگهبان حافظه مرحلهٔ
  گریدل را متوقف کرد (گریدل هنوز وابستگی‌ها را دانلود و آماده می‌کرد)؛ اجرای دوبارهٔ همان
  دستور با کش آماده در ۲۱ تا ۲۷ ثانیه تمام شد. **اگر بار اول متوقف شد، همان دستور را دوباره
  اجرا کنید.**
- GitHub Actions هم با هر push هر دو معماری را می‌سازد و محتوایشان را بررسی می‌کند، ولی آن
  فایل‌ها با کلید آزمایشیِ همان اجرا امضا می‌شوند؛ فایل‌های ریلیز از ساخت دستی با کلید ثابت
  می‌آیند.

### تحویل ۰.۹.۳ — ۲۰ آبان ۱۴۰۵ (هوش جستجوگر ۲)

فقط معماری درخواست‌شده ساخته شد.

| فایل | معماری | حجم | sha256 |
| --- | --- | ---: | --- |
| `IronPin-0.9.3-armeabi-v7a-release.apk` | ۳۲ بیتی (`armeabi-v7a`) | ۱۳.۱MB (۱۳٬۷۸۲٬۵۳۴ بایت) | `5800de8e6563dc6d164efcd595f19ef3ff6d50354da9c09439b819873bcd4be7` |

بررسی‌شده روی خود فایل: `versionName 0.9.3`، `versionCode 25`، `minSdk 21`، `targetSdk 35`،
`native-code: armeabi-v7a`؛ فقط `lib/armeabi-v7a/` با `libapp.so`، `libflutter.so`،
`libtesseract.so`، `libleptonica.so`، `libjpeg.so`، `libpngx.so`؛ `assets/tessdata/fas`+`eng`؛
امضای v1 و v2 معتبر. نشانه‌های کد تازه (`finder.meta`، `ironpin.periodic.source-finder`،
`html.duckduckgo.com`) در `libapp.so` هست.

- امضا با کلید محلی `tool/sign_env.sh` است (`CN=IronPin Local Sideload`، اثر انگشت SHA-256
  `dd80c370…597ddf7a`)، نه کلید آزمایشی Android و نه کلید رسمی صاحب برنامه. این کلید در پوشهٔ
  `keys/` کنار پروژه و بیرون از گیت می‌ماند؛ ساخت‌های بعدی از همین محیط با همین کلید امضا
  می‌شوند و روی هم نصب می‌شوند.
- با کلید تحویل‌های قبلی یکی نیست: اول از داخل برنامه پشتیبان بگیرید، بعد نسخهٔ قبلی را حذف
  و این را نصب کنید.
- نسخهٔ ۶۴ بیتی ساخته نشد. با push، GitHub Actions هر دو معماری را می‌سازد.

**ساخت روی میزبان ۲ گیگابایتی بدون swap.** تلاش اول (`flutter build apk` یک‌جا) ماشین را حدود
۴۰ دقیقه قفل کرد و با کشتن فرایندها تمام شد: کامپایلر Dart و JVM گریدل با هم در حافظه جا
نمی‌شوند. ساخت موفق دو مرحله‌ای بود — اول AOT به‌تنهایی (حدود ۳۰ ثانیه)، بعد بسته‌بندی گریدل
(۵۹ تا ۹۱ ثانیه؛ کمترین حافظهٔ آزادِ دیده‌شده ۲۸۱MB). فایل تحویلی با همین دستور ساخته شد:

```bash
bash tool/build_low_memory.sh android-arm
```

مرحلهٔ اول همان آرگومان‌هایی را می‌دهد که افزونهٔ گریدل Flutter می‌دهد، پس گریدل خروجی را
به‌روز می‌بیند و دوباره کامپایل نمی‌کند (پوشهٔ `.dart_tool/flutter_build/<هش>` در هر دو یکی بود).

### تحویل ۰.۹.۲ — ۲۰ آبان ۱۴۰۵

هر دو فایل در [ریلیز v0.9.2](https://github.com/alisport1384/IronPin/releases/tag/v0.9.2) هستند.

| فایل ریلیز | معماری | حجم | sha256 |
| --- | --- | ---: | --- |
| `IronPin-0.9.2-armeabi-v7a-release.apk` | ۳۲ بیتی (`armeabi-v7a`) | ۱۳.۱MB (۱۳٬۷۰۲٬۰۱۰ بایت) | `8ae9ccdccd313e955ad683c2316fbe3013c5d5c6bbe44983aae964fb7a7507bd` |
| `IronPin-0.9.2-arm64-v8a-release.apk` | ۶۴ بیتی (`arm64-v8a`) | ۱۳.۷MB (۱۴٬۳۴۰٬۵۴۶ بایت) | `f97722aab3f8268c8c43411560ed9b16151b71b9d8a58568aef0e59911fa3883` |

هر دو: `versionName 0.9.2`، `versionCode 24`، `minSdk 21`، `targetSdk 35`، شامل
`assets/tessdata/fas`+`eng` و فقط کتابخانه‌های معماری خودش.

- فایل ۳۲ بیتی در محیط ساخت دستی ساخته شد (commit `6f80094`).
- فایل ۶۴ بیتی را GitHub Actions ساخت (اجرای `43067735559`، commit `8ad112d`؛ کد برنامه با
  تگ `v0.9.2` یکی است و فقط فایل workflow فرق دارد).
- هر دو با **کلید آزمایشی Android** امضا شده‌اند، ولی با دو کلید جدا، چون هر محیط ساخت کلید
  آزمایشی خودش را می‌سازد. اثر انگشت SHA-256: ۳۲ بیتی `efe968e4…3923e1`، ۶۴ بیتی
  `36580490…6f899d`.
- هیچ‌کدام با کلید تحویل‌های قبلی یکی نیست؛ اندروید نصب روی نسخهٔ قبلی را رد می‌کند. اول از
  داخل برنامه پشتیبان بگیرید، بعد نسخهٔ قبلی را حذف و این را نصب کنید.
- تا وقتی یک کلید ثابت (`tool/sign_env.sh`، یا همان کلید به‌صورت secret در Actions) استفاده
  نشود، هر ساخت تازه همین وضع را دارد.

### ساخت خودکار در GitHub Actions

`.github/workflows/android.yml` با هر push این کارها را می‌کند: `flutter analyze`، همهٔ
آزمون‌ها، ساخت دو APK (یکی برای هر معماری)، بررسی محتوای هر APK، و گذاشتن هر دو فایل به‌همراه
`SHA256SUMS.txt` در artifact با نام `IronPin-<نسخه>-release-APKs`.

از ۰.۹.۶ سه کار دیگر هم در همان اجرا انجام می‌شود: امضا با کلید ثابتِ secret (بخش ۳)،
بررسی `versionName` و `native-code` و پذیرش امضا با `apksigner verify`، و — فقط روی push
تگ `v*` — انتشار همان دو فایل در ریلیز. یعنی فایل ریلیز و فایل artifact از یک اجرا و یک
درخت می‌آیند و کلیدشان یکی است.

تا پیش از commit `8ad112d` این ساخت همیشه شکست می‌خورد. علت: workflow هر دو معماری را با
`--split-per-abi` در یک دستور می‌ساخت، ولی `android/app/build.gradle` خودش `ndk.abiFilters`
را از روی `-Ptarget-platform` تنظیم می‌کند و Gradle این دو را با هم قبول نمی‌کند
(`ndk abiFilters cannot be present when splits abi filters are set`). حالا workflow همان دو
دستور جدای بخش ۳ را اجرا می‌کند. **`--split-per-abi` را با این پروژه به کار نبرید.**

تا ۰.۹.۵ APKهای Actions با کلید آزمایشیِ همان اجرا امضا می‌شدند و این کلید در هر اجرا
عوض می‌شد. از ۰.۹.۶ کلید از secret می‌آید و در همهٔ اجراها یکی است.

### تحویل ۰.۹.۱ — ۲۰ آبان ۱۴۰۵ (بازساخت پس از رفع اشکال نوسازی)

این دو فایل همان نسخهٔ `0.9.1+23` هستند که پس از رفع اشکال «نوسازی فقط یک‌بار» دوباره
ساخته شدند؛ هش‌های پیش از بازساخت‌های قبلی (`6f283c06…`/`d8edd312…`/`8e124bc4…`/`996eaf21…`)
معتبر نیستند. هر بار که کد تغییر می‌کند، هر دو معماری از همان درخت دوباره ساخته و هش‌ها
به‌روز می‌شوند؛ `sha256sum -c releases/SHA256SUMS` تنها مرجع معتبر است.

| فایل | معماری | حجم | sha256 |
| --- | --- | ---: | --- |
| `releases/app-armeabi-v7a-release.apk` | ۳۲ بیتی (`armeabi-v7a`) | ۱۳.۰MB (۱۳٬۶۵۵٬۹۹۶ بایت) | `df9cc0f5a73f9128f2458bb3143f46ecc0a02d19f4e48f85a20961a59e218fb9` |
| `releases/app-arm64-v8a-release.apk` | ۶۴ بیتی (`arm64-v8a`) | ۱۳.۶MB (۱۴٬۳۰۰٬۷۵۵ بایت) | `2f94dbc488dbbea36f4aa725a5ed8404e383270e3f94290faa5ff36c465ad075` |

هر دو: `versionName 0.9.1`، `versionCode 23`، `minSdk 21`، `targetSdk 35`، امضا با کلید
آزمایشی Android، شامل `assets/tessdata/fas`+`eng` و فقط کتابخانه‌های معماری خودش.
بررسی هر دو فایل با `unzip -l | grep lib/` انجام و صفر فایل از معماری دیگر دیده شد.

## ۴) امضا

- بدون متغیر محیطی: APK با **کلید آزمایشی Android** امضا می‌شود (همان کاری که برای این
  تحویل انجام شد). نصب روی نسخهٔ قبلی که با همان کلید نصب شده کار می‌کند، ولی برای انتشار
  رسمی کافی نیست.
- با کلید صاحب برنامه (`tool/sign_env.sh`):

  ```bash
  export IRONPIN_KEYSTORE=/path/to/release.jks
  export IRONPIN_STORE_PASSWORD=...
  export IRONPIN_KEY_ALIAS=...
  export IRONPIN_KEY_PASSWORD=...
  ```

## ۵) بررسی فایل ساخته‌شده (قبل از تحویل)

```bash
BT=/home/user/sdk/android-sdk/build-tools/35.0.0
$BT/aapt dump badging  releases/app-armeabi-v7a-release.apk | head -3
$BT/apksigner verify --print-certs releases/app-armeabi-v7a-release.apk | head -2
unzip -l releases/app-armeabi-v7a-release.apk | grep -E 'lib/|tessdata'
sha256sum releases/*.apk > releases/SHA256SUMS
```

چه چیزی باید دیده شود:

- `versionName 0.9.5`، `versionCode 27`، `sdkVersion 21`، `targetSdkVersion 35`.
- فقط `lib/armeabi-v7a/*` در فایل ۳۲بیتی و فقط `lib/arm64-v8a/*` در فایل ۶۴بیتی،
  هر کدام شامل `libapp.so`، `libflutter.so`، `libtesseract.so`، `libleptonica.so`،
  `libjpeg.so`، `libpngx.so`.
- `assets/tessdata/fas.traineddata` و `assets/tessdata/eng.traineddata`.
- صفر فایل از معماری دیگر.

## ۶) آزمون قبل از ساخت

```bash
flutter analyze --no-pub     # باید «No issues found!» بدهد
flutter test --concurrency=1 # ۴۸۲ آزمون در ۰.۹.۵
bash tool/test_on_another_day.sh 45   # همان آزمون‌ها، انگار ۴۵ روز بعد است
```

## ۷) خطاهای واقعیِ دیده‌شده و درمانشان

| خطا | علت | درمان |
| --- | --- | --- |
| `Gradle build daemon disappeared unexpectedly` | RAM کم میزبان (۲GB) + AOT | swap میزبان روشن شود و در `android/gradle.properties`: `-Xmx512m -XX:MaxMetaspaceSize=384m -XX:+UseSerialGC -XX:ActiveProcessorCount=1` |
| `const_finder.dart.snapshot: No such file` | کش ناقص Flutter | `flutter precache --linux` (و در صورت نیاز `--android`) |
| `Could not find cz.adaptech...tesseract4android` | نبود مخزن JitPack | `maven { url "https://jitpack.io" }` در `android/build.gradle` |
| `Unresolved reference: utf8Text` | نام گتر در Tesseract4Android | `engine.getUTF8Text()` |
| `Install Android SDK Build-Tools 33/34` وسط ساخت | وابستگی AARها | اجازهٔ نصب خودکار `sdkmanager` (اتصال اینترنت در ساخت) |
| آزمونی که دیروز سبز بود امروز می‌شکند، بدون تغییر کد | ردیفِ تاریخ‌ثابتِ fixture از پنجرهٔ زمانی بیرون رفته | پنجره را در آن آزمون باز کنید؛ با `tool/test_on_another_day.sh` بقیه را هم پیدا کنید |
| ماشین قفل می‌شود و `Gradle task assembleRelease failed with exit code -9` | ۲GB بدون swap: کامپایلر Dart و JVM گریدل هم‌زمان | `bash tool/build_low_memory.sh android-arm` (AOT جدا، بعد گریدل، با نگهبان حافظه) |

## ۸) آنچه این سند ثابت نمی‌کند

- نصب و اجرا روی گوشی واقعی انجام نشده است.
- APKها با کلید آزمایشی امضا شده‌اند، نه کلید رسمی صاحب برنامه.
- ساخت با اینترنت انجام می‌شود (JitPack، Maven، pub)؛ ساخت آفلاین آزمایش نشده است.
