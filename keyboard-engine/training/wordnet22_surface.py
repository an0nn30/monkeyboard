"""Learn usual display casing and local grammatical support from distinct clean training lines."""
from pathlib import Path
import hashlib,sys,re
from collections import Counter,defaultdict
from paired_text import key,pairs,engine
def fit(path):
    import csv
    protected={key(' '.join((r['left'],r['gold'].split('|')[0],r['right']))) for n in (15,16)
               for r in csv.DictReader((engine.parent/f'Benchmarks/build{n}/cases.tsv').open(),delimiter='\t')}
    c=defaultdict(Counter);seen=set();words=set((engine/'model/wordnet22/vocab.txt').read_text().splitlines());ng=Counter()
    for _,text in pairs(path):
        k=key(text)
        if k in seen or k in protected or hashlib.sha256(k.encode()).digest()[0]<38:continue
        seen.add(k);ss=re.findall(r"[A-Za-z]+(?:'[A-Za-z]+)*",text.replace('’',"'"));ws=['^','^']+[w.lower() for w in ss]+['$']
        for i,w in enumerate(ss):
            if i>0 or w.lower()=='i' or w.lower().startswith("i'"):c[w.lower()][w]+=1
        for i in range(2,len(ws)):
            ng.update({tuple(ws[i-n+1:i+1]) for n in (2,3)})
    out=engine/'model/wordnet22'
    with (out/'forms.tsv').open('w') as f:
        for w in sorted(words):
            if c[w]:
                v,n=c[w].most_common(1)[0]
                if v!=w and n>=3 and n/sum(c[w].values())>=.95:f.write(f'{w}\t{v}\n')
    (out/'context.tsv').write_text(''.join(' '.join(t)+'\t'+str(n)+'\n' for t,n in sorted(ng.items(),key=lambda item:' '.join(item[0])) if n>=2))
if __name__=='__main__':fit(Path(sys.argv[1]))
