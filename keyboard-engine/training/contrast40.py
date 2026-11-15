"""Fit context contrasts for observed real-word errors; no blind fixture is an input.
Export regularized contextual log odds, not trigger sentences or replacement rules.
"""
import argparse, json, math, random, struct
from collections import Counter, defaultdict
from pathlib import Path
import numpy as np
from scipy.optimize import minimize
from scipy.sparse import csr_matrix
from real25 import source_rows, sha
from paired_text import engine, key, pairs, tokens
OUT=engine/'model/contrast40'
OFF=(-2,-1,1,2)
def features(ctx,classes):
    a,b,d,e=ctx; ac,bc,dc,ec=[classes.get(w,'?') for w in ctx]
    vals=(a,b,d,e,ac,bc,dc,ec,a+'/'+b,b+'/'+d,d+'/'+e,
          bc+'/'+dc,b+'/'+dc,bc+'/'+d,ac+'/'+bc,dc+'/'+ec)
    return [str(i)+':'+v for i,v in enumerate(vals) if '?' not in v]
def context(ws,i,n):
    return tuple(ws[i+j] if 0<=i+j<len(ws) and j<=n else ('^' if i+j<0 else '?') for j in OFF)
def train(paired,taskmaster,sms,misses, *, extra_edges=(), extra_contexts=(), output=OUT):
    rows=source_rows(taskmaster,paired,sms)
    classes=dict(s.split('\t') for s in (engine/'model/cloze27/vocab.tsv').read_text().splitlines())
    lex={s.split('\t')[0] for s in (engine/'model/words.tsv').read_text().splitlines()}
    obs=Counter()
    for raw,clean in pairs(paired):
        if sha(key(clean))[0]<38:continue
        a,b=tokens(raw),tokens(clean)
        if len(a)!=len(b):continue
        for x,y in zip(a,b):
            if x!=y and x in lex and y in lex and x.isalpha() and y.isalpha() and 2<=min(len(x),len(y)) and max(len(x),len(y))<=7:
                obs[x,y]+=1
    difficult=json.loads(misses.read_text())
    assert len(difficult)==28
    edges={(x,y) for (x,y),n in obs.items() if n>=20}
    special=defaultdict(list)
    for r in difficult:
        x,y=r['observed'].lower(),r['target'].lower()
        words=tokens(r['expected']);i=r['target_index']
        assert words[i]==y
        edges.add((x,y));special[y].append((words,i))
    edges.update(extra_edges)
    for w,ws,i in extra_contexts:special[w].append((ws,i))
    words=set(w for pair in edges for w in pair); tr=defaultdict(list);cal=defaultdict(list)
    # Normalize and dedup in source_rows. Subsample common types for balance;
    # the margin is calibrated on separate sentences with their natural contexts.
    random.Random(41029).shuffle(rows)
    for s,source in rows:
        ws=s.split();dest=cal if sha('contrast40/cal/'+s)[0]<40 else tr
        for i,w in enumerate(ws[:-1]):
            if w in words and len(dest[w]) < (5000 if dest is tr else 3500):
                dest[w].append((ws,i))
    practice=(engine/'training/context40-practice.txt').read_text().splitlines()
    for line in practice:
        ws=tokens(line)
        for i,w in enumerate(ws[:-1]):
            if w in words:special[w].append((ws,i))
    for w,samples in special.items():
        tr[w].extend(samples)
    cache={}
    for w in sorted(words):
        for group,bank in [('train',tr),('cal',cal)]:
            entries=bank[w]
            seq=[(features(context(ws,i,n),classes),weight)
                 for ws,i in entries for n in [1,2]
                 for weight in [6.0 if group=='train' and (ws,i) in special.get(w,[]) else 1.0]]
            cache[group,w]=seq
    out=[];meta=[];output.mkdir(exist_ok=True)
    for x,y in sorted(edges):
        if min(len(tr[x]),len(tr[y]))<8:continue
        nx,ny=len(tr[x]),len(tr[y])
        a,b=cache['train',x],cache['train',y];count=Counter(f for feats,_ in a+b for f in feats)
        index={f:i for i,f in enumerate(sorted(f for f,n in count.items() if n>=2))}
        if not index:continue
        def matrix(seq):
            flat=[index[f] for feats,_ in seq for f in feats if f in index]
            indptr=np.cumsum([0]+[sum(f in index for f in feats) for feats,_ in seq],dtype=np.int32)
            return csr_matrix((np.ones(len(flat)),flat,indptr),shape=(len(seq),len(index)))
        X=matrix(a+b); yy=np.r_[np.zeros(len(a)),np.ones(len(b))]
        # A balanced prior prevents suggestions based solely on unequal frequencies.
        sw=np.r_[np.full(len(a),min(len(a),len(b))/len(a)),np.full(len(b),min(len(a),len(b))/len(b))]
        importance=np.array([v for _,v in a+b]);sw[importance>1]=importance[importance>1]
        def loss(w):
            z=X@w; p=1/(1+np.exp(-np.clip(z,-45,45)))
            return np.logaddexp(0,z).dot(sw)-(sw*yy).dot(z)+1.4*w.dot(w)/2, X.T@(sw*(p-yy))+1.4*w
        w=minimize(loss,np.zeros(len(index)),jac=True,method='L-BFGS-B',options={'maxiter':70}).x
        # Quantize before calibration. Correctly typed words are the negative class.
        w=np.round(w,2);w[abs(w)<.08]=0
        neg=matrix(cache['cal',x])@w
        pos=matrix(cache['cal',y])@w
        # Calibrate against the strongest of the single-/two-following-word
        # views available while typing, not just the final context.
        neg=neg.reshape(-1,2).max(axis=1);pos=pos.reshape(-1,2).max(axis=1)
        threshold=max(3.0, float(np.quantile(neg,.9998,method='higher'))+.18 if len(neg) else 4.5)
        threshold=math.ceil(threshold*100)/100
        if len(pos)<4 or sum(pos>=threshold)<2:continue
        out.append((x,y,threshold,{f:int(round(w[i]*100)) for f,i in index.items() if w[i]}))
        meta.append(dict(literal=x,alternative=y,training=[nx,ny],calibration=[len(neg),len(pos)],threshold=threshold,
                         false_edits=int(sum(neg>=threshold)),caught=int(sum(pos>=threshold))))
    # Share the feature dictionary across classifiers. Sorted six-byte entries
    # are searched in-place in the static library, never expanded into a weight map.
    keys=sorted({k for *_,wt in out for k in wt});ids={k:i for i,k in enumerate(keys)}
    (output/'features.txt').write_text(''.join(k+'\n' for k in keys))
    buf=bytearray(); headers=[]
    for x,y,margin,wt in out:
        headers.append(f'{x}\t{y}\t{margin:.2f}\t{len(buf)//6}\t{len(wt)}\n')
        for k in sorted(wt):buf.extend(struct.pack('<Ih',ids[k],wt[k]))
    (output/'weights.bin').write_bytes(buf)
    (output/'models.tsv').write_text(''.join(headers))
    (output/'fit.json').write_text(json.dumps({'source_messages':len(rows),'annotated_misses':len(difficult),
        'observed_directions':len(edges),'models':meta},indent=2)+'\n')
    print('fit',len(meta),'calibrated contrasts from',len(rows),'messages;',len(buf)//6,'weights',flush=True)
if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    for k in ('paired','taskmaster','sms','misses'):ap.add_argument(k,type=Path)
    train(**vars(ap.parse_args()))
