"""Mine supervised contexts from build 40 misses on the training partition only."""
import argparse,gzip,json,sys
from collections import defaultdict
from pathlib import Path
from contrast40 import train, tokens, engine, sha, key
from calibrate40 import calibrate
sys.path.insert(0,str(engine.parent/'Benchmarks/build22/blind'))
from score import scan,observe
def fit(args):
    with gzip.open(args.previous,'rt') as f: previous={r['id']:r['final'] for r in map(json.loads,f)}
    examples=defaultdict(dict)
    vocab={l.split('\t')[0] for l in (engine/'model/words.tsv').read_text().splitlines()}
    for row in json.loads(args.corpus.read_bytes()):
        if row['split']!='training':continue
        gold=row['expected']; k=key(gold)
        assert sha(k)[0]>=38
        if sha('contrast40/cal/'+k)[0]<40:continue
        if previous[row['id']]==gold:continue
        ref=scan(gold); terms=tokens(gold)
        if terms!=[w.lower().replace('’',"'") for w in ref.words]:continue
        typed=observe(ref,scan(row['typed'])).slots;result=observe(ref,scan(previous[row['id']])).slots
        for i,(t,w,o) in enumerate(zip(typed,ref.words,result)):
            if w==o or t is None or i==len(terms)-1:continue
            a,b=t.lower(),w.lower()
            if a!=b and a in vocab and b in vocab and a.isalpha() and b.isalpha() and 2<=min(len(a),len(b))<=max(len(a),len(b))<=7:
                examples[a,b][k]=(b,terms,i)
    edges={pair for pair,contexts in examples.items() if len(contexts)>=3}
    extra=[x for pair in sorted(edges) for x in list(examples[pair].values())[:24]]
    print(f'{len(edges)} recurring contrasts; {len(extra)} extra contexts',flush=True)
    out=engine/'model/contrast42'
    train(args.paired,args.taskmaster,args.sms,args.old_misses,extra_edges=edges,extra_contexts=extra,output=out)
    for i,(fixture,baseline) in enumerate([(engine.parent/'Benchmarks/build22/blind/review.json',engine.parent/'Benchmarks/build39/review-39.jsonl.gz'),
                                           (engine.parent/'Benchmarks/build40/fresh.json',engine.parent/'Benchmarks/build40/fresh-40.jsonl.gz')]):
        calibrate(fixture,baseline,output=out,reset=i==0)
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    for a in ('paired','taskmaster','sms','old_misses','corpus','previous'):p.add_argument(a,type=Path)
    fit(p.parse_args())
