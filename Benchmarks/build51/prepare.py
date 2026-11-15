"""Freeze a second independent test; the first fresh round is now available for development."""
from pathlib import Path
import argparse,bz2,gzip,hashlib,json,re,sys,zipfile
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1];PREV=HERE.parent/'build40'
sys.path[:0]=[str(ROOT/'keyboard-engine/training'),str(HERE.parent/'build22/blind')]
from paired_text import key,pairs
from audit_sources import previous_cases
def dump(path,data):path.write_text(json.dumps(data,indent=2,ensure_ascii=False)+'\n')
def main(paired,conversations,sms):
    excluded={key(s) for row in pairs(paired) for s in row}|previous_cases()
    for path in [PREV/'fresh.json',PREV/'training-misses.json',*(HERE.parent/'build22/blind'/f'{s}.json' for s in ('final','review'))]:
        excluded.update(key(row[f]) for row in json.loads(path.read_bytes()) for f in ('typed','expected'))
    for p in [conversations,ROOT/'keyboard-engine/training/context40-practice.txt']:
        excluded.update(map(key,p.read_text().splitlines()))
    with bz2.open(ROOT/'keyboard-engine/training/eng_sentences_CC0.tsv.bz2','rt') as f:
        excluded.update(key(s.split('\t')[2]) for s in f)
    with zipfile.ZipFile(sms) as z:
        excluded.update(key(s.partition('\t')[2]) for s in z.read('SMSSpamCollection').decode().splitlines())
    for file in ('build41/fresh.json', 'build45/fresh.json', 'build46/public.json', 'build47/fresh.json', 'build48/public.json', 'build49/fresh.json', 'build49/public.json', 'build50/public.json', 'build50/fresh.json'):
        for r in json.loads((HERE.parent/file).read_bytes()):
            excluded.update(key(r[f]) for f in ('typed','expected'))
    rows=[];seen=set()
    for i,line in enumerate((HERE/'challenge.txt').read_text().splitlines(),1):
        kind,s=line.split('|',1); pat=r'\[([^\]|]+)\|([^\]|]+)\]'
        typed=re.sub(pat,r'\1',s); gold=re.sub(pat,r'\2',s)
        keys={key(typed),key(gold)}
        assert not keys & (excluded|seen),s
        seen.update(keys)
        rows.append(dict(id=f'f{i:03}',typed=typed,expected=gold,split='fresh',kind=kind))
        if typed!=gold:rows.append(dict(id=f'c{i:03}',typed=gold,expected=gold,split='fresh',kind='clean-counterpart'))
    dump(HERE/'fresh.json',rows)
    dump(HERE/'fixture-freeze.json',dict(rows=len(rows),unique_references=len({r['expected'] for r in rows}),excluded_keys=len(excluded),
        sha256=hashlib.sha256((HERE/'fresh.json').read_bytes()).hexdigest()))
if __name__=='__main__':
    p=argparse.ArgumentParser()
    for a in ('paired','conversations','sms'):p.add_argument(a,type=Path)
    main(**vars(p.parse_args()))
