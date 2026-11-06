# شواهد نهایی۰.۵

- analyze.log: بدون ایراد؛ tests.log:170آزمون موفق با concurrency=1. format/fix آخرین اجرای نهایی‌اند.
- live-smoke.log و research/live-smoke-v050.json:24مسیر عمومی،17خوانش و7timeout؛ موتور/SourceClient واقعی. controller/SQLite با HTTP mock در آزمون کامل جدا کنترل می‌شوند.
- aot.log/build.log ساخت موفق ARM32/64؛ build-first-failed-metaspace.log شکست نخست با سقف256MB متاسپیس است. سقف متاسپیس به384MB، heap512MB و یک CPU/worker اصلاح و ساخت تکرار شد. شکست تاریخی به عنوان موفقیت ثبت نشده است.
- فایل‌های aapt/signature خروجی واقعی ابزار Android برای هر ABI هستند؛ check_apks.py تولید و اعتبارسنجی مجدد apk-metadata.json را انجام می‌دهد. JAVA_HOME/PATH برای JDK17 و ANDROID_SDK_ROOT برای SDK تنظیم شوند؛ build-tools34.0.0 لازم است.
- runtime-inputs.sha256.json ورودی‌های runtime و تنظیمات ساختی را که پس از build ثابت ماندند ثبت می‌کند. اسناد/بسته‌بندی پس از build تکمیل شدند و runtime تغییر نکرده است.
- کنترل باینری/ویجت میزبان، نصب و شبکه واقعی گوشی، SAF، FPS گوشی یا نصب درجا نیست. کلید امضا آزمایشی قبلی است؛ private key در بسته نیست.
