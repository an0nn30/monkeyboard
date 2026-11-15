"""Score decisions on released 53/54/55 word positions and names using the production Swift probe."""
import argparse
from collections import Counter
import gzip
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'Benchmarks/build22/blind'))
from score import WORD, observe, scan


def evaluate(number, probe, verbose):
    directory = ROOT / 'Benchmarks' / f'build{number}'
    fixture = json.loads((directory / 'holdout/cases.json').read_bytes())
    prev = directory / (f'holdout-{number}.jsonl.gz' if number < 55 else 'primary/candidate.jsonl.gz')
    baseline = {row['id']: row['final'] for row in map(json.loads, gzip.open(prev, 'rt'))}
    opportunities = []
    for row in fixture:
        words = row['typed'].split()
        edit_at = {e['typed_index']: e for e in row['edits']}
        protected = {p['typed_index']: p['category'] for p in row['protected']}
        spans = list(re.finditer(r'\S+', row['expected']))
        ref = scan(row['expected'])
        prior = observe(ref, scan(baseline[row['id']]))
        shift = 0
        for i, token in enumerate(words):
            old = token.strip('?.!,;:"()')
            if not re.fullmatch(r"[^\W\d_]+(?:['’][^\W\d_]+)*", old):
                continue
            e = edit_at.get(i, {})
            goal = e.get('expected', old)
            kind = e.get('category', protected.get(i, 'correct'))
            j = i + shift
            if e:
                assert j == e['expected_index']
                shift += len(goal.split()) - 1
            start, end = spans[j].start(), spans[j + len(goal.split()) - 1].end()
            idx = [k for k, m in enumerate(WORD.finditer(row['expected'])) if start <= m.start() < end]
            if not idx:
                continue
            fixed = (all(prior.slots[k] == ref.words[k] for k in idx) and not any(prior.extras.get(k) for k in idx[1:]))
            opportunities.append((kind, old, goal, fixed, ' '.join(words[:i]), ' '.join(words[i+1:])))
    text = ''.join(f'{left}\t{word}\t{right}\n' for _, word, _, _, left, right in opportunities)
    run = subprocess.run([probe, ROOT/'Keyboard/Resources'], input=text, capture_output=True, text=True, check=True)
    lines = run.stdout.splitlines()
    assert len(lines) == len(opportunities)
    counts = {}
    for (kind, word, goal, old_fixed, left, right), line in zip(opportunities, lines):
        repaired, _, guard, *pool = line.split('\t')
        keep = guard == 'protected'
        if keep:
            repaired = ''
        counts.setdefault(kind, Counter())
        c = counts[kind]
        c['positions'] += 1
        if goal != word:
            c['in_candidates'] += goal.lower() in pool
        c['baseline_correct'] += old_fixed
        c['guarded'] += keep
        would_fix = word == goal if keep else (repaired == goal if repaired else old_fixed)
        c['overlay_correct'] += would_fix
        c['old_repairs_blocked_by_guard'] += keep and old_fixed and word != goal
        c['new_changes_to_correct_input'] += word == goal and bool(repaired and repaired != goal)
        if verbose and (old_fixed and not would_fix or (kind in ('ordinary','missing-space') and not would_fix)):
            print(number, kind, word, '->', goal, 'result', repaired or '(preserve)', 'guard', keep, left[-40:], right[:40], file=sys.stderr)
    return counts


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('probe', type=Path)
    p.add_argument('--verbose', action='store_true')
    a = p.parse_args()
    print(json.dumps({i:evaluate(i,a.probe,a.verbose) for i in (53,54,55)}, indent=2))
