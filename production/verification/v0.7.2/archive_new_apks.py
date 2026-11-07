"""Package ONLY the new 0.7.2 APKs losslessly; historical files are read-only.
Research: https://www.daemonology.net/bsdiff/ and
https://docs.python.org/3.13/library/zlib.html (raw DEFLATE, wbits=-15).
Compressed libapp streams are sensitive to minor AOT changes. Patch the raw
library, re-deflate it byte-exactly, then patch the resulting synthetic APK.
Creation requires bsdiff4; restoration uses only Python's standard library.
"""
from pathlib import Path
import hashlib, json, shutil, struct, subprocess, sys, zipfile, zlib
import bsdiff4
ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT.parent/'deliverables'/'IronPin-0.7.2'
OUT.mkdir(parents=True, exist_ok=True)
sha = lambda b: hashlib.sha256(b).hexdigest()

def payload(blob, member):
    import io
    with zipfile.ZipFile(io.BytesIO(blob)) as z:
        i = z.getinfo(member)
        assert i.compress_type == zipfile.ZIP_DEFLATED
        start = i.header_offset + 30 + sum(struct.unpack_from('<HH',blob,i.header_offset+26))
        return start, i.compress_size, z.read(member)

def main():
    shutil.copyfile(Path(__file__).parent/'restore_apks.py', OUT/'RESTORE-APK-0.7.2.py')
    metadata = json.loads((Path(__file__).parent/'apk-metadata.json').read_text())
    manifest = {'version':'0.7.2+11', 'format':'zip-aware-bsdiff40-v1',
        'zlibBuildVersion':zlib.ZLIB_VERSION,'zlibRuntimeVersion':zlib.ZLIB_RUNTIME_VERSION,
        'compression':{'level':6,'wbits':-15,'memLevel':8,'strategy':0},'files':[]}
    patches = {}
    for a in metadata:
        abi = a['abi']; member = f'lib/{abi}/libapp.so'
        base = ROOT.parent/'deliverables'/'IronPin-0.7.1'/f'IronPin-0.7.1-{abi}.apk'
        newfile = ROOT.parent/'.cache/apks-v072'/f'app-{abi}-release.apk'
        old = base.read_bytes(); new = newfile.read_bytes()
        assert sha(new) == a['sha256']
        start, count, rawold = payload(old, member)
        newstart, newcount, rawnew = payload(new, member)
        co = zlib.compressobj(6,zlib.DEFLATED,-15)
        packed = co.compress(rawnew)+co.flush()
        assert packed == new[newstart:newstart+newcount], 'DEFLATE must match signed APK exactly'
        synthetic = old[:start]+packed+old[start+count:]
        rawpatch = bsdiff4.diff(rawold,rawnew)
        outerpatch = bsdiff4.diff(synthetic,new)
        assert bsdiff4.patch(rawold,rawpatch)==rawnew
        assert bsdiff4.patch(synthetic,outerpatch)==new
        rp=f'{abi}.libapp.bsdiff'; op=f'{abi}.outer.bsdiff'
        patches[rp]=rawpatch; patches[op]=outerpatch
        manifest['files'].append({'file':a['file'],'bytes':len(new),'sha256':sha(new),
            'base':f'../IronPin-0.7.1/{base.name}','baseSha256':sha(old),
            'member':member,'baseOffset':start,'baseCompressedBytes':count,
            'rawSha256':sha(rawnew),'rawBytes':len(rawnew),'compressedSha256':sha(packed),
            'compressedBytes':len(packed),'syntheticSha256':sha(synthetic),
            'rawPatch':rp,'rawPatchSha256':sha(rawpatch),
            'outerPatch':op,'outerPatchSha256':sha(outerpatch)})
        print(abi, 'raw patch', len(rawpatch), 'outer patch', len(outerpatch), flush=True)
    archive = OUT/'IronPin-0.7.2-apks.lossless.zip'
    with zipfile.ZipFile(archive,'w',zipfile.ZIP_STORED) as z:
        z.writestr('manifest.json',json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
        for p,b in patches.items():z.writestr(p,b)
    (OUT/'APK-ARCHIVE.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print('archive bytes',archive.stat().st_size,flush=True)
    # A separate standard-library decoder, not bsdiff4, proves exact restoration.
    target = ROOT.parent/'.cache/restored-v072'
    subprocess.run([sys.executable,str(OUT/'RESTORE-APK-0.7.2.py'),'--output',str(target)],check=True)
    for a in metadata:
        assert (target/a['file']).read_bytes() == (ROOT.parent/'.cache/apks-v072'/f'app-{a["abi"]}-release.apk').read_bytes()
    (Path(__file__).parent/'archive-result.json').write_text(json.dumps({
        'archive':archive.name,'bytes':archive.stat().st_size,'sha256':sha(archive.read_bytes()),
        'historicalFilesModified':False,'standardLibraryRestorationVerified':True,
        'apkByteEqualityVerified':True,'files':manifest['files']},indent=2)+'\n')

if __name__=='__main__':main()
