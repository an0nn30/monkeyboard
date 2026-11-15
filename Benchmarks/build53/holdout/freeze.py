"""Build or verify the independently authored blind paired-message fixture."""

import argparse
import bz2
import collections
import csv
import hashlib
import json
import re
import unicodedata
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
BENCHMARKS = HERE.parents[1]
TRAIN = BENCHMARKS.parent / 'keyboard-engine/training'
SMS_SHA256 = '1587ea43e58e82b14ff1f5425c88e17f8496bfcdb67a583dbff9eefaf9963ce3'

# Only source fixtures are included. Earlier prediction and replay-result files are unused.
PREFIX_CASES = """
cases.tsv held-out.tsv mistaps/cases.tsv texting/check.tsv texting/development.tsv
texting/dialogue-holdout.tsv build10/calibration.tsv build10/fresh.tsv build10/replay.tsv
build11/development.tsv build11/pairs.tsv build11/replay.tsv build11/texts.tsv
""".split()
CONTEXT_CASES = """
build12/everyday-fresh.tsv build13/fresh.tsv build13/holdout.tsv build14/fresh.tsv
""".split()
FULL_TSV = """
build15/cases.tsv build16/cases.tsv build17/confirmation.tsv build17/sentences.tsv
build18/challenge.tsv build18/sentences.tsv build19/audit.tsv build19/confirmation.tsv
build19/sentences.tsv build20/audit.tsv build20/confirmation.tsv build20/final.tsv
build20/fresh.tsv build20/general.tsv build20/short.tsv build20/spoken.tsv
build21/audit-blind.tsv build21/audit-dev.tsv build21/blind.tsv build21/confirmation-blind.tsv
build21/confirmation-dev.tsv build21/dev.tsv build21/paired.tsv
""".split()
FULL_JSON = (
    ['build22/blind/final.json', 'build22/blind/review.json', 'build41/regressions.json']
    + [f'build{n}/fresh.json' for n in (40, 41, 45, 47, 49, 50, 51)]
    + [f'build{n}/public.json' for n in (46, 48, 49, 50, 51)]
)
TEXT_CASES = """
build15/texts.txt build17/texts.tsv build18/examples.tsv build19/controls.txt build20/examples.txt
""".split()
CATEGORY = {'o': 'ordinary', 'r': 'real-word', 'j': 'missing-space'}
SOURCE = {'authored': 'independently-authored', 'sms': 'uci-sms-ham'}


def norm(text):
    text = unicodedata.normalize('NFKD', text.casefold().replace('’', "'"))
    text = ''.join(c for c in text if not unicodedata.combining(c))
    return ' '.join(re.findall(r'[a-z0-9]+', text.replace("'", '')))


def sha(data):
    return hashlib.sha256(data).hexdigest()


def tsv_rows(file):
    with (BENCHMARKS / file).open() as stream:
        yield from csv.reader((s for s in stream if s.strip() and not s.startswith('#')), delimiter='\t')


def previous_forms():
    items = set()

    def add(text):
        if text.strip():
            items.add(norm(text))

    for file in PREFIX_CASES:
        for row in tsv_rows(file):
            kind, typed, expected = row[:3]
            add(typed)
            for gold in expected.split('|'):
                if kind == 'next':
                    add(typed + ' ' + gold)
                else:
                    add(' '.join(typed.split()[:-1] + [gold]))
    for file in CONTEXT_CASES:
        for before, typed, after, gold, *_ in tsv_rows(file):
            for word in [typed, *gold.split('|')]:
                add(' '.join([before, word, after]))
    for file in FULL_TSV:
        with (BENCHMARKS / file).open() as stream:
            for row in csv.DictReader(stream, delimiter='\t'):
                if 'expected' in row:
                    add(row['typed'])
                    add(row['expected'])
                else:
                    for word in [row['typed'], *row['gold'].split('|')]:
                        add(' '.join([row['left'], word, row['right']]))
    for file in FULL_JSON:
        for row in json.loads((BENCHMARKS / file).read_bytes()):
            add(row['typed'])
            add(row['expected'])
    for file in TEXT_CASES:
        for line in (BENCHMARKS / file).read_text().splitlines():
            for field in re.split(r'[|\t]', line):
                add(field)
    return items


def exclusion_groups(desktop, conversations):
    desktop_keys = {
        norm(line[3:]) for line in desktop.read_text().splitlines()
        if line.startswith(('C: ', 'S: '))
    }
    with bz2.open(TRAIN / 'eng_sentences_CC0.tsv.bz2', 'rt') as source:
        tatoeba = {norm(line.split('\t', 2)[2]) for line in source}
    sources = [conversations, TRAIN / 'context40-practice.txt', TRAIN / 'everyday-phrases.txt']
    practice = {norm(line) for file in sources for line in file.read_text().splitlines()}
    return {
        'desktop_typed_and_reference': desktop_keys, 'prior_fixtures': previous_forms(),
        'tatoeba_cc0': tatoeba, 'taskmaster_and_local_phrase_practice': practice,
    }


def read_sms(path):
    assert sha(path.read_bytes()) == SMS_SHA256, 'unexpected archive revision'
    with zipfile.ZipFile(path) as archive:
        return {
            index: line[4:].strip()
            for index, line in enumerate(archive.read('SMSSpamCollection').decode().splitlines(), 1)
            if line.startswith('ham\t')
        }


def print_candidates(sms, blocked):
    seen = set()
    for index in sorted(sms, key=lambda i: sha(f'holdout53/{i}'.encode())):
        message = sms[index]
        key = norm(message)
        if key in blocked or key in seen:
            continue
        seen.add(key)
        if (6 <= len(message.split()) <= 26 and '  ' not in message
                and re.fullmatch(r"[a-zA-Z][A-Za-z ,'.!?-]+[.!?]", message)):
            print(f'{index}\t{message}')


def parse_template(template):
    typed = expected = ''
    protected, edits = [], []
    start = 0
    for match in re.finditer(r'\[([^\[\]]+)\]', template):
        literal = template[start:match.start()]
        typed += literal
        expected += literal
        typed_i, expected_i = len(typed.split()), len(expected.split())
        kind, *fields = match[1].split('|')
        if kind in ('name', 'slang'):
            word, = fields
            protected.append(dict(text=word, category=kind, typed_index=typed_i, expected_index=expected_i))
            typed += word
            expected += word
        else:
            gold, bad = fields
            assert gold != bad and kind in CATEGORY
            if kind == 'j':
                assert bad == gold.replace(' ', '') and len(gold.split()) == 2
            else:
                assert len(bad.split()) == len(gold.split()) == 1
            edits.append(dict(category=CATEGORY[kind], typed=bad, expected=gold,
                              typed_index=typed_i, expected_index=expected_i))
            typed += bad
            expected += gold
        start = match.end()
    typed += template[start:]
    expected += template[start:]
    assert edits and not any(c in typed + expected for c in '[]|')
    return typed, expected, protected, edits


def make_pairs(sms):
    rows = []
    for source, filename in [('authored', 'authored.txt'), ('sms', 'sms.txt')]:
        for i, line in enumerate((HERE / filename).read_text().splitlines(), 1):
            if source == 'sms':
                sid, line = line.split('\t', 1)
                i = int(sid)
            typed, expected, protected, edits = parse_template(line)
            if source == 'sms':
                assert expected == sms[i], f'UCI reference must match line {i} byte for byte'
            cats = {e['category'] for e in edits}
            subtype = cats.pop() if len(cats) == 1 else 'mixed'
            pair = f'{source}-{i:04}'
            common = dict(pair_id=pair, split='blind', source=SOURCE[source], source_id=i, expected=expected)
            rows.append(dict(id=pair + '-n', kind=subtype, typed=typed, protected=protected, edits=edits, **common))
            literal_spans = [dict(p, typed_index=p['expected_index']) for p in protected]
            rows.append(dict(id=pair + '-c', kind='clean', typed=expected, protected=literal_spans, edits=[], **common))
    return rows


def validate(rows, groups):
    forms, refs = set(), set()
    kinds, sources, protected = [collections.Counter() for _ in range(3)]
    for noisy, clean in zip(rows[::2], rows[1::2], strict=True):
        expected = clean['expected']
        assert clean['typed'] == expected == noisy['expected']
        assert norm(expected) not in refs and norm(noisy['typed']) not in forms
        assert norm(expected) not in forms and norm(noisy['typed']) != norm(expected)
        forms.update((norm(expected), norm(noisy['typed'])))
        refs.add(norm(expected))
        kinds[noisy['kind']] += 1
        sources[clean['source']] += 1
        for row in (noisy, clean):
            for p in row['protected']:
                for field in ('typed', 'expected'):
                    surface = row[field].split()[p[field + '_index']].strip('.,?!:;"()')
                    assert surface == p['text'], (row['id'], p, surface)
                protected[p['category']] += 1
        for e in noisy['edits']:
            for field in ('typed', 'expected'):
                start, words = e[field + '_index'], e[field].split()
                surface = ' '.join(noisy[field].split()[start:start + len(words)]).strip('.,?!:;"()')
                assert surface == e[field], (noisy['id'], e, surface)
    collisions = {name: len(forms & group) for name, group in groups.items()}
    assert not any(collisions.values()), collisions
    return dict(rows=len(rows), unique_references=len(refs), pair_sources=sources, noisy_pair_kinds=kinds,
                pairs_with_two_or_more_edits=sum(len(r['edits']) >= 2 for r in rows),
                protected_occurrences_including_clean_and_noisy=protected, normalized_form_overlaps=collisions,
                exclusion_normalized_key_counts={k:len(v) for k,v in groups.items()})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--desktop', type=Path, default=Path.home() / 'Desktop/typo_sentences.md')
    parser.add_argument('--conversations', type=Path, default=Path('/tmp/mb21/train.txt'))
    parser.add_argument('--sms', type=Path, default=Path('/tmp/mb22/blind/sms.zip'))
    parser.add_argument('--candidates', action='store_true')
    parser.add_argument('--write', action='store_true')
    args = parser.parse_args()
    groups = exclusion_groups(args.desktop, args.conversations)
    sms = read_sms(args.sms)
    if args.candidates:
        print_candidates(sms, set.union(*groups.values()))
        return
    rows = make_pairs(sms)
    stats = validate(rows, groups)
    data = (json.dumps(rows, ensure_ascii=False, indent=2) + '\n').encode()
    frozen = dict(**stats, fixture_sha256=sha(data), uci_archive_sha256=SMS_SHA256,
                  desktop_sha256=sha(args.desktop.read_bytes()), taskmaster_sha256=sha(args.conversations.read_bytes()),
                  source_annotation_sha256={p:sha((HERE / p).read_bytes()) for p in ('authored.txt','sms.txt')},
                  authoring='Independent one-pass evaluation authoring before viewing any candidate or baseline output.')
    manifest = (json.dumps(frozen, ensure_ascii=False, indent=2, sort_keys=True) + '\n').encode()
    for filename, contents in [('cases.json', data), ('freeze.json', manifest)]:
        path = HERE / filename
        if args.write and not path.exists():
            path.write_bytes(contents)
        assert path.read_bytes() == contents, filename + ' differs from freeze'
    print(manifest.decode())


if __name__ == '__main__':
    main()
