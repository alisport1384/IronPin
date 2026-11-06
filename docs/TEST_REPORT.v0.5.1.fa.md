# گزارش آزمون۰.۵.۱+۶ — ۱۵آبان۱۴۰۵

## نتیجه آفلاین قطعی

**175آزمون موفق؛ flutter analyzeبدون ایراد؛ format/fixاجرا شدند.** concurrency1. متریک میزبان8000ردیف/4000نتیجه،304msو275تیکmainTimer؛اینFPSگوشی نیست.

آزمون‌های تازه/به‌روز:همه70اتصال ثابتdefaultONوURLیکتا،مهاجرت یک‌باره همه‌روشن و حفظ خاموشی بعدی،حفظpayloadپایگاهv1درschema2،انتشار/SQLite/جستجوی قیمت منبع موفق پیش از پایان منبع کند،سه ورق۳تازه از متن واقعی قنبری،گروه میلگرد۱۴و۱۶و۲۰و۲۲خباززاده و جدول محصول/قیمت/تاریخ بدون واحد. همه آزمون‌های قبلی موتور/تاریخ/تبدیل معتبر/لاگر/نگهداری/محاسبات/رابط حفظ شدند. آزمون قدیمیِ باقی‌ماندن همهopt-outهای۰.۳برای این مهاجرت صریح، به انتظار همهONو سپس حفظopt-outتازه اصلاح شد؛ نگهداری داده همچنان آزموده است.

## پژوهش و پیش‌فرض

۴اتصال تازه:سه تلگرام قنبری،خباززاده و آیرومارت و جدول ورق خباززاده. ایتای سامانه آهن از قبل adapterداشت و منبع جدید شمرده نشد. همه70اتصال ثبت‌شده پیش‌فرض روشن؛ پیشنهاد لینک احرازنشده پیش‌فرض روشن نیست. دایرکتوری40وب/35تلگرام/41غیرتلگرام و11دفتر/تماس مشهد دارد.

fixtureهای گنجانده‌شده تلگرام،متن/شناسه/زمان واقعی هستند. جدول خباززاده **بازسازی معنایی از مرور** است،نهDOMدانلودشده. کلمهبرگ در عنوان محصول به واحد نرخ تبدیل نشد. علامتRبه‌تنهایی ریال قطعی نیست. هیچ قیمت نمونه‌ای در نصب اول تزریق نمی‌شود؛AIAPI/backend/وابستگی جدید وجود ندارد.

## شبکه نهایی — تمام70مسیر یکتا

دو درخواست هم‌زمان،متناسب با محدودیت اپ؛ نه موازی باtest/build. اجرای نهایی پس از حذف یک ورودی تکراری قدیمی از ابتدا تکرار شد. گزارش میانی71ورودی،نتیجه نهایی نیست.

| شناسه | وضعیت | ردیف | دارای تاریخ هفته | قابل‌مقایسه |
|---|---|---:|---:|---:|
| melal-rebar | خوانده شد | 440 | 370 | 350 |
| melal-sheet | خوانده شد | 335 | 335 | 279 |
| melal-beam | خوانده شد | 82 | 67 | 65 |
| melal-angle | خوانده شد | 196 | 175 | 144 |
| melal-channel | خوانده شد | 93 | 87 | 76 |
| melal-profile | خوانده شد | 296 | 296 | 294 |
| melal-pipe | خوانده شد | 290 | 290 | 255 |
| asre-esfahan | خوانده شد | 11 | 8 | 8 |
| asre-khorasan | خوانده شد | 10 | 4 | 8 |
| telegram-mashhad | خوانده شد | 52 | 34 | 0 |
| telegram-ahanresan | خوانده شد | 78 | 0 | 0 |
| telegram-bonyan | بدون پیام عمومی | — | — | — |
| telegram-ahanemashhad | خوانده شد | 37 | 16 | 0 |
| telegram-melal | خوانده شد | 94 | 94 | 0 |
| telegram-mkz | خوانده شد | 105 | 105 | 0 |
| telegram-mkz1 | خوانده شد | 487 | 487 | 0 |
| telegram-mkz2 | خوانده شد | 466 | 466 | 30 |
| telegram-mkz3 | خوانده شد | 408 | 408 | 0 |
| telegram-mkz4 | خوانده شد | 667 | 667 | 0 |
| telegram-asre | خوانده شد | 89 | 55 | 0 |
| telegram-ahanprice | خوانده شد | 31 | 31 | 0 |
| telegram-milgerdprice | خوانده شد | 19 | 14 | 0 |
| telegram-tirahanprice | خوانده شد | 18 | 10 | 0 |
| telegram-varaghprice | خوانده شد | 20 | 15 | 0 |
| telegram-l-uprice | خوانده شد | 22 | 14 | 0 |
| telegram-profileprice | خوانده شد | 16 | 10 | 0 |
| telegram-looleprice | خوانده شد | 16 | 10 | 0 |
| telegram-modiranahan-z | خوانده شد | 396 | 396 | 0 |
| telegram-ahan-online | خوانده شد | 18 | 0 | 0 |
| telegram-ao-thin-plate | خوانده شد | 40 | 5 | 3 |
| telegram-ao-pipe-box | خوانده شد | 20 | 0 | 0 |
| telegram-fooladsell | خوانده شد | 138 | 0 | 0 |
| telegram-kavirsteel | خوانده شد | 20 | 0 | 0 |
| telegram-asroon | بدون پیام عمومی | — | — | — |
| telegram-shekoftegroup | بدون پیام عمومی | — | — | — |
| telegram-novinpars | خوانده شد | 309 | 126 | 0 |
| telegram-hayperahan | خوانده شد | 72 | 0 | 39 |
| telegram-radmanahan | خوانده شد | 286 | 107 | 0 |
| telegram-fiahan | خوانده شد | 631 | 400 | 0 |
| telegram-ahan100 | خوانده شد | 63 | 62 | 0 |
| public-bale-ahanonlineofficial | timeout | — | — | — |
| public-bale-modiranahan | timeout | — | — | — |
| public-eitaa-modiranahan | timeout | — | — | — |
| public-eitaa-shekoftehsigmashhad | timeout | — | — | — |
| public-bale-pivanco | timeout | — | — | — |
| public-eitaa-galvanizeahaninfo | timeout | — | — | — |
| public-rubika-ahaninja1 | timeout | — | — | — |
| public-eitaa-ahan100 | timeout | — | — | — |
| public-rubika-ahan100 | timeout | — | — | — |
| public-bale-ahan100 | timeout | — | — | — |
| public-rubika-novinparsgroup | timeout | — | — | — |
| public-bale-novinparsgroup | timeout | — | — | — |
| public-eitaa-radmanahan | timeout | — | — | — |
| public-rubika-radmanahan | timeout | — | — | — |
| public-eitaa-hayperahan | timeout | — | — | — |
| public-rubika-hayperahan | timeout | — | — | — |
| public-rubika-tikahan | timeout | — | — | — |
| public-eitaa-fiahan1 | timeout | — | — | — |
| public-rubika-fiahan_com | timeout | — | — | — |
| public-bale-fiahan | timeout | — | — | — |
| public-eitaa-samaneahan_com | timeout | — | — | — |
| public-bale-ahaneroz | timeout | — | — | — |
| public-rubika-khabazzade_iron | timeout | — | — | — |
| public-rubika-tahamtaniron | timeout | — | — | — |
| fardad-sheet | timeout | — | — | — |
| mashhad-sheet | timeout | — | — | — |
| telegram-ghanbari | خوانده شد | 530 | 530 | 0 |
| telegram-khabazzade | خوانده شد | 293 | 159 | 0 |
| telegram-iromart | خوانده شد | 34 | 0 | 0 |
| khabazzade-sheet | timeout | — | — | — |

جمع:40خوانده‌شده/30ناموفق (27timeoutو3پاسخ بدون متن پیام عمومی). 7228ردیف،همه7228دارای تکمیل خودکارv2؛5004مبلغ عددی،4788نامزد مبلغ متنی،1551قابل‌مقایسه و5853دارای تاریخ در هفته. نامزد/مبلغ عددی به معنی نرخ قطعی هفته یا مجاز به تبدیل نیست.

ورق:1436ردیف/988نامزد متنی. جستجوی «ورق۳مشهد» در همه تاریخ43ردیف و در هفته اخیر35ردیف از قنبری پیدا کرد؛ این تعداد مدل مستقل نیست و اعلام‌های روزهای مختلف می‌تواند مشخصات تکراری داشته باشد. مبنای ارز/واحدِ ناقص حدس زده نشد. این نتیجه،تأیید نرخ تازه قابل‌مقایسه مشهد نیست.

قنبری530ردیف/506نامزد و35ورق۳هفته اخیر؛خباززاده293ردیف/292نامزد/159دارای تاریخ هفته؛آیرومارت34ردیف/22نامزد اما0درهفته اخیر داشت. هر سه تلگرام با خودSourceClientخوانده شدند. جدول خباززاده/فرداد/مشهدفولاد و سرویس‌های داخلی درHTTPاین محیطtimeoutشدند؛ مرور عمومیِ پژوهش بعضی را خواند،ولی موفقیت شبکه گوشی/DOMاصلی محسوب نمی‌شود. سه کانال بنیان/asroon/shekoftegroupپیام خواندنی ندادند؛ داده قبلی در اپ حفظ می‌شود. smokeAllTestsPassedصرفاً ثبت/اجرای همه مسیرهاست،نه موفقیت تمام سرورها.

## ساخت و بررسی باینری

ساخت نهایی releaseهر دوABIموفق،Gradle67.2ثانیه؛Flutter3.24.5/Dart3.5.4/JDK17/compileSDK35/min21/target35. heap384MB/metaspace384MBوCPU/worker1. AGPابزارهایbuild33.0.1را خود نصب کرد؛aapt/apksignerبررسی از34.0.0اجرا شدند. ساخت پیش از حذفURLتکراری متوقف شده بود و به عنوان موفقیت تحویل محسوب نمی‌شود.

- IronPin-0.5.1-armeabi-v7a.apk: 8060340بایت،code1006،SHA256`3cfc068affbc0e5104c5921b22e59cb599e2baf2386a7cba6e609a2025bd098f`.
- IronPin-0.5.1-arm64-v8a.apk: 8441515بایت،code2006،SHA256`f1960e038d24094c2654c0cb07256aabcd04dee0be4b1998aa573988942652b1`.

package=`ir.ironpin.ironpin`؛versionName=`0.5.1`؛هرAPKفقطABIخودش/ELFمقصددرست؛امضایv1/v2معتبر و گواهی همان قبلی:`360dabf5f2cf2ee39c9dc90bcb093a381e93a17d6a4f87d978a41d9ecff588b4`. registryداخلAPKبا سورس برابر است. نشانگرهایallRegisteredSourcesEnabledVersion،telegram-ghanbari،khabazzade-sheet،ProductQuery،PublicTablesوv2در هر دوAOTهستند؛TextAnalysisSheetنیست.

امضاAndroidDebugآزمایشی قبلی،نه کلید انتشار مالک است. APKهای همین تحویل با گواهی قبلی بررسی شدند؛ خروجی احتمالیCIاز کلیدdebugتازه runnerاستفاده می‌کند و هم‌امضابودنCIتضمین نشده است. privatekeyدرGit/بسته نیست. نصب واقعی/حفظ داده در نصب درجا/شبکه وSAFوFPSگوشی در این محیط آزموده نشده‌اند؛ همان معماری قبلی را بدون حذف اپ نصب کنید.

## سند و پوش

سند تولیدبخش46به‌بعد،پژوهش جدید،درخواست،تغییرات،آمارهمهمنابع وشواهدموجودند. hashورودیruntimeپس ازساخت ثبت شده است؛schema2/وابستگی/معماری وverified_onlyعوض نشده‌اند.

مجوز تازه پوش همین نوبت دریافت شد. منبع کامل منتخب،شامل تغییرات۰.۴/۰.۵که قبلاً فقطZIPبودند،پس ازاینQAرویmainپوش می‌شود. رسید اجرای واقعی و بازخوانیSHAشاخه راه‌دور درPUSH_RECEIPT.jsonکنارتحویل ثبت می‌شود. اعتبار فقط در محیط موقتGit،نهURL/config/فایل/log،استفاده می‌شود. سورس/patch/deltaنسبت به ZIPتحویلی۰.۵است ونتیجه کنترل بسته‌بندی درPACKAGING.jsonخارجسورس می‌آید.
