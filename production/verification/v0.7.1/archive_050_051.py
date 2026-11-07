"""User-approved lossless archival: exactly four v0.5.0/v0.5.1 APKs.
Unmodified v0.7.0 APKs are checksum-pinned decode bases; no other old file
is changed. Verify archive and independent standard-Python restore BEFORE
removing the four original paths. Archive and guides live beside deliverables.
"""
from pathlib import Path
import hashlib, io, json, os, subprocess, sys, tarfile
import bsdiff4
root = Path(__file__).resolve().parents[4]/'deliverables'
work = root.parent/'.cache'/'archive-050-051'
work.mkdir(parents=True, exist_ok=True)
sha = lambda b: hashlib.sha256(b).hexdigest()
archive = root/'ARCHIVED-APK-0.5.0-0.5.1.tar.xz'
assert not archive.exists(), 'Do not execute an archival step twice'
entries = []; patches = {}
for version in ['0.5.0', '0.5.1']:
    for abi in ['armeabi-v7a', 'arm64-v8a']:
        relative = f'IronPin-{version}/IronPin-{version}-{abi}.apk'
        baseversion = '0.7.0' if version == '0.5.0' else '0.5.0'
        basepath = f'IronPin-{baseversion}/IronPin-{baseversion}-{abi}.apk'
        old, target = (root/basepath).read_bytes(), (root/relative).read_bytes()
        patchname = f'{version}-{abi}.bsdiff'
        patch = bsdiff4.diff(old, target)
        assert bsdiff4.patch(old, patch) == target
        patches[patchname] = patch
        entries.append({'path':relative,'bytes':len(target),'sha256':sha(target),
                        'basePath':basepath,'baseSha256':sha(old),'patch':patchname,'patchSha256':sha(patch)})
manifest = {'format':'BSDIFF40 inside tar.xz', 'authorizedVersions':['0.5.0','0.5.1'],
            'preservedExternalBases':'Both unmodified v0.7.0 APKs must remain beside this archive',
            'files':entries,'originalBytes':sum(e['bytes'] for e in entries)}
encoded = (json.dumps(manifest,ensure_ascii=False,indent=2)+'\n').encode()
with tarfile.open(work/'verified.tar.xz','w:xz',preset=9) as t:
    for name, data in [('manifest.json',encoded),*patches.items()]:
        info=tarfile.TarInfo(name);info.size=len(data);info.mtime=0;t.addfile(info,io.BytesIO(data))
with tarfile.open(work/'verified.tar.xz') as t:
    assert t.extractfile('manifest.json').read() == encoded
    for name,data in patches.items(): assert t.extractfile(name).read() == data
os.replace(work/'verified.tar.xz',archive)
(root/'ARCHIVED-APK-0.5.0-0.5.1.manifest.json').write_bytes(encoded)
# Reuse only the portable decoder algorithm, not its historical main() or bases.
previous = (root/'RESTORE-APK-0.4.0.py').read_text()
algorithm = previous[previous.index('def sha('):previous.index('def main():')]
restore = '''#!/usr/bin/env python3
"""Restore the four archived 0.5/0.5.1 APKs, verifying every SHA256.
Keep both v0.7.0 APKs in the adjacent IronPin-0.7.0 folder. Standard Python only.
Use --output DIRECTORY to restore without touching original deliverable folders.
"""
from pathlib import Path
import argparse, bz2, hashlib, json, os, tarfile
''' + algorithm + '''
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path);args=p.parse_args()
    root=Path(__file__).resolve().parent; out=args.output or root; recovered={}
    archive=root/'ARCHIVED-APK-0.5.0-0.5.1.tar.xz'
    checks=(root/'ARCHIVED-APK-0.5.0-0.5.1.SHA256SUMS.txt').read_text().splitlines()
    expected=next(line.split('  ',1)[0] for line in checks if line.endswith('  '+archive.name))
    assert sha(archive.read_bytes())==expected,'Archive SHA256 mismatch'
    with tarfile.open(archive) as t:
        manifest=json.load(t.extractfile('manifest.json'))
        assert manifest==json.loads((root/'ARCHIVED-APK-0.5.0-0.5.1.manifest.json').read_text())
        for e in manifest['files']:
            old=recovered.get(e['basePath'])
            if old is None: old=(root/e['basePath']).read_bytes()
            assert sha(old)==e['baseSha256'],'Base SHA256 mismatch'
            delta=t.extractfile(e['patch']).read();assert sha(delta)==e['patchSha256']
            result=patch(old,delta)
            assert len(result)==e['bytes'] and sha(result)==e['sha256'],'Restored APK SHA256 mismatch'
            relative=Path(e['path']);assert not relative.is_absolute() and '..' not in relative.parts
            dest=out/relative
            if dest.exists(): assert sha(dest.read_bytes())==e['sha256'],'Refusing to overwrite different file'
            else:
                dest.parent.mkdir(parents=True,exist_ok=True)
                tmp=dest.with_suffix('.apk.restoring');tmp.write_bytes(result);os.replace(tmp,dest)
            recovered[e['path']]=result
            print(dest,e['sha256'])
if __name__=='__main__':main()
'''
(root/'RESTORE-APK-0.5.0-0.5.1.py').write_text(restore)
guide='''# آرشیو بدون اتلاف APKهای۰.۵ و۰.۵.۱

طبق اجازه صریح «فقط همین چهار APK»، فقط APKهای ARM32 وARM64 نسخه‌های۰.۵.۰ و۰.۵.۱ از مسیر مستقیم به آرشیو تفاضلی منتقل شدند. سورس، اسناد، بقیه تحویل‌ها و APKهای۰.۶به‌بعد تغییری نکردند.

## وابستگی ضروری
این آرشیو به **هر دو APK دست‌نخورده۰.۷.۰** در پوشه مجاور `IronPin-0.7.0` وابسته است. آن دو را حذف یا جابه‌جا نکنید. فایل‌های۰.۵ ابتدا از۰.۷، سپس۰.۵.۱ از۰.۵ بازسازی می‌شوند. همه اندازه‌ها و SHA256های اصلی در مانیفست داخل و بیرون آرشیو ثبت‌اند.

## بازیابی بایت‌برابر
فقط Python3 استاندارد؛ بدون اینترنت، بسته اضافی، نصب برنامه یا credential:

```sh
python3 RESTORE-APK-0.5.0-0.5.1.py --output recovered
```

حذف `--output recovered` چهار مسیر اصلی را برمی‌گرداند. فایل متفاوت موجود بازنویسی نمی‌شود. رمزگشا ابتدا SHA آرشیو، سپس پایه و patch و APK نهایی را تأیید می‌کند. پیش از حذف چهار APK اصلی، بازیابی مستقل به پوشه جدا و تطابق بایت‌برابر هر چهار فایل اجرا و ثبت شد. این آرشیو تحویل قدیمی است؛ APK جدید در پوشه جدا۰.۷.۱ قرار می‌گیرد.
'''
(root/'ARCHIVED-APK-0.5.0-0.5.1.fa.md').write_text(guide)
def checks():
    names=[archive.name,'ARCHIVED-APK-0.5.0-0.5.1.manifest.json','RESTORE-APK-0.5.0-0.5.1.py','ARCHIVED-APK-0.5.0-0.5.1.fa.md']
    (root/'ARCHIVED-APK-0.5.0-0.5.1.SHA256SUMS.txt').write_text(''.join(f'{sha((root/n).read_bytes())}  {n}\n' for n in names))
checks()
result=subprocess.run([sys.executable,str(root/'RESTORE-APK-0.5.0-0.5.1.py'),'--output',str(work/'recovered')],check=True,capture_output=True,text=True)
for e in entries: assert (root/e['path']).read_bytes()==(work/'recovered'/e['path']).read_bytes()
for e in entries: (root/e['path']).unlink()
report={'archive':archive.name,'archiveBytes':archive.stat().st_size,'archiveSha256':sha(archive.read_bytes()),
        'originalBytes':manifest['originalBytes'],'savedBytes':manifest['originalBytes']-archive.stat().st_size,
        'independentStandardPythonRestore':'passed','fourOriginalByteComparisons':'passed','removedOnly':[e['path'] for e in entries],
        'restoreOutput':result.stdout}
(Path(__file__).parent/'archive-result.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(report,ensure_ascii=False,indent=2))
