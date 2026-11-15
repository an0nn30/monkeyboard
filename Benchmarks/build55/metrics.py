"""Case-sensitive whole-message and all-or-nothing error-event scoring, with clean controls."""
import argparse, json, re, sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'build22/blind'))
from score import WORD, scan, observe, load_outputs

def evaluate(rows, outputs):
    assert len(rows) == len({r['id'] for r in rows}) and set(outputs) == {r['id'] for r in rows}
    counts = Counter()
    for r in rows:
        expected, typed, actual = r['expected'], r['typed'], outputs[r['id']]
        ref = scan(expected)
        obs = observe(ref, scan(actual))
        inp = observe(ref, scan(typed))
        counts['correct_words'] += sum(t == w for t, w in zip(inp.slots, ref.words))
        counts['collateral'] += sum(t == w != a for t, w, a in zip(inp.slots, ref.words, obs.slots))
        label = 'noisy' if r['edits'] else 'clean'
        counts[label] += 1; counts[label + '_exact'] += (actual == expected)
        spans = list(re.finditer(r'\S+', expected)); words = list(WORD.finditer(expected))
        for e in r['edits']:
            j = e['expected_index']; end = spans[j+len(e['expected'].split())-1].end()
            ix = [i for i, w in enumerate(words) if spans[j].start() <= w.start() < end]
            assert [ref.words[i] for i in ix] == scan(e['expected']).words
            fixed = all(obs.slots[i] == ref.words[i] for i in ix) and not any(obs.extras.get(i) for i in ix[1:])
            for key in ('all', e['category']):
                counts[key] += 1; counts[key+'_fixed'] += fixed
    return dict(counts)

if __name__ == '__main__':
    p=argparse.ArgumentParser()
    p.add_argument('fixture',type=Path);p.add_argument('outputs',type=Path,nargs='+'); a=p.parse_args()
    rows=json.loads(a.fixture.read_bytes())
    for f in a.outputs:
        print(json.dumps({str(f):evaluate(rows,load_outputs([f],{r['id'] for r in rows}))},sort_keys=True))
