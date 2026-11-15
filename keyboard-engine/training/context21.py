"""Learn compact lexical context counts and a word-boundary ranker.
Use fit sentences disjoint from the examples used to estimate feature counts.
No list of short-word substitution or split rules.
"""
import hashlib, json, math, random, struct, sys
from collections import Counter
from pathlib import Path
import numpy as np
from scipy.optimize import minimize
from scipy.special import expit
engine=Path(__file__).resolve().parents[1]
def train(work):
    rng=random.Random(21017);counts=Counter();sentences=(work/'train.txt').read_text().splitlines()
    fit=[]
    for s in sentences:
        if hashlib.sha256(s.encode()).digest()[1]<52:fit.append(s);continue
        words=['^']+s.split()+['$']
        for n in (1,2,3):
            for i in range(len(words)-n+1):
                term=tuple(words[i:i+n])
                if n<3 or any(len(w)<=3 for w in term):counts[term]+=1
    vocab=sorted(w for (w,),v in ((t,v) for t,v in counts.items() if len(t)==1) if v>=2)
    ids={w:i+1 for i,w in enumerate(vocab)}
    assert len(ids)<65536
    model=engine/'model/context21';model.mkdir(exist_ok=True)
    (model/'vocab.txt').write_text('\n'.join(vocab)+'\n')
    def retain(t,n):return all(x in ids for x in t) and n>=(3 if len(t)==3 else 2)
    def pack(t):
        code=0
        for w in t:code=(code<<16)|ids[w]
        return code
    obs={t:v for t,v in counts.items() if retain(t,v)}
    with (model/'counts.bin').open('wb') as f:
        for code,v in sorted((pack(t),v) for t,v in obs.items()):f.write(struct.pack('<QH',code,min(v,65535)))
    def feats(p,a,b):
        terms=[(a,),(b,),(a,b),(p,a)]
        va,vb,vab,vpa=[math.log1p(min(65535,obs.get(t,0))) for t in terms]
        return [1,va,vb,vab,vpa,min(va,vb),min(vab,vpa),min(len(a),8),min(len(b),8),int(len(a)==1),int(len(b)==1)]
    X=[];Y=[]
    def add(p,word,gold):
        for i in range(1,len(word)):
            a,b=word[:i],word[i:]
            if a not in ids or b not in ids:continue
            if (len(a)==1 and a not in ('a','i')) or (len(b)==1 and b not in ('a','i')):continue
            X.append(feats(p,a,b));Y.append(int(i==gold))
    for s in fit:
        ws=['^']+s.split()
        for i in range(1,len(ws)):
            prev,w=ws[i-1:i+1]
            if not w.isalpha():continue
            # Valid whole words and their accidental single-character corruptions.
            add(prev,w,None)
            if len(w)>2:
                j=rng.randrange(len(w));mut=[w[:j]+w[j+1:],w[:j]+w[j]+w[j:],w[:j]+rng.choice('abcdefghijklmnopqrstuvwxyz')+w[j+1:]]
                if j:mut.append(w[:j-1]+w[j]+w[j-1]+w[j+1:])
                for z in mut:add(prev,z,None)
            if i+1<len(ws) and ws[i+1].isalpha():add(prev,w+ws[i+1],len(w))
    x=np.asarray(X);y=np.asarray(Y)
    def objective(w):
        z=x@w;reg=.0001
        return (np.logaddexp(0,z)-y*z).mean()+reg*np.square(w[1:]).sum()/2, x.T@(expit(z)-y)/len(y)+reg*np.r_[0,w[1:]]
    fitmodel=minimize(objective,np.zeros(x.shape[1]),jac=True,method='L-BFGS-B',options={'maxiter':400,'ftol':1e-11});assert fitmodel.success,fitmodel.message
    (model/'boundary.txt').write_text(' '.join(f'{w:.8f}' for w in fitmodel.x)+'\n')
    print(json.dumps(dict(count_sentences=len(sentences)-len(fit),fit_sentences=len(fit),vocabulary=len(vocab),ngrams=len(obs),positive=int(y.sum()),negative=int(len(y)-y.sum()),loss=float(fitmodel.fun)),indent=2))
if __name__=='__main__':train(Path(sys.argv[1]))
