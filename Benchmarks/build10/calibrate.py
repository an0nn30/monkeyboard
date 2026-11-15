"""Choose a conservative commit threshold on calibration only, then freeze it."""
import csv, json, sys, collections, itertools
def data(detail,base):
    rows=json.load(open(detail))
    orig=list(csv.DictReader(open(base),delimiter="\t"))
    assert [r["input"] for r in rows]==[r["context"] for r in orig]
    return list(zip(rows,[r['candidate'] for r in orig]))
def winner(r,base,margin,floor,prior):
    typed=r["typed"].lower()
    pool=r.get("pool",[])
    if not pool or not r['leading'].strip():return base
    scores=[]
    for i,w in enumerate(pool):
        if w['edits']>min(2,1+int(len(typed)>=6)):continue
        # Out-of-vocab guesses are real competitors; do not give them zero odds.
        x=(w['score'] if w['score'] is not None else 0.)-3.0*(w['edits']-1)
        x+=prior*(w['word']==base.lower())+.5/(1+i)
        scores.append((x,-i,w))
    scores.sort(key=lambda x:(x[0],x[1]),reverse=True)
    if not scores:return base
    s,_,w=scores[0]
    if w['score'] is None or w['score']<floor or s-max(0,scores[1][0] if len(scores)>1 else 0)<margin:return base
    out=w['word']
    return out.capitalize() if r['typed'][:1].isupper() else out
def metrics(rows,policy):
    win=lose=wrong=0
    for r,base in rows:
        new=policy(r,base);want=r['expected']
        win+=new==want and base!=want;lose+=base==want and new!=want
        wrong+=(new not in (r['typed'],want))-(base not in (r['typed'],want))
    return win,lose,wrong
if __name__=="__main__":
    rows=data(*sys.argv[1:3]); choices=[]
    for m,f,p in itertools.product((1.5,2.,2.5,3.,3.5,4.),(1.,2.,3.,4.),(1.,2.,3.)):
        w,l,x=metrics(rows,lambda r,b:winner(r,b,m,f,p))
        if x<=0 and l<=1:choices.append((w-l,-x,-l,m,f,p))
    print("gain, wrong changes prevented, lost correct, margin, floor, prior")
    print(sorted(choices,reverse=True)[:10])
