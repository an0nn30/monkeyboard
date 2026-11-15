"""Train the build-10 causal sentence scorer. Never reads keyboard/user input."""
import argparse, bz2, collections, hashlib, json, math, random, re, struct, time
from pathlib import Path
import numpy as np
import torch
from torch import nn
from torch.nn import functional as F

root = Path(__file__).resolve().parents[2]
D, V, T = 64, 8192, 32
parser = argparse.ArgumentParser()
parser.add_argument("taskmaster", type=Path)
parser.add_argument("--output", type=Path, default=root / "model/neural")
parser.add_argument("--epochs", type=int, default=7)
parser.add_argument("--device", default="mps" if torch.backends.mps.is_available() else "cpu")
parser.add_argument("--transformer", action="store_true", help="Research arm: 15M parameter causal decoder")
args = parser.parse_args()
if args.transformer and args.output == root / "model/neural":
    parser.error("--transformer requires a separate --output directory")
rng = random.Random(4178)
torch.manual_seed(4178)
torch.set_num_threads(6)
def digest(s): return hashlib.sha256(s.encode()).digest()
def words(s): return re.findall(r"[a-z]+(?:'[a-z]+)*", s.lower().replace("’", "'"))
def checked(path, hexdigest):
    assert hashlib.sha256(path.read_bytes()).hexdigest() == hexdigest, path
    return path
# Exclude the existing held-out split by sentence or whole dialogue. Reserve a
# separate validation bucket from the remainder for early stopping, not the typing benchmark.
train, dev, excluded = set(), set(), set()
def add(s, bucket):
    if len(s)>200 or re.search(r"[@#/<>0-9]", s): return
    ts = words(s)
    if not 3 <= len(ts) <= T: return
    key = " ".join(ts)
    (excluded if bucket < 26 else dev if bucket < 35 else train).add(key)
path = checked(root / "training/eng_sentences_CC0.tsv.bz2", "c2e2edd063a31cbbc8e416a4858225e934bbb0afff485031821e59f230ccf1ca")
for row in bz2.open(path, "rt"):
    _, lang, s, _ = row.rstrip("\n").split("\t", 3)
    if lang == "eng": add(s, digest(" ".join(words(s)))[0])
for dialog in json.loads(checked(args.taskmaster, "1e590ed0ccee279e40c2fb9e083d3b9417477c6bfe35ce5b2277167698dd858d").read_text()):
    for u in dialog["utterances"]:
        if u["speaker"] == "USER":
            for s in re.split(r"[.!?;:]",u["text"]): add(s,digest(dialog["conversation_id"])[0])
train = sorted(train - dev - excluded); dev = sorted(dev - excluded)
freq = collections.Counter(w for s in train for w in s.split())
vocab = ["<unk>", "<start>"] + [w for w,n in sorted(freq.items(),key=lambda x:(-x[1],x[0]))[:V-2]]
V = len(vocab); lookup = {w:i for i,w in enumerate(vocab)}
def data(sentences):
    return [[1] + [lookup.get(w,0) for w in s.split()] for s in sentences]
tr = data(train); va = data(dev)
print("sentences:",len(tr),len(va),"vocab:", V, "device:",args.device,flush=True)
from networks import CausalLM, Decoder
assert V == 8192
model=(Decoder() if args.transformer else CausalLM()).to(args.device)
print("parameters:",sum(p.numel() for p in model.parameters()),flush=True)
opt=torch.optim.AdamW(model.parameters(),lr=.0007 if args.transformer else .003)
def epoch(dataset, train):
    model.train(train); total=n=0
    # Length buckets reduce wasted output projection on padding.
    ids=list(range(len(dataset))); rng.shuffle(ids); batches=[]
    for start in range(0,len(ids),4096):
        chunk=sorted(ids[start:start+4096],key=lambda i:len(dataset[i]))
        batches.extend([chunk[j:j+96] for j in range(0,len(chunk),96)])
    rng.shuffle(batches)
    with torch.set_grad_enabled(train):
        for batch in batches:
            seq=[dataset[i] for i in batch]; t=max(map(len,seq))
            mat=np.zeros((len(seq),t), dtype=np.int64)
            for i,s in enumerate(seq): mat[i,:len(s)]=s
            ten=torch.from_numpy(mat).to(args.device)
            logits=model(ten[:,:-1])
            loss=F.cross_entropy(logits.reshape(-1,V),ten[:,1:].reshape(-1),ignore_index=0)
            if train:
                opt.zero_grad(set_to_none=True); loss.backward(); nn.utils.clip_grad_norm_(model.parameters(),2.); opt.step()
            count=np.count_nonzero(mat[:,1:]);total+=loss.item()*count;n+=count
    return total/n
def export():
    dest=args.output; dest.mkdir(exist_ok=True,parents=True)
    (dest/"vocab.txt").write_text("\n".join(vocab)+"\n")
    if args.transformer:
        torch.save({k:v.detach().cpu().half() for k,v in model.state_dict().items()},dest/"decoder.pt")
        return
    cpu=lambda p:p.detach().cpu()
    E=cpu(model.e.weight)
    # Pre-project the type-specific keys/queries/values offline. Runtime only
    # scores requested spelling candidates, never a V-wide softmax.
    params=[E,F.linear(E,cpu(model.q.weight)),F.linear(E,cpu(model.k.weight)),F.linear(E,cpu(model.v.weight)),cpu(model.h.weight),cpu(model.h.bias),cpu(model.out.weight),cpu(model.out.bias)]
    blob=struct.pack("<4sII",b"MBS1",V,D)
    for p in params:
        a=p.numpy().astype("float32"); scale=max(float(np.max(np.abs(a)))/127,1e-9)
        blob+=struct.pack("<f",scale)+np.rint(a/scale).clip(-127,127).astype("int8").tobytes()
    (dest/"weights.tmp").write_bytes(blob);(dest/"weights.tmp").replace(dest/"weights.i8")
best=float("inf")
for e in range(args.epochs):
    t=time.monotonic(); a=epoch(tr,True); b=epoch(va,False)
    print(f"epoch={e+1} train_nll={a:.4f} validation_nll={b:.4f} secs={time.monotonic()-t:.1f}",flush=True)
    if b < best: best=b;export()
    else: break
    if e>=2:
        for pg in opt.param_groups: pg['lr']*=.72
