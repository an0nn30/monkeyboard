"""Score frozen simulator outputs; optional --gate returns a failing exit status on a release hold.
Rates are separate: recovering the labeled error, exactness once we edit a sentence,
and exact preservation on clean controls. Abstentions cannot inflate the first two.
"""
import argparse, csv, importlib.util, json
from pathlib import Path
from collections import Counter
H=Path(__file__).resolve().parent
def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
score=load('metrics',H.parent/'build20/score.py')
# Simulator quality gates. Passing a finite synthetic audit does not authorize a device release.
TARGETS={'recovery':0.99,'clean_preservation':0.999,'correct_when_changed':0.995}
def evaluate(cases,path):
    rows=list(csv.DictReader(cases.open(),delimiter='\t'));out=score.words.load(path)
    assert len(rows)==len(out) and set(out)=={r['id'] for r in rows}
    s=Counter()
    for r in rows:
        o=out[r['id']];m=score.measure(r,o);noisy=r['expected']!=r['typed'];assert noisy==bool(r['slot'] or r['gap'])
        s.update(m);s['errors']+=noisy;s['clean']+=not noisy;s['clean_exact']+=not noisy and o==r['typed']
        s['modified']+=o!=r['typed'];s['modified_exact']+=o!=r['typed'] and o==r['expected']
    rates={k:s[n]/s[d] for k,n,d in [('recovery','recovered','errors'),('clean_preservation','clean_exact','clean'),('correct_when_changed','modified_exact','modified')]}
    return {'counts':dict(s),'rates':rates,'failed':[k for k,v in rates.items() if v<TARGETS[k]]}
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--gate',action='store_true');p.add_argument('--misses',type=Path);a=p.parse_args()
    result={name:evaluate(H/'audit-blind.tsv',H/f'audit{name}.jsonl') for name in ['20','21']}
    if a.misses:
        baseline,outputs=[score.words.load(H/f'audit{i}.jsonl') for i in (20,21)]
        with a.misses.open('w') as f:
            writer=csv.writer(f,delimiter='\t',lineterminator='\n')
            writer.writerow(['id','kind','typed','expected','build20','build21','target_missed','intended_words_changed','false_splits'])
            for r in csv.DictReader((H/'audit-blind.tsv').open(),delimiter='\t'):
                o=outputs[r['id']]
                if o==r['expected']:continue
                m=score.measure(r,o)
                writer.writerow([r['id'],r['kind'],r['typed'],r['expected'],baseline[r['id']],o,
                                 int(r['typed']!=r['expected'] and not m['recovered']),m['changed_intended'],m['false_splits']])
    new=result['21'];s=new['counts'];base=result['20']['counts']
    hold=bool(new['failed'] or s['changed_intended']>base['changed_intended'] or s['false_splits']>base['false_splits'])
    print(json.dumps({'status':'HOLD' if hold else 'passes this audit','targets':TARGETS,'builds':result},indent=2))
    return int(hold and a.gate)
if __name__=='__main__':raise SystemExit(main())
