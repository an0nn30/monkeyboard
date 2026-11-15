"""Fit a candidate accept/reject gate on historical 54; evaluate unchanged on historical 53.
Not a shipping measurement. Counts describe only disputed word choices proposed by RoBERTa."""
import argparse,gzip,json,re,sys
from pathlib import Path
import numpy as np
from sklearn.linear_model import LogisticRegression
from sklearn.preprocessing import StandardScaler
from sklearn.pipeline import make_pipeline
ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'Benchmarks/build22/blind'))
from score import scan,observe,alignment,WORD
def rows(number,path):
    ds=json.load(open(ROOT/f'Benchmarks/build{number}/holdout/cases.json'))
    b=ROOT/{53:'Benchmarks/build54/previous-54.jsonl.gz',54:'Benchmarks/build54/holdout-54.jsonl.gz',55:'Benchmarks/build55/primary/baseline.jsonl.gz'}[number]
    legacy={r['id']:r['final'] for r in map(json.loads,gzip.open(b,'rt'))}
    ref={r['id']:r['expected'] for r in ds};data=[]
    for id,i,old,n,opts in json.load(open(path)):
        display=legacy[id]
        spans=list(re.finditer(r"[A-Za-z]+(?:['’][A-Za-z]+)*|[0-9]+|[^\s]",display))
        if i>=len(spans) or spans[i][0].lower()!=old.lower(): continue
        wordPositions=list(WORD.finditer(display))
        w=next((k for k,x in enumerate(wordPositions) if x.start()==spans[i].start()),None)
        if w is None: continue
        obs=scan(display);target=scan(ref[id]);links,_=alignment(obs.words,target.words)
        if links[w] is None: continue
        gold=target.words[links[w]].lower()
        _,rawScore,rawDisc=opts[0];candidates=[]
        for k,(s,v,z) in enumerate(opts[1:]):
            rival=max(a[1] for j,a in enumerate(opts) if j not in {k+1}) 
            delta=np.array(z)-np.array(rawDisc)
            features=[v-rawScore,v,max(-12,min(12,v-rival)),int(n>1),len(old),abs(len(s)-len(old)),*delta, max(z[1:])-max(rawDisc[1:]), max(z[3:])-max(rawDisc[3:])]
            candidates.append((features,s))
        if candidates:data.append((old.lower(),gold,candidates))
    return data
def fit(train,features):
    X=[o[:features] for old,gold,opts in train for o,s in opts]; y=[s==gold for old,gold,opts in train for o,s in opts]
    return make_pipeline(StandardScaler(),LogisticRegression(C=.5,max_iter=1200)).fit(X,y)
def results(model,rows,num,threshold):
    matrix=[o[:num] for _,_,opts in rows for o,s in opts]
    ps=iter(model.predict_proba(matrix)[:,1])
    recovered=damaged=other=total=0
    for old,gold,opts in rows:
        ranked=[(next(ps),s) for _,s in opts]; p,s=max(ranked);total+=old!=gold
        if p>=threshold:
            recovered+=(old!=gold and s==gold);damaged+=(old==gold and s!=gold);other+=s!=gold and old!=gold
    return dict(recovered=recovered,damaged=damaged,other=other,original_wrongs=total)
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('dir',type=Path);a=p.parse_args()
    cohorts={i:rows(i,a.dir/f'{i}.json') for i in [53,54,55]}
    for held in cohorts:
        tr=sum((r for i,r in cohorts.items() if i!=held),[]);va=cohorts[held]
        for dim in [6,14]:
            m=fit(tr,dim); thresholds=np.arange(.15,.95,.025)
            # Charge three wrong edits to originally correct words for every recovered error.
            obj=[(r['recovered']-3*r['damaged']-.5*r['other'],-t) for t in thresholds if (r:=results(m,tr,dim,t))]
            t=-max(obj)[1];print(json.dumps({'held':held,'dim':dim,'threshold':t,**results(m,va,dim,t)}))
