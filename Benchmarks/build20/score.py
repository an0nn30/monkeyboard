"""Score the labeled edit separately from collateral changes and exact final text."""
import argparse,csv,importlib.util
from collections import Counter,defaultdict
from pathlib import Path
here=Path(__file__).resolve().parent
def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path);mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod);return mod
words=module('wordscore',here.parent/'build17/score.py')
bounds=module('gapscore',here.parent/'build19/score.py')
def measure(r,out):
    m=bounds.measured(r,out);ref,before,_=words.align(r['expected'],r['typed']);_,after,_=words.align(r['expected'],out)
    if r['slot']:
        i=int(r['slot']); assert before[i]!=ref[i]
        m['recovered']=int(after[i]==ref[i])
    m['changed_intended']=sum(a==b and c!=a for a,b,c in zip(ref,before,after))
    return m
def score(cases, paths):
    rows=list(csv.DictReader(cases.open(),delimiter='\t'));ids={r['id'] for r in rows}
    assert len(ids)==len(rows)
    results=[]
    for p in paths:
        outputs=words.load(p);assert set(outputs)==ids;result={};group=defaultdict(Counter)
        for r in rows:
            m=measure(r,outputs[r['id']]);result[r['id']]=m;group[r['kind']].update(m);group['all'].update(m)
        for g,m in group.items():print(p.stem,g,*[m[k] for k in ('cases','recovered','exact','false_splits','changed_intended')],sep='\t')
        results.append(result)
    for label in ('exact','recovered','false_splits','changed_intended'):
        diff=[results[1][i][label]-results[0][i][label] for i in ids]
        print(label,'increases',sum(max(0,x) for x in diff),'decreases',-sum(min(0,x) for x in diff))
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('cases',type=Path);p.add_argument('outputs',type=Path,nargs=2)
    args=p.parse_args();print('build group cases recovered exact false_splits changed_intended');score(args.cases,args.outputs)
