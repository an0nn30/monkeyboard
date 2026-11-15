"""Freeze the complete paired corpus, established training partition, and replay inputs."""
import argparse,csv,hashlib,json,re,sys
from pathlib import Path
from collections import Counter
H=Path(__file__).resolve().parent; ROOT=H.parents[1]
sys.path.insert(0,str(ROOT/'keyboard-engine/training'));from paired_text import pairs,key
def digest(s):return hashlib.sha256(s.encode()).digest()
def prepare(src,work):
    work.mkdir(exist_ok=True,parents=True)
    old=set()
    for f in (ROOT/'Benchmarks').rglob('*.tsv'):
        if H in f.parents:continue
        for r in csv.DictReader(f.open(),delimiter='\t'):
            for c in ('expected','typed','sentence','text','context','prompt'):
                if r.get(c):old.add(key(r[c]))
            if all(x in r for x in ('left','gold','right')):old.add(key(' '.join((r['left'],r['gold'].split('|')[0],r['right']))))
    allrows=[];groups=Counter();seen=set();fresh=[];clean=[];cleanseen=set()
    for i,(s,c) in enumerate(pairs(src)):
        part='training' if digest(key(c))[0]>=38 else 'reserved'
        r=dict(id=f'p{i:06d}',typed=s,expected=c,split=part);allrows.append(r);groups[part]+=1
        if part=='reserved':
            if key(c) not in old and key(s) not in old and key(c) not in seen and s!=c:
                fresh.append(r);seen.add(key(c))
            if c not in cleanseen:
                clean.append(dict(id=f'c{i:06d}',typed=c,expected=c,split='keep'));cleanseen.add(c)
    print(len(allrows),'pairs',groups,len({key(r['expected']) for r in allrows}),'unique references;',len(fresh),'completely unused reserved references;',len(clean),'distinct reserved clean controls')
    for label,rs in [('all',allrows),('unused',fresh),('clean',clean),('dev',[r for r in allrows if r['split']=='reserved' and digest(r['id'])[0]<12])]:
        (work/(label+'.json')).write_text(json.dumps(rs,ensure_ascii=False))
        if label == 'dev':
            with (work/'dev.tsv').open('w', newline='') as f:
                w = csv.DictWriter(f, fieldnames=['id','typed','expected','split'], delimiter='\t')
                w.writeheader()
                w.writerows(rs)
    for i in range(10):
        (work/f'all{i}.json').write_text(json.dumps(allrows[i*10000:(i+1)*10000],ensure_ascii=False))
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('src',type=Path);p.add_argument('work',type=Path);prepare(**vars(p.parse_args()))
