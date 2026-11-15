"""Independently recheck frozen files and old/new outcomes for this comparison."""
import gzip,json,hashlib,sys,tarfile
from pathlib import Path
D=Path(__file__).resolve().parent; ROOT=D.parents[1]
sys.path.insert(0,str(D.parent/'build22/blind'))
from score import load_outputs, observe, scan
def read(n):return json.loads((D/n).read_bytes())
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def audit():
    frozen=read('candidate-freeze.json')
    # The checkout can contain a newer candidate; use the frozen 53 source
    # snapshot for files superseded by that candidate.
    with tarfile.open(D/'frozen-sources.tar.gz') as snapshot:
        for k,v in frozen['sources'].items():
            if sha(ROOT/k)!=v:
                assert hashlib.sha256(snapshot.extractfile(k).read()).hexdigest()==v, k
    failed=read('old-failures.json')
    dev=read('development.json'); rows={r['id']:r for r in dev}
    outputs={n:load_outputs([D/f'development-{n}.jsonl.gz'],set(rows)) for n in ('52','53')}
    recovered=0
    for error in failed['typos']:
        i=error['index'];r=rows[error['id']];ref=scan(r['expected'])
        get=lambda s:observe(ref,scan(s)).slots[i]
        assert get(outputs['52'][r['id']])==error['actual']!=ref.words[i]
        recovered+=get(outputs['53'][r['id']])==ref.words[i]
    restored=0
    for r in failed['clean']:
        assert outputs['52'][r['id']]==r['actual']!=r['expected']
        restored+=outputs['53'][r['id']]==r['expected']
    assert len(failed['typos'])==69 and len(failed['clean'])==15
    fresh=read('holdout/cases.json'); ids={r['id'] for r in fresh}; refs={}
    for r in fresh: refs.setdefault(r['pair_id'],set()).add(r['typed']==r['expected'])
    assert len(refs)==149 and all(s=={True,False} for s in refs.values()) and len(ids)==298
    summary=read('holdout-summary.json')
    for n in ('52','53'):
        out=load_outputs([D/f'holdout-{n}.jsonl.gz'],ids)
        assert sum(out[r['id']]==r['expected'] for r in fresh)==summary['totals'][n]['all']['exact']
    assert summary['protected_by_kind']['name']['intended_tokens']==78 and summary['protected_by_kind']['slang']['intended_tokens']==118
    return dict(archived_missed_word_slots=69,recovered_from_those_69=recovered,archived_clean_messages_changed=15,restored_from_those_15=restored,holdout_rows=298,unique_messages=149,all_frozen_hashes_match=True)
if __name__=='__main__': print(json.dumps(audit(),indent=2))
