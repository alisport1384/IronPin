# سند ساخت آیرون‌پین — نسخهٔ ۰.۹.۱

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

### تحویل ۰.۹.۱ — ۲۰ آبان ۱۴۰۵ (بازساخت پس از رفع اشکال نوسازی)

این دو فایل همان نسخهٔ `0.9.1+23` هستند که پس از رفع اشکال «نوسازی فقط یک‌بار» دوباره
ساخته شدند؛ هش‌های پیش از این بازساخت (`6f283c06…`/`d8edd312…`) معتبر نیستند.

| فایل | معماری | حجم | sha256 |
| --- | --- | ---: | --- |
| `releases/app-armeabi-v7a-release.apk` | ۳۲ بیتی (`armeabi-v7a`) | ۱۳.۰MB (۱۳٬۶۵۵٬۵۲۴ بایت) | `8e124bc4debfe8b581f3229732d09e84ab33d3f05b1ba13ce6a772eeb17fc067` |
| `releases/app-arm64-v8a-release.apk` | ۶۴ بیتی (`arm64-v8a`) | ۱۳.۶MB (۱۴٬۳۰۰٬۴۰۷ بایت) | `996eaf218db48fb40420a151e06158ff80e43d32d330c01e2d87b71aee0826d9` |

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

- `versionName 0.9.1`، `versionCode 23`، `sdkVersion 21`، `targetSdkVersion 35`.
- فقط `lib/armeabi-v7a/*` در فایل ۳۲بیتی و فقط `lib/arm64-v8a/*` در فایل ۶۴بیتی،
  هر کدام شامل `libapp.so`، `libflutter.so`، `libtesseract.so`، `libleptonica.so`،
  `libjpeg.so`، `libpngx.so`.
- `assets/tessdata/fas.traineddata` و `assets/tessdata/eng.traineddata`.
- صفر فایل از معماری دیگر.

## ۶) آزمون قبل از ساخت

```bash
flutter analyze --no-pub     # باید «No issues found!» بدهد
flutter test                 # ۴۰۶ آزمون
```

## ۷) خطاهای واقعیِ دیده‌شده و درمانشان

| خطا | علت | درمان |
| --- | --- | --- |
| `Gradle build daemon disappeared unexpectedly` | RAM کم میزبان (۲GB) + AOT | swap میزبان روشن شود و در `android/gradle.properties`: `-Xmx512m -XX:MaxMetaspaceSize=384m -XX:+UseSerialGC -XX:ActiveProcessorCount=1` |
| `const_finder.dart.snapshot: No such file` | کش ناقص Flutter | `flutter precache --linux` (و در صورت نیاز `--android`) |
| `Could not find cz.adaptech...tesseract4android` | نبود مخزن JitPack | `maven { url "https://jitpack.io" }` در `android/build.gradle` |
| `Unresolved reference: utf8Text` | نام گتر در Tesseract4Android | `engine.getUTF8Text()` |
| `Install Android SDK Build-Tools 33/34` وسط ساخت | وابستگی AARها | اجازهٔ نصب خودکار `sdkmanager` (اتصال اینترنت در ساخت) |

## ۸) آنچه این سند ثابت نمی‌کند

- نصب و اجرا روی گوشی واقعی انجام نشده است.
- APKها با کلید آزمایشی امضا شده‌اند، نه کلید رسمی صاحب برنامه.
- ساخت با اینترنت انجام می‌شود (JitPack، Maven، pub)؛ ساخت آفلاین آزمایش نشده است.
