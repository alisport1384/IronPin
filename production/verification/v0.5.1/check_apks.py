"""Verify built APKs without installing them. Requires Android build-tools/JDK17."""
from pathlib import Path
import hashlib, json, os, re, struct, subprocess, zipfile
root=Path(__file__).resolve().parents[3]
sdk=Path(os.environ.get('ANDROID_SDK_ROOT',os.environ.get('ANDROID_HOME','/home/user/.cache/android-sdk')))
tools=sdk/'build-tools'/'34.0.0'
expected_cert='360dabf5f2cf2ee39c9dc90bcb093a381e93a17d6a4f87d978a41d9ecff588b4'
results=[]
for abi,code,machine in [('armeabi-v7a',1006,40),('arm64-v8a',2006,183)]:
    apk=root/'build/app/outputs/flutter-apk'/f'app-{abi}-release.apk'
    badging=subprocess.check_output([str(tools/'aapt'),'dump','badging',str(apk)],text=True)
    permissions=subprocess.check_output([str(tools/'aapt'),'dump','permissions',str(apk)],text=True)
    signature=subprocess.check_output([str(tools/'apksigner'),'verify','--verbose','--print-certs',str(apk)],text=True)
    (Path(__file__).parent/f'{abi}-aapt.txt').write_text(badging+'\n'+permissions)
    (Path(__file__).parent/f'{abi}-signature.txt').write_text(signature)
    assert "name='ir.ironpin.ironpin'" in badging
    assert "versionName='0.5.1'" in badging and f"versionCode='{code}'" in badging
    assert "sdkVersion:'21'" in badging and "targetSdkVersion:'35'" in badging
    assert 'Verified using v1 scheme (JAR signing): true' in signature
    assert 'Verified using v2 scheme (APK Signature Scheme v2): true' in signature
    certificate=re.search(r'Signer #1 certificate SHA-256 digest: (\w+)',signature)[1]
    assert certificate==expected_cert
    with zipfile.ZipFile(apk) as z:
        abis=sorted({n.split('/')[1] for n in z.namelist() if n.startswith('lib/')})
        assert abis==[abi]
        registry=z.read('assets/flutter_assets/assets/registry.json')
        assert registry==(root/'assets/registry.json').read_bytes()
        app=z.read(f'lib/{abi}/libapp.so')
        assert app[:4]==b'\x7fELF' and struct.unpack('<H',app[18:20])[0]==machine
        markers={s:any(s.encode(e)in app for e in ['utf-8','utf-16-le']) for s in ['0.5.1','محلی v2','جزئیات بیشتر','allRegisteredSourcesEnabledVersion','telegram-ghanbari','khabazzade-sheet','ProductQuery','PublicTables','retire']}
        for s in ['0.5.1','محلی v2','جزئیات بیشتر','allRegisteredSourcesEnabledVersion','telegram-ghanbari','khabazzade-sheet','retire']:assert markers[s],s
        assert b'TextAnalysisSheet' not in app
    results.append({'file':f'IronPin-0.5.1-{abi}.apk','abi':abi,'bytes':apk.stat().st_size,'sha256':hashlib.sha256(apk.read_bytes()).hexdigest(),'package':'ir.ironpin.ironpin','versionName':'0.5.1','versionCode':code,'minSdk':21,'targetSdk':35,'certificateSha256':certificate,'signatureV1':True,'signatureV2':True,'registryMatchesSource':True,'nativeAbis':abis,'elfMachine':machine,'aotMarkers':markers,'removedManualSheetMarkerAbsent':True,'deviceInstallationTested':False})
(Path(__file__).parent/'apk-metadata.json').write_text(json.dumps(results,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(results,ensure_ascii=False,indent=2))
