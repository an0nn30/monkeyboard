"""Deterministic, synthetic keyboard slips in unseen CC0 sentences; separate calibration/evaluation."""
import bz2, hashlib, re, random
from pathlib import Path
p=Path(__file__).resolve().parent
source=p.parents[1]/"keyboard-engine/training/eng_sentences_CC0.tsv.bz2"
assert hashlib.sha256(source.read_bytes()).hexdigest()=="c2e2edd063a31cbbc8e416a4858225e934bbb0afff485031821e59f230ccf1ca"
rows=["qwertyuiop","asdfghjkl","zxcvbnm"]
coords={c:(j+off,i) for i,(row,off) in enumerate(zip(rows,[0,.5,1.2])) for j,c in enumerate(row)}
neighbors={c:[k for k,(u,v) in coords.items() if 0<(u-x)**2+(v-y)**2<2.4] for c,(x,y) in coords.items()}
seen=set()
samples=[[],[]]
for line in bz2.open(source,"rt"):
    _,lang,s,_=line.rstrip("\n").split("\t",3)
    ts=re.findall(r"[a-z]+(?:'[a-z]+)*",s.lower().replace("’","'"))
    key=" ".join(ts); h=hashlib.sha256(key.encode()).digest()
    if h[0]>=26 or key in seen or not 7<=len(ts)<=25 or not re.fullmatch(r"[A-Za-z ,.!?'’-]+",s):continue
    seen.add(key); ww=ts[-1]
    if not 3<=len(ww)<=10 or not ww.isalpha():continue
    r=random.Random(h); i=r.randrange(len(ww)); kind=r.randrange(5)
    if kind==0: typo=ww[:i]+ww[i+1:]
    elif kind==1:
        j=min(i,len(ww)-2);typ=ww[j:j+2];typo=ww[:j]+typ[::-1]+ww[j+2:]
    elif kind==2: typo=ww[:i]+ww[i]+ww[i:]
    elif kind==3: typo=ww[:i]+r.choice(neighbors[ww[i]])+ww[i+1:]
    else: typo=ww
    if kind!=4 and ww==typo:continue
    samples[h[0]%2].append((h,("keep" if kind==4 else "fix")+"\t"+" ".join(ts[:-1]+[typo])+"\t"+ww))
for name,sample in zip(["development","replay"],samples):
    (p/(name+".tsv")).write_text("\n".join(s for _,s in sorted(sample)[384:1200])+"\n")
