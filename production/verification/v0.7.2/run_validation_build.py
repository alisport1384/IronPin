"""Run final offline QA, then build/audit both ABIs with unchanged runtime inputs."""
from pathlib import Path
import subprocess,json,hashlib,sys
root=Path(__file__).resolve().parents[3]; logs=Path(__file__).parent
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def run(args,name):
    print('START',name,flush=True)
    with (logs/name).open('w') as f:
        p=subprocess.run(args,cwd=root,stdout=f,stderr=subprocess.STDOUT)
    print('END',name,'exit',p.returncode,flush=True)
    if p.returncode: print((logs/name).read_text()[-5000:],flush=True);sys.exit(p.returncode)
run(['flutter','analyze'],'analyze.log')
run(['flutter','test','--concurrency=1','--reporter','expanded'],'offline-final.log')
paths=subprocess.check_output(['git','ls-files','lib','assets','android','pubspec.yaml','pubspec.lock'],cwd=root,text=True).splitlines()
before={p:sha(root/p) for p in paths}
(logs/'runtime-inputs.sha256.json').write_text(json.dumps(before,indent=2)+'\n')
run([sys.executable,str(logs/'build_serial.py')],'build-console.log')
assert before=={p:sha(root/p) for p in paths},'Runtime inputs changed during build'
run([sys.executable,str(logs/'check_apks.py')],'apk-audit.log')
(logs/'input-verification.json').write_text(json.dumps({'runtimeInputsBeforeAfterBuildEqual':True,'files':len(paths),'dependencyLockUnchanged':subprocess.check_output(['git','diff','--','pubspec.lock'],cwd=root,text=True)=='','schema':3,'deviceInstallationTested':False},indent=2)+'\n')
print('VALIDATION_BUILD_COMPLETE',flush=True)
