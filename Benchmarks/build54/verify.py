"""Audit archived misses, new holdout pairing, annotations and frozen inputs."""
import hashlib,json,sys
from pathlib import Path
D=Path(__file__).resolve().parent
ROOT=D.parents[1]
sys.path.insert(0,str(D.parent/'build22/blind'))
from score import load_outputs,scan,observe
def read(f):return json.loads(f.read_bytes())
def audit():
    f=read(D/'candidate-freeze.json')
    for file,h in f['input_sha256'].items():assert hashlib.sha256((ROOT/file).read_bytes()).hexdigest()==h,file
    d=D.parent/'build53';dev={r['id']:r for r in read(d/'development.json')};wrong=read(d/'old-failures.json')
    o=load_outputs([D/'development-54.jsonl.gz'],set(dev))
    fixed=sum(observe(scan(dev[e['id']]['expected']),scan(o[e['id']])).slots[e['index']]==e['target'] for e in wrong['typos'])
    clean=sum(o[e['id']]==e['expected'] for e in wrong['clean'])
    prev=read(D/'previous-summary.json');fresh=read(D/'holdout-summary.json')
    rows=read(D/'holdout/cases.json');ids={r['id'] for r in rows}
    assert len(ids)==len(rows)==2*len({r['expected'] for r in rows})
    for n in ('52','54'):
        results=load_outputs([D/f'holdout-{n}.jsonl.gz'],ids)
        assert sum(results[r['id']]==r['expected'] for r in rows)==fresh['totals'][n]['all']['exact']
    assert fresh['protected_total']['intended_tokens']==sum(len(r['protected']) for r in rows)
    return dict(old_69_missed_word_positions_recovered=fixed,old_15_changed_clean_messages_restored=clean,
                retained_historical_six=read(D/'regressions-summary.json')['totals']['54']['kind/six']['exact'],
                fresh_messages=len(rows)//2,replay_rows=len(rows), protected=fresh['protected_by_kind'],
                previous_53_test_now_development=prev['protected_by_kind'],verified_files=len(f['input_sha256']))
if __name__=='__main__':print(json.dumps(audit(),indent=2))
