"""Require the build 60 replay to reproduce recorded ranks, then check each group."""
import json
import sys
from pathlib import Path

def load(path):
    return [json.loads(line) for line in Path(path).open()]

def score(cohort, baseline, candidate):
    source = Path(__file__).resolve().parents[1] / 'build60'
    previous = json.loads((source / 'results.json').read_bytes())
    older = json.loads((source / 'regression.json').read_bytes())
    groups = {'recovered': previous['long_lost'], 'retained': previous['long_gained'],
              'earlier': older['recovered']['examples'] + older['retained']['examples']}
    ids = [r['id'] for r in load(cohort)]
    if len(set(ids)) != len(ids) or set(ids) != {r['id'] for group in groups.values() for r in group}:
        raise ValueError('Regression cohort differs from the two previous reports')
    predictions = []
    for path in (baseline, candidate):
        rows = load(path)
        if [r['id'] for r in rows] != ids:
            raise ValueError('Replay rows do not match the cohort')
        predictions.append({r['id']: r['words'] for r in rows})
    before, after = predictions
    report = {}
    for name, rows in groups.items():
        examples = []
        for r in rows:
            i, w = r['id'], r['word']
            if before[i] != r['build60']:
                raise ValueError(f'Build 60 does not reproduce recorded ranks for {i}')
            examples.append(dict(id=i, word=w, build60=before[i], build61=after[i]))
        report[name] = dict(total=len(rows), correct=sum(r['build61'][:1] == [r['word']] for r in examples),
                            examples=examples)
    return report

if __name__ == '__main__':
    result = score(*sys.argv[1:])
    print(json.dumps(result, indent=2))
    if any(group['correct'] != group['total'] for group in result.values()):
        raise SystemExit('Regression check failed')
