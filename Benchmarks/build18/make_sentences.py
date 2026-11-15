"""Freeze new full messages from the previously reserved build-16 partition."""
import csv
import hashlib
import sys
from pathlib import Path

here = Path(__file__).resolve().parent
sys.path.insert(0, str(here.parents[1]/'keyboard-engine/training'))
from paired_text import key, pairs

def hashed(text):
    return hashlib.sha256(text.encode()).digest()

def rows(path):
    with path.open() as f:
        yield from csv.DictReader(f, delimiter='\t')

def collect(source):
    old = set()
    for v in (15,16):
        for r in rows(here.parent/f'build{v}/cases.tsv'):
            old.add(key(' '.join([r['left'],r['gold'].split('|')[0],r['right']])))
    for path in ['sentences.tsv','confirmation.tsv']:
        for r in rows(here.parent/'build17'/path):
            old.update([key(r['expected']),key(r['typed'])])
    examples = list(csv.reader((here/'examples.tsv').open(),delimiter='\t'))
    for _,src,ref in examples:
        old.update([key(src),key(ref)])
    pool = {}
    for src,ref in pairs(source):
        target = key(ref)
        if hashed(target)[0]>=38 or target in old or key(src) in old or src==ref or len(src)>120:continue
        choice = (hashed('mb18/input/'+src),src,ref)
        pool[target] = min(choice,pool.get(target,choice))
    ordered = sorted(pool,key=lambda t:hashed('mb18/target/'+t))
    assert len(ordered)>=3600
    for i,target in enumerate(ordered[:3600]):
        _,src,ref=pool[target]
        noisy=i<2400
        yield f'msg{i:04}', 'holdout','noisy' if noisy else 'clean',src if noisy else ref,ref
    for i,(kind,src,ref) in enumerate(examples):
        yield f'eg{i:03}','reported' if kind=='reported' else 'authored',kind,src,ref

if __name__=='__main__':
    with (here/'sentences.tsv').open('w') as f:
        w=csv.writer(f,delimiter='\t',lineterminator='\n')
        w.writerow(['id','split','kind','typed','expected'])
        w.writerows(collect(Path(sys.argv[1])))
