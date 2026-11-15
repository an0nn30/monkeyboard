"""Freeze new full messages; promote only the prior round's 28 real-word misses."""
import argparse, bz2, gzip, hashlib, json, re, sys, zipfile
from pathlib import Path
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(ROOT/'keyboard-engine/training'))
sys.path.insert(0, str(ROOT/'Benchmarks/build22/blind'))
from paired_text import key, pairs
from score import scan, observe
from audit_sources import previous_cases
def dump(name, obj):
    (HERE/name).write_text(json.dumps(obj, indent=2, ensure_ascii=False)+'\n')
def prepare(paired, conversations, sms):
    old=ROOT/'Benchmarks/build22/blind'
    outputs={r['id']:r['final'] for r in map(json.loads,gzip.open(ROOT/'Benchmarks/build39/final-39.jsonl.gz','rt'))}
    oldsets=[json.loads((old/(s+'.json')).read_bytes()) for s in ('review','final')]
    misses=[]
    for row in oldsets[1]:
        if row['kind'] not in ('real-word','public-real-word'):continue
        ref=scan(row['expected'])
        before=observe(ref,scan(row['typed'])); after=observe(ref,scan(outputs[row['id']]))
        for i,(w,t,o) in enumerate(zip(ref.words,before.slots,after.slots)):
            if t!=w and o!=w:
                misses.append({**row,'build39':outputs[row['id']],'target_index':i,'observed':t,'target':w})
    assert len(misses)==28
    dump('training-misses.json',misses)
    blocked={key(s) for pair in pairs(paired) for s in pair}|previous_cases()
    blocked.update(key(row[field]) for rows in oldsets for row in rows for field in ('typed','expected'))
    blocked.update(map(key,conversations.read_text().splitlines()))
    with bz2.open(ROOT/'keyboard-engine/training/eng_sentences_CC0.tsv.bz2','rt') as f:
        blocked.update(key(line.split('\t')[2]) for line in f)
    with zipfile.ZipFile(sms) as z:
        blocked.update(key(line.partition('\t')[2]) for line in z.read('SMSSpamCollection').decode().splitlines())
    rows=[]; used=set();pattern=re.compile(r'\[([^\]|]+)\|([^\]|]+)\]')
    for n,line in enumerate((HERE/'challenge.txt').read_text().splitlines(),1):
        changed=bool(pattern.search(line)); raw=pattern.sub(r'\1',line);gold=pattern.sub(r'\2',line)
        assert not ({key(raw),key(gold)} & (blocked|used)),line
        used.update((key(raw),key(gold)))
        def add(kind,s,id_suffix):
            rows.append(dict(id=f'new-{n:03d}-{id_suffix}',kind=kind,source='authored',split='fresh',
                             typed=s,expected=gold,pair=n))
        if changed:
            add('context-error',raw,'typo');add('clean-counterpart',gold,'clean')
        else:add('intentional-literal',gold,'literal')
    dump('fresh.json',rows)
    dump('fixture-freeze.json',{'fresh_sha256':hashlib.sha256((HERE/'fresh.json').read_bytes()).hexdigest(),
        'training_misses_sha256':hashlib.sha256((HERE/'training-misses.json').read_bytes()).hexdigest(),
        'normalized_strings_checked':len(blocked),'novel_reference_messages':len({r['expected'] for r in rows}),
        'counts':{k:sum(r['kind']==k for r in rows) for k in sorted({r['kind'] for r in rows})}})
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    for k in ('paired','conversations','sms'):p.add_argument(k,type=Path)
    prepare(**vars(p.parse_args()))
