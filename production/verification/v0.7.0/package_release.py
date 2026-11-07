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
o = r.parent/'deliverables'/'IronPin-0.7.0'
o.mkdir(parents=True, exist_ok=True)
sha = lambda b: hashlib.sha256(b).hexdigest()
head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=r, text=True).strip()
base = o.parent/'IronPin-0.6.1'/'IronPin-0.6.1-source.zip'
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
verify = 'production/verification/v0.7.0/'
assert b'No issues found!' in c[verify+'analyze.log']
assert b'+246: All tests passed!' in c[verify+'offline-final.log']
for p, h in json.loads(c[verify+'runtime-inputs.sha256.json']).items():
    assert p in c and sha(c[p]) == h, p
added = sorted(set(c)-set(b))
deleted = sorted(set(b)-set(c))
modified = sorted(p for p in c if p in b and c[p] != b[p])
payload = sorted(added+modified)
assert not deleted, deleted
for name, pp in [('IronPin-0.7.0-source.zip', paths), ('IronPin-0.7.0-changes-only.zip', payload)]:
    with ZipFile(o/name, 'w', ZIP_DEFLATED, compresslevel=9) as z:
        for p in pp: z.writestr('IronPin/'+p, c[p])
patch = ''
for p in payload:
    patch += f'diff --git a/{p} b/{p}\n' + ('new file mode 100644\n' if p in added else '')
    patch += ''.join(line if line.endswith('\n') else line+'\n\\ No newline at end of file\n'
        for line in difflib.unified_diff(b.get(p,b'').decode().splitlines(keepends=True),
            c[p].decode().splitlines(keepends=True), fromfile='a/'+p if p in b else '/dev/null', tofile='b/'+p))
pf = o/'IronPin-0.6.1-to-0.7.0.patch'
pf.write_text(patch)
with tempfile.TemporaryDirectory(dir=r.parent/'.cache') as tmp:
    t = Path(tmp)
    for p, content in b.items():
        f = t/p; f.parent.mkdir(parents=True, exist_ok=True); f.write_bytes(content)
    subprocess.run(['git','apply','--check',str(pf)], cwd=t, check=True, capture_output=True)
    subprocess.run(['git','apply',str(pf)], cwd=t, check=True, capture_output=True)
    assert {str(p.relative_to(t)):p.read_bytes() for p in t.rglob('*') if p.is_file()} == c
with ZipFile(o/'IronPin-0.7.0-changes-only.zip') as z:
    rebuilt = b.copy(); rebuilt.update({n.removeprefix('IronPin/'):z.read(n) for n in z.namelist()})
    assert rebuilt == c
with ZipFile(o/'IronPin-0.7.0-source.zip') as z:
    assert {n.removeprefix('IronPin/'):z.read(n) for n in z.namelist()} == c
for src, dest in {
    'docs/TEST_REPORT.v0.7.0.fa.md':'TEST_REPORT.fa.md',
    'docs/RESEARCH_PRODUCTS.v0.7.0.fa.md':'RESEARCH_PRODUCTS.fa.md',
    'production/CHANGES.v0.7.0.fa.md':'CHANGES.v0.7.0.fa.md',
    'production/PRODUCTION.fa.md':'PRODUCTION.fa.md',
}.items(): shutil.copyfile(r/src, o/dest)
apks = json.loads(c[verify+'apk-metadata.json'])
for a in apks:
    src = r/'build/app/outputs/flutter-apk'/f'app-{a["abi"]}-release.apk'
    assert sha(src.read_bytes()) == a['sha256']
    shutil.copyfile(src, o/a['file'])
remote = subprocess.check_output(['git','ls-remote','https://github.com/alisport1384/IronPin.git','refs/heads/main'], text=True).split()[0]
if args.pushed: assert remote == head
manifest = {'version':'0.7.0+9','baselineVersion':'0.6.1','baselineGit':'3dd60b6d81e15ddc34002d491d09d5259c52a341',
    'baselineSourceZipSha256':sha(base.read_bytes()),'sourceFiles':len(paths),'changedFiles':len(payload),
    'addedFiles':len(added),'modifiedFiles':len(modified),'deletedFiles':deleted,
    'offlineTestsPassed':246,'analyze':'No issues found','patchApplyVerified':True,'deltaReconstructionVerified':True,
    'sourceZipBytesVerified':True,'runtimeInputHashesVerified':True,'dependencyLockUnchanged':True,
    'gitHead':head,'remoteHead':remote,'pushVerified':args.pushed,'apks':apks,
    'newSourceLiveTransport':'both timed out at 22 seconds; research reading and transcribed fixtures are separate evidence',
    'deviceInstallationTested':False,
    'archivedV04':json.loads((o.parent/'ARCHIVED-APK-0.4.0.manifest.json').read_text()),
    'files':[{'path':p,'sha256':sha(c[p]),'change':'added' if p in added else 'modified' if p in modified else 'unchanged'} for p in paths]}
(o/'PACKAGING.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+'\n')
status = f'پوش تأیید شد؛ main ریموت برابر commit محلی `{head}` است.' if args.pushed else f'commit محلی آماده: `{head}`. **پوش انجام نشده است؛ احراز هویت تازه و امن لازم است.** ریموت همچنان `{remote}` است. از اعتبار قبلی استفاده نشده است.'
apktext = '\n'.join(f'- [{a["abi"]}]({a["file"]}) — {a["bytes"]:,} بایت؛ SHA256: `{a["sha256"]}`' for a in apks)
md = f'''# تحویل IronPin — ۰.۷.۰+۹

## نصب اندروید
{apktext}

ARM64 برای بیشتر گوشی‌های جدید و ARM32 برای دستگاه سازگار۳۲بیتی است؛ فقط APK مناسب دستگاه را نصب کنید. package ثابت، min21/target35 و codes1009/2009 با **همان گواهی AndroidDebug قبلی** حفظ شدند؛ این کلید انتشار فروشگاهی نیست. پیش از ارتقا بکاپ بگیرید و روی نسخه قبلی نصب کنید؛ uninstall نکنید. نصب/ارتقای گوشی واقعی آزموده نشده است.

## تغییر اصلی
- خانواده مستقل ورق/پلیت/صفحه فولادی و فرم اختصاصی۱۶خانواده با فیلدهای اختیاری؛ خانواده → مشخصات → مود قیمت → تأیید.
- تمام اعلام‌های یکتای مرتبط در۴۸ساعت با تاریخ اعلام منبع، نه دریافت؛ بدون شرط کارخانه/فروشنده/کشور/شهر/محل تولید. نامعلومِ انتخاب‌شده تطبیق مثبت نیست؛ فیلد خالی محدودیت ندارد.
- واحدهای نامرتبط جدا، فقط ریال صریح به تومان؛ داده مبهم تازه دیده می‌شود اما آمار ندارد. کاتالوگ کامل محلی با جستجو/صفحه‌بندی و انتخاب کالای بدون رنج محفوظ است. میانگین نرخ منتخب به تومان گرد می‌شود.
-۷۲منبع ثبت‌شده پیش‌فرض روشن با مهاجرت یک‌باره و حفظ انتخاب بعدی؛ دو اتصال تازه ثامن نبشی/شهرآهن پروفیل مشهد. دریافت مستقیم هر دو از این محیط timeout شد؛ fixture پژوهشی را آزمون زنده موفق معرفی نمی‌کنیم.
- لاگ فقط خلاصه محصول/منبع: کل۱MiB، هر فایل۱۲۸KiB، حداکثر۱۰نمونه تغییر در snapshot. لاگ تشخیصی قدیمی برنامه حذف می‌شود، نه دیتابیس/تاریخچه/بکاپ.
- فارسی، بکاپ کامل ادغامی و دریافت فقط با دکمه نوسازی محفوظ؛ بدون وابستگی/بک‌اند/قیمت حدسی تازه.

## سورس و اسناد
- [سورس کامل](IronPin-0.7.0-source.zip): {len(paths)}فایل؛ بدون SDK/کش/کلید/APK/credential.
- [فقط تغییرات نسبت به۰.۶.۱](IronPin-0.7.0-changes-only.zip): {len(payload)}فایل = {len(modified)}تغییر + {len(added)}افزوده، بدون حذف.
- [patch دقیق۰.۶.۱به۰.۷](IronPin-0.6.1-to-0.7.0.patch)؛ apply-check و بازسازی بایت‌برابر مستقل آزموده شد. روی همان ZIPمبنای۰.۶.۱اعمال شود، نه هر نسخه دلخواه.
- [پژوهش/قرارداد](RESEARCH_PRODUCTS.fa.md) · [گزارش آزمون](TEST_REPORT.fa.md) · [تغییرات](CHANGES.v0.7.0.fa.md) · [سند تولید](PRODUCTION.fa.md) · [مانیفست](PACKAGING.json) · [SHA256](SHA256SUMS.txt).

## تأیید واقعی
۲۴۶آزمون آفلاین موفق؛ analyze بدون مسئله. دوAPK release با aapt/apksigner، v1/v2، گواهی قبلی، ABI/ELF، registry، markerهای جدیدAOT و SAF/dex بررسی شدند. source hash قبل/بعد ساخت یکسان و lockfile ثابت است. آزمون گوشی واقعی/SAF/نصب/upgrade/FPS انجام نشده و دریافت زنده همه منابع تأیید نشده است.

## وضعیت پوش
{status}

## نگهداری تحویل قبلی
طبق اجازه همین نوبت، فقط دو APK۰.۴ از مسیر مستقیم به [آرشیو بدون اتلاف تفاضلی](../ARCHIVED-APK-0.4.0.tar.xz) منتقل شدند؛ [راهنما](../ARCHIVED-APK-0.4.0.fa.md)، [رمزگشای Python](../RESTORE-APK-0.4.0.py) و [مانیفست](../ARCHIVED-APK-0.4.0.manifest.json) کنار آن‌اند. بازیابی به آرشیو۰.۱تا۰.۳ موجود و تغییریافته‌نشده نیاز دارد. هر دو APK با رمزگشای مستقل، اندازه و SHA256 اصلی بایت‌برابر شدند. APKهای۰.۵به‌بعد و سورس‌ها/اسناد قدیمی دست‌نخورده‌اند؛ مجوز یکپارچه‌سازی تا۰.۵ داده نشد و اجرا نشد.
'''
(o/'DELIVERY.fa.md').write_text(md)
links = [(a['file'], a['abi']) for a in apks]+[('IronPin-0.7.0-changes-only.zip','فقط تغییرات'),('IronPin-0.7.0-source.zip','سورس کامل'),('TEST_REPORT.fa.md','گزارش آزمون')]
page = '<!doctype html><html lang="fa" dir="rtl"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>IronPin ۰.۷</title><style>body{margin:0;background:#101a24;color:#e1eaf1;font:16px Tahoma,Arial;line-height:2}main{max-width:960px;margin:auto;padding:28px}h1{color:#4ed8c1}a{color:#64e3d4}nav{display:flex;gap:12px;flex-wrap:wrap}nav a{border:1px solid #42626b;padding:8px 16px;border-radius:12px}pre{white-space:pre-wrap;overflow-wrap:anywhere;font:inherit;background:#15242e;padding:24px;border-radius:16px}</style><main><h1>IronPin — رنج محصول‌محور ۰.۷.۰</h1><p>۲۴۶ آزمون موفق · دو APK ممیزی‌شده · پوش وابسته به احراز هویت تازه</p><nav>'+''.join(f'<a href="{html.escape(p)}">{html.escape(label)}</a>' for p,label in links)+'</nav><pre>'+html.escape(md)+'</pre></main></html>'
(o/'DELIVERY.fa.html').write_text(page)
checks = ''.join(f'{sha(p.read_bytes())}  {p.name}\n' for p in sorted(o.iterdir()) if p.is_file() and p.name != 'SHA256SUMS.txt')
(o/'SHA256SUMS.txt').write_text(checks)
for line in checks.splitlines(): h,n = line.split('  ',1); assert sha((o/n).read_bytes()) == h
print(json.dumps({k:manifest[k] for k in ['sourceFiles','changedFiles','addedFiles','modifiedFiles','gitHead','pushVerified']}, indent=2))
