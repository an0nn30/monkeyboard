"""Learn short context contrasts and literal protection from independent clean text.
Only aggregate context features surviving multi-message thresholds are exported.
The first fresh round is development; never read the second challenge here.
"""
import argparse
import json
from collections import Counter, defaultdict
from pathlib import Path
from real25 import source_rows
from paired_text import engine, tokens

def features(ws, i, classes):
    a,b=(['^','^']+ws[:i])[-2:]
    d,e=(ws[i+1:]+['$','$'])[:2]
    # Strong evidence needs two adjacent context words. The broader features
    # discriminate only in combination with an independent feature at runtime.
    return (f'1:{a}/{b}', f'2:{b}/{d}', f'3:{d}/{e}', f'4:{b}', f'5:{d}',
            f'6:{classes.get(b,"?")}/{d}', f'7:{b}/{classes.get(d,"?")}')

def train(paired, taskmaster, sms):
    rows = source_rows(taskmaster, paired, sms)
    pairs={tuple(l.split('\t')[:2]) for l in (engine/'model/contrast42/models.tsv').read_text().splitlines()}
    source=engine.parent/'Benchmarks/build41/fresh.json'
    for r in json.loads(source.read_bytes()):
        if r['kind']=='context':
            a,b=tokens(r['typed']),tokens(r['expected'])
            if len(a)==len(b):pairs.update((w,z) for w,z in zip(a,b) if w!=z)
    # Include all contrasts on which the first development pass harmed a literal.
    from gzip import open as gzopen
    with gzopen(engine.parent/'Benchmarks/build44/fresh-44.jsonl.gz','rt') as f: old={r['id']:r['final'] for r in map(json.loads,f)}
    for r in json.loads(source.read_bytes()):
        if r['typed']==r['expected']:
            a,b=tokens(r['typed']),tokens(old[r['id']])
            if len(a)==len(b):pairs.update((w,z) for w,z in zip(a,b) if w!=z)
    tracked={w for e in pairs for w in e}
    classes=dict(l.split('\t') for l in (engine/'model/cloze27/vocab.tsv').read_text().splitlines())
    counts=defaultdict(Counter); messages=Counter()
    for s,_ in rows:
        ws=s.split(); seen=set()
        for i,w in enumerate(ws):
            if w not in tracked:continue
            for f in features(ws,i,classes):
                if '?' not in f:seen.add((w,f))
        messages.update({w for w,_ in seen})
        for w,f in seen:counts[w][f]+=1
    # Each local feature is fit against both meanings. Score ratios with
    # capped class balancing; common literal contexts must retain their vote.
    data=[]
    for x,y in sorted(pairs):
        for f in sorted(counts[x].keys()|counts[y].keys()):
            a,b=counts[x][f],counts[y][f]
            if max(a,b)<3:continue
            prior=min(32.,max(1/32.,messages[y]/max(messages[x],1)))
            # Shrink sparse contexts toward the overall odds for these words.
            # A common word must exceed its prior before it gets any votes.
            lift=(b+max(1.,prior))/(a+max(1.,1/prior))/prior
            ratio=max(lift,1/lift)
            if ratio < 4 or (b if lift>1 else a)<3:continue
            vote=3 if ratio>=10 else 2 if ratio>=6 else 1
            if f[0] in '4567' and ratio<8:continue
            # Single-word support cannot on its own trigger a change.
            data.append(f'{x}\t{y}\t{f}\t{vote if lift>1 else -vote}\n')
    dest=engine/'model/evidence45';dest.mkdir(exist_ok=True)
    import struct
    keys=sorted({line.split('\t')[2] for line in data})
    ids={v:i for i,v in enumerate(keys)}
    blocks=defaultdict(list)
    for line in data:
        x,y,f,n=line.rstrip().split('\t');blocks[x,y].append((ids[f],int(n)))
    packed=bytearray(); inventory=[]
    for (x,y), rows_ in sorted(blocks.items()):
        inventory.append(f'{x}\t{y}\t{len(packed)//5}\t{len(rows_)}\n')
        for ix,v in sorted(rows_):packed.extend(struct.pack('<Ib',ix,v))
    (dest/'keys.txt').write_text('\n'.join(keys)+'\n')
    (dest/'headers.tsv').write_text(''.join(inventory))
    (dest/'votes.bin').write_bytes(packed)
    (dest/'fit.json').write_text(json.dumps(dict(clean_messages=len(rows),directions=len(pairs),features=len(data)),indent=2)+'\n')
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    for a in ('paired','taskmaster','sms'):p.add_argument(a,type=Path)
    train(**vars(p.parse_args()))
