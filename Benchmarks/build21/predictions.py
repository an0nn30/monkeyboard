"""Choose one next word per intact blind sentence without filtering to the model vocabulary."""
import csv,hashlib,json,re,sys
from pathlib import Path
def cases(file):
    for r in csv.DictReader(file.open(),delimiter='\t'):
        if r['typed']!=r['expected']:continue
        words=list(re.finditer(r"[A-Za-z]+(?:'[A-Za-z]+)*",r['expected']))
        if len(words)<4:continue
        j=2+int.from_bytes(hashlib.sha256(r['id'].encode()).digest()[:4],'big')%(len(words)-2)
        yield {'id':r['id'],'prompt':r['expected'][:words[j].start()],'expected':words[j][0].lower()}
if __name__=='__main__':
    f=Path(sys.argv[1]);rows=list(cases(f))
    if len(sys.argv)==2:print(json.dumps(rows))
    else:
        for path in sys.argv[2:]:
            raw=[json.loads(l) for l in Path(path).read_text().splitlines()];d={r['id']:[w.lower() for w in r['guesses']] for r in raw}
            assert len(raw)==len(d)==len(rows) and set(d)=={r['id'] for r in rows}
            print(path,len(rows),*[sum(r['expected'] in d[r['id']][:k] for r in rows) for k in (1,3)])
