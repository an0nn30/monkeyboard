"""Compare restored word boundaries, collateral splits, and exact final text on matched cases."""
import csv, json, re
from collections import Counter, defaultdict
from difflib import SequenceMatcher
from pathlib import Path

here = Path(__file__).resolve().parent
def compact(text):
    # Ignore case for the boundary metric; exact text is scored separately.
    return ''.join(c.lower() for c in text if not c.isspace())

def measured(row, final):
    gold=row['expected']
    a,b=compact(gold),compact(final)
    correspondence={}
    for i,j,n in SequenceMatcher(None,a,b,autojunk=False).get_matching_blocks():
        for k in range(n):correspondence[i+k]=j+k
    def positions(s):
        return {len(compact(s[:m.start()])) for m in re.finditer(r'\s+',s)}
    out_gaps=positions(final)
    words=[(len(compact(gold[:m.start()])),len(compact(gold[:m.end()]))) for m in re.finditer(r"[^\W_]+(?:['’][^\W_]+)*",gold)]
    def mapped_word(start,end):
        first=correspondence.get(start)
        if first is None or any(correspondence.get(i)!=first+(i-start) for i in range(start,end)):return None
        return first
    wrong=0
    for s,e in words:
        p=mapped_word(s,e)
        if p is not None and any(i in out_gaps for i in range(p+1,p+e-s)):wrong+=1
    result={'cases':1,'exact':int(gold==final),'false_splits':wrong,'with_false_split':int(wrong>0)}
    if row['gap']!='':
        g=int(row['gap']);assert gold[g]==' ' and row['typed']==gold[:g]+gold[g+1:]
        point=len(compact(gold[:g]))
        s=next(s for s,e in words if e==point);e=next(e for s,e in words if s==point)
        p=mapped_word(s,e)
        # Both intended words must survive in full with just the correct internal space.
        # Require the outer token edges too, even when punctuation borders the words.
        good = p is not None and (p==0 or p in out_gaps or not b[p-1].isalnum()) and (
            p+e-s==len(b) or p+e-s in out_gaps or not b[p+e-s].isalnum()) and (
            {i for i in out_gaps if p<i<p+e-s}=={p+point-s})
        result['recovered']=int(good)
    return Counter(result)

def score(cases,paths):
    with cases.open() as f: rows=list(csv.DictReader(f,delimiter='\t'))
    ids={r['id'] for r in rows};assert len(ids)==len(rows)
    all_results=[]
    for path in paths:
        outputs=[json.loads(l) for l in path.read_text().splitlines()]
        out={r['id']:r['final'] for r in outputs}
        assert len(out)==len(outputs)==len(rows) and set(out)==ids
        all_results.append(out)
        groups=defaultdict(Counter)
        for row in rows:
            m=measured(row,out[row['id']])
            groups[row['split'],row['kind']].update(m);groups['all',row['kind']].update(m)
        for group,count in groups.items():print(path.stem,*group,dict(count),sep='\t')
    old,new=all_results
    for kind in ('noisy','clean'):
        units=[r for r in rows if r['kind']==kind]
        print(kind,'newly exact',sum(old[r['id']]!=r['expected']==new[r['id']] for r in units),
              'lost exact',sum(old[r['id']]==r['expected']!=new[r['id']] for r in units))

if __name__=='__main__':
    import argparse
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--cases',type=Path,default=here/'sentences.tsv')
    p.add_argument('paths',nargs=2,type=Path)
    args=p.parse_args();score(args.cases,args.paths)
