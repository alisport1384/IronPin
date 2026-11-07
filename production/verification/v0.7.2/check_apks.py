"""Verify built APKs without installing them. Requires Android build-tools/JDK17."""
from pathlib import Path
import hashlib, json, os, re, struct, subprocess, zipfile
root=Path(__file__).resolve().parents[3]
sdk=Path(os.environ.get('ANDROID_SDK_ROOT',os.environ.get('ANDROID_HOME','/home/user/.cache/android-sdk')))
tools=sdk/'build-tools'/'34.0.0'
expected_cert='360dabf5f2cf2ee39c9dc90bcb093a381e93a17d6a4f87d978a41d9ecff588b4'
results=[]
for abi,code,machine in [('armeabi-v7a',1011,40),('arm64-v8a',2011,183)]:
    apk=root/'build/app/outputs/flutter-apk'/f'app-{abi}-release.apk'
    badging=subprocess.check_output([str(tools/'aapt'),'dump','badging',str(apk)],text=True)
    permissions=subprocess.check_output([str(tools/'aapt'),'dump','permissions',str(apk)],text=True)
    signature=subprocess.check_output([str(tools/'apksigner'),'verify','--verbose','--print-certs',str(apk)],text=True)
    (Path(__file__).parent/f'{abi}-aapt.txt').write_text(badging+'\n'+permissions)
    (Path(__file__).parent/f'{abi}-signature.txt').write_text(signature)
    assert "name='ir.ironpin.ironpin'" in badging
    assert "versionName='0.7.2'" in badging and f"versionCode='{code}'" in badging
    assert 'android.permission.MANAGE_EXTERNAL_STORAGE' not in permissions
    assert 'android.permission.WRITE_EXTERNAL_STORAGE' not in permissions
    assert 'android.permission.READ_EXTERNAL_STORAGE' not in permissions
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
        markers={s:any(s.encode(e)in app for e in ['utf-8','utf-16-le']) for s in ['rahsakht-wire','rahsakht-galv','rahsakht-rabits','rahsakht-bastar','telegram-rahsakht','telegram-profilonline','khoshkam-rebar','maham-beam12','طول بازشده هر بولت روی محور میله (متر)','وزن واقعی هر عدد یا ست کامل (کیلوگرم)','تسمه فولادی','0.7.2','محلی v2','جزئیات بیشتر','allRegisteredSourcesEnabledVersion','telegram-ghanbari','khabazzade-sheet','ProductQuery','PublicTables','samen-angle','shahr-mashhad','telegram-bonyan-ghavam','eitaa-bonyan-ghavam','selectedCity','loggingEnabled','لغو محاسبه','مشخصات بیشتر','فهرست کامل محلی','رنج عددی قابل مقایسه نداریم','samen-angle','shahr-mashhad','telegram-bonyan-ghavam','eitaa-bonyan-ghavam','selectedCity','loggingEnabled','لغو محاسبه','مشخصات بیشتر','رنج عددی قابل مقایسه نداریم','retire','IronPin-backup','importBackup','exportBackup','محاسبات همان کالا','رنج‌گیری ۴۸ ساعت','تأیید و نمایش رنج','جستجو در تمام اعلام‌های نتیجه','تنظیمات کاربری بکاپ، از جمله روشن/خاموش بودن منابع، جایگزین شوند.']}
        markers.update({s:any(s.encode(e) in app for e in ['utf-8','utf-16-le']) for s in ['rahsakht-wire','rahsakht-galv','rahsakht-rabits','rahsakht-bastar','telegram-rahsakht','telegram-profilonline','khoshkam-rebar','maham-beam12','طول بازشده هر بولت روی محور میله (متر)','وزن واقعی هر عدد یا ست کامل (کیلوگرم)','تسمه فولادی']})
        for s in ['rahsakht-wire','rahsakht-galv','rahsakht-rabits','rahsakht-bastar','telegram-rahsakht','telegram-profilonline','khoshkam-rebar','maham-beam12','طول بازشده هر بولت روی محور میله (متر)','وزن واقعی هر عدد یا ست کامل (کیلوگرم)','تسمه فولادی','0.7.2','محلی v2','جزئیات بیشتر','allRegisteredSourcesEnabledVersion','telegram-ghanbari','khabazzade-sheet','samen-angle','shahr-mashhad','telegram-bonyan-ghavam','eitaa-bonyan-ghavam','selectedCity','loggingEnabled','لغو محاسبه','مشخصات بیشتر','رنج عددی قابل مقایسه نداریم','retire','IronPin-backup','importBackup','exportBackup','محاسبات همان کالا','رنج‌گیری ۴۸ ساعت','تأیید و نمایش رنج','جستجو در تمام اعلام‌های نتیجه','تنظیمات کاربری بکاپ، از جمله روشن/خاموش بودن منابع، جایگزین شوند.']:assert markers[s],s
        assert b'TextAnalysisSheet' not in app
        dex=b''.join(z.read(n) for n in z.namelist() if n.endswith('.dex'))
        for marker in [b'importBackup',b'exportBackup',b'application/x-ndjson',b'IronPin/backups']:assert marker in dex, marker
    results.append({'file':f'IronPin-0.7.2-{abi}.apk','abi':abi,'bytes':apk.stat().st_size,'sha256':hashlib.sha256(apk.read_bytes()).hexdigest(),'package':'ir.ironpin.ironpin','versionName':'0.7.2','versionCode':code,'minSdk':21,'targetSdk':35,'certificateSha256':certificate,'signatureV1':True,'signatureV2':True,'registryMatchesSource':True,'nativeAbis':abis,'elfMachine':machine,'aotMarkers':markers,'removedManualSheetMarkerAbsent':True,'deviceInstallationTested':False})
(Path(__file__).parent/'apk-metadata.json').write_text(json.dumps(results,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(results,ensure_ascii=False,indent=2))
