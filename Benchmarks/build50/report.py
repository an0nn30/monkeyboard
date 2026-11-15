"""Score the selected production build against the two original simulator baselines."""
from pathlib import Path
import argparse, gzip, importlib.util, json
from collections import Counter
HERE=Path(__file__).resolve().parent
BENCH=HERE.parent
module=importlib.util.spec_from_file_location('compare_builds',BENCH/'build44/compare.py')
compare=importlib.util.module_from_spec(module)
module.loader.exec_module(compare)

def save(name,value):
    (HERE/name).write_text(json.dumps(value,indent=2,sort_keys=True)+'\n')

def make(corpus):
    suites={'desktop':(corpus,'build44','desktop'),'fresh':(HERE/'fresh.json','build50','fresh'),
            'practice1':(BENCH/'build41/fresh.json','build44','fresh'),
            'practice2':(BENCH/'build45/fresh.json','build46','fresh'),
            'public':(HERE/'public.json','build50','public'),
            'practice3':(BENCH/'build47/fresh.json','build48','fresh'),
            'public1':(BENCH/'build46/public.json','build46','public'),
            'public2':(BENCH/'build48/public.json','build48','sms'),
            'practice4':(BENCH/'build49/fresh.json','build49','fresh'),
            'public3':(BENCH/'build49/public.json','build49','public'),
            'regressions':(BENCH/'build41/regressions.json','build44','regressions')}
    for kind,(cases,old,prefix) in suites.items():
        paths={n:BENCH/old/f'{prefix}-{n}.jsonl.gz' for n in ('39','40')}
        paths['50']=HERE/f'{kind}-50.jsonl.gz'
        save(kind+'-comparison.json',compare.compare(cases,paths,'50'))
    fix={a['id']:a['final'] for a in map(json.loads,gzip.open(HERE/'desktop-50.jsonl.gz','rt'))}
    counts=Counter()
    for row in map(json.loads,gzip.open(BENCH/'build40/desktop-changes.jsonl.gz','rt')):
        ref=compare.scan(row['expected'])
        typed,a,b,c=[compare.observe(ref,compare.scan(v)).slots for v in (row['typed'],row['build39'],row['build40'],fix[row['id']])]
        for w,t,x,y,z in zip(ref.words,typed,a,b,c):
            if t==w:continue
            if x==w!=y:
                counts['archived_losses']+=1;counts['archived_losses_correct_now']+=z==w
            if x!=w==y:
                counts['archived_gains']+=1;counts['archived_gains_correct_now']+=z==w
    audit=json.loads((BENCH/'build44/archive-audit.json').read_bytes())
    audit['historical_slots']['50']=counts
    save('archive-audit.json',audit)
if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('corpus',type=Path)
    make(ap.parse_args().corpus)
