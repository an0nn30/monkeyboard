"""Count a labelled typo only when all its reference words are recovered."""
from collections import Counter,defaultdict
import json,re,sys
from pathlib import Path
D=Path(__file__).resolve().parent
sys.path.insert(0,str(D.parent/'build22/blind'))
from score import WORD,scan,observe,load_outputs
def count():
    rows=json.loads((D/'holdout/cases.json').read_bytes())
    outputs={n:load_outputs([D/f'holdout-{n}.jsonl.gz'],{r['id'] for r in rows}) for n in ('52','54')}
    counts=defaultdict(Counter)
    for r in rows:
        if not r['edits']:continue
        gold=scan(r['expected']); words=list(WORD.finditer(r['expected']))
        spans=list(re.finditer(r'\S+',r['expected']))
        obs={n:observe(gold,scan(out[r['id']])) for n,out in outputs.items()}
        for e in r['edits']:
            j=e['expected_index'];start=spans[j].start();end=spans[j+len(e['expected'].split())-1].end()
            indices=[i for i,w in enumerate(words) if start<=w.start()<end]
            assert [gold.words[k] for k in indices]==scan(e['expected']).words
            result={n:all(a.slots[k]==gold.words[k] for k in indices) and not any(a.extras.get(k) for k in indices[1:]) for n,a in obs.items()}
            for key in ('all',e['category']):
                c=counts[key];c['errors']+=1
                for n in outputs:c[n]+=int(result[n])
                c['recovered']+=result['54'] and not result['52']
                c['lost']+=result['52'] and not result['54']
    return counts
if __name__=='__main__':print(json.dumps(count(), indent=2))
