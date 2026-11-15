"""Fit a contextual wrong-word detector on synthetic substitutions in public text."""
import argparse
import bz2
import json
import random
import re
from collections import defaultdict
from functools import lru_cache
from pathlib import Path

import cmudict
import numpy as np
import torch
from rapidfuzz.distance import DamerauLevenshtein
from transformers import RobertaForMaskedLM, RobertaTokenizerFast
from wordfreq import top_n_list, zipf_frequency

LAYERS = (4, 8, 12)
WORDS = re.compile(r"[A-Za-z]+(?:'[A-Za-z]+)*")


def make_pairs(corpus, dialogue, count, seed):
    rng = random.Random(seed)
    lines = [r.split('\t')[2] for r in bz2.open(corpus, "rt")]
    if dialogue:
        extra = [u["text"] for d in json.loads(dialogue.read_text()) for u in d["utterances"]]
        rng.shuffle(extra)
        lines.extend(extra[:len(lines) // 2])
    lines = list(dict.fromkeys(lines))
    rng.shuffle(lines)
    freq = {w: zipf_frequency(w, "en") for w in top_n_list("en", 60000)
            if len(w) >= 2 and w.isascii() and WORDS.fullmatch(w)}
    deletion = defaultdict(set)
    for w in freq:
        deletion[w].add(w)
        for i in range(len(w)):
            deletion[w[:i] + w[i + 1:]].add(w)
    phones = cmudict.dict()
    groups = defaultdict(set)
    def phonetic(p):
        return tuple(x.rstrip("012") for x in p)
    for w in freq:
        for p in phones.get(w, []):
            groups[phonetic(p)].add(w)
    @lru_cache(None)
    def choices(w):
        found = set(deletion[w])
        for i in range(len(w)):
            found.update(deletion[w[:i] + w[i + 1:]])
        found = {k for k in found if k != w and DamerauLevenshtein.distance(k, w, score_cutoff=1) <= 1}
        for p in phones.get(w, []):
            found.update(groups[phonetic(p)])
        found.discard(w)
        return sorted(found)
    pairs = []
    for line in lines:
        if not (4 <= len(line.split()) <= 24) or len(line) > 180:
            continue
        spans = [m for m in WORDS.finditer(line) if m.group().lower() in freq and m.group().islower()]
        if not spans:
            continue
        # Sample across word frequencies, so a sentence's function words do not
        # dominate the examples of genuine content-word confusions.
        rng.shuffle(spans)
        targets = sorted(spans, key=lambda m: rng.random() + 0.18 * max(0, freq[m.group()] - 5.5))
        for match in targets:
            source = match.group()
            pool = choices(source)
            if not pool:
                continue
            weights = [0.08 + 1 / (1 + (freq[w] - freq[source]) ** 2) for w in pool]
            bad = rng.choices(pool, weights=weights, k=1)[0]
            a, b = match.span()
            pairs.append((line, a, b, bad))
            break
        if len(pairs) >= count: break
    return pairs


@torch.inference_mode()
def features(pairs, checkpoint, layers):
    tok = RobertaTokenizerFast.from_pretrained(checkpoint)
    model = RobertaForMaskedLM.from_pretrained(checkpoint,attn_implementation="eager").eval().to("mps")
    rows = []
    for line, a, b, bad in pairs:
        for text, right in [(line,b),(line[:a]+bad+line[b:],a+len(bad))]:
            rows.append((text,a,right))
    features = []
    for k in range(0,len(rows),64):
        batch = rows[k:k+64]
        enc = tok([r[0] for r in batch],return_offsets_mapping=True,return_tensors="pt",padding=True)
        ids = enc.input_ids.to("mps")
        positions = []
        for offsets,(_,a,b) in zip(enc.offset_mapping.tolist(),batch):
            target = [i for i,(left,right) in enumerate(offsets) if right>a and left<b and right>left]
            assert target
            positions.append([float(i in target)/len(target) for i in range(len(offsets))])
        weights = torch.tensor(positions,device="mps").unsqueeze(-1)
        states = model.roberta(ids, attention_mask=ids.ne(1), output_hidden_states=True).hidden_states
        vector = torch.cat([(states[j]*weights).sum(dim=1) for j in layers],dim=-1)
        features.append(vector.cpu().half().numpy())
        if k % 6400 == 0: print("encoded",k,"of",len(rows),flush=True)
    return np.concatenate(features).reshape(len(pairs),2,-1)


def fit(feat, output):
    torch.manual_seed(5613)
    device = "mps"
    split = int(len(feat)*0.94)
    x = torch.from_numpy(feat).float().to(device)
    mean = x[:split].mean((0,1)); std=x[:split].std((0,1)).clamp(min=0.03)
    x = (x-mean)/std
    width = x.shape[-1]
    head = torch.nn.Sequential(torch.nn.Linear(width,192),torch.nn.GELU(),torch.nn.Dropout(0.15),
                               torch.nn.Linear(192,1)).to(device)
    opt=torch.optim.AdamW(head.parameters(),lr=.0005,weight_decay=.015)
    best = -1
    for epoch in range(10):
        head.train()
        for index in torch.randperm(split,device=device).split(256):
            y=head(x[index]).squeeze(-1)
            loss=(torch.nn.functional.softplus(y[:,0]-y[:,1]).mean()+
                  0.35*(torch.nn.functional.softplus(y[:,0]).mean()+torch.nn.functional.softplus(-y[:,1]).mean()))
            opt.zero_grad();loss.backward();opt.step()
        head.eval()
        with torch.no_grad():
            y=head(x[split:]).squeeze(-1)
            pair=(y[:,1]>y[:,0]).float().mean().item()
            true_pos=(y[:,1]>0).float().mean().item()
            true_neg=(y[:,0]<0).float().mean().item()
            print(epoch,"pair",pair,"sensitivity",true_pos,"specificity",true_neg,flush=True)
            score=pair+0.25*(true_pos+true_neg)
            if score>best:
                best=score
                torch.save({"mean":mean.cpu(),"std":std.cpu(),"layers":LAYERS,
                            "weights":{k:v.cpu() for k,v in head.state_dict().items()}},output)


if __name__=="__main__":
    p=argparse.ArgumentParser()
    p.add_argument("checkpoint",type=Path);p.add_argument("corpus",type=Path);p.add_argument("work",type=Path)
    p.add_argument("--dialogue",type=Path);p.add_argument("--count",type=int,default=42000)
    args=p.parse_args();args.work.mkdir(parents=True,exist_ok=True)
    pairs=make_pairs(args.corpus,args.dialogue,args.count,5613)
    print("pairs",len(pairs),flush=True)
    data=features(pairs,args.checkpoint,LAYERS);fit(data,args.work/"detector.pt")
