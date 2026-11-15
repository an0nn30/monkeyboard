"""Withdraw unsupported new automatic directions after repeated literal regressions.
The data labels drive the decision. Never change the original build-40 directions.
"""
import gzip,json
from collections import defaultdict
from pathlib import Path
from paired_text import engine,key
import sys
base=engine.parent/'Benchmarks'
sys.path.insert(0,str(base/'build22/blind'))
from score import scan,observe
errors=defaultdict(set)
for fixture,old,new in [(base/'build46/public.json',base/'build46/public-40.jsonl.gz',base/'build46/public-46.jsonl.gz'),
                        (base/'build49/fresh.json',base/'build49/fresh-40.jsonl.gz',base/'build49/fresh-49.jsonl.gz')]:
    read=lambda p:{r['id']:r['final'] for r in map(json.loads,gzip.open(p,'rt'))}
    before,after=read(old),read(new)
    for row in json.loads(fixture.read_bytes()):
        ref=scan(row['expected']);a,b,c=[observe(ref,scan(x)).slots for x in (row['typed'],before[row['id']],after[row['id']])]
        for w,typed,prev,now in zip(ref.words,a,b,c):
            if w==typed==prev and now and w.lower()!=now.lower():
                errors[w.lower(),now.lower()].add(key(row['expected']))
prior={tuple(l.split('\t')[:2]) for l in (engine/'model/contrast40/models.tsv').read_text().splitlines()}
quarantine={pair for pair,messages in errors.items() if len(messages)>=2 and pair not in prior}
out=engine/'model/trust50';out.mkdir(exist_ok=True)
(out/'suggestion-only.tsv').write_text(''.join(a+'\t'+b+'\n' for a,b in sorted(quarantine)))
print('Held back',len(quarantine),'recurring newly harmful directions:',sorted(quarantine))
