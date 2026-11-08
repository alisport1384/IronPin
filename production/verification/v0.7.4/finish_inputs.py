"""Record the post-build input verification for 0.7.4 (run after the audit)."""
from pathlib import Path
import hashlib, json, subprocess
root = Path(__file__).resolve().parents[3]
logs = Path(__file__).parent
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
paths = subprocess.check_output(
    ['git','ls-files','lib','assets','android','pubspec.yaml','pubspec.lock'],
    cwd=root, text=True).splitlines()
before = json.loads((logs/'runtime-inputs.sha256.json').read_text())
same = before == {p: sha(root/p) for p in paths}
lock = subprocess.check_output(['git','diff','--','pubspec.lock'], cwd=root, text=True) == ''
(logs/'input-verification.json').write_text(json.dumps({
    'runtimeInputsBeforeAfterBuildEqual': same,
    'files': len(paths),
    'dependencyLockUnchanged': lock,
    'schema': 4,
    'deviceInstallationTested': False}, indent=2) + '\n')
print('inputs equal:', same, 'files:', len(paths), 'lock unchanged:', lock)
