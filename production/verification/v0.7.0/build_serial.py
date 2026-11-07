"""Build each ABI separately on a 2 GiB host, with an in-process RAM guard.
No credentials or machine-specific keys are copied into the source package.
SDK/tool locations must already be supplied through the environment.
"""
from pathlib import Path
import json, os, signal, subprocess, time, shutil

root = Path(__file__).resolve().parents[3]
logs = Path(__file__).parent
cache = Path(os.environ.get('IRONPIN_APK_CACHE', '/home/user/.cache/apks-v070'))
cache.mkdir(parents=True, exist_ok=True)
results = []

def available():
    for line in Path('/proc/meminfo').read_text().splitlines():
        if line.startswith('MemAvailable:'):
            return int(line.split()[1]) * 1024
    return 1024**3

def abort(process):
    try: os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError: pass
    # Flutter/native compiler children can outlive a terminated Gradle process.
    # Limit cleanup to this build's private SDK paths, never notebook/server jobs.
    for directory in Path('/proc').iterdir():
        if not directory.name.isdigit(): continue
        try:
            command = (directory/'cmdline').read_bytes().replace(b'\0', b' ')
            if b'/home/user/.cache/java/' in command or b'/home/user/.cache/flutter/bin/cache/' in command:
                os.kill(int(directory.name), signal.SIGKILL)
        except (OSError, PermissionError): pass

def run_guarded(command, logfile):
    started = time.monotonic()
    minimum = available()
    with (logs/logfile).open('w') as log:
        process = subprocess.Popen(command, cwd=root, stdout=log,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        while process.poll() is None:
            free = available()
            minimum = min(minimum, free)
            if free < 150*1024*1024:
                log.write('\nMEMORY_GUARD: aborted before sandbox exhaustion.\n'); log.flush()
                abort(process)
                raise SystemExit(f'Memory guard stopped {logfile}; no success claimed.')
            if time.monotonic() - started > 900:
                abort(process)
                raise SystemExit(f'Time limit stopped {logfile}; no success claimed.')
            time.sleep(.4)
    if process.returncode != 0:
        print((logs/logfile).read_text()[-5000:], flush=True)
        raise SystemExit(process.returncode)
    return {'elapsedSeconds': round(time.monotonic()-started, 2),
            'minimumAvailableMiB': round(minimum/1024**2, 1), 'exitCode': process.returncode}

for target, abi in [('android-arm', 'armeabi-v7a'), ('android-arm64', 'arm64-v8a')]:
    # Compile AOT without the Gradle JVM competing for the same 2 GiB RAM.
    # Defines mirror Flutter 3.24.5's BaseFlutterTask.buildBundle command.
    precompile = run_guarded(['flutter', '--quiet', 'assemble', '--no-version-check',
        '--depfile', 'build/app/intermediates/flutter/release/flutter_build.d',
        '--output', 'build/app/intermediates/flutter/release',
        '-dTargetFile=lib/main.dart', '-dTargetPlatform=android', '-dBuildMode=release',
        '-dTrackWidgetCreation=true', '-dTreeShakeIcons=true', '-dFlavor=',
        f'-dAndroidArchs={target}', '-dMinSdkVersion=21',
        f'android_aot_bundle_release_{target}'], f'aot-{abi}.log')
    build = run_guarded(['flutter', 'build', 'apk', '--release', '--split-per-abi',
                        '--target-platform', target], f'build-{abi}.log')
    source = root/'build/app/outputs/flutter-apk'/f'app-{abi}-release.apk'
    shutil.copyfile(source, cache/source.name)
    record = {'abi': abi, 'aot': precompile, **build}
    results.append(record)
    print(json.dumps(record), flush=True)
# Preserve both APKs even if Gradle's second target removes the first output.
for source in cache.glob('app-*-release.apk'):
    shutil.copyfile(source, root/'build/app/outputs/flutter-apk'/source.name)
(logs/'build-summary.json').write_text(json.dumps(results, indent=2)+'\n')
