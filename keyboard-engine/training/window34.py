"""Fit a sparse local cloze model; export frequent three-neighbor features, never whole messages."""
from collections import Counter, defaultdict
import hashlib, re, struct, sys
from pathlib import Path
from paired_text import pairs, key, engine

OFFSETS = [(-2,-1,1),(-1,1,2),(-3,-2,-1),(1,2,3),(-2,1,2),(-2,-1,2)]
def fit(path):
    records=[];seen=set();freq=Counter();form=defaultdict(Counter)
    for raw,expected in pairs(path):
        k=key(expected)
        if k in seen or hashlib.sha256(k.encode()).digest()[0]<38:continue
        seen.add(k)
        words=re.findall(r"[A-Za-z]+(?:['’][A-Za-z]+)*", expected.replace('’',"'"))
        if len(words)<5:continue
        records.append([w.lower() for w in words]);freq.update(records[-1])
        for i,w in enumerate(words):
            if i>0:form[w.lower()][w]+=1
    vocab=[w for w in sorted(freq) if freq[w]>=2]
    ids={w:i+1 for i,w in enumerate(vocab)}; rows=defaultdict(Counter)
    for words in records:
        v=[ids.get(w,0) for w in words]
        for i,w in enumerate(v):
            if not w:continue
            for pat,offsets in enumerate(OFFSETS):
                if i+min(offsets)<0 or i+max(offsets)>=len(v):continue
                a,b,c=(v[i+d] for d in offsets)
                if min(a,b,c):rows[(pat,a,b,c)][w]+=1
    out=engine/'model/window34';out.mkdir(exist_ok=True)
    with (out/'vocab.tsv').open('w') as f:
        for w in vocab:
            pretty,n=(form[w].most_common(1) or [(w,0)])[0]
            f.write(f"{w}\t{pretty if n>=2 and n>=.95*sum(form[w].values()) else w}\n")
    with (out/'contexts.bin').open('wb') as f:
        n=0
        for (pat,a,b,c),counts in sorted(rows.items()):
            (target,hits),*rest=counts.most_common();total=counts.total();runner=rest[0][1] if rest else 0
            if hits<2 or hits<.93*total:continue
            f.write(struct.pack('<BHHHHBB',pat,a,b,c,target,min(hits,255),min(runner,255)));n+=1
    print(len(records),'unique lowercased training messages;',len(ids),'vocabulary;',n,'supported cloze rows')
if __name__=='__main__':fit(Path(sys.argv[1]))
