"""Fit the main decoder's output projection without shifting the states used by semantic review."""
import argparse, copy, json, random
from pathlib import Path
import numpy as np
import torch
from torch.nn import functional as F
from networks import Decoder,T
def train(work, base, out):
    seed=41201;torch.manual_seed(seed);rng=random.Random(seed);torch.set_num_threads(5)
    device='mps' if torch.backends.mps.is_available() else 'cpu'
    vocab=(base/'vocab.txt').read_text().splitlines();ids={w:i for i,w in enumerate(vocab)}
    def examples(file,cap):
        seq=[]
        for s in (work/file).read_text().splitlines():
            ws=s.split();seq.append([1]+[ids.get(w,0) for w in ws[:T]])
        rng.shuffle(seq);return seq[:cap]
    tr=examples('train.txt',150000);va=examples('validation.txt',6000)
    model=Decoder().to(device).eval()
    model.load_state_dict(torch.load(base/'decoder.pt',map_location='cpu',weights_only=True))
    for p in model.parameters():p.requires_grad_(False)
    ref=copy.deepcopy(model.out)
    for p in model.out.parameters():p.requires_grad_(True)
    opt=torch.optim.AdamW(model.out.parameters(),lr=0.00030,weight_decay=0.)
    def run(rows,fit):
        sums=[0,0,0];batches=[]
        for start in range(0,len(rows),4000):
            chunk=sorted(rows[start:start+4000],key=len)
            batches.extend([chunk[i:i+128] for i in range(0,len(chunk),128)])
        if fit:rng.shuffle(batches)
        with torch.set_grad_enabled(fit):
            for batch in batches:
                n=max(map(len,batch))-1;x=np.zeros((len(batch),n+1),np.int64)
                for i,s in enumerate(batch):x[i,:len(s)]=s
                x=torch.from_numpy(x).to(device);target=x[:,1:]
                with torch.no_grad():
                    h=model.emb(x[:,:-1])+model.pos(torch.arange(n,device=device))[None];h=model.norm(model.layers(h))
                    # Sample positions deterministically per epoch; bound output-layer memory.
                    step=2;offset=rng.randrange(step) if fit else 0;h=h[:,offset::step].reshape(-1,h.size(-1));target=target[:,offset::step].reshape(-1)
                    ix=target!=0;h=h[ix];target=target[ix];prior=F.softmax(ref(h),dim=-1) if fit else None
                logits=model.out(h);loss=F.cross_entropy(logits,target)
                if fit:
                    anchor=F.kl_div(F.log_softmax(logits,dim=-1),prior,reduction='batchmean')
                    opt.zero_grad(set_to_none=True);(loss+0.8*anchor).backward();opt.step()
                sums[0]+=loss.item()*target.numel();sums[1]+=(logits.argmax(-1)==target).sum().item();sums[2]+=target.numel()
        return {'nll':sums[0]/sums[2],'top1':sums[1]/sums[2],'tokens':sums[2]}
    result={'seed':seed,'train_sentences':len(tr),'validation_sentences':len(va),'device':device,'modified_parameters':sum(p.numel() for p in model.out.parameters()),'baseline':run(va,False)}
    print(result,flush=True)
    result['training']=run(tr,True);result['candidate']=run(va,False);print(result,flush=True)
    assert result['candidate']['nll']<result['baseline']['nll']
    out.mkdir(exist_ok=True,parents=True);torch.save({k:v.detach().cpu().half() for k,v in model.state_dict().items()},out/'decoder.pt')
    (out/'vocab.txt').write_bytes((base/'vocab.txt').read_bytes());(out/'fit.json').write_text(json.dumps(result,indent=2)+'\n')
if __name__=='__main__':
    p=argparse.ArgumentParser();[p.add_argument(a,type=Path) for a in ('work','base','out')];train(**vars(p.parse_args()))
