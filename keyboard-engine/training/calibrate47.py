"""Calibrate only the exported decision margins, keeping build 42 reproducible."""
import shutil
from calibrate40 import calibrate, engine
base=engine.parent/'Benchmarks'
dest=engine/'model/contrast47'
dest.mkdir(exist_ok=True)
shutil.copyfile(engine/'model/contrast42/models.tsv',dest/'models.tsv')
# The features and weights remain identical. Put them in a temporary directory
# for the calibrator; ship only the revised thresholds.
import tempfile
from pathlib import Path
with tempfile.TemporaryDirectory() as d:
    p=Path(d)
    for name in ('features.txt','weights.bin','fit.json','models.tsv'):
        shutil.copyfile(engine/'model/contrast42'/name,p/name)
    for cases,old in [(base/'build41/fresh.json',base/'build44/fresh-40.jsonl.gz'),
                      (base/'build46/public.json',base/'build46/public-40.jsonl.gz')]:
        calibrate(cases,old,output=p,reset=False)
    # A common threshold cannot always separate both senses. Keep the previous
    # threshold if raising it would erase a verified build-40 positive.
    import json, struct
    from contrast40 import context, features
    from paired_text import tokens
    cls=dict(l.split('\t') for l in (engine/'model/cloze27/vocab.tsv').read_text().splitlines())
    keys=(p/'features.txt').read_text().splitlines(); weights=(p/'weights.bin').read_bytes()
    old={tuple(l.split('\t')[:2]):l.split('\t')[2] for l in (engine/'model/contrast42/models.tsv').read_text().splitlines()}
    witnesses={}
    for r in json.loads((base/'build41/regressions.json').read_bytes()):
        if r['kind']!='six':continue
        ws=tokens(r['expected']); ts=tokens(r['typed'])
        for i,(a,b) in enumerate(zip(ts,ws)):
            if a!=b:witnesses.setdefault((a,b),[]).append((ws,i))
    lines=[]
    for l in (p/'models.tsv').read_text().splitlines():
        a,b,thr,pos,n=l.split('\t');orig=old[a,b]
        if (a,b) in witnesses and float(thr)>float(orig):
            w={keys[k]:v for k,v in struct.iter_unpack('<Ih',weights[int(pos)*6:(int(pos)+int(n))*6])}
            for ws,i in witnesses[a,b]:
                scores=[sum(w.get(f,0) for f in features(context(ws,i,nright),cls)) for nright in (1,2)]
                if max(scores) < round(100*float(thr)) or any(round(100*float(orig))<=v<round(100*float(thr)) for v in scores):
                    thr=orig;break
        lines.append('\t'.join([a,b,thr,pos,n]))
    (dest/'models.tsv').write_text('\n'.join(lines)+'\n')
