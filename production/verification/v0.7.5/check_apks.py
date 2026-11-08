"""Verify the built APKs without installing them. Requires Android build-tools/JDK17."""
from pathlib import Path
import hashlib, json, os, re, struct, subprocess, zipfile

root = Path(__file__).resolve().parents[3]
sdk = Path(os.environ.get('ANDROID_SDK_ROOT', os.environ.get('ANDROID_HOME', '/home/user/sdk/android-sdk')))
tools = sdk / 'build-tools' / '35.0.0'
VERSION = '0.7.5'
# The stable sideload certificate created by tool/sign_env.sh: the whole point of
# the key is that it does not change between releases, so a new APK installs over
# the old one and the local archive survives.
expected_cert = 'd944e55c86cbdddccc3556479f69cd92179629b9749f34906a13c0d7d576a88b'
results = []
for abi, code, machine in [('armeabi-v7a', 1014, 40), ('arm64-v8a', 2014, 183)]:
    apk = root / 'build/app/outputs/flutter-apk' / f'app-{abi}-release.apk'
    badging = subprocess.check_output([str(tools / 'aapt'), 'dump', 'badging', str(apk)], text=True)
    permissions = subprocess.check_output([str(tools / 'aapt'), 'dump', 'permissions', str(apk)], text=True)
    signature = subprocess.check_output(
        [str(tools / 'apksigner'), 'verify', '--verbose', '--print-certs', str(apk)], text=True)
    (Path(__file__).parent / f'{abi}-aapt.txt').write_text(badging + '\n' + permissions)
    (Path(__file__).parent / f'{abi}-signature.txt').write_text(signature)
    assert "name='ir.ironpin.ironpin'" in badging
    assert f"versionName='{VERSION}'" in badging and f"versionCode='{code}'" in badging
    assert 'android.permission.MANAGE_EXTERNAL_STORAGE' not in permissions
    assert 'android.permission.WRITE_EXTERNAL_STORAGE' not in permissions
    assert 'android.permission.READ_EXTERNAL_STORAGE' not in permissions
    assert "sdkVersion:'21'" in badging and "targetSdkVersion:'35'" in badging
    assert 'Verified using v1 scheme (JAR signing): true' in signature
    assert 'Verified using v2 scheme (APK Signature Scheme v2): true' in signature
    certificate = re.search(r'Signer #1 certificate SHA-256 digest: (\w+)', signature)[1]
    assert certificate == expected_cert, certificate
    with zipfile.ZipFile(apk) as z:
        abis = sorted({n.split('/')[1] for n in z.namelist() if n.startswith('lib/')})
        assert abis == [abi], abis
        assert z.read('assets/flutter_assets/assets/registry.json') == \
            (root / 'assets/registry.json').read_bytes()
        app = z.read(f'lib/{abi}/libapp.so')
        assert app[:4] == b'\x7fELF' and struct.unpack('<H', app[18:20])[0] == machine
        # Markers of what this release is: the index the prices tab reads, the
        # stored labels the filters use and the honest count on the tab.
        markers = {s: any(s.encode(e) in app for e in ['utf-8', 'utf-16-le']) for s in [
            VERSION, 'source_date_raw', 'thickness_label', 'size_num', 'derive',
            'candidateCount', 'extend', 'candidateRows',
            'پیشنهاد بعدی', 'مورد آماده نمایش', 'کاندیدهای همان کالا',
            'رنج‌گیری ۴۸ ساعت', 'تأیید و نمایش رنج', 'جزئیات بیشتر',
            'مشخصات بیشتر', 'لغو محاسبه', 'فیلتر بازار',
            'importBackup', 'exportBackup', 'selectedCity', 'loggingEnabled',
            'rahsakht-wire', 'telegram-rahsakht', 'maham-beam12',
        ]}
        for s in markers:
            assert markers[s], s
        assert b'TextAnalysisSheet' not in app
        dex = b''.join(z.read(n) for n in z.namelist() if n.endswith('.dex'))
        for marker in [b'importBackup', b'exportBackup', b'application/x-ndjson', b'IronPin/backups']:
            assert marker in dex, marker
    results.append({
        'file': f'IronPin-{VERSION}-{abi}.apk', 'abi': abi,
        'bytes': apk.stat().st_size,
        'sha256': hashlib.sha256(apk.read_bytes()).hexdigest(),
        'package': 'ir.ironpin.ironpin', 'versionName': VERSION, 'versionCode': code,
        'minSdk': 21, 'targetSdk': 35, 'certificateSha256': certificate,
        'signatureV1': True, 'signatureV2': True, 'registryMatchesSource': True,
        'nativeAbis': abis, 'elfMachine': machine, 'aotMarkers': markers,
        'removedManualSheetMarkerAbsent': True, 'deviceInstallationTested': False,
    })
(Path(__file__).parent / 'apk-metadata.json').write_text(
    json.dumps(results, ensure_ascii=False, indent=2) + '\n')
print(json.dumps(results, ensure_ascii=False, indent=2))
