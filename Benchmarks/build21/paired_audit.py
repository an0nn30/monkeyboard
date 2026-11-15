"""Select entire previously unevaluated texts from the reserved partition of the owner's S:/C: file."""
import csv, hashlib, random, sys, json, re
from pathlib import Path
here=Path(__file__).resolve().parent;root=here.parents[1]
sys.path.insert(0,str(root/'keyboard-engine/training'));from paired_text import key,pairs
def fixture(source):
    old=set()
    for f in here.parent.rglob('*.tsv'):
        if here in f.parents and f.name not in ('dev.tsv','blind.tsv'):continue
        for r in csv.DictReader(f.open(),delimiter='\t'):
            old.update(key(r[c]) for c in ('expected','typed','text','sentence','prompt') if r.get(c))
            if all(r.get(c) for c in ('left','gold','right')):old.add(key(' '.join([r['left'],r['gold'].split('|')[0],r['right']])))
    def h(s):return hashlib.sha256(s.encode()).digest()
    options={}
    for x,y in pairs(source):
        k=key(y)
        if h(k)[0]>=38 or k in old or key(x) in old or x==y or not 4<=len(k.split())<=25:continue
        if not re.fullmatch(r"[\w ’',.?!;-]+",x) or not re.fullmatch(r"[\w ’',.?!;-]+",y):continue
        options.setdefault(k,[]).append((x,y))
    rows=[];seen=set()
    for k in sorted(options,key=lambda s:h('unseen-paired-21/'+s)):
        if k in seen:continue
        x,y=sorted(options[k],key=lambda xy:h(xy[0]))[0];clean=len(rows)%3==0
        if key(x) in seen:continue
        rows.append(dict(id=f'paired-{len(rows)}',split='reserved',kind='clean' if clean else 'noisy',typed=y if clean else x,expected=y))
        seen.update([k,key(x)])
        if len(rows)==1350:break
    return rows
if __name__=='__main__':
    rows=fixture(Path(sys.argv[1]))
    with (here/'paired.tsv').open('w') as f:
        w=csv.DictWriter(f,fieldnames=rows[0],delimiter='\t',lineterminator='\n');w.writeheader();w.writerows(rows)
    Path(sys.argv[2]).write_text(json.dumps(rows));print(len(rows))
