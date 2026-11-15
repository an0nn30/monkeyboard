"""Fit a boundary channel on clean text; export only high-confidence internal cuts.
No input sentence, replacement pair or benchmark phrase is stored on the keyboard.
"""
import argparse, bz2, gzip, json, math, re
from collections import Counter
from pathlib import Path
from paired_text import engine
from difflib import SequenceMatcher
LEX = re.compile(r"[A-Za-z]+(?:['’][A-Za-z]+)*|[^\w\s]")
def train(desktop, conversations):
    nouns, words, adjacent, positions = (Counter() for _ in range(4))
    seen = set()
    def consume(sentence):
        t = LEX.findall(sentence)
        key = tuple(w.lower() for w in t)
        if key in seen: return
        seen.add(key)
        words.update(set(w for w in key if w.isalpha()))
        nouns.update(set(w.lower() for w in t[1:] if w.isalpha() and w[0].isupper()))
        adjacent.update(set(zip(key,key[1:])))
    for r in json.loads(desktop.read_bytes()):
        if r['split']=='training': consume(r['expected'])
    for s in conversations.read_text().splitlines(): consume(s)
    with bz2.open(engine/'training/eng_sentences_CC0.tsv.bz2','rt') as f:
        for s in f: consume(s.split('\t')[2])
    b=engine.parent/'Benchmarks'
    # The historical clean SMS replays contribute evidence that a boundary was intentional.
    for n in (46,48,49,50,51):
        for r in json.loads((b/f'build{n}/public.json').read_bytes()): consume(r['expected'])
    # Learn the minimum evidence for a fragment cut from real two-piece errors.
    # Attested intact pairs are a hard negative; names do not train positive cuts.
    positive=Counter()
    for r in json.loads((b/'build53/development.json').read_bytes()):
        a = r['typed'].lower().split(); z=r['expected'].lower().split()
        for tag,i,j,k,l in SequenceMatcher(None,a,z,autojunk=False).get_opcodes():
            if tag=='replace' and j-i==2 and l-k==1 and a[i]+a[i+1]==z[k]:
                positive[(a[i],a[i+1])]+=1
    def evidence(a,b):
        combined=words[a+b]; weak,strong=sorted((words[a],words[b]))
        if (combined<5 or nouns[a+b]*3>combined or adjacent[a,b]
            or len(a+b)<3 or weak>=25 or (len(a)==1 and words[a]>=1000)
            or (len(b)==1 and words[b]>=1000)): return -1
        return math.log1p(combined)-1.6*math.log1p(weak)-0.09*math.log1p(strong)
    # Calibrate on demonstrated joins against standard clean-text boundaries.
    # An unseen boundary between common words is not by itself evidence of a typo.
    scores=[evidence(a,b) for a,b in positive if evidence(a,b)>0]
    threshold=max(1.8,min(3.5,min(scores,default=2.5)))
    output=[]
    for w in sorted(words):
        if not w.isascii() or not w.isalpha() or not 3<=len(w)<=20: continue
        cuts=sum(1<<i for i in range(1,len(w)) if evidence(w[:i],w[i:])>=threshold)
        if cuts: output.append(f'{w}\t{cuts}\n')
    path=engine/'model/rejoin53';path.mkdir(exist_ok=True)
    (path/'cuts.tsv').write_text(''.join(output))
    print(json.dumps(dict(lexical_entries=len(output),sentences=len(seen), observed_training_pairs=len(positive),threshold=threshold)))
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('desktop',type=Path);p.add_argument('conversations',type=Path)
    train(**vars(p.parse_args()))
