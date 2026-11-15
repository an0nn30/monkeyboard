"""Freeze both suites without loading any keyboard or candidate output."""
import argparse
import bz2
import csv
import hashlib
import json
import random
import re
import sys
import zipfile
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
TRAIN = ROOT / 'keyboard-engine/training'
sys.path.insert(0, str(TRAIN))
from paired_text import key, pairs

SMS_SHA = '1587ea43e58e82b14ff1f5425c88e17f8496bfcdb67a583dbff9eefaf9963ce3'
WORDS = re.compile(r"[A-Za-z]+(?:'[A-Za-z]+)*")
LAYOUT = ['qwertyuiop', 'asdfghjkl', 'zxcvbnm']
REAL = {'if': 'of', 'of': 'if', 'by': 'be', 'is': 'us', 'us': 'is',
        'in': 'on', 'on': 'in', 'at': 'as', 'as': 'at', 'from': 'form',
        'for': 'four', 'then': 'than', 'than': 'then', 'meet': 'meat',
        'with': 'wish', 'send': 'sent', 'now': 'not', 'read': 'real',
        'hear': 'here', 'here': 'hear', 'your': 'tour', 'my': 'me',
        'me': 'my', 'find': 'fine', 'like': 'life', 'home': 'hope'}
QUOTAS = {'public-clean': 100, 'public-multi': 68, 'public-word': 44,
          'public-short': 30, 'public-real-word': 30, 'public-join': 24,
          'public-apostrophe': 8}
TM_FILES = ('flights', 'hotels', 'music', 'sports', 'movies', 'restaurant-search',
            'food-ordering', 'woz-dialogs')


def digest(text):
    return hashlib.sha256(text.encode()).digest()


def collect_blocked(args):
    blocked = {key(x) for pair in pairs(args.desktop) for x in pair}
    # Compare full typed and correct sentences from headerless and headered
    # fixtures, including earlier word-in-context benchmarks.
    for path in (ROOT / 'Benchmarks').rglob('*.tsv'):
        if HERE.parent in path.parents:
            continue
        with path.open() as f:
            for row in csv.reader(f, delimiter='\t', quoting=csv.QUOTE_NONE):
                blocked.update(map(key, row))
                if len(row) >= 3 and row[0] in ('next', 'fix', 'keep'):
                    ctx = row[1].split()
                    for gold in row[2].split('|'):
                        blocked.add(key(' '.join(ctx + [gold])))
                        blocked.add(key(' '.join(ctx[:-1] + [gold])))
                if len(row) >= 4:  # left, typed, right, gold
                    for target in [row[1], *row[3].split('|')]:
                        blocked.add(key(' '.join([row[0], target, row[2]])))
        with path.open() as f:
            for row in csv.DictReader(f, delimiter='\t'):
                if all(c in row for c in ('left', 'typed', 'gold', 'right')):
                    for t in [row['typed'], *row['gold'].split('|')]:
                        blocked.add(key(' '.join([row['left'], t, row['right']])))
    for path in [*(ROOT / 'Benchmarks').rglob('*.txt'), *TRAIN.glob('*.txt'),
                 args.build21 / 'train.txt', args.build21 / 'validation.txt']:
        if HERE.parent not in path.parents:
            blocked.update(map(key, path.read_text().splitlines()))
    with bz2.open(TRAIN / 'eng_sentences_CC0.tsv.bz2', 'rt') as f:
        blocked.update(key(line.split('\t')[2]) for line in f)
    for file in [args.taskmaster1, *(args.taskmaster2 / (s + '.json') for s in TM_FILES)]:
        for dialog in json.loads(file.read_bytes()):
            for utterance in dialog['utterances']:
                s = utterance['text']
                blocked.add(key(s))
                blocked.update(map(key, re.split(r'[.!?;:]', s)))
    return blocked


def mutate(word, rng):
    i = rng.randrange(len(word))
    kind = rng.randrange(4)
    if kind == 0 and len(word) > 2:
        return word[:i] + word[i+1:]
    if kind == 1:
        return word[:i] + word[i] + word[i:]
    j = i + 1 if i + 1 < len(word) else i - 1
    if kind == 2 and word[i] != word[j]:
        i, j = sorted((i,j))
        return word[:i] + word[j] + word[i] + word[j+1:]
    row = next(row for row in LAYOUT if word[i] in row)
    k = row.index(word[i])
    letter = rng.choice([row[p] for p in (k-1,k+1) if 0 <= p < len(row)])
    return word[:i] + letter + word[i+1:]


def corrupt(s, kind, seed):
    rng = random.Random(seed)
    if kind == 'public-clean':
        return s
    if kind == 'public-join':
        gaps = list(re.finditer(r'(?<=[a-z]) (?=[a-z])', s))
        if gaps:
            gap = rng.choice(gaps)
            return s[:gap.start()] + s[gap.end():]
        return None
    words = [w for w in WORDS.finditer(s) if w[0].islower()]
    if kind == 'public-apostrophe':
        words = [w for w in words if "'" in w[0]]
        replace = lambda w: w.replace("'", "")
    elif kind == 'public-real-word':
        words = [w for w in words if w[0] in REAL]
        replace = REAL.get
    else:
        short = kind == 'public-short'
        words = [w for w in words if w[0].isalpha() and
                 (2 <= len(w[0]) <= 3 if short else len(w[0]) >= (3 if kind == 'public-multi' else 4))]
        replace = lambda w: mutate(w, rng)
    n = rng.choice([2, 3]) if kind == 'public-multi' else 1
    if len(words) < n:
        return None
    for w in sorted(rng.sample(words, n), key=lambda x: -x.start()):
        s = s[:w.start()] + replace(w[0]) + s[w.end():]
    return s


def public_pool(archive, blocked):
    assert hashlib.sha256(archive.read_bytes()).hexdigest() == SMS_SHA
    pools = {'review': {}, 'final': {}}
    seen = set()
    with zipfile.ZipFile(archive) as z:
        lines = z.read('SMSSpamCollection').decode().splitlines()
    for lineno, line in enumerate(lines, 1):
        if not line.startswith('ham\t'):
            continue
        s = line[4:].strip()
        k = key(s)
        if (k in seen or k in blocked or not 6 <= len(s.split()) <= 26 or
                '  ' in s or not re.fullmatch(r"[a-zA-Z][A-Za-z ,'.!?-]+[.!?]", s)):
            continue
        seen.add(k)
        split = 'review' if digest('mb22/source/' + k)[0] < 128 else 'final'
        pools[split][lineno] = s
    return pools


def freeze(args):
    blocked = collect_blocked(args)
    pools = public_pool(args.sms_zip, blocked)
    used = set()
    report = {'sms_zip_sha256': SMS_SHA, 'excluded_normalized_keys': len(blocked),
              'public_eligible_after_exclusions': {k:len(v) for k,v in pools.items()},
              'suites': {}}
    for split, pool in pools.items():
        rows = []
        for n, line in enumerate((HERE / f'authored-{split}.txt').read_text().splitlines(), 1):
            fields = line.split('|')
            kind, typed, gold = fields[0], fields[1], fields[-1]
            keys = {key(typed), key(gold)}
            if keys & (blocked | used):
                raise ValueError(f'Non-fresh authored case {split} {n}')
            used.update(keys)
            rows.append(dict(id=f'{split}-a{n:03d}', split=split, source='authored',
                             kind=kind, typed=typed, expected=gold))
        for kind, quota in QUOTAS.items():
            n = 0
            for line in sorted(pool, key=lambda i:digest(f'mb22/{split}/{kind}/{i}')):
                gold = pool[line]
                typed = corrupt(gold, kind, f'mb22/noise/{split}/{kind}/{line}')
                if not typed:
                    continue
                keys = {key(typed), key(gold)}
                if keys & used or keys & blocked:
                    continue
                used.update(keys)
                rows.append(dict(id=f'{split}-sms{line:04d}', split=split, source='uci-sms',
                                 source_line=line, kind=kind, typed=typed, expected=gold))
                n += 1
                if n == quota:
                    break
            if n != quota:
                raise ValueError(f'Insufficient samples for {split} {kind}: {n}')
        rows.sort(key=lambda r:digest('mb22/order/' + r['id']))
        raw = (json.dumps(rows, ensure_ascii=False, indent=2) + '\n').encode()
        (HERE / f'{split}.json').write_bytes(raw)
        report['suites'][split] = {'cases':len(rows), 'sha256':hashlib.sha256(raw).hexdigest(),
                                   'kinds':dict(sorted(Counter(r['kind'] for r in rows).items()))}
    (HERE / 'freeze.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['desktop', 'taskmaster1', 'taskmaster2', 'build21', 'sms_zip']:
        parser.add_argument(name, type=Path)
    freeze(parser.parse_args())
