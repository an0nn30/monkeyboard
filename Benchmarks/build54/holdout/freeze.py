"""Verify or initially freeze the build 54 independent paired-message holdout."""
import argparse
import importlib.util
import json
import sys
from collections import Counter
from difflib import SequenceMatcher
from itertools import combinations
from pathlib import Path

HERE = Path(__file__).resolve().parent
B53 = HERE.parents[1] / 'build53'
# Reuse the exact annotation/index rules without importing any model or scorer.
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('fixture53', B53 / 'holdout/freeze.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


def make_pairs():
    rows = []
    for i, line in enumerate((HERE / 'authored.txt').read_text().splitlines(), 1):
        typed, expected, protected, edits = fixture.parse_template(line)
        categories = {entry['category'] for entry in edits}
        kind = categories.pop() if len(categories) == 1 else 'mixed'
        pair = f'new54-{i:04d}'
        common = dict(pair_id=pair, split='blind', source='independently-authored', source_id=i, expected=expected)
        rows.append(dict(id=pair + '-n', kind=kind, typed=typed, protected=protected, edits=edits, **common))
        pristine = [dict(p, typed_index=p['expected_index']) for p in protected]
        rows.append(dict(id=pair + '-c', kind='clean', typed=expected, protected=pristine, edits=[], **common))
    return rows


def word_similarity_pairs(left, right=None):
    # Ordered-word matching can catch near-identical messages that differ by an inserted name or article.
    pool = combinations(left, 2) if right is None else ((a, b) for a in left for b in right)
    return max(SequenceMatcher(None, a, b, autojunk=False).ratio() for a, b in pool)


def freeze(args):
    rows = make_pairs()
    groups = fixture.exclusion_groups(args.desktop, args.conversations)
    prior_refs = set()
    for filename in ('holdout/cases.json', 'development.json', 'desktop-check.json'):
        previous = json.loads((B53 / filename).read_bytes())
        keys = {fixture.norm(r[k]) for r in previous for k in ('typed', 'expected')}
        groups['build53_' + filename.split('/')[0].split('.')[0]] = keys
        if filename.startswith('holdout'):
            prior_refs.update(fixture.norm(r['expected']) for r in previous)
    groups['uci_sms_ham'] = {fixture.norm(msg) for msg in fixture.read_sms(args.sms).values()}
    stats = fixture.validate(rows, groups)
    refs = [fixture.norm(r['expected']).split() for r in rows if r['kind'] == 'clean']
    similarity = {
        'within_new_references': word_similarity_pairs(refs),
        'against_build53_holdout_references': word_similarity_pairs(refs, [r.split() for r in prior_refs]),
    }
    assert max(similarity.values()) < 0.75, similarity
    name_case = Counter()
    edit_counts = Counter()
    edit_categories = Counter()
    for row in rows:
        if row['kind'] == 'clean':
            continue
        edit_counts[len(row['edits'])] += 1
        edit_categories.update(e['category'] for e in row['edits'])
        for p in row['protected']:
            if p['category'] == 'name':
                word = p['text']
                name_case['lowercase' if word.islower() else 'all_caps' if word.isupper() else 'capitalized'] += 1
    data = (json.dumps(rows, indent=2, ensure_ascii=False) + '\n').encode()
    manifest = dict(**stats, fixture_sha256=fixture.sha(data),
                    source_annotation_sha256=fixture.sha((HERE / 'authored.txt').read_bytes()),
                    desktop_sha256=fixture.sha(args.desktop.read_bytes()),
                    taskmaster_sha256=fixture.sha(args.conversations.read_bytes()),
                    uci_archive_sha256=fixture.SMS_SHA256, edits_per_noisy_sentence=edit_counts,
                    noisy_edit_categories=edit_categories, name_case_per_companion=name_case,
                    maximum_reference_word_sequence_similarity={k: round(v, 6) for k,v in similarity.items()},
                    authoring='A separate authoring pass for build 54 with no access to baseline or candidate predictions.')
    meta = (json.dumps(manifest, sort_keys=True, indent=2) + '\n').encode()
    for filename, contents in [('cases.json', data), ('freeze.json', meta)]:
        path = HERE / filename
        if args.write and not path.exists():
            path.write_bytes(contents)
        assert path.read_bytes() == contents, filename + ' differs from freeze'
    print(meta.decode())


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--desktop', type=Path, default=Path.home() / 'Desktop/typo_sentences.md')
    parser.add_argument('--conversations', type=Path, default=Path('/tmp/mb21/train.txt'))
    parser.add_argument('--sms', type=Path, default=Path('/tmp/mb22/blind/sms.zip'))
    parser.add_argument('--write', action='store_true')
    freeze(parser.parse_args())
