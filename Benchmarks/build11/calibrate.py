"""Select release margins on development rows, never on locked build-11 cases."""
import csv, json, re, sys, struct, itertools
from pathlib import Path
import numpy as np

root=Path(__file__).resolve().parents[2]
model=root/'keyboard-engine/model/semantics'
words=(model/'vocab.txt').read_text().splitlines()
ids={w:i for i,w in enumerate(words)}
vectors=np.frombuffer((model/'vectors.i8').read_bytes(),dtype='i1',offset=12).reshape(len(words),80).astype('float32')/127
freq={w:int(n) for w,n in (l.split() for l in (root/'keyboard-engine/model/words.tsv').read_text().splitlines())}
stop=set("will would could should might must want wanted went got get gets take took taking put found find just really also again there here today yesterday tomorrow still said told left right back front thing things sure make made think come came going before after when until around down over into near went last next way asked looking brought bring gave every another time upstairs downstairs something someone getting had have did done how him her his our was not the for its all that from with and are were mine can you this that those there what she one two".split())
det=set("the a an my your our their his her another this that".split())
def index(w):
    if w in ids:return ids[w]
    for end,rep in [('ies','y'),('es',''),('s',''),('ing',''),('ed','')]:
        if w.endswith(end) and (stem:=w[:-len(end)]+rep) in ids:return ids[stem]
def evidence(leading,candidates,typed):
    ts=re.findall("[a-z]+",re.split(r"[.!?\n]",leading.lower())[-1])[-128:]
    if not ts or ts[-1] not in det:return []
    cues=list(dict.fromkeys(index(w) for w in ts if len(w)>=3 and w not in stop and w not in det))
    cues=[i for i in cues if i is not None]
    if not cues:return []
    out=[]
    for i,c in enumerate(candidates):
        ix=index(c['word'])
        if ix is None or c['edits']!=1:continue
        sim=sorted((vectors[cues]@vectors[ix]).tolist(),reverse=True)
        # Same cue repeated many times does not create independent support.
        strength=sim[0]+.24*max(0,sim[1] if len(sim)>1 else 0) - .38 * (len(typed)!=len(c['word']))
        out.append((strength, -i,c['word'],sim[0]))
    return sorted(out,reverse=True)
def typoedit(a,b):
    if len(a)==len(b):
        return any(a[i]!=a[i+1] and a[:i]+a[i+1]+a[i]+a[i+2:]==b for i in range(len(a)-1))
    return len(a)==len(b)+1 and any(a[i]==a[i+1] and a[:i]+a[i+1:]==b for i in range(len(a)-1))
def slip(r,base):
    # Only if v10 abstained and the first dictionary/engine choice reverses
    # an adjacent swap or duplicated tap in a known word.
    p=r.get('pool',[]); t=r['typed'].lower()
    if base.lower()!=t or len(t)<5 or index(t) is not None or not p:return base
    w=p[0]['word']
    if freq.get(w,0)>=3 and typoedit(t,w):return w
    return base
def rows(detail,baseline):
    ds=json.load(open(detail));bs=list(csv.DictReader(open(baseline),delimiter='\t'))
    assert [d['input'] for d in ds]==[b['context'] for b in bs]
    out=[]
    for r,b in zip(ds,bs):
        base=b['candidate'].lower();lit=r['typed'].lower();fixed=slip(r,base)
        sem=evidence(r.get('leading',''),r.get('pool',[]),lit)
        out.append((r['expected'].lower(),lit,base,fixed,sem))
    return out
def decision(base,sem,minimum,margin):
    if len(sem)<2:return base
    s,_,w,peak=sem[0]; runner=sem[1][0]
    return w if peak>=minimum and s-runner>=margin else base
if __name__=='__main__':
    rs=rows(sys.argv[1],sys.argv[2])
    for minimum,margin in itertools.product((.45,.50,.55,.60,.65),(.12,.18,.24)):
        good=wrong=lost=0;changes=[]
        for expected,typed,base,sl,sem in rs:
            out=decision(sl,sem,minimum,margin) if len(typed)>=4 and not typoedit(typed,sl) and index(typed) is None else sl
            if out!=sl and len(out)!=len(typed):out=sl
            good+=int(out==expected)-int(base==expected)
            wrong+=int(out not in (expected,typed))-int(base not in (expected,typed))
            if out!=sl:changes.append((typed,sl,out,expected))
            lost+=out!=expected and base==expected
        print(minimum,margin,good,wrong,lost,changes[:8])
