"""Estimate a separate bidirectional collocation and grammar-class word ranker.

Use only established training corpus partitions; neither review nor final inputs
are accessed. `real25.source_rows` also excludes challenge-eligible public SMS.
Independent clean-sentence hash buckets provide counts, fitting, calibration,
and a new development comparison. No messages or substitution rules are stored.
"""
import argparse, math, struct
from collections import Counter
from pathlib import Path
import numpy as np
from scipy.optimize import minimize
from scipy.cluster.vq import kmeans2
from scipy.sparse import coo_matrix
from scipy.sparse.linalg import svds
from real25 import engine, source_rows, neighbors, sha
from paired_text import tokens,pairs,key
from difflib import SequenceMatcher

OUT=engine/'model/cloze27'

def signature(s):return sha('real25-development/'+s)[0]
def bucket(s):return sha('cloze27-fit/'+s)[0]
def code(a,b,c,d=0):return (a<<48)|(b<<32)|(c<<16)|d

def contexts(a,b,c,d,e,classes):
    ac,bc,cc,dc,ec=(classes[i] for i in (a,b,c,d,e))
    return (code(0,b,c),code(0,c,d),code(1,b,c,d),code(1,a,b,c),code(1,c,d,e),
            code(2,bc,c,dc),code(3,b,c,dc),code(4,bc,c,d),code(5,ac,bc,c),code(6,c,dc,ec))

def train(args):
    rng=np.random.default_rng(27117)
    rows=source_rows(args.taskmaster,args.paired,args.sms)
    real=[line.split('\t') for line in (engine/'model/real25/targets.tsv').read_text().splitlines()];ts=[row[0] for row in real];ti={w:i for i,w in enumerate(ts)}
    pool=[[int(j) for j in row[2].split(',')] for row in real]
    canon=[s for s,g in rows if signature(s)>=18 and bucket(s)>=31]
    freq=Counter(w for s in canon for w in s.split());words=['<unk>','<s>','</s>']+sorted({w for w,n in freq.items() if n>=3}|set(ts));ids={w:i for i,w in enumerate(words)};tids=[ids[w] for w in ts];V=len(words)
    assert V<65535
    # PPMI of immediate left/right collocates, projected to a low rank before
    # clustering. Labels therefore generalize from rare neighboring nouns and
    # verbs to words with similar grammatical distributions.
    obs=Counter();enc=[]
    for s in canon:
        v=[1]+[ids.get(w,0) for w in s.split()]+[2];enc.append(v)
        for i,w in enumerate(v[1:-1],1):
            if not w:continue
            obs[w,v[i-1]]+=1;obs[w,v[i+1]+V]+=1
    I,J,C=zip(*((i,j,n) for (i,j),n in obs.items() if n>=2));I=np.array(I);J=np.array(J);C=np.array(C,dtype=np.float64)
    ri=np.bincount(I,weights=C,minlength=V);cj=np.bincount(J,weights=C,minlength=2*V);ppmi=np.maximum(np.log(C*C.sum()/ri[I]/cj[J]),0)*np.sqrt(np.minimum(C,30)/30)
    mat=coo_matrix((ppmi,(I,J)),shape=(V,2*V)).tocsr();u,s,_=svds(mat,k=36,rng=rng);u*=np.sqrt(s);u/=np.maximum(np.linalg.norm(u,axis=1,keepdims=True),.0001)
    core=np.flatnonzero(ri>=10);cent,labels=kmeans2(u[core],42,iter=22,minit='++',rng=rng);classes=(np.argmax(u@cent.T,axis=1)+4).tolist();classes[:3]=[0,1,2]
    counts=Counter();targets=set(tids);target_id={w:i for i,w in enumerate(tids)}
    for v in enc:
        for i,c in enumerate(v[1:-1],1):
            if c not in targets:continue
            a,b,d,e=(v[i-2] if i>1 else 1,v[i-1],v[i+1],v[i+2] if i+2<len(v) else 2)
            ctx=contexts(a,b,c,d,e,classes);counts.update(set(ctx))
    counts={k:min(n,65535) for k,n in counts.items() if n>=2};print('count corpus',len(canon),'grammar classes',42,'retained ngrams',len(counts),flush=True)
    errors=Counter()
    for raw,gold in pairs(args.paired):
        s=key(gold)
        if sha(s)[0]<38 or signature(s)<18 or bucket(s)<31:continue
        x=tokens(raw);y=tokens(gold)
        for tag,i,j,k,l in SequenceMatcher(None,x,y,autojunk=False).get_opcodes():
            if tag!='replace' or j-i!=l-k:continue
            for aa,bb in zip(x[i:j],y[k:l]):
                if aa in ti and bb in ti and ti[bb] in pool[ti[aa]]:errors[ti[aa],ti[bb]]+=1
    lfreq=[math.log1p(freq[w]) for w in ts]
    def features(a,b,d,e,literal,idx):
        c=tids[idx];cs=[math.log1p(counts.get(z,0)) for z in contexts(a,b,c,d,e,classes)];lit=literal==idx;prior=math.log1p(errors[literal,idx]);n=len(ts[literal]);
        return [1.0*lit,lfreq[idx],prior,min(prior,1.),*cs,min(cs[:2]),max(cs[2:5]),min(cs[6:8]),min(cs[:2])*lit,lfreq[idx]*lit,int(lit and n<=3),int(lit and n>=5)]
    def examples(group,limit,all_positions=False):
        samples=[]
        for line,source in rows:
            sig=signature(line);buck=bucket(line)
            if not ((group=='fit' and sig>=18 and buck<31) or (group=='cal' and 9<=sig<18) or (group=='dev' and sig<9)):continue
            ws=line.split();v=[1,1]+[ids.get(w,0) for w in ws]+[2,2];pos=[i for i,w in enumerate(ws[:-1]) if w in ti]
            if not all_positions and len(pos)>2:pos=rng.choice(pos,2,replace=False)
            for i in pos:
                g=ti[ws[i]];options=np.array(pool[g],dtype='i'); options=options[np.argsort(-np.array([lfreq[j] for j in options]))]
                # Include swaps among high-frequency words where edit proximity
                # offers little help, as well as the full error neighborhood.
                n=len(options);noisy=int(options[rng.integers(min(4,n) if rng.random()<.72 else n)]);context=(v[i],v[i+1],v[i+3],v[i+4] if rng.random()<.40 else 2)
                samples.append((context,g,noisy,source,line,i))
        if len(samples)>limit:samples=[samples[k] for k in rng.choice(len(samples),limit,replace=False)]
        return samples
    def table(samples,fit):
        sizes=[];chunks=[];gold=[];meta=[]
        for ctx,g,noise,source,line,i in samples:
            for lit in [g,noise]:
                opts=[lit]+pool[lit];m=np.asarray([features(*ctx,lit,j) for j in opts],dtype=np.float32);sizes.append(len(opts));chunks.append(m);gold.append(opts.index(g));meta.append((lit,g,source,opts,line,i,ctx[3]!=2))
        return np.concatenate(chunks),np.asarray(sizes),np.asarray(gold),meta
    fit=examples('fit',16000);x,n,y,_=table(fit,True);starts=np.cumsum(np.r_[0,n[:-1]]);target=x[starts+y].sum(axis=0,dtype=np.float64)
    def objective(w):
        score=x@w.astype(np.float32);peak=np.maximum.reduceat(score,starts);p=np.exp(score-np.repeat(peak,n));total=np.add.reduceat(p,starts);p/=np.repeat(total,n);reg=.00075
        return ((np.log(total)+peak).sum(dtype=np.float64)-target@w)/len(n)+reg*(w@w)/2, (x.T@p-target)/len(n)+reg*w
    w=minimize(objective,np.zeros(x.shape[1]),jac=True,method='L-BFGS-B',options={'maxiter':180}).x;del x
    print('fit patterns',len(fit),'parameters',len(w),flush=True)
    OUT.mkdir(parents=True,exist_ok=True);(OUT/'vocab.tsv').write_text(''.join(f'{word}\t{c}\n' for word,c in zip(words,classes)));(OUT/'targets.tsv').write_text(''.join(f'{word}\t{tids[i]}\t{lfreq[i]:.7f}\t'+','.join(str(j)+':'+str(errors[i,j]) for j in pool[i])+'\n' for i,word in enumerate(ts)));(OUT/'rank.txt').write_text(' '.join(f'{v:.8f}' for v in w)+'\n')
    # Delta-code the sorted keys. A block directory supports bounded binary
    # search without inflating the on-disk model at keyboard startup.
    ordered=sorted(counts.items()); directory=[]; packed=bytearray()
    def varint(x):
        while x>=128:
            packed.append((x&127)|128);x>>=7
        packed.append(x)
    for first in range(0,len(ordered),16):
        prev=ordered[first][0];directory.append((prev,len(packed)))
        for k,n in ordered[first:first+16]:
            varint(k-prev);varint(n);prev=k
    with (OUT/'counts.bin').open('wb') as f:
        f.write(struct.pack('<I',len(directory)))
        for k,offset in directory:f.write(struct.pack('<QI',k,offset))
        f.write(packed)
    def predictions(group):
        scores=[];samples=examples(group,9000)
        for chunk in range(0,len(samples),500):
            x,n,y,meta=table(samples[chunk:chunk+500],False);z=x@w.astype(np.float32);start=0
            for size,(lit,g,source,opts,line,i,two) in zip(n,meta):
                row=z[start:start+size];ix=np.argsort(-row);j=ix[0];k=ix[1];start+=size
                scores.append((lit==g,opts[j]==g,float(row[j]-row[0]),float(row[j]-row[k]),source,lit,opts[j],g,line,i,two))
        return scores
    def stats(rows,m,g):
        keep=sum(c and a>=m and b>=g for c,_,a,b,*_ in rows);right=sum(not c and ok and a>=m and b>=g for c,ok,a,b,*_ in rows);wrong=sum(not c and not ok and a>=m and b>=g for c,ok,a,b,*_ in rows);return right,keep,wrong
    cal=predictions('cal');dev=predictions('dev');n=len(cal)//2
    cfg=[(m,g) for m in np.arange(1.,9.,.5) for g in np.arange(.5,6.,.5)];good=[(result[0],m,g) for m,g in cfg if (result:=stats(cal,m,g))[1]<=n*.0004 and result[2]<=n*.0015];_,m,g=max(good or [(0,9.,6.)]);(OUT/'policy.txt').write_text(f'{m} {g}\n');print('selected',m,g,'cal',n,stats(cal,m,g),'dev',len(dev)//2,stats(dev,m,g),flush=True)
    for name in ['sms','cc0','paired','taskmaster']:
        subset=[v for v in dev if v[4]==name];print('dev',name,len(subset)//2,stats(subset,m,g),flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    for a in ('taskmaster','paired','sms'):p.add_argument(a,type=Path)
    train(p.parse_args())
