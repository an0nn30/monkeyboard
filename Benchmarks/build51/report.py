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
    suites={'desktop':(corpus,'build44','desktop'),'fresh':(HERE/'fresh.json','build51','fresh'),
            'practice1':(BENCH/'build41/fresh.json','build44','fresh'),
            'practice2':(BENCH/'build45/fresh.json','build46','fresh'),
            'public':(HERE/'public.json','build51','public'),
            'practice3':(BENCH/'build47/fresh.json','build48','fresh'),
            'public1':(BENCH/'build46/public.json','build46','public'),
            'public2':(BENCH/'build48/public.json','build48','sms'),
            'practice4':(BENCH/'build49/fresh.json','build49','fresh'),
            'public3':(BENCH/'build49/public.json','build49','public'),
            'practice5':(BENCH/'build50/fresh.json','build50','fresh'),
            'public4':(BENCH/'build50/public.json','build50','public'),
            'regressions':(BENCH/'build41/regressions.json','build44','regressions')}
    for kind,(cases,old,prefix) in suites.items():
        paths={n:BENCH/old/f'{prefix}-{n}.jsonl.gz' for n in ('39','40')}
        paths['51']=HERE/f'{kind}-51.jsonl.gz'
        save(kind+'-comparison.json',compare.compare(cases,paths,'51'))
    # Use the complete corpus output (not a shorter isolated replay) to show
    # recovery of exactly the slot indices at which the two archives differed.
    fix = {r['id']: r['final'] for r in map(json.loads, gzip.open(HERE/'desktop-51.jsonl.gz','rt'))}
    counts = Counter()
    for row in map(json.loads,gzip.open(BENCH/'build40/desktop-changes.jsonl.gz','rt')):
        ref = compare.scan(row['expected'])
        typed, old, new, now = [compare.observe(ref,compare.scan(v)).slots for v in
                                (row['typed'],row['build39'],row['build40'],fix[row['id']])]
        for w,t,a,b,c in zip(ref.words,typed,old,new,now):
            if t==w:continue
            if a==w!=b:
                counts['archived_losses']+=1; counts['archived_losses_correct_now']+=c==w
            if a!=w==b:
                counts['archived_gains']+=1; counts['archived_gains_correct_now']+=c==w
    audit=json.loads((BENCH/'build44/archive-audit.json').read_bytes())
    audit['historical_slots']['51']=counts
    save('archive-audit.json',audit)
    # Pool the two final pre-specified suites by denominators without touching
    # the earlier development tests. IDs use separate namespaces.
    reports=[json.loads((HERE/(name+'-comparison.json')).read_bytes()) for name in ('fresh','public')]
    summary={}
    for n in ('39','40','51'):
        c=Counter()
        for report in reports:c.update(report['totals'][n]['all'])
        summary[n]=dict(c)
    paired={}
    for n in ('39','40'):
        c=Counter()
        for report in reports:c.update(report['paired_against_51'][n]['all'])
        paired[n]=dict(c)
    save('final-fresh-combined.json',dict(totals=summary,paired_against_51=paired))
if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('corpus',type=Path)
    make(ap.parse_args().corpus)
