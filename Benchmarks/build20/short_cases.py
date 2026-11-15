"""Freeze actual short-word errors and controls from the paired data's reserved partition."""
import csv,hashlib,re,sys
from collections import Counter
from pathlib import Path
from difflib import SequenceMatcher
from make_cases import key, pairs, here, sha
def generate(src):
    used=set()
    for f in here.parent.rglob('*.tsv'):
        if f.name=='short.tsv' and f.parent==here:continue
        for r in csv.DictReader(f.open(),delimiter='\t'):
            for col in ('expected','typed','context','sentence'):
                if r.get(col):used.add(key(r[col]))
            if all(x in r for x in ['left','right','gold']):used.add(key(' '.join([r['left'],r['gold'].split('|')[0],r['right']])))
    # Corrected reference sentences in the paired reserve have already been
    # exhausted by builds 16–19. Test fresh error locations (typed, target),
    # and report previously seen references explicitly as regression material.
    previous_gold=used.copy()
    used=set()
    for f in here.parent.rglob('*.tsv'):
        if f.parent==here and f.name=='short.tsv':continue
        for r in csv.DictReader(f.open(),delimiter='\t'):
            if r.get('typed') and r.get('expected'):used.add((key(r['typed']),key(r['expected'])))
    train=set()
    for a,b in pairs(src):
        if sha(key(b))[0]>=38:train.add(key(b))
    pool=[]
    pat=r"[^\W_]+(?:['’][^\W_]+)*"
    for idx,(a,b) in enumerate(pairs(src)):
        k=key(b)
        if sha(k)[0]>=38 or k in train or not 4<=len(k.split())<=28:continue
        x=list(re.finditer(pat,a));y=list(re.finditer(pat,b))
        A=[m[0].lower() for m in x]; B=[m[0].lower() for m in y]
        for tag,i,j,m,n in SequenceMatcher(None,A,B,autojunk=False).get_opcodes():
            if tag=='replace' and j-i==n-m==1 and 2<=len(A[i])<=3 and 1<=len(B[m])<=4 and A[i].isascii() and A[i].isalpha() and B[m].isalpha() and x[i][0].islower() and y[m][0].islower():
                start,end=y[m].span();typed=b[:start]+x[i][0]+b[end:]
                pool.append((sha(str(idx)+'short audit'),k,x[i][0]+'-'+y[m][0],typed,b,m))
        pool.append((sha(str(idx)+'short clean'),k,'clean','',b,''))
    count=Counter();rows=[]; kinds=set();seen=set()
    for _,k,kind,t,b,slot in sorted(pool,key=lambda r:(r[2]=='clean',r[0])):
        if k in seen or count[kind]>=(240 if kind=='clean' else 8) or (key(t or b),k) in used:continue
        if kind!='clean':kinds.add(kind)
        count[kind]+=1;rows.append(('short-'+str(len(rows)),'paired-reused-reference' if k in previous_gold else 'paired-new-reference',kind,t or b,b,'',slot));seen.add(k)
    with (here/'short.tsv').open('w') as f:
        w=csv.writer(f,delimiter='\t',lineterminator='\n');w.writerow(['id','split','kind','typed','expected','gap','slot']);w.writerows(rows)
    print(len(rows),'sentences;',len(kinds),'distinct errors;',count['clean'],'clean')
if __name__=='__main__':generate(Path(sys.argv[1]))
