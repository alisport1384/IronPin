"""Verified full source, minimal delta, patch and two-ABI delivery. No keys.
Run only after staging the intended source and committing it. --pushed requires
remote main to equal the local commit. Historical release files are read only.
"""
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED
import argparse, difflib, hashlib, html, json, re, shutil, subprocess, tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--pushed', action='store_true')
args = parser.parse_args()
r = Path(__file__).resolve().parents[3]
o = r.parent/'deliverables'/'IronPin-0.7.1'
o.mkdir(parents=True, exist_ok=True)
sha = lambda b: hashlib.sha256(b).hexdigest()
head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=r, text=True).strip()
base = o.parent/'IronPin-0.7.0'/'IronPin-0.7.0-source.zip'
assert sha(base.read_bytes()) in (base.parent/'SHA256SUMS.txt').read_text()
with ZipFile(base) as z:
    b = {n.removeprefix('IronPin/'): z.read(n) for n in z.namelist() if not n.endswith('/')}
paths = sorted(subprocess.check_output(['git', 'ls-files'], cwd=r, text=True).splitlines())
c = {p: (r/p).read_bytes() for p in paths}
for p, content in c.items():
    assert not set(Path(p).parts) & {'.git', '.cache', '.dart_tool', 'build', '__pycache__'}, p
    assert not p.endswith(('.apk', '.keystore', '.jks', '.pyc')), p
    assert not re.search(rb'(?:ghp_[A-Za-z0-9]{25,}|github_pat_[A-Za-z0-9_]{25,})', content), p
assert c['pubspec.lock'] == b['pubspec.lock']
verify = 'production/verification/v0.7.1/'
assert b'No issues found!' in c[verify+'analyze.log']
assert b'+262: All tests passed!' in c[verify+'offline-final.log']
for p, h in json.loads(c[verify+'runtime-inputs.sha256.json']).items():
    assert p in c and sha(c[p]) == h, p
added = sorted(set(c)-set(b))
deleted = sorted(set(b)-set(c))
modified = sorted(p for p in c if p in b and c[p] != b[p])
payload = sorted(added+modified)
assert not deleted, deleted
for name, pp in [('IronPin-0.7.1-source.zip', paths), ('IronPin-0.7.1-changes-only.zip', payload)]:
    with ZipFile(o/name, 'w', ZIP_DEFLATED, compresslevel=9) as z:
        for p in pp: z.writestr('IronPin/'+p, c[p])
patch = ''
for p in payload:
    patch += f'diff --git a/{p} b/{p}\n' + ('new file mode 100644\n' if p in added else '')
    patch += ''.join(line if line.endswith('\n') else line+'\n\\ No newline at end of file\n'
        for line in difflib.unified_diff(b.get(p,b'').decode().splitlines(keepends=True),
            c[p].decode().splitlines(keepends=True), fromfile='a/'+p if p in b else '/dev/null', tofile='b/'+p))
pf = o/'IronPin-0.7.0-to-0.7.1.patch'
pf.write_text(patch)
with tempfile.TemporaryDirectory(dir=r.parent/'.cache') as tmp:
    t = Path(tmp)
    for p, content in b.items():
        f = t/p; f.parent.mkdir(parents=True, exist_ok=True); f.write_bytes(content)
    subprocess.run(['git','apply','--check',str(pf)], cwd=t, check=True, capture_output=True)
    subprocess.run(['git','apply',str(pf)], cwd=t, check=True, capture_output=True)
    assert {str(p.relative_to(t)):p.read_bytes() for p in t.rglob('*') if p.is_file()} == c
with ZipFile(o/'IronPin-0.7.1-changes-only.zip') as z:
    rebuilt = b.copy(); rebuilt.update({n.removeprefix('IronPin/'):z.read(n) for n in z.namelist()})
    assert rebuilt == c
with ZipFile(o/'IronPin-0.7.1-source.zip') as z:
    assert {n.removeprefix('IronPin/'):z.read(n) for n in z.namelist()} == c
for src, dest in {
    'docs/TEST_REPORT.v0.7.1.fa.md':'TEST_REPORT.fa.md',
    'docs/RESEARCH_SCOPE_RANGE.v0.7.1.fa.md':'RESEARCH_SCOPE_RANGE.fa.md',
    'production/CHANGES.v0.7.1.fa.md':'CHANGES.v0.7.1.fa.md',
    'production/PRODUCTION.fa.md':'PRODUCTION.fa.md',
}.items(): shutil.copyfile(r/src, o/dest)
apks = json.loads(c[verify+'apk-metadata.json'])
for a in apks:
    src = r/'build/app/outputs/flutter-apk'/f'app-{a["abi"]}-release.apk'
    assert sha(src.read_bytes()) == a['sha256']
    shutil.copyfile(src, o/a['file'])
remote = subprocess.check_output(['git','ls-remote','https://github.com/alisport1384/IronPin.git','refs/heads/main'], text=True).split()[0]
if args.pushed: assert remote == head
manifest = {'version':'0.7.1+10','baselineVersion':'0.7.0','baselineGit':'6e942bd0710dece0034114cfcd2d58dc0fc026bf',
    'baselineSourceZipSha256':sha(base.read_bytes()),'sourceFiles':len(paths),'changedFiles':len(payload),
    'addedFiles':len(added),'modifiedFiles':len(modified),'deletedFiles':deleted,
    'offlineTestsPassed':262,'analyze':'No issues found','patchApplyVerified':True,'deltaReconstructionVerified':True,
    'sourceZipBytesVerified':True,'runtimeInputHashesVerified':True,'dependencyLockUnchanged':True,
    'gitHead':head,'remoteHead':remote,'pushVerified':args.pushed,'apks':apks,
    'newSourceLiveTransport':'Telegram SourceClient parsed 31 rows/27 text amounts in 1630ms, zero fresh comparable ranges; Eitaa timed out at 22 seconds; only a one-page manual smoke',
    'deviceInstallationTested':False,
    'archivedV050051':json.loads((o.parent/'ARCHIVED-APK-0.5.0-0.5.1.manifest.json').read_text()),
    'files':[{'path':p,'sha256':sha(c[p]),'change':'added' if p in added else 'modified' if p in modified else 'unchanged'} for p in paths]}
(o/'PACKAGING.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+'\n')
status = f'پوش تأیید شد؛ main ریموت برابر commit محلی `{head}` است.' if args.pushed else f'commit محلی آماده: `{head}`. **پوش انجام نشده است؛ احراز هویت تازه و امن لازم است.** ریموت همچنان `{remote}` است. از اعتبار قبلی استفاده نشده است.'
apktext = '\n'.join(f'- [{a["abi"]}]({a["file"]}) — {a["bytes"]:,} بایت؛ SHA256: `{a["sha256"]}`' for a in apks)
md = f'''# تحویل IronPin — ۰.۷.۱+۱۰

## نصب
{apktext}

ARM64 برای بیشتر گوشی‌های جدید؛ ARM32 برای دستگاه سازگار۳۲بیتی. فقط APK مناسب دستگاه را نصب کنید. **قبل از ارتقا بکاپ کامل بگیرید، روی نسخه قبلی نصب کنید و uninstall نکنید.** package ثابت، min21/target35 و codes1010/2010 با همان گواهی AndroidDebug پیشین؛ این امضای فروشگاهی نیست. نصب/ارتقای گوشی واقعی آزموده نشده است.

## تغییرهای اصلی
- رنج فقط پس از تأیید، با snapshot ثابت، پیشرفت، لغو، مهلت محدود و تلاش مجدد؛ دریافت هر منبع محاسبه را از نو شروع نمی‌کند. نبود نرخ معتبر، دلیل روشن دارد.
- **انتخاب شهر فقط در اطلاعات**؛ یک scope ماندگار برای نمایش، جستجو، نمودار، رنج و هزینه بازار؛ همه نقش‌های صریح همان کالا و بدون حدس. Back انتخاب‌گر شهر را پاک نمی‌کند؛ «همه شهرها» فقط با انتخاب صریح.
- **دریافت تمام منابع فعال مستقل از شهر**؛ داده شهرهای دیگر محلی حفظ می‌شود و در scope منتخب نمایش/محاسبه نمی‌شود. حسابگر عمومی فقط ورودی دستی می‌گیرد.
- **لاگ پیش‌فرض خاموش**؛ کلید اختیاری در اطلاعات، فقط محصول/منبع و سقف۱MiB/۱۲۸KiB.
- منبع تازه بنیان فولاد قوام مشهد، یک سازمان/دو endpoint تلگرام و ایتا، مجموع۷۴مسیر ثبت‌شده؛ SourceClient تلگرام۳۱ردیف خواند ولی۰رنج تازه قابل مقایسه، ایتا۲۲s timeout. ارز/واحد نامعلوم یا تاریخ قدیمی وارد آمار نمی‌شود؛ خرید/دستمزد نرخ فروش نیست.
- قرارداد۴۸ساعت بر تاریخ اعلام، همه اعلام‌های یکتا، مشخصات اختیاری، ریال صریح→تومان و واحدهای جدا، کاتالوگ کامل، بکاپ ادغامی، فارسی و نوسازی فقط دستی محفوظ‌اند؛ dependency/schema تغییر نکرده است.

## نتیجه واقعی
**۲۶۲آزمون آفلاین موفق و analyze بدون مسئله.** دو APK release، ABI/ELF، registry، markerهای جدید AOT، SAF/dex، امضای v1/v2 و گواهی قبلی ممیزی شدند. hash ورودی runtime قبل/بعد ساخت برابر و lockfile ثابت است. snapshot مصنوعی۸۷۳۰ردیف با heartbeat آزموده شد؛ این FPS یا DB خصوصی گوشی کاربر نیست. لاگ ارسالی علت قطعی فریز رنج را ثبت نکرده بود؛ نصب/SAF/upgrade/کارایی گوشی و دریافت همه۷۴مسیر آزموده نشده‌اند.

## سورس و تغییرات دقیق نسبت به۰.۷.۰
- [سورس کامل](IronPin-0.7.1-source.zip): {len(paths)}فایل بدون credential/کلید/APK/SDK/cache.
- [فقط تغییرات](IronPin-0.7.1-changes-only.zip): {len(payload)}فایل = {len(added)}افزوده + {len(modified)}اصلاح، بدون حذف.
- [patch۰.۷.۰به۰.۷.۱](IronPin-0.7.0-to-0.7.1.patch): apply-check و بازسازی بایت‌برابر، مستقل از ZIP تغییرات تأیید شد. فقط روی ZIP سورس دقیق۰.۷.۰ اعمال شود.
- [گزارش آزمون](TEST_REPORT.fa.md) · [پژوهش/محدودیت‌ها](RESEARCH_SCOPE_RANGE.fa.md) · [تغییرات](CHANGES.v0.7.1.fa.md) · [سند تولید](PRODUCTION.fa.md) · [مانیفست](PACKAGING.json) · [SHA256](SHA256SUMS.txt).

## وضعیت پوش
{status}

## نگهداری تحویل‌های قبلی
فقط۴APK۰.۵/۰.۵.۱ طبق اجازه در [آرشیو بدون اتلاف](../ARCHIVED-APK-0.5.0-0.5.1.tar.xz) قرار گرفتند؛ [راهنما](../ARCHIVED-APK-0.5.0-0.5.1.fa.md)، [manifest](../ARCHIVED-APK-0.5.0-0.5.1.manifest.json)، [SHA](../ARCHIVED-APK-0.5.0-0.5.1.SHA256SUMS.txt) و [بازیاب Python](../RESTORE-APK-0.5.0-0.5.1.py) کنار آن‌اند. بازیابی مستقل و SHA/بایت هر چهار فایل پیش از حذف مسیر مستقیم موفق بود؛۲۰۶۸۰۸۱۷بایت صرفه‌جویی. **دو APK۰.۷.۰ پایه ضروری این آرشیو هستند و باید حفظ شوند.** سورس/اسناد قدیمی و APK۰.۶به‌بعد دست‌نخورده‌اند. این پوشه جدید جایگزین تحویل قبلی نیست.
'''
(o/'DELIVERY.fa.md').write_text(md)
links=[(a['file'],a['abi']) for a in apks]+[('IronPin-0.7.1-changes-only.zip','فقط تغییرات'),('IronPin-0.7.1-source.zip','سورس کامل'),('TEST_REPORT.fa.md','گزارش آزمون')]
page='<!doctype html><html lang="fa" dir="rtl"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>IronPin۰.۷.۱</title><style>body{margin:0;background:#101a24;color:#e1eaf1;font:16px Tahoma,Arial;line-height:2}main{max-width:960px;margin:auto;padding:28px}h1{color:#4ed8c1}a{color:#64e3d4}nav{display:flex;gap:12px;flex-wrap:wrap}nav a{border:1px solid #42626b;padding:8px 16px;border-radius:12px}pre{white-space:pre-wrap;overflow-wrap:anywhere;font:inherit;background:#15242e;padding:24px;border-radius:16px}</style><main><h1>IronPin —۰.۷.۱</h1><p>۲۶۲آزمون موفق · رنج پایدار · شهر واحد · لاگ اختیاری</p><nav>'+''.join(f'<a href="{html.escape(p)}">{html.escape(label)}</a>' for p,label in links)+'</nav><pre>'+html.escape(md)+'</pre></main></html>'
(o/'DELIVERY.fa.html').write_text(page)
checks=''.join(f'{sha(p.read_bytes())}  {p.name}\n' for p in sorted(o.iterdir()) if p.is_file() and p.name!='SHA256SUMS.txt')
(o/'SHA256SUMS.txt').write_text(checks)
for line in checks.splitlines(): h,n=line.split('  ',1);assert sha((o/n).read_bytes())==h
print(json.dumps({k:manifest[k] for k in ['sourceFiles','changedFiles','addedFiles','modifiedFiles','gitHead','pushVerified']},indent=2))
