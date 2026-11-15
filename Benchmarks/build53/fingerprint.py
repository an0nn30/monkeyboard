"""Record the selected inputs and binaries before scoring the held-out data."""
from pathlib import Path
import argparse,datetime,hashlib,json
D=Path(__file__).resolve().parent; ROOT=D.parents[1]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def record(binary,ext,baseline,baseline_ext,sim):
    freeze=json.loads((D/'holdout/freeze.json').read_bytes())
    assert sha(D/'holdout/cases.json')==freeze['fixture_sha256']
    old=json.loads((D.parent/'build52/candidate-freeze.json').read_bytes())
    assert sha(baseline)==old['compiled_replay_sha256']['52']
    assert sha(baseline_ext/'MonkeyBoardKeyboard.debug.dylib')==old['extension_sha256']['52']
    # Include legacy resources, not just the new models, and the exact controller replay seam.
    inputs=set()
    for p in (ROOT/'Keyboard',ROOT/'Shared',ROOT/'keyboard-engine/src',ROOT/'keyboard-engine/model',ROOT/'keyboard-engine/include'):
        inputs.update(f for f in p.rglob('*') if f.is_file() and not f.name.startswith('.') and f.suffix != '.md')
    inputs.update([ROOT/'MonkeyBoard.xcodeproj/project.pbxproj',D.parent/'build17/Adapter.swift',D.parent/'build17/run.sh',D/'holdout/cases.json',D/'development.json',D/'desktop-check.json'])
    return dict(time_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),device=sim,build=53,baseline=52,physical_deployment=False,
      replay_sha256={'52':sha(baseline),'53':sha(binary)},extension_sha256={'52':sha(baseline_ext/'MonkeyBoardKeyboard.debug.dylib'),'53':sha(ext/'MonkeyBoardKeyboard.debug.dylib')},holdout_sha256=freeze['fixture_sha256'],
      sources={str(p.relative_to(ROOT)):sha(p) for p in sorted(inputs)})
if __name__=='__main__':
    p=argparse.ArgumentParser()
    for k in ('binary','ext','baseline','baseline_ext'):p.add_argument(k,type=Path)
    p.add_argument('sim')
    out=D/'candidate-freeze.json'
    if out.exists():raise SystemExit('The selected candidate is already frozen.')
    out.write_text(json.dumps(record(**vars(p.parse_args())),indent=2,sort_keys=True)+'\n')
