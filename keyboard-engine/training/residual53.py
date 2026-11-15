"""Learn a joint residual edit/missing-space decoder from simulated typing.

Build 52 residuals supply only aggregate edit-type frequencies. No reference
tokens or contexts from those fixtures enter the training or candidate tables.
"""
import argparse
from collections import Counter
import gzip
import json
from pathlib import Path
import random
import re
import struct
import subprocess
import sys
import tempfile

import numpy as np
from scipy.optimize import minimize

from real25 import engine, source_rows, sha

F = 33
DEST = engine / 'model/residual53'
BENCH = engine.parent / 'Benchmarks'
sys.path.insert(0, str(BENCH / 'build22/blind'))
from score import scan, observe

def error_prior():
    counts = Counter()
    for suite in ('fresh', 'public'):
        gold = json.loads((BENCH / f'build51/{suite}.json').read_bytes())
        with gzip.open(BENCH / f'build52/{suite}-52.jsonl.gz', 'rt') as f:
            out = {r['id']:r['final'] for r in map(json.loads, f)}
        for row in gold:
            ref = scan(row['expected'])
            typed = observe(ref, scan(row['typed'])).slots
            shown = observe(ref, scan(out[row['id']])).slots
            for i, (x, w, result) in enumerate(zip(typed, ref.words, shown)):
                if x == w or result == w: continue
                if x is None:
                    counts['join'] += 1
                    continue
                x, w = x.lower(), w.lower()
                if i and x == ref.words[i-1].lower()+w: continue
                if len(w) == len(x)+1 and any(w[:i]+w[i+1:] == x for i in range(len(w))):
                    counts['drop'] += 1
                elif len(x) == len(w)+1 and any(x[:i]+x[i+1:] == w for i in range(len(x))):
                    counts['repeat'] += 1
                elif len(x) == len(w) and any(x[:i]+x[i:i+2][::-1]+x[i+2:] == w for i in range(len(x)-1)):
                    counts['swap'] += 1
                elif len(x) == len(w) and sum(a!=b for a,b in zip(x,w))==1:
                    counts['key'] += 1
                else: counts['other'] += 1
    return counts

def make_examples(rows, prior, rng):
    # These messages were never counted into the deployed textspell30 language
    # statistics. Partition by complete normalized reference before sampling.
    groups = {'fit': [], 'cal': [], 'test': []}
    for s, origin in rows:
        if sha('real25-development/'+s)[0] >= 18 and sha('textspell30-counts/'+s)[0] >= 47:
            continue
        split = sha('residual53-v1/'+s)[0]
        groups['cal' if split<40 else 'test' if split<80 else 'fit'].append((s, origin))
    keyboards = ['qwertyuiop','asdfghjkl','zxcvbnm']
    xy = {k:(i+shift,j) for j,(r,shift) in enumerate(zip(keyboards,[0,.25,.75])) for i,k in enumerate(r)}
    neighbors = {k:[v for v,(c,d) in xy.items() if 0 < (a-c)**2+(b-d)**2 <= 2.1] for k,(a,b) in xy.items()}
    def damage(w, op):
        i = rng.randrange(len(w))
        if op=='repeat': return w[:i]+w[i]+w[i:]
        if op=='swap' and len(w)>1:
            i = rng.randrange(len(w)-1)
            return w[:i]+w[i:i+2][::-1]+w[i+2:]
        if op=='drop': return w[:i]+w[i+1:]
        return w[:i]+rng.choice(neighbors.get(w[i],['a']))+w[i+1:]
    ops = ['join','drop','repeat','swap','key']
    examples=[]
    for group,data in groups.items():
        rng.shuffle(data)
        for s,origin in data:
            words=s.split()
            positions=list(range(len(words)))
            rng.shuffle(positions)
            for i in positions[:3 if origin!='sms' else len(positions)]:
                w=words[i]
                if not re.fullmatch("[a-z]+(?:'[a-z]+)*",w): continue
                end=i+1
                # Preserve unknown words, including names and slang. Failed or
                # out-of-vocabulary generated corruptions also act as negatives.
                if rng.random()<.32:
                    raw=target=w
                    op='clean'
                else:
                    op=rng.choices(ops,weights=[prior[v]+3 for v in ops])[0]
                    if op=='join' and end<len(words):
                        target=w+' '+words[end]
                        raw=w+words[end]
                        end+=1
                    else:
                        raw=damage(w,op)
                        target=w
                if raw==target and op!='clean': continue
                if rng.random()<.06 and i==0 and op=='repeat' and len(raw)>2 and raw[0]==raw[1]:
                    raw = raw[:2].upper()+raw[2:]
                    target = target.capitalize()
                left=' '.join(words[max(i-2,0):i])
                right=' '.join(words[end:end+(rng.choices([0,1,2],[.35,.25,.4])[0])])
                if 3<=len(raw)<=25: examples.append((group,left,raw,right,target,op,origin))
    return examples

def features(examples, probe, tmp):
    inp=tmp/'cases.tsv'
    inp.write_text(''.join(f'{l}\t{w}\t{r}\n' for _,l,w,r,*_ in examples))
    binary=tmp/'features.bin'
    with inp.open('rb') as src,binary.open('wb') as dst:
        subprocess.run([probe],stdin=src,stdout=dst,check=True)
    data=binary.read_bytes()
    pos=0
    bank={k:[] for k in ('fit','cal','test')}
    for entry in examples:
        n=struct.unpack_from('<H',data,pos)[0]; pos+=2
        if not n: continue
        xs=np.zeros((n+1,F),np.float32)
        options=['']
        for i in range(1,n+1):
            size=data[pos]; pos+=1
            options.append(data[pos:pos+size].decode());pos+=size
            xs[i]=np.frombuffer(data,dtype='<f4',count=F,offset=pos);pos+=4*F
        group,left,w,right,gold,op,origin=entry
        correct=options.index(gold) if gold in options else 0
        bank[group].append((xs,correct,[(' ' in v) for v in options],op,origin))
    assert pos==len(data)
    return bank

def fit(bank):
    rows=bank['fit']
    sizes=np.array([len(x) for x,*_ in rows])
    starts=np.r_[0,np.cumsum(sizes[:-1])]
    X=np.concatenate([x for x,*_ in rows])
    gold=np.array([y for x,y,*_ in rows])
    target=X[starts+gold].sum(axis=0,dtype=np.float64)
    def loss(w):
        z=X@w.astype(np.float32)
        peak=np.maximum.reduceat(z,starts)
        ex=np.exp(z-np.repeat(peak,sizes)); den=np.add.reduceat(ex,starts)
        probs=ex/np.repeat(den,sizes)
        reg=.0006
        return ((np.log(den)+peak).sum(dtype=np.float64)-target@w)/len(rows)+reg*w@w/2, (X.T@probs-target)/len(rows)+reg*w
    result=minimize(loss,np.zeros(F),jac=True,method='L-BFGS-B',options={'maxiter':350,'ftol':1e-10})
    return result.x

def scored(items, weights):
    rows=[]
    for x,gold,split,op,origin in items:
        z=x@weights
        order=np.argsort(-z,kind='stable')
        j,k=order[:2]
        if j: rows.append((float(z[j]),float(z[j]-z[k]),split[j],bool(j==gold),op,origin,len(x)==2,x[j,19]>0))
    return rows

def metrics(rows, gate):
    yes=[r for r in rows if r[0]>=gate[0] and r[1]>=gate[1]]
    return dict(correct=sum(r[3] for r in yes),wrong=sum(not r[3] for r in yes),
                changed_clean=sum(r[4]=='clean' for r in yes),proposals=len(yes))

def train(args):
    rng=random.Random(53117)
    prior=error_prior()
    examples=make_examples(source_rows(args.conversations,args.paired,args.sms),prior,rng)
    with tempfile.TemporaryDirectory() as name:
        tmp=Path(name)
        probe=tmp/'probe'
        subprocess.run(['rustc','--edition=2021','-Awarnings','-O',engine/'training/residual53_probe.rs','-o',probe],check=True)
        bank=features(examples,probe,tmp)
    w=fit(bank)
    gates=[]
    report={'edit_prior':prior,'considered_examples':dict(Counter(x[0] for x in examples)),
            'examples_with_candidates':{k:len(v) for k,v in bank.items()}}
    cal=scored(bank['cal'],w)
    test=scored(bank['test'],w)
    # A unique split has no competing spelling, while a transposition
    # preserves every character. These mechanisms have distinct error rates.
    cohorts=[('missing_space',lambda r:r[2]),('spelling',lambda r:not r[2]),
             ('sole_split',lambda r:r[2] and r[6]),('transposition',lambda r:not r[2] and r[7])]
    for name,selected in cohorts:
        sample=[r for r in cal if selected(r)]
        rules=[]
        for margin in np.arange(1,9,.5):
            for gap in np.arange(1,6,.5):
                m=metrics(sample,(margin,gap))
                if m['wrong']<=max(1,m['correct']*.009) and m['changed_clean']<=max(1,m['correct']*.00035):
                    rules.append((m['correct'],-margin,-gap))
        _,neg_m,neg_g=max(rules or [(0,-9,-6)])
        gate=-neg_m,-neg_g
        gates.extend(gate)
        report[name]={'thresholds':list(gate),'calibration':metrics(sample,gate),
                      'reserved':metrics([r for r in test if selected(r)],gate)}
    def gate_for(r):
        i=2 if r[2] and r[6] else 3 if r[7] else 0 if r[2] else 1
        return gates[i*2:i*2+2]
    report['combined_reserved']=metrics([r for r in test if r[0]>=gate_for(r)[0] and r[1]>=gate_for(r)[1]],(0.,0.))
    DEST.mkdir(exist_ok=True)
    (DEST/'weights.txt').write_text(' '.join(f'{v:.8f}' for v in [*w,*gates])+'\n')
    (DEST/'fit.json').write_text(json.dumps(report,sort_keys=True,indent=2)+'\n')
    print(json.dumps(report),flush=True)
if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for a in ('conversations','paired','sms'):parser.add_argument(a,type=Path)
    train(parser.parse_args())
