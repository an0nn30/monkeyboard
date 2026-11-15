"""Test an independent replaced-token discriminator on proposed edits; no gold spans are sent to the model."""
from pathlib import Path
import argparse, json, gzip, re, sys
import numpy as np
import torch
from transformers import ElectraForPreTraining, BertTokenizerFast

def run(cp, logits, documents, dest):
    tok=BertTokenizerFast(vocab_file=str(cp/'vocab.txt'),do_lower_case=True)
    m=ElectraForPreTraining.from_pretrained(cp).eval().to('mps')
    out={x['id']:x['final'] for x in map(json.loads,gzip.open(documents,'rt'))}
    records=[]; questions={}
    for id,i,word,original,n,tops in json.loads(logits.read_text()):
        if not tops or tops[0][1] - original < -1:continue
        text=out[id]
        spans=list(re.finditer(r"[A-Za-z]+(?:['’][A-Za-z]+)*|[0-9]+|[^\sA-Za-z0-9]+",text))
        if i>=len(spans) or spans[i][0].lower()!=word.lower():continue
        start,end=spans[i].span(); row=[]
        for candidate,score in [(word,original)]+tops[:3]:
            line=text[:start]+candidate+text[end:]
            key=(line,start,start+len(candidate))
            questions.setdefault(key,None); row.append((candidate,score,key))
        records.append((id,i,word,n,row))
    qs=list(questions)
    for k in range(0,len(qs),64):
        chunk=qs[k:k+64]; t=tok([q[0] for q in chunk],padding=True,return_offsets_mapping=True,return_tensors='pt')
        offsets=t.pop('offset_mapping').numpy()
        with torch.inference_mode(): z=m(**{k:v.to('mps') for k,v in t.items()}).logits.cpu().numpy()
        for q,off,p in zip(chunk,offsets,z):
            mask=(off[:,0]>=q[1]) & (off[:,1]<=q[2]) & (off[:,1]>off[:,0])
            questions[q]=float(p[mask].mean()) if mask.any() else 0.
    dest.write_text(json.dumps([(id,i,w,n,[(c,s,questions[q]) for c,s,q in row]) for id,i,w,n,row in records]))
if __name__=='__main__':
    p=argparse.ArgumentParser()
    for x in ['cp','logits','documents','out']:p.add_argument(x,type=Path)
    a=p.parse_args();run(a.cp,a.logits,a.documents,a.out)
