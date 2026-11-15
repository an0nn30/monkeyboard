"""Record the exact replay binary, production extension (including both models),
controller pipeline, simulator and corpus BEFORE loading any holdout predictions."""
import argparse, datetime, hashlib, json, plistlib
from pathlib import Path
D = Path(__file__).resolve().parent
ROOT = D.parents[1]
def sha(f):
    with open(f,'rb') as h:
        return hashlib.file_digest(h, 'sha256').hexdigest()
def ext(dir):
    return dir/'dd/Build/Products/Debug-iphonesimulator/MonkeyBoard.app/PlugIns/MonkeyBoardKeyboard.appex'
def manifest(base, cand, sim, freeze, output):
    if output.exists(): raise SystemExit('Use a new filename; never overwrite a candidate freeze.')
    historical=json.loads((D.parent/'build54/candidate-freeze.json').read_bytes())
    assert sha(base/'replay')==historical['replay_sha256']['54']
    assert sha(ext(base)/'MonkeyBoardKeyboard.debug.dylib')==historical['extension_sha256']['54']
    report={'utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'simulator':sim,
            'build':plistlib.loads((ext(cand)/'Info.plist').read_bytes())['CFBundleVersion'],
            'baseline':'54','holdout_manifest_sha256':sha(freeze),
            'replay_sha256':sha(cand/'replay'),'baseline_replay_sha256':sha(base/'replay'),
            'candidate_extension_files':{str(f.relative_to(ext(cand))):sha(f) for f in sorted(ext(cand).rglob('*')) if f.is_file()},
            'source_sha256':{}}
    files=list((ROOT/'Keyboard').glob('*.swift'))+list((ROOT/'Shared').glob('*.swift'))+[f for f in (ROOT/'Keyboard/Resources').rglob('*') if f.is_file() and not f.name.startswith('.')]+[
        ROOT/'MonkeyBoard.xcodeproj/project.pbxproj',D.parent/'build17/Adapter.swift',D.parent/'build17/run.sh',D/'metrics.py']
    report['source_sha256']={str(p.relative_to(ROOT)):sha(p) for p in sorted(files)}
    output.write_text(json.dumps(report,indent=2,sort_keys=True)+'\n')
if __name__=='__main__':
    p=argparse.ArgumentParser()
    for n in ['baseline','candidate','simulator','holdout_manifest','output']:p.add_argument(n,type=str if n=='simulator' else Path)
    a=p.parse_args();manifest(a.baseline,a.candidate,a.simulator,a.holdout_manifest,a.output)
