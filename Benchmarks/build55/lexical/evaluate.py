"""Measure the lexical component and its upper bound on public development replays."""
import argparse
from collections import Counter, defaultdict
import gzip
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'Benchmarks/build22/blind'))
from score import WORD, scan, observe


def evaluate(number, probe, verbose):
    folder = ROOT / f'Benchmarks/build{number}'
    data = json.loads((folder / 'holdout/cases.json').read_bytes())
    baseline = {r['id']: r['final'] for r in map(json.loads, gzip.open(folder / f'holdout-{number}.jsonl.gz', 'rt'))}
    entries = []
    for row in data:
        words = list(re.finditer(r'\S+', row['expected']))
        typed = row['typed'].split()
        observed = observe(scan(row['expected']), scan(baseline[row['id']]))
        edits = list(row['edits'])
        slots = set()
        for edit in edits:
            i = edit['expected_index']
            j = i + len(edit['expected'].split()) - 1
            start, end = words[i].start(), words[j].end()
            indices = [i for i, m in enumerate(WORD.finditer(row['expected'])) if start <= m.start() < end]
            old = ' '.join(observed.slots[k] or '' for k in indices).strip()
            if any(observed.extras.get(k) for k in indices[1:]):
                old = ''
            k = edit['typed_index']
            slots.add(k)
            entries.append((edit['category'], edit['typed'], edit['expected'], old, ' '.join(typed[:k]), ' '.join(typed[k + 1:])))
        protect = {p['typed_index']: p['category'] for p in row['protected']}
        for k, word in enumerate(typed):
            if k in slots:
                continue
            word = word.strip('!?,.;:"()')
            if not re.fullmatch(r"[^\W\d_]+(?:['’][^\W\d_]+)*", word):
                continue
            entries.append((protect.get(k, 'correct'), word, word, word, ' '.join(typed[:k]), ' '.join(typed[k + 1:])))
    lines = ''.join(f'{l}\t{w}\t{r}\n' for _, w, _, _, l, r in entries)
    run = subprocess.run([probe, ROOT / 'Keyboard/Resources'], input=lines, capture_output=True, check=True, text=True)
    answers = run.stdout.splitlines()
    assert len(answers) == len(entries)
    report = defaultdict(Counter)
    for (kind, typed, target, old, _, _), answer in zip(entries, answers):
        new, known, protected, *pool = answer.split('\t')
        c = report[kind]
        c['events'] += 1
        if typed == target:
            c['new_changes'] += bool(new and new != target)
            c['literal_guard'] += protected == 'protected'
            if verbose and new and new != target:
                print('clean edit:', typed, '->', new)
        else:
            c['in_candidates'] += target.lower() in pool
            c['top1'] += pool[:1] == [target.lower()]
            c['lexical_repairs'] += new == target
            c['wrong_proposals'] += bool(new and new != target)
            c['baseline_repairs'] += old == target
            c['overlay_repairs'] += (new or old) == target
            c['regressed_repairs'] += old == target and bool(new and new != target)
            c['blocked_by_literal_guard'] += protected == 'protected'
            if verbose and new != target and (new or kind != 'real-word'):
                print(kind, typed, '->', target, 'baseline', old, 'new', new, pool[:3])
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('probe', type=Path)
    parser.add_argument('--verbose', action='store_true')
    args = parser.parse_args()
    print(json.dumps({n: evaluate(n, args.probe, args.verbose) for n in (53, 54)}, indent=2))
