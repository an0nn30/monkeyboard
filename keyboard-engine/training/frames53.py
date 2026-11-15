"""Induce discriminative local frames for the observed real-word errors.
Validate each direction on separate clean messages before allowing automatic edits.
"""
from collections import Counter,defaultdict
from pathlib import Path
import hashlib,json,math,struct,sys
from real25 import source_rows
from paired_text import engine
B=engine.parent/'Benchmarks'
def train(desktop,tm,sms):
    dev={r['id']:r for r in json.loads((B/'build53/development.json').read_bytes())}
    err=json.loads((B/'build53/old-failures.json').read_bytes())['typos']
    pairs={(r['typed'].lower(),r['target'].lower()) for r in err if dev[r['id']]['kind'] in ('context','public-real-word') and r['typed'] and r['typed'].isalpha() and r['target'].isalpha()}
    vocab={w for p in pairs for w in p}
    classes=dict(l.split('\t') for l in (engine/'model/cloze27/vocab.tsv').read_text().splitlines())
    def features(words,i):
        a,b=(['^','^']+words[:i])[-2:]
        d,e=(words[i+1:]+['$','$'])[:2]
        g=lambda w:classes.get(w,'?')
        return (f'0:{a}/{b}',f'1:{b}/{d}',f'2:{d}/{e}',f'3:{g(b)}/{d}',f'4:{b}/{g(d)}',f'5:{a}/{g(b)}/{g(d)}',f'6:{g(b)}/{g(d)}/{e}', f'7:{b}', f'8:{d}', f'9:{g(b)}/{g(d)}', f'A:{g(a)}/{g(b)}', f'B:{g(d)}/{g(e)}')
    counts=defaultdict(Counter);freq=Counter();val=defaultdict(list)
    for s,_ in source_rows(tm,desktop,sms):
        ws=s.split()
        sample=hashlib.sha256(('frames53/'+s).encode()).digest()[0]<42
        seen=set()
        for i,w in enumerate(ws[:-1]):
            if w in vocab:
                feat=features(ws,i);seen.update((w,f) for f in feat if '?' not in f and '$' not in f)
                if sample:val[w].append(feat)
        if not sample:
            for w,f in seen:counts[w][f]+=1
            freq.update({w for w,f in seen})
    data={}
    for x,y in sorted(pairs):
        tab={}
        for f in counts[x].keys()|counts[y].keys():
            a,b=counts[x][f],counts[y][f]
            # Evidence must be absolute and also unusual relative to each word's base rate.
            if max(a,b)<4:continue
            lift=math.log((b+.5)/(a+.5))-0.45*max(-3,min(3,math.log((freq[y]+1)/(freq[x]+1))))
            if abs(lift)<math.log(5):continue
            tab[f]=max(-9,min(9,round(lift*1.5)))
        def score(fs):
            v=[tab.get(f,0) for f in fs]; core=max(v[:3]); m=max(core,min(max(v[7],v[10]),max(v[8],v[11])))
            if min(v[:3]) < -1 or min(v) < -4 or m<3 or sum(t>=2 for t in v)<3 or max(v[1:7]+[v[8],v[9],v[11]])<2:return -1
            return m+sum(sorted(v,reverse=True)[:3])
        # In the calibration fold, contrasts are also tested as unmodified literals.
        neg=Counter(score(v) for v in val[x]);pos=Counter(score(v) for v in val[y])
        threshold=next((n for n in range(16,36) if sum(c for k,c in neg.items() if k>=n)==0 and sum(c for k,c in pos.items() if k>=n)>=3),None)
        if threshold:data[x,y]=(threshold,tab)
    dest=engine/'model/frames53';dest.mkdir(exist_ok=True)
    with (dest/'policy.tsv').open('w') as f:
        for (x,y),(t,tab) in data.items():
            for k,v in sorted(tab.items()):f.write(f'{x}\t{y}\t{t}\t{k}\t{v}\n')
    print('directions',len(pairs),'admitted',len(data),'entries',sum(len(t) for _,t in data.values()))
if __name__=='__main__':train(*[Path(p) for p in sys.argv[1:]])
