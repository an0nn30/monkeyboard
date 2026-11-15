"""Pair-counting and per-row regression check on frozen build 10 outputs."""
import csv, sys
from collections import Counter
from pathlib import Path
root=Path(__file__).resolve().parent
def read(p):
    with p.open() as f:return list(csv.DictReader(f,delimiter='\t'))
def outcome(r):
    w=r['candidate']
    if r['kind']=='keep':return 'keep' if w==r['expected'] else 'wrong'
    if w==r['expected']:return 'fix'
    return 'abstain' if w==r['context'].split()[-1] else 'wrong'
candidate=Path(sys.argv[1]) if len(sys.argv)>1 else root
totals=[Counter(),Counter()]
for suite in ['pairs','texts','replay']:
    rows=[read(p/f'build{v}-{suite}.tsv') for p,v in [(root,10),(candidate,11)]]
    assert [[(r['kind'],r['context'],r['expected']) for r in ds] for ds in rows][0]==[(r['kind'],r['context'],r['expected']) for r in rows[1]]
    counts=[Counter(map(outcome,ds)) for ds in rows]
    for total,n in zip(totals,counts):total.update(n)
    print(suite,counts)
    introduced=[r['context'] for l,r in zip(*rows) if outcome(r)=='wrong' and (outcome(l)!='wrong' or l['candidate']!=r['candidate'])]
    lost=[r['context'] for l,r in zip(*rows) if outcome(l) in ('fix','keep') and l['candidate']!=r['candidate']]
    assert not introduced and not lost,(suite,introduced,lost)
    if suite=='pairs':
        for i in range(0,len(rows[0]),2):
            a,b=[r['context'].split()[-5:] for r in rows[0][i:i+2]]
            assert a==b,(a,b)
        print('both sides correct', [sum(all(outcome(r)=='fix' for r in ds[i:i+2]) for i in range(0,len(ds),2)) for ds in rows])
print('Totals',totals)
assert totals[1]['fix']>totals[0]['fix']
