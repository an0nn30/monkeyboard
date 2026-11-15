"""Fingerprint the two simulator executables, source and this second blind cohort."""
from pathlib import Path
import sys,json,hashlib,datetime
D=Path(__file__).resolve().parent
ROOT=D.parents[1]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def save(baseline,baseline_ext,bin54,ext54,sim):
    old=json.loads((D.parent/'build52/candidate-freeze.json').read_bytes())
    assert sha(baseline)==old['compiled_replay_sha256']['52']
    assert sha(baseline_ext/'MonkeyBoardKeyboard.debug.dylib')==old['extension_sha256']['52']
    form=D/'holdout/cases.json';manifest=json.loads((D/'holdout/freeze.json').read_bytes())
    assert sha(form)==manifest['fixture_sha256']
    fs={form,D.parent/'build17/Adapter.swift',D.parent/'build17/run.sh', ROOT/'MonkeyBoard.xcodeproj/project.pbxproj'}
    for p in ('Shared','Keyboard','keyboard-engine/model','keyboard-engine/src','keyboard-engine/include'):
        fs.update(f for f in (ROOT/p).rglob('*') if f.is_file() and not f.name.startswith('.') and f.suffix!='.md')
    return dict(utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),simulator=sim,build=54,physical_deployment=False,
                baseline=52,holdout=sha(form),replay_sha256={'52':sha(baseline),'54':sha(bin54)},
                extension_sha256={'52':sha(baseline_ext/'MonkeyBoardKeyboard.debug.dylib'),'54':sha(ext54/'MonkeyBoardKeyboard.debug.dylib')},
                input_sha256={str(p.relative_to(ROOT)):sha(p) for p in sorted(fs)})
if __name__=='__main__':
    f=D/'candidate-freeze.json'
    if f.exists():raise SystemExit('Already frozen, will not overwrite.')
    f.write_text(json.dumps(save(*(Path(k) for k in sys.argv[1:5]),sys.argv[5]),indent=2,sort_keys=True)+'\n')
