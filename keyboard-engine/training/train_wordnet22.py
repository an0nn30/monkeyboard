"""Train a character/subword neural spelling model on aligned S:/C: word edits.
The model predicts canonical tokens from the noisy token and its noisy neighbours,
with an explicit unknown-word class. Only shared weights/vocabulary ship.
"""
import argparse, hashlib, json, math, random, struct, sys
from collections import Counter,defaultdict
from difflib import SequenceMatcher
from pathlib import Path
import re
import numpy as np
import torch
from torch import nn
from torch.nn import functional as F
from paired_text import key,pairs,engine
def toks(s):return re.findall(r"[a-z]+(?:'[a-z]+)*",s.lower().replace('’',"'"))
BINS=32768;D=48;H=112;K=48;SEED=20261114
def grams(w):
    if not w:return []
    v=b'^'+w.encode('ascii',errors='ignore')[:28]+b'$';out=[]
    # Order: full word, then character windows, boundary bigrams first.
    def hashed(x):
        h=2166136261
        for b in x:h=((h^b)*16777619)&0xffffffff
        return 1+h%(BINS-1)
    out.append(hashed(v))
    for n in (3,2,4,1):
        for j in range(len(v)+1-n):
            out.append(hashed(v[j:j+n]))
            if len(out)==K:return out
    return out
def align(a,b):
    for tag,i,j,k,l in SequenceMatcher(None,a,b,autojunk=False).get_opcodes():
        if j-i==l-k:
            for x,y in zip(range(i,j),range(k,l)):yield x,y
def cache(src,work,public):
    rng=random.Random(SEED);rows=[];freq=Counter();valid=[]
    seen=set()
    protected=set()
    for build in (15,16):
        import csv
        for r in csv.DictReader((engine.parent/f'Benchmarks/build{build}/cases.tsv').open(),delimiter='\t'):
            protected.add(key(' '.join([r['left'],r['gold'].split('|')[0],r['right']])))
    for x,y in pairs(src):
        k=key(y)
        if k in protected or hashlib.sha256(k.encode()).digest()[0]<38:continue
        a,b=toks(x),toks(y)
        if k not in seen:freq.update(b);seen.add(k)
        (valid if hashlib.sha256(('neural-dev/'+k).encode()).digest()[0]<6 else rows).append((a,b))
    vocab=['<other>']+[w for w,n in sorted(freq.items()) if n>=3];ids={w:i for i,w in enumerate(vocab)}
    # Block unseen words and genuinely grammatical nearby alternatives using conversational negatives.
    texts=public.read_text().splitlines();rng.shuffle(texts)
    rows.extend((s.split(),s.split()) for s in texts[:52000])
    words={'':0};G=[[]]
    def wid(w):
        if w not in words:words[w]=len(G);G.append(grams(w))
        return words[w]
    def encode(data):
        X=[];y=[];weight=[]
        for a,b in data:
            local=[0,0]+list(map(wid,a))+[0,0]
            for i,j in align(a,b):
                if len(a[i])>26:continue
                X.append([local[i+2],local[i+1],local[i],local[i+3],local[i+4]])
                y.append(ids.get(b[j],0));weight.append(4. if a[i]!=b[j] else 1.)
        return np.asarray(X,np.int32),np.asarray(y,np.int32),np.asarray(weight,np.float32)
    tr=encode(rows);va=encode(valid)
    table=np.zeros((len(G),K),np.int32)
    for i,g in enumerate(G):table[i,:len(g)]=g
    np.savez(work/'word22.npz',trX=tr[0],try_=tr[1],trw=tr[2],vaX=va[0],vay=va[1],vaw=va[2],table=table)
    (work/'word22-vocab.txt').write_text('\n'.join(vocab)+'\n')
    print('aligned training word slots',len(tr[0]),'development',len(va[0]),'vocab',len(vocab),'features',len(G),flush=True)
class Ranker(nn.Module):
    def __init__(self,n):
        super().__init__();self.e=nn.Embedding(BINS,D,padding_idx=0);self.a=nn.Linear(5*D,H);self.b=nn.Linear(H,n)
    def forward(self,feat):
        x=self.e(feat).sum(-2)/feat.ne(0).sum(-1,keepdim=True).clamp(min=1).sqrt();return self.b(F.relu(self.a(x.flatten(1))))
def train(work,dest,epochs):
    torch.manual_seed(SEED);rng=np.random.default_rng(SEED);torch.set_num_threads(5);device='mps' if torch.backends.mps.is_available() else 'cpu'
    blob=np.load(work/'word22.npz');v=(work/'word22-vocab.txt').read_text().splitlines();g=torch.tensor(blob['table'],device=device,dtype=torch.int32)
    model=Ranker(len(v)).to(device);opt=torch.optim.AdamW(model.parameters(),lr=.003);best=0;record=[]
    def epoch(train):
        k='tr' if train else 'va';xs=blob[k+'X'];ys=blob['try_' if train else 'vay'];w=blob[k+'w'];order=rng.permutation(len(xs)) if train else np.arange(len(xs));n=ok=0
        model.train(train)
        with torch.set_grad_enabled(train):
            for i in range(0,len(order),1024):
                idx=order[i:i+1024];x=xs[idx].copy();y=torch.tensor(ys[idx],device=device,dtype=torch.long)
                if train:
                    # At commit no right words are available. Later, either one or two have arrived.
                    mask=rng.random(len(idx));x[mask<.48,3:]=0;x[(mask>=.48)&(mask<.70),4]=0
                    x[rng.random(len(idx))<.12,1:3]=0
                logits=model(g[torch.tensor(x,device=device,dtype=torch.long)]);weights=torch.tensor(w[idx],device=device)
                if train:
                    loss=(F.cross_entropy(logits,y,reduction='none')*weights).mean();opt.zero_grad(set_to_none=True);loss.backward();opt.step()
                bad=weights>1;ok+=((logits.argmax(-1)==y)&bad).sum().item();n+=bad.sum().item()
        return ok/max(1,n)
    for e in range(epochs):
        if e==3:opt.param_groups[0]['lr']=.001
        if e==6:opt.param_groups[0]['lr']=.0005
        a=epoch(True);b=epoch(False);record.append((a,b));print('epoch',e+1,'observed-error top1 train/validation',a,b,flush=True)
        if b>best:
            dest.mkdir(exist_ok=True,parents=True);best=b
            with (dest/'weights.bin').open('wb') as f:
                f.write(struct.pack('<5I',BINS,D,H,len(v),K))
                for p in (model.e.weight,model.a.weight,model.b.weight):
                    z=p.detach().cpu().numpy();sc=np.maximum(np.max(np.abs(z),axis=1)/127,1e-9)
                    f.write(sc.astype('<f4').tobytes());f.write(np.rint(z/sc[:,None]).clip(-127,127).astype('i1').tobytes())
                for p in (model.a.bias,model.b.bias):f.write(p.detach().cpu().numpy().astype('<f4').tobytes())
            (dest/'vocab.txt').write_text('\n'.join(v)+'\n')
    (work/'word22-log.json').write_text(json.dumps(record))
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('source',type=Path);p.add_argument('work',type=Path);p.add_argument('public',type=Path);p.add_argument('--epochs',type=int,default=7);a=p.parse_args();cache(a.source,a.work,a.public);train(a.work,engine/'model/wordnet22',a.epochs)
