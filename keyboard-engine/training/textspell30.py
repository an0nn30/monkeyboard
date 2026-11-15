"""Fit a contextual nonword noisy channel for conversational and SMS text.

No challenge inputs are read. The shared real25 loader excludes all eligible
SMS source messages and all reserved paired/CC0 keys. Token counts come from
separate normalized sentences from the ranking, calibration and development
splits. Synthetic keyboard errors include short words, and intentional,
unfamiliar clean tokens compete in the same pool as all dictionary candidates.
"""
import argparse,math,random,re,struct
from collections import Counter,defaultdict
from difflib import SequenceMatcher
from pathlib import Path
import numpy as np
from scipy.optimize import minimize
from real25 import engine,source_rows,sha
from paired_text import key,pairs,tokens

OUT=engine/'model/textspell30'; OLD=engine/'model/spelling22'; ALPHA="abcdefghijklmnopqrstuvwxyz'";F=27

def sig(s):return sha('real25-development/'+s)[0]
def buck(s):return sha('textspell30-counts/'+s)[0]
def one(w):
    for i,c in enumerate(w):
        yield w[:i]+w[i+1:],(c,'')
        for b in ALPHA:
            if b!=c:yield w[:i]+b+w[i+1:],(c,b)
        if i and w[i-1]!=c:yield w[:i-1]+c+w[i-1]+w[i+1:],(w[i-1:i+1],w[i-1:i+1][::-1])
    for i in range(len(w)+1):
        for b in ALPHA:yield w[:i]+b+w[i:],('',b)

def hashcode(a,b,c):return a<<32|b<<16|c

def train(args):
    rng=random.Random(30095);rows=source_rows(args.taskmaster,args.paired,args.sms);freq=Counter();casual=Counter();seen=set();counts=Counter();ctxfreq=Counter();obs=Counter()
    text_counts=[(s,source) for s,source in rows if sig(s)>=18 and buck(s)>=47]
    english={s.split('\t')[0]:int(s.split('\t')[1]) for s in (engine/'model/words.tsv').read_text().splitlines()};general=Counter(english)
    for s,src in text_counts:
        ws=s.split();freq.update(ws)
        if src=='sms':casual.update(ws)
    old_vocab=[row.split('\t')[0] for row in (OLD/'vocab.tsv').read_text().splitlines()];old={w:i for i,w in enumerate(old_vocab)}
    # Count messages may contain singletons/rare names. Retain observed words as
    # literals, but generate replacements only with independent lexical support.
    vocab=sorted(set(freq)|set(old)|set(english)|{'^','$'});ids={w:i for i,w in enumerate(vocab)};assert len(vocab)<65535
    targets={w for w in vocab if re.fullmatch(r"[a-z]+(?:'[a-z]+)*",w) and len(w)<=22 and (freq[w]>=3 or casual[w]>=2 or general[w]>=2 or w in old)};sos=ids['^']+1;eos=ids['$']+1
    observed=set(freq)|set(english)|set(old)
    for s,src in text_counts:
        seq=[sos]+[ids[w]+1 for w in s.split()]+[eos];ctxfreq.update(hashcode(0,a,b) for a,b in zip(seq,seq[1:]));ctxfreq.update(hashcode(a,b,c) for a,b,c in zip(seq,seq[1:],seq[2:]))
    ctxfreq={k:min(n,65535) for k,n in ctxfreq.items() if n>=2}
    for x,y in pairs(args.paired):
        k=key(y)
        if sha(k)[0]<38 or sig(k)<18 or buck(k)<47:continue
        a,b=tokens(x),tokens(y)
        for tag,i,j,p,q in SequenceMatcher(None,a,b,autojunk=False).get_opcodes():
            if tag=='replace' and j-i==q-p:
                for raw,dst in zip(a[i:j],b[p:q]):
                    if raw!=dst and dst in ids:obs[raw,dst]+=1
    ops={(a,b):float(v) for a,b,v in (line.split('\t') for line in (OLD/'edits.tsv').read_text().splitlines())}; costs=lambda a,b:ops.get((a,b),7.5 if len(a)==2 else 10.5)
    # Reverse edits permit an exact one-Damerau-edit search without scanning a dictionary.
    def rivals(x):
        out={}
        for w,(a,b) in one(x):
            if w in targets:
                cost=costs(b,a);out[w]=min(out.get(w,100.),cost)
        return out
    def feature(x,w,cost,a,b,d,e):
        literal=w is None;n=len(x);lit=float(literal);w='' if literal else w;cid=ids.get(w,-1)+1
        lc,rc,tri,lp,rp=[math.log1p(ctxfreq.get(z,0)) if cid else 0. for z in (hashcode(0,b,cid),hashcode(0,cid,d),hashcode(b,cid,d),hashcode(a,b,cid),hashcode(cid,d,e))];s=casual[w];k=obs[x,w];
        return [lit,lit*min(n,12),lit*(n<=3),lit*(n==2),math.log1p(freq[w]),math.log1p(general[w]),math.log1p(s),-cost,-cost/math.sqrt(n),math.log1p(k),float(k>0),lc,rc,tri,lp,rp,min(lc,rc),max(lc,rc),max(tri,lp,rp),float(n<=3)*lc,float(n<=3)*rc,lit*(b==sos),lit*(d==0),lit*(n>=4 and any(x[i]==x[i-1]==x[i-2] for i in range(2,n))),float(len(w)>n),float(len(w)<n and not literal),float(w==x[:1]*len(w) and len(w)>1)]
    keyboards=['qwertyuiop','asdfghjkl','zxcvbnm'];xy={c:(i+d,j) for j,(line,d) in enumerate(zip(keyboards,[0,.25,.75])) for i,c in enumerate(line)}
    nearby={c:[k for k,(u,v) in xy.items() if k!=c and (a-u)**2+(b-v)**2<2.1] for c,(a,b) in xy.items()}
    def typo(w):
        i=rng.randrange(len(w));c=w[i];op=rng.randrange(5)
        if op==0:return w[:i]+w[i+1:]
        if op==1 and i+1<len(w):return w[:i]+w[i+1]+c+w[i+2:]
        if op==2:return w[:i]+c+w[i:]
        y=rng.choice(nearby.get(c,[]) or ALPHA[:26]);return w[:i]+(y+c if op==3 else y)+w[i+1:]
    def dataset(group):
        examples=[];unique=set();pooled=defaultdict(list)
        for s,origin in rows:
            h=sig(s)
            if not ((group=='fit' and h>=18 and buck(s)<47) or (group=='cal' and 9<=h<18) or (group=='dev' and h<9)):continue
            ws=s.split();v=[sos,sos]+[ids.get(z,-1)+1 for z in ws]+[0,0];poses=list(range(len(ws)));rng.shuffle(poses)
            for i in poses[:len(poses) if origin=='sms' else 3]:
                w=ws[i]
                if not w.isalpha() or not 2<=len(w)<=22:continue
                ctx=(v[i],v[i+1],v[i+3],v[i+4]) if rng.random()<.75 else (v[i],v[i+1],0,0)
                x=typo(w)
                if len(x)>=2 and x not in observed and w in targets:
                    pooled[origin,'corrupt'].append((ctx,x,w,origin,True))
                if w not in observed or (group=='fit' and ((origin=='sms' and rng.random()<.45) or (freq[w]<15 and rng.random()<.38))):
                    pooled[origin,'clean'].append((ctx,w,w,origin,False))
        for (origin,typ),items in pooled.items():
            rng.shuffle(items);limit=18000 if group=='fit' and typ=='corrupt' else 5500
            if origin=='sms' and group=='fit':limit=5000
            for row in items:
                _,x,w,_,_=row
                # Disjoint message partitions and a single vote for the same
                # noisy/gold token pair within each origin and evaluation slice.
                ident=(origin,x,w); 
                if ident in unique:continue
                unique.add(ident);examples.append(row);limit-=1
                if limit==0:break
        return examples
    def assemble(examples):
        chunks=[];meta=[];sizes=[];gold=[]
        for ctx,x,w,origin,err in examples:
            options=list(rivals(x).items());cs=[(None,0.)]+[(v,cost) for v,cost in options if v!=x];choices=[v for v,c in cs];j=choices.index(w) if err and w in choices else 0
            if len(cs)==1:continue
            chunks.append(np.asarray([feature(x,v,c,*ctx) for v,c in cs],np.float32));sizes.append(len(cs));gold.append(j);meta.append((x,w,origin,err,choices,ctx))
        return np.concatenate(chunks),np.asarray(sizes),np.asarray(gold),meta
    f=dataset('fit');mat,ns,ys,meta=assemble(f);starts=np.cumsum(np.r_[0,ns[:-1]]);g=mat[starts+ys].sum(axis=0,dtype=np.float64)
    def objective(w):
        z=mat@w.astype(np.float32);p0=np.maximum.reduceat(z,starts);p=np.exp(z-np.repeat(p0,ns));s=np.add.reduceat(p,starts);p/=np.repeat(s,ns);reg=.0008
        return ((np.log(s)+p0).sum(dtype=np.float64)-g@w)/len(ns)+reg*(w@w)/2,(mat.T@p-g)/len(ns)+reg*w
    fitted=minimize(objective,np.zeros(F),jac=True,method='L-BFGS-B',options={'maxiter':200}).x
    print('count messages',len(text_counts),'SMS',sum(src=='sms' for s,src in text_counts),'vocabulary',len(vocab),'candidates',len(targets),'fit examples',len(ns),'clean/typos',Counter(v[3] for v in meta),'weights',np.round(fitted,3),flush=True)
    OUT.mkdir(parents=True,exist_ok=True);(OUT/'vocab.tsv').write_text(''.join(f'{w}\t{freq[w]}\t{general[w]}\t{casual[w]}\t{int(w in targets)}\n' for w in vocab));(OUT/'rank.txt').write_text(' '.join(f'{v:.8f}' for v in fitted)+'\n');(OUT/'edits.tsv').write_bytes((OLD/'edits.tsv').read_bytes());(OUT/'observed.tsv').write_text(''.join(f'{x}\t{ids[w]}\t{n}\n' for (x,w),n in sorted(obs.items()) if n>=1))
    # Single fixed-width record per supported collocation; trim low-support
    # trigrams that provide too little evidence to beat the literal outside fit.
    with (OUT/'contexts.bin').open('wb') as fp:
        for k,n in sorted(ctxfreq.items()):fp.write(struct.pack('<QH',k,n))
    def score(examples):
        m,n,_,meta=assemble(examples);zs=m@fitted.astype(np.float32);at=0;out=[]
        for count,(x,w,org,err,opts,ctx) in zip(n,meta):
            z=zs[at:at+count];at+=count;order=np.argsort(-z);j,k=order[:2];out.append((org,err,j!=0 and opts[j]==w,j!=0,float(z[j]-z[0]),float(z[j]-z[k]),len(x),w,x,opts[j]))
        return out
    def report(rows,m,g):
        yes=[(err,ok) for _,err,ok,change,delta,gap,*_ in rows if change and delta>=m and gap>=g];return (sum(err and ok for err,ok in yes),sum(err and not ok for err,ok in yes),sum(not err for err,ok in yes))
    cal=score(dataset('cal'));dev=score(dataset('dev'))
    for label,group in [('short',lambda v:v[6]<=3),('long',lambda v:v[6]>3)]:
        subset=[v for v in cal if group(v)];neg=sum(not v[1] for v in subset);cfg=[]
        for m in np.arange(1.,8.5,.5):
            for g in np.arange(.5,6.,.5):
                good,bad,fp=report(subset,m,g)
                if fp<=max(1,neg*.035) and bad<=good*.012:cfg.append((good,m,g))
        _,m,g=max(cfg or [(0,9.,6.)]);print('cal',label,'example totals',Counter(v[1] for v in subset),m,g,report(subset,m,g),flush=True);(OUT/f'{label}.txt').write_text(f'{m} {g}\n')
        for origin in ('sms','cc0','paired','taskmaster'):
            sub=[v for v in dev if group(v) and v[0]==origin];print('dev',label,origin,'examples',Counter(v[1] for v in sub),'fixed/wrong/clean changes',report(sub,m,g),flush=True)

def native_audit(args):
    """One held-out SMS message split; unique one-edit typos and literal controls."""
    import subprocess,tempfile
    rows=source_rows(args.taskmaster,args.paired,args.sms);sms=[s for s,origin in rows if origin=='sms' and sig(s)<9];vocab={row.split('\t')[0] for row in (OUT/'vocab.tsv').read_text().splitlines()};rng=random.Random(30117);sample=[];types=set()
    for sentence in sms:
        ws=sentence.split()
        for i,w in enumerate(ws):
            if not w.isalpha() or not 2<=len(w)<=22:continue
            left=' '.join(ws[:i]);right=' '.join(ws[i+1:i+3]);sample.append((left,w,right,w,False)); j=rng.randrange(len(w));kind=rng.randrange(4)
            if kind==0:x=w[:j]+w[j+1:]
            elif kind==1:x=w[:j]+w[j]+w[j:]
            elif kind==2 and j+1<len(w):x=w[:j]+w[j+1]+w[j]+w[j+2:]
            else:
                row=next(r for r in ('qwertyuiop','asdfghjkl','zxcvbnm') if w[j] in r);k=row.index(w[j]);letter=rng.choice([row[n] for n in (k-1,k+1) if 0<=n<len(row)]);x=w[:j]+letter+w[j+1:]
            if len(x)<2 or x in vocab or (x,w) in types:continue
            types.add((x,w));sample.append((left,x,right,w,True))
    with tempfile.TemporaryDirectory() as tmp:
        tmp=Path(tmp);f=tmp/'audit.rs';f.write_text(''.join(f'#[path="{engine}/src/{model}.rs"] mod {model};\n' for model in ('spelling22','textspell30'))+'''use std::io::{self,BufRead};use std::ffi::{CString,CStr};
fn main(){for row in io::stdin().lock().lines().map_while(Result::ok){let q:Vec<_>=row.split('|').collect();let s:Vec<_>=q.iter().map(|x|CString::new(*x).unwrap()).collect();let mut o=[0i8;128];unsafe{spelling22::mb_spelling22_v1(s[0].as_ptr(),s[1].as_ptr(),s[2].as_ptr(),o.as_mut_ptr(),128);}let prior=unsafe{CStr::from_ptr(o.as_ptr())}.to_str().unwrap();println!("{}|{}",prior,textspell30::repair(q[0],q[1],q[2]).unwrap_or_default());}}''');exe=tmp/'audit';subprocess.run(['rustc','--edition=2021','-O',str(f),'-o',str(exe)],check=True);q='\n'.join('|'.join(r[:3]) for r in sample)+'\n';raw=subprocess.run([str(exe)],input=q,text=True,capture_output=True,check=True).stdout.splitlines();assert len(raw)==len(sample)
    for label,selector in [('all',lambda n:True),('short',lambda n:n<=3),('long',lambda n:n>3)]:
        counts=Counter()
        for (_,typed,_,gold,corrupt),r in zip(sample,raw):
            if not selector(len(typed)):continue
            base,new=r.lower().split('|');
            for version,o in [('existing',base),('new',new),('combined',base or new)]:
                metric=('fixed' if o==gold else 'wrong' if o else 'abstained') if corrupt else ('changed clean' if o else 'kept clean');counts[version,metric]+=1
        print('native SMS',label,dict(sorted(counts.items())),flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    for a in ('taskmaster','paired','sms'):p.add_argument(a,type=Path)
    p.add_argument('--native-audit',action='store_true');args=p.parse_args()
    if args.native_audit:native_audit(args)
    else:train(args)
