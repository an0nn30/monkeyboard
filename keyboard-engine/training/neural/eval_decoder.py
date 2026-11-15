"""Offline 15M research arm. Reuse exactly the eligible simulator candidates and old commits."""
import argparse, csv, json, re, sys
from pathlib import Path
import torch
from networks import Decoder, T
base=Path(__file__).resolve().parents[3]/"Benchmarks/build10"
sys.path.insert(0,str(base))
from calibrate import winner
a=argparse.ArgumentParser()
a.add_argument("checkpoint",type=Path);a.add_argument("detail",type=Path)
a.add_argument("baseline",type=Path);a.add_argument("out",type=Path)
a.add_argument("--window",type=int,default=T)
a.add_argument("--policy",nargs=3,type=float,default=[3.5,3.,3.])
a.add_argument("--dump",type=Path)
args=a.parse_args()
torch.set_num_threads(4)
m=Decoder().eval();m.load_state_dict(torch.load(args.checkpoint/"decoder.pt",map_location="cpu",weights_only=True))
vocab=(args.checkpoint/"vocab.txt").read_text().splitlines();ids={w:i for i,w in enumerate(vocab)}
pool=json.loads(args.detail.read_text()); full=list(csv.DictReader(args.baseline.open(),delimiter="\t"))
assert [r['input'] for r in pool]==[r['context'] for r in full]
reviewed=set((base.parents[1]/"keyboard-engine/training/display-words.txt").read_text().split())
reviewed.update((base.parents[1]/"keyboard-engine/training/texting-display-words.txt").read_text().split())
reviewedids=torch.tensor(sorted(ids[w] for w in reviewed if w in ids))
with torch.inference_mode():
    for row,old in zip(pool,full):
        if 'pool' not in row and row['kind']!='next':continue
        ctx=row.get("leading",row['input'])
        ts=re.findall(r"[a-z]+(?:'[a-z]+)*",re.split(r"[.!?\n]",ctx)[-1].lower().replace("’","'"))
        ix=([1]+[ids.get(w,0) for w in ts])[-min(T,args.window):]
        if not ts:continue
        logits=m(torch.tensor([ix]))[0,-1]
        if row['kind']=='next':
            old['candidate']="|".join(vocab[reviewedids[k]] for k in logits[reviewedids].topk(3).indices)
        else:
            for w in row['pool']:
                w['score']=float(logits[ids[w['word']]]) if w['word'] in ids else None
            old['candidate']=winner(row,old['candidate'],*args.policy)
with args.out.open("w") as f:
    writer=csv.DictWriter(f,fieldnames=full[0].keys(),delimiter="\t",lineterminator="\n");writer.writeheader();writer.writerows(full)
if args.dump:args.dump.write_text(json.dumps(pool))
