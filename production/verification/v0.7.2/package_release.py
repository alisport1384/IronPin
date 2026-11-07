"""Package committed source, exact changes and compressed patch against 0.7.1.
New APKs are already audited and stored in a separately verified lossless archive.
No historical deliverable is modified. No credential or private key is packaged.
Run after commit. A successful local commit is NOT evidence of a remote push.
"""
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED, ZipInfo
import hashlib, html, json, lzma, re, shutil, subprocess, tempfile
R=Path(__file__).resolve().parents[3]
O=R.parent/'deliverables'/'IronPin-0.7.2'
BASE='a5bde31ba2de2f14351efe13259109f0ae95dc77'
V='production/verification/v0.7.2/'
sha=lambda b:hashlib.sha256(b).hexdigest()

def git(*args):return subprocess.check_output(['git',*args],cwd=R)

def main():
    assert not git('status','--porcelain').strip(), 'Commit intended source first'
    O.mkdir(exist_ok=True,parents=True)
    head=git('rev-parse','HEAD').decode().strip()
    base=O.parent/'IronPin-0.7.1/IronPin-0.7.1-source.zip'
    assert sha(base.read_bytes()) in (base.parent/'SHA256SUMS.txt').read_text()
    with ZipFile(base) as z:b={n.removeprefix('IronPin/'):z.read(n) for n in z.namelist() if not n.endswith('/')}
    paths=sorted(git('ls-files').decode().splitlines())
    c={p:(R/p).read_bytes() for p in paths}
    # Ensure actual working files are exactly the committed bytes.
    for p,data in c.items():
        assert git('show',f'{head}:{p}')==data,p
        assert not set(Path(p).parts)&{'.git','.cache','.dart_tool','build','__pycache__'},p
        assert not p.endswith(('.apk','.jks','.keystore','.pyc')),p
        assert not re.search(rb'(?:ghp_[A-Za-z0-9]{25,}|github_pat_[A-Za-z0-9_]{25,})',data),p
    assert c['pubspec.lock']==b['pubspec.lock']
    assert b'No issues found!' in c[V+'analyze.log']
    assert b'+310: All tests passed!' in c[V+'offline-final.log']
    assert b'+48: All tests passed!' in c[V+'focused-final.log']
    for p,h in json.loads(c[V+'runtime-inputs.sha256.json']).items():assert sha(c[p])==h,p
    historical=json.loads(c[V+'historical-deliverables-before.sha256.json'])
    for p,h in historical.items():assert sha((O.parent/p).read_bytes())==h,p
    added=sorted(set(c)-set(b));deleted=sorted(set(b)-set(c))
    modified=sorted(p for p in c if p in b and c[p]!=b[p]);payload=sorted(added+modified)
    assert not deleted,deleted
    for name,pp in [('IronPin-0.7.2-source.zip',paths),('IronPin-0.7.2-changes-only.zip',payload)]:
        with ZipFile(O/name,'w',ZIP_DEFLATED,compresslevel=9) as z:
            for p in pp:
                i=ZipInfo('IronPin/'+p,(2026,11,7,0,0,0));i.compress_type=ZIP_DEFLATED;i.external_attr=0o100644<<16
                z.writestr(i,c[p],compresslevel=9)
    with ZipFile(O/'IronPin-0.7.2-source.zip') as z:assert {n.removeprefix('IronPin/'):z.read(n) for n in z.namelist()}==c
    with ZipFile(O/'IronPin-0.7.2-changes-only.zip') as z:
        rebuilt=b.copy();rebuilt.update({n.removeprefix('IronPin/'):z.read(n) for n in z.namelist()});assert rebuilt==c
    patch=git('diff','--binary','--no-ext-diff',BASE,head,'--','.')
    (O/'IronPin-0.7.1-to-0.7.2.patch.xz').write_bytes(lzma.compress(patch,preset=9))
    with tempfile.TemporaryDirectory(dir=R.parent/'.cache') as tmp:
        t=Path(tmp)
        for p,data in b.items():
            f=t/p;f.parent.mkdir(parents=True,exist_ok=True);f.write_bytes(data)
        pf=R.parent/'.cache/IronPin-0.7.1-to-0.7.2.patch'
        pf.write_bytes(lzma.decompress((O/'IronPin-0.7.1-to-0.7.2.patch.xz').read_bytes()))
        subprocess.run(['git','apply','--check',str(pf)],cwd=t,check=True,capture_output=True)
        subprocess.run(['git','apply',str(pf)],cwd=t,check=True,capture_output=True)
        assert {str(p.relative_to(t)):p.read_bytes() for p in t.rglob('*') if p.is_file()}==c
    for src,dest in {
        'docs/TEST_REPORT.v0.7.2.fa.md':'TEST_REPORT.fa.md',
        'docs/RESEARCH_BOLTS_FLATS_MASHHAD.v0.7.2.fa.md':'RESEARCH.fa.md',
        'production/CHANGES.v0.7.2.fa.md':'CHANGES.v0.7.2.fa.md',
        'production/PRODUCTION.fa.md':'PRODUCTION.fa.md',
    }.items():shutil.copyfile(R/src,O/dest)
    archive=json.loads(c[V+'archive-result.json'])
    assert sha((O/archive['archive']).read_bytes())==archive['sha256']
    assert (O/'RESTORE-APK-0.7.2.py').read_bytes()==c[V+'restore_apks.py']
    apks=json.loads(c[V+'apk-metadata.json'])
    remote=subprocess.check_output(['git','ls-remote','https://github.com/alisport1384/IronPin.git','refs/heads/main'],text=True).split()[0]
    manifest={'version':'0.7.2+11','baselineVersion':'0.7.1','baselineGit':BASE,
        'baselineSourceZipSha256':sha(base.read_bytes()),'gitHead':head,'observedRemoteHead':remote,
        'pushVerified':False,'sourceFiles':len(paths),'changedFiles':len(payload),
        'addedFiles':len(added),'modifiedFiles':len(modified),'deletedFiles':deleted,
        'offlineTestsPassed':310,'newTestsPassed':48,'analyze':'No issues found',
        'sourceZipBytesVerified':True,'deltaReconstructionVerified':True,'patchApplyVerified':True,
        'runtimeInputHashesVerified':True,'dependencyLockUnchanged':True,
        'historicalFilesVerifiedUnchanged':len(historical),'apkArchive':archive,'apks':apks,
        'deviceInstallationTested':False,'endpointsRegistered':82,
        'liveTransport':'8 attempts: two Telegram endpoints returned 18/38 rows, zero fresh comparable ranges; six websites timed out at 22s. Fixtures are semantic reconstructions, not live HTML.',
        'files':[{'path':p,'sha256':sha(c[p]),'change':'added' if p in added else 'modified' if p in modified else 'unchanged'} for p in paths]}
    (O/'PACKAGING.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
    md=f'''# تحویل IronPin — ۰.۷.۲+۱۱

## نتیجه
بولت/انکربولت و تسمه اضافه شد؛ **۳۱۰آزمون موفق،۴۸آزمون تازه، analyze بدون مسئله، ساخت و ممیزی هر دو APK موفق**. اینها محاسبه وزن/هزینه‌اند، نه تأیید ظرفیت یا طراحی کاشت. نصب و ارتقای واقعی گوشی آزموده نشده است.

## دریافت و نصب APK
برای نگهداری پایدار در سقف فضای محیط، **فقط دو APK تازه** به‌صورت [آرشیو بدون اتلاف](IronPin-0.7.2-apks.lossless.zip) ذخیره شده‌اند ({archive['bytes']:,}بایت). فایل‌های تاریخی تغییر نکرده‌اند.

۱. این پوشه و دو APK موجود در `../IronPin-0.7.1/` را با همین ساختار نگه دارید.
۲. [بازیاب Python](RESTORE-APK-0.7.2.py) را اجرا کنید: `python RESTORE-APK-0.7.2.py`؛ فقط کتابخانه استاندارد، بدون شبکه/کلید/نصب پکیج. می‌توانید `--output DIRECTORY` بدهید.
۳. APK بازسازی‌شده مناسب دستگاه را نصب کنید. بازسازی مستقل هر دو فایل **بایت‌به‌بایت با خروجی امضاشده برابر** و SHAها کنترل شده‌اند. نسخه zlib ثبت‌شده در [مانیفست آرشیو](APK-ARCHIVE.json) موجود است؛ اگر DEFLATE سازگار نباشد بازیاب خطای صریح می‌دهد، نه APK متفاوت.

- ARM64 برای بیشتر گوشی‌های جدید: `IronPin-0.7.2-arm64-v8a.apk`،۸٬۵۵۲٬۴۹۳بایت، SHA256 `4bf72ab6a86d59a25adb6dc6efefe4b40a557a2c59bae23e4ba87501ddb7cf0d`.
- ARM32 برای گوشی سازگار۳۲بیتی: `IronPin-0.7.2-armeabi-v7a.apk`،۸٬۱۷۹٬۳۴۴بایت، SHA256 `830f772620aa9d98a95fbf8f042116369e6267eb93a365de4cb6a534ee0416cb`.

**پیش از ارتقا بکاپ بگیرید؛ روی نسخه قبلی نصب کنید و uninstall نکنید.** package ثابت `ir.ironpin.ironpin`، min۲۱/target۳۵، codes۱۰۱۱/۲۰۱۱، همان گواهی AndroidDebug قبلی و امضای v1/v2 ممیزی شد؛ امضای فروشگاهی نیست.

## تغییرهای اصلی
- حسابگر مستقل تسمه در ساده/پیشرفته؛ بولت نظری از قطر و طول بازشده با جرم واقعی متعلقات؛ انکر/ست کامل از وزن واقعی. وزن پنهان/فرضی مهره و واشر نداریم؛ واحد عدد/ست با شاخه مخلوط نیست.
- رنج بولت فقط با مشخصات فنی کامل و هم‌گروه؛ نوع، قطر، طول/رزوه، گرید، جنس، پوشش و متعلقات؛ انکر مکانیکی/شیمیایی با مدل/عمق کاشت. ناقص‌ها در اعلام‌ها دیده می‌شوند، نه آمار.
- هشت مسیر جدید، مجموع۸۲endpoint متعلق به چهار مجموعه، نه هشت فروشنده. مهاجرت فقط همین مسیرها را یک‌بار فعال می‌کند؛ خاموش‌های قدیمی و بعدی محفوظ‌اند.
- **نتیجه واقعی شبکه:** دو کانال راه‌ساخت۱۸ و پروفیل آنلاین۳۸ردیف؛ هر دو صفر رنج تازه. شش صفحه وب timeout۲۲s؛ خوانایی در ابزار وب به معنی موفقیت SourceClient نیست. LPNT سرنخ نمایه تماس رسمی مشهد با دریافت مستقیم ناموفق؛ شهر دفتر مشهد بست نامعلوم، صرفاً سرنخ انکربولت.
- شهر فقط اطلاعات/یک scope ماندگار؛ دریافت همه منابع فعال مستقل از شهر، داده محلی همه شهرها، لاگ پیش‌فرض خاموش، freshness۴۸ساعت با تاریخ صریح، بکاپ و نوسازی دستی حفظ‌اند. ارز/واحد/سال نامعلوم حدس زده نمی‌شود. lockfile و schema۳ ثابت‌اند.

## سورس دقیق نسبت به۰.۷.۱
- [سورس کامل](IronPin-0.7.2-source.zip): {len(paths)}فایل، بدون SDK/cache/APK/کلید/credential.
- [فقط تغییرات](IronPin-0.7.2-changes-only.zip): {len(payload)}فایل، {len(added)}افزوده و {len(modified)}اصلاح، بدون حذف؛ روی سورس دقیق۰.۷.۱ بازنویسی کنید.
- [patch فشرده](IronPin-0.7.1-to-0.7.2.patch.xz): ابتدا با xz یا Python/lzma باز کنید، سپس `git apply --check` و `git apply` روی سورس دقیق۰.۷.۱. **هر دو روش مستقل، سورس کامل را بایت‌برابر بازسازی کردند.**
- [آزمون‌ها](TEST_REPORT.fa.md) · [پژوهش و محدودیت‌ها](RESEARCH.fa.md) · [تغییرات](CHANGES.v0.7.2.fa.md) · [سند تولید](PRODUCTION.fa.md) · [مانیفست بسته](PACKAGING.json) · [SHA256](SHA256SUMS.txt).

## Git و تاریخچه
commit محلی: `{head}`. هنگام بسته‌بندی remote برابر `{remote}` بود. **پوش این نسخه هنوز تأیید نشده است**؛ نتیجه واقعی جداگانه در `PUSH_STATUS.json` ثبت می‌شود. اعتبار قبلی استفاده نشده است.

هر۱۵۸فایل تحویل تاریخی با SHA قبل از کار تطبیق داده شد و همگی بدون تغییرند. فقط خروجی‌های جدید این نسخه بسته‌بندی شدند. APKهای۰.۷.۱ پایه آرشیو جدید و APKهای۰.۷.۰ پایه آرشیو تاریخی‌اند؛ حذفشان نکنید.
'''
    (O/'DELIVERY.fa.md').write_text(md)
    page='<!doctype html><html lang="fa" dir="rtl"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>IronPin۰.۷.۲</title><style>body{margin:0;background:#101a24;color:#e1eaf1;font:16px Tahoma,Arial;line-height:2}main{max-width:950px;margin:auto;padding:24px}h1,a{color:#58dec7}pre{white-space:pre-wrap;overflow-wrap:anywhere;font:inherit;background:#15242e;padding:20px;border-radius:14px}</style><main><h1>IronPin —۰.۷.۲</h1><p>بولت · انکربولت · تسمه · منابع بیشتر مشهد</p><pre>'+html.escape(md)+'</pre></main></html>'
    (O/'DELIVERY.fa.html').write_text(page)
    checks=''.join(f'{sha(p.read_bytes())}  {p.name}\n' for p in sorted(O.iterdir()) if p.is_file() and p.name!='SHA256SUMS.txt')
    (O/'SHA256SUMS.txt').write_text(checks)
    print(json.dumps({k:manifest[k] for k in ['gitHead','sourceFiles','changedFiles','addedFiles','modifiedFiles','historicalFilesVerifiedUnchanged']},indent=2))
    print('New release files',sum(p.stat().st_size for p in O.iterdir() if p.is_file()),'bytes')

if __name__=='__main__':main()
