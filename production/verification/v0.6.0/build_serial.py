"""Build each ABI separately on a 2 GiB host, with an in-process RAM guard.
No credentials or machine-specific keys are copied into the source package.
SDK/tool locations must already be supplied through the environment.
"""
from pathlib import Path
import json, os, signal, subprocess, time, shutil

root = Path(__file__).resolve().parents[3]
logs = Path(__file__).parent
cache = Path(os.environ.get('IRONPIN_APK_CACHE', '/home/user/.cache/apks-v060'))
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

for target, abi in [('android-arm', 'armeabi-v7a'), ('android-arm64', 'arm64-v8a')]:
    started = time.monotonic()
    minimum = available()
    with (logs/f'build-{abi}.log').open('w') as log:
        process = subprocess.Popen(['flutter', 'build', 'apk', '--release', '--split-per-abi',
                                    '--target-platform', target], cwd=root, stdout=log,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        while process.poll() is None:
            free = available()
            minimum = min(minimum, free)
            if free < 150*1024*1024:
                log.write('\nMEMORY_GUARD: aborted before sandbox exhaustion.\n'); log.flush()
                abort(process)
                raise SystemExit(f'Memory guard stopped {abi}; no success claimed.')
            if time.monotonic() - started > 900:
                abort(process)
                raise SystemExit(f'Time limit stopped {abi}; no success claimed.')
            time.sleep(.4)
    if process.returncode != 0:
        print((logs/f'build-{abi}.log').read_text()[-5000:], flush=True)
        raise SystemExit(process.returncode)
    source = root/'build/app/outputs/flutter-apk'/f'app-{abi}-release.apk'
    shutil.copyfile(source, cache/source.name)
    record = {'abi': abi, 'elapsedSeconds': round(time.monotonic()-started, 2),
              'minimumAvailableMiB': round(minimum/1024**2, 1), 'exitCode': process.returncode}
    results.append(record)
    print(json.dumps(record), flush=True)
# Preserve both APKs even if Gradle's second target removes the first output.
for source in cache.glob('app-*-release.apk'):
    shutil.copyfile(source, root/'build/app/outputs/flutter-apk'/source.name)
(logs/'build-summary.json').write_text(json.dumps(results, indent=2)+'\n')
