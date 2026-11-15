"""Fit a bidirectional lexical cloze model for conservative real-word repairs.

No benchmark examples are read. For SMS, exclude every message whose length and
surface can enter the frozen public challenge, and every normalized equivalent.
The model is trained on clean words. Development corruptions are generated from
an exhaustive, general edit neighborhood and do not define the runtime policy.
"""
import argparse
import bz2
import hashlib
import math
import random
import re
import struct
import zipfile
from collections import Counter
from pathlib import Path

import numpy as np
import torch
from torch import nn
from paired_text import engine, key, pairs

OUT = engine/'model/real25'
SEED = 250113
D, H, EPOCHS, BATCH = 40, 120, 7, 1536

def sha(s):
    return hashlib.sha256(s.encode()).digest()

def source_rows(taskmaster, paired, sms):
    assert sha_bytes(taskmaster)=='edc28ced48aeaa75702590ccde3de70a283370d152323749b16c75b8984ce655'
    assert sha_bytes(sms)=='1587ea43e58e82b14ff1f5425c88e17f8496bfcdb67a583dbff9eefaf9963ce3'
    cc0=engine/'training/eng_sentences_CC0.tsv.bz2'
    assert sha_bytes(cc0)=='c2e2edd063a31cbbc8e416a4858225e934bbb0afff485031821e59f230ccf1ca'
    # Shield reserved clean messages across sources as well as within each source.
    forbidden=set(); rows={}
    for _,clean in pairs(paired):
        k=key(clean)
        if sha(k)[0]<38:forbidden.add(k)
        else:rows[k]='paired'
    for line in taskmaster.read_text().splitlines():rows.setdefault(key(line),'taskmaster')
    with bz2.open(cc0,'rt') as f:
        for line in f:
            _,lang,s,_=line.rstrip('\n').split('\t',3)
            if lang!='eng':continue
            k=key(s)
            if sha(k)[0]<26:forbidden.add(k)
            else:rows.setdefault(k,'cc0')
    with zipfile.ZipFile(sms) as z:
        ham=[s[4:].strip() for s in z.read('SMSSpamCollection').decode().splitlines() if s.startswith('ham\t')]
    eligible={key(s) for s in ham if 6<=len(s.split())<=26 and '  ' not in s and re.fullmatch(r"[a-zA-Z][A-Za-z ,'.!?-]+[.!?]",s)}
    for s in ham:
        k=key(s)
        if k not in eligible:rows.setdefault(k,'sms')
    out=[(s,source) for s,source in rows.items() if s not in forbidden and 3<=len(s.split())<=45]
    return out

def sha_bytes(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def neighbors(w):
    for i in range(len(w)):
        yield w[:i]+w[i+1:]
        for c in 'abcdefghijklmnopqrstuvwxyz':yield w[:i]+c+w[i+1:]
        if i:yield w[:i-1]+w[i]+w[i-1]+w[i+1:]
    for i in range(len(w)+1):
        for c in 'abcdefghijklmnopqrstuvwxyz':yield w[:i]+c+w[i:]

class Cloze(nn.Module):
    def __init__(self,nv,nt):
        super().__init__();self.emb=nn.Embedding(nv,D);self.hidden=nn.Linear(5*D,H);self.out=nn.Linear(H,nt)
    def forward(self,x):
        return self.out(self.hidden(self.emb(x).flatten(1)).tanh())

def main(args):
    rng=random.Random(SEED);torch.manual_seed(SEED);torch.set_num_threads(4)
    rows=source_rows(args.taskmaster,args.paired,args.sms)
    train=[];dev=[];cal=[]
    for s,source in rows:
        h=sha('real25-development/'+s)[0];(dev if h<9 else cal if h<18 else train).append((s,source))
    print('groups',*[dict(Counter(source for _,source in x)) for x in (train,cal,dev)],flush=True)
    freq=Counter(w for s,_ in train for w in s.split());words=['<unk>','<s>','<empty>']+[w for w,n in sorted(freq.items()) if n>=3]
    ids={w:i for i,w in enumerate(words)}
    targets=[w for w,n in sorted(freq.items()) if n>=24 and 2<=len(w)<=5 and w.isascii() and w.isalpha()]
    targets=[w for w in targets if any(x!=w and x in targets for x in neighbors(w))]
    ti={w:i for i,w in enumerate(targets)}; target_set=set(ti)
    neighborhood={w: sorted({x for x in neighbors(w) if x in target_set and x!=w}) for w in targets}
    def encode(rows):
        x=[];labels=[];meta=[]
        for s,source in rows:
            ws=s.split();idx=[ids.get(w,0) for w in ws];v=[1]*3+idx+[2]*2
            for i,w in enumerate(ws[:-1]):
                if w not in ti:continue
                x.append([v[i+2],v[i+1],v[i],v[i+4],v[i+5]])
                labels.append(ti[w]);meta.append(source)
        return np.asarray(x,np.int32),np.asarray(labels,np.int32),meta
    x,y,_=encode(train);cx,cy,cs=encode(cal);dx,dy,ds=encode(dev)
    device='mps' if torch.backends.mps.is_available() else 'cpu';model=Cloze(len(words),len(targets)).to(device)
    opt=torch.optim.AdamW(model.parameters(),lr=.003)
    train_x=torch.from_numpy(x).to(device);train_y=torch.from_numpy(y).long().to(device)
    print('vocabulary',len(words),'output',len(targets),'positions',len(y),'device',device,flush=True)
    def logits(x):
        model.eval()
        with torch.no_grad():
            return np.concatenate([model(torch.from_numpy(x[i:i+BATCH]).to(device)).cpu().numpy() for i in range(0,len(x),BATCH)])
    for epoch in range(EPOCHS):
        model.train();order=np.random.default_rng(SEED+epoch).permutation(len(x));loss_sum=0.
        for i in range(0,len(x),BATCH):
            sel=torch.from_numpy(order[i:i+BATCH]).to(device);batch=train_x[sel].clone()
            # At the first review the keyboard has only one word after the target.
            missing=torch.rand((len(batch),),device=device)<.62;batch[missing,4]=2
            mask=torch.rand(batch.shape,device=device)<.06;batch[mask]=0
            loss=nn.functional.cross_entropy(model(batch),train_y[sel]);opt.zero_grad(set_to_none=True);loss.backward();opt.step();loss_sum+=float(loss.detach())*len(sel)
        print('epoch',epoch+1,'nll',round(loss_sum/len(y),3),flush=True)
    OUT.mkdir(exist_ok=True,parents=True)
    (OUT/'vocab.txt').write_text('\n'.join(words)+'\n');(OUT/'targets.tsv').write_text(''.join(f'{w}\t{freq[w]}\t'+','.join(str(ti[v]) for v in neighborhood[w])+'\n' for w in targets))
    # Rowwise quantization keeps both the footprint and dot products small.
    with (OUT/'cloze.bin').open('wb') as f:
        f.write(struct.pack('<4I',len(words),len(targets),D,H))
        for a in (model.emb.weight,model.hidden.weight,model.out.weight):
            orig=a.detach().cpu().numpy();scale=np.maximum(np.max(np.abs(orig),axis=1),1e-8)/127
            f.write(scale.astype('<f4').tobytes());f.write(np.rint(orig/scale[:,None]).astype('i1').tobytes())
        for a in (model.hidden.bias,model.out.bias):f.write(a.detach().cpu().numpy().astype('<f4').tobytes())
    def scores(x,y,source):
        x=x.copy();x[:,4]=2
        z=logits(x);rng=random.Random(SEED);stats=[]
        for i,gold in enumerate(y):
            a=targets[gold]; rival=rng.choice(neighborhood[a]);typed=ti[rival]
            for t,label in [(gold,1),(typed,0)]:
                cand=[t]+[ti[w] for w in neighborhood[targets[t]]];rank=np.argsort(-z[i,cand]);b=cand[rank[0]];second=cand[rank[1]]
                stats.append((label,t,b,gold,float(z[i,b]-z[i,t]),float(z[i,b]-z[i,second]),source[i]))
        return stats
    c=scores(cx,cy,cs);d=scores(dx,dy,ds)
    def report(rows,margin,gap):
        decisions=[(not keep,b==g) for keep,t,b,g,delta,lead,_ in rows if t!=b and delta>=margin and lead>=gap]
        recovered=sum(noisy and ok for noisy,ok in decisions);false=sum(not noisy for noisy,ok in decisions);wrong=sum(noisy and not ok for noisy,ok in decisions)
        return recovered,false,wrong
    # Fixed operating objective, chosen before viewing calibration results.
    configs=[(m,g) for m in (4.5,5,5.5,6,6.5,7,7.5,8,8.5,9) for g in (2,2.5,3,3.5,4,4.5)]
    for _,rows in [('cal',c),('dev',d)]:
        for m,g in [(5,2.5),(6,3),(7,3.5),(8,4)]:print(_,m,g,len(rows)//2,report(rows,m,g),flush=True)
    viable=[(report(c,m,g)[0],m,g) for m,g in configs if report(c,m,g)[1]<=len(c)//2*.0004 and report(c,m,g)[2]<=len(c)//2*.004]
    _,m,g=max(viable or [(0,9.,4.5)])
    print('selected margins',m,g,flush=True)
    (OUT/'policy.txt').write_text(f'{m} {g}\n')
    for group in sorted(set(ds)):
        subset=[line for line in d if line[-1]==group];print('dev',group,len(subset)//2,report(subset,m,g),flush=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for arg in ('taskmaster','paired','sms'):parser.add_argument(arg,type=Path)
    main(parser.parse_args())
