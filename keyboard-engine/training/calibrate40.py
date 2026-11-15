"""Raise contrast thresholds on old development sentences; never use build 40's blind benchmark.
Check the raw input and build 39's rendered text, as either can supply neighbors
while keypresses are arriving. Protect both original correct words and correct build 39 repairs; competing wrong targets are negatives.
Run after contrast40.py. Records conservative thresholds in models.tsv, not text.
"""
import argparse,gzip,json,re,sys,struct
from pathlib import Path
from collections import defaultdict
from contrast40 import OUT,features,context
from paired_text import engine,tokens
sys.path.insert(0,str(engine.parent/'Benchmarks/build22/blind'))
from score import alignment
def calibrate(fixture,baseline, *, output=OUT, reset=True):
    classes=dict(l.split('\t') for l in (engine/'model/cloze27/vocab.tsv').read_text().splitlines())
    keys=(output/'features.txt').read_text().splitlines();buf=(output/'weights.bin').read_bytes()
    models=[l.split('\t') for l in (output/'models.tsv').read_text().splitlines()];weights=defaultdict(list)
    for i,(a,b,threshold,pos,n) in enumerate(models):
        w={keys[k]:v for k,v in struct.iter_unpack('<Ih',buf[int(pos)*6:(int(pos)+int(n))*6])}
        weights[a].append((i,w))
    fit={(s['literal'],s['alternative']):s['threshold'] for s in
         json.loads((output/'fit.json').read_bytes())['models']}
    caps=[round((fit[m[0],m[1]] if reset else float(m[2]))*100) for m in models]; original=caps.copy()
    opener=gzip.open if baseline.suffix=='.gz' else open
    with opener(baseline,'rt') as f: old={r['id']:r['final'] for r in map(json.loads,f)}
    rows=json.loads(fixture.read_bytes())
    for r in rows:
        gold=tokens(r['expected'])
        baseline_words=tokens(old[r['id']]); matched,_=alignment(gold,baseline_words)
        already_right={i for i,j in enumerate(matched) if j is not None and baseline_words[j]==gold[i]}
        for s in (r['typed'],old[r['id']]):
            # Do not train any crossing-sentence contexts. The runtime truncates
            # both sides at sentence punctuation.
            parts=[tokens(part) for part in re.split(r'[.!?;:\n]',s)]
            ws=[w for part in parts for w in part];mapped,_=alignment(gold,ws)
            protected={j:gold[i] for i,j in enumerate(mapped) if j is not None and
                       (gold[i]==ws[j] or i in already_right)}
            start=0
            for part in parts:
                for j,w in enumerate(part[:-1]):
                    if start+j not in protected or w not in weights:continue
                    for right in (1,2):
                        fs=features(context(part,j,right),classes)
                        for m,coefs in weights[w]:
                            if models[m][1]==protected[start+j]:continue
                            sc=sum(coefs.get(f,0) for f in fs)
                            if sc>=original[m]: caps[m]=max(caps[m],sc+20)
                start+=len(part)
    raised={}
    for m,c,prior in zip(models,caps,original):
        if c>prior:raised[m[0]+'->'+m[1]]=[prior/100,c/100]
        m[2]=f'{c/100:.2f}'
    (output/'models.tsv').write_text(''.join('\t'.join(m)+'\n' for m in models))
    print('Raised on development-only literal controls:',json.dumps(raised,sort_keys=True))
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('fixture',type=Path);p.add_argument('baseline',type=Path)
    calibrate(**vars(p.parse_args()))
