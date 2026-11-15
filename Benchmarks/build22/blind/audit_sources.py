"""Independently check full-message overlap, source membership, and the source-corpus split.

Only fixture inputs, training sources, and the literal-count asset are read. No replay output
or candidate prediction is used. Normalization matches the training partition's word key.
"""
import argparse
import bz2
import csv
import hashlib
import json
import random
import re
import zipfile
from collections import Counter, defaultdict
from pathlib import Path

from freeze import HERE, ROOT, TRAIN, SMS_SHA, digest, key, pairs


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inputs():
    manifest = json.loads((HERE / 'freeze.json').read_bytes())
    suites = {}
    for name, spec in manifest['suites'].items():
        path = HERE / (name + '.json')
        if sha(path) != spec['sha256']:
            raise ValueError(f'{name} differs from the original frozen inputs')
        rows = json.loads(path.read_bytes())
        suites[name] = {key(r[c]) for r in rows for c in ('typed', 'expected')}
    if suites['review'] & suites['final']:
        raise ValueError('Review and final intersect')
    return suites


def previous_cases():
    earlier = set()
    for f in (ROOT / 'Benchmarks').rglob('*.tsv'):
        if HERE.parent in f.parents:
            continue
        with f.open() as lines:
            for r in csv.DictReader(lines, delimiter='\t'):
                for c in ('expected', 'typed', 'sentence', 'text', 'context', 'prompt'):
                    if r.get(c):
                        earlier.add(key(r[c]))
                if all(c in r for c in ('left', 'gold', 'right')):
                    earlier.add(key(' '.join((r['left'], r['gold'].split('|')[0], r['right']))))
    return earlier


def audit(args):
    suites = inputs()
    protected = suites['review'] | suites['final']
    sources, counts = {}, Counter()
    desktop = list(pairs(args.desktop))
    partitions = defaultdict(set)
    paired_all = set()
    earlier = previous_cases()
    for s, g in desktop:
        raw, gold = key(s), key(g)
        partition = 'reserved' if digest(gold)[0] < 38 else 'training'
        counts[partition] += 1
        partitions[partition].add(gold)
        paired_all.update((raw, gold))
    sources['all_desktop_noisy_and_correct_forms'] = paired_all
    if partitions['reserved'] & partitions['training']:
        raise ValueError('Desktop gold family occurs in both partitions')
    with bz2.open(TRAIN/'eng_sentences_CC0.tsv.bz2', 'rt') as f:
        sources['whole_tatoeba_cc0'] = {key(line.split('\t')[2]) for line in f}
    public = args.public.read_text().splitlines()
    sources['whole_taskmaster_build21_training'] = set(map(key, public))
    shuffled = list(public)
    random.Random(20261114).shuffle(shuffled)
    sources['neural_ranker_52000_taskmaster_negatives'] = set(map(key, shuffled[:52000]))

    if sha(args.sms_zip) != SMS_SHA:
        raise ValueError('SMS source differs from original archive')
    with zipfile.ZipFile(args.sms_zip) as z:
        rows = z.read('SMSSpamCollection').decode().splitlines()
    ham = [s[4:] for s in rows if s.startswith('ham\t')]
    counts_by_feature = Counter()
    used = set()
    for s in ham:
        k = key(s)
        if k in paired_all or k in protected or k in used:
            continue
        used.add(k)
        terms = ['^', *re.findall(r"[a-z]+(?:'[a-z]+)*", s.lower())]
        counts_by_feature.update(set(terms[1:]) | {' '.join(t) for t in zip(terms, terms[1:])})
    sources['casual_sms_training'] = used
    expected_asset = ''.join(f'{s}\t{n}\n' for s, n in sorted(counts_by_feature.items()) if n >= 2).encode()
    if expected_asset != (ROOT/'keyboard-engine/model/wordnet22/casual.tsv').read_bytes():
        raise ValueError('Literal model cannot be reproduced from the disjoint SMS messages')
    eligible = {key(s) for msg in ham if (s := msg.strip()) and 6 <= len(s.split()) <= 26 and
                '  ' not in s and re.fullmatch(r"[a-zA-Z][A-Za-z ,'.!?-]+[.!?]", s)}
    sources['real_word_sms_candidates_before_additional_training_exclusions'] = {key(s) for s in ham} - eligible
    checks = {name: {'normalized_messages':len(items),
                     'overlap':{suite:len(items & keys) for suite,keys in suites.items()}}
              for name,items in sources.items()}
    if any(any(v['overlap'].values()) for v in checks.values()):
        raise ValueError(f'Training sources intersect a frozen fixture: {checks}')
    return dict(sources=checks, desktop_sha256=sha(args.desktop), taskmaster_train_sha256=sha(args.public),
                casual_sms_asset_sha256=hashlib.sha256(expected_asset).hexdigest(),
                eligible_sms_message_count=len(eligible), suites_normalized_forms={s:len(k) for s,k in suites.items()},
                distinct_desktop_gold_by_partition={s:len(k) for s,k in partitions.items()},
                desktop_pair_counts=dict(counts), desktop_gold_train_reserved_overlap=0,
                reserved_gold_matching_prior_normalized_fixture_fields=len(partitions['reserved'] & earlier),
                reserved_gold_without_prior_normalized_fixture_field_match=len(partitions['reserved'] - earlier),
                reserved_gold_in_tatoeba_source=len(partitions['reserved'] & sources['whole_tatoeba_cc0']),
                reserved_gold_in_taskmaster_train_source=len(partitions['reserved'] & sources['whole_taskmaster_build21_training']),
                shared_uci_collection_for_training_and_fixtures=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('desktop', 'public', 'sms_zip'):
        parser.add_argument(name, type=Path)
    print(json.dumps(audit(parser.parse_args()), indent=2))
