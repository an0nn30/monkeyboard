"""Annotate lexical entries with evidence for ambiguous names and spaced compound forms."""
import argparse
from collections import defaultdict
import gzip
import hashlib
from pathlib import Path
import re
import struct
import importlib.util
import rdata
from rapidfuzz.distance import DamerauLevenshtein

ROOT = Path(__file__).resolve().parents[3]
PREVIOUS = ROOT / 'Benchmarks/build55/lexical'
spec = importlib.util.spec_from_file_location('lexical55_builder', PREVIOUS / 'build.py')
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)


def phonetic_neighbors(path, entries):
    assert hashlib.sha256(path.read_bytes()).hexdigest() == base.CMU_SHA
    frequencies = {}
    patterns = defaultdict(set)
    for line in path.read_text().splitlines():
        spelled, phones = line.split(maxsplit=1)
        word = spelled.split('(')[0]
        key = base.hash_word(word)
        if not (3 <= len(word) <= 12 and word.isascii() and word.isalpha() and key in entries):
            continue
        frequency, flags = entries[key]
        if frequency < 265 or flags & 1 == 0 or flags & 4:
            continue
        frequencies[word] = frequency
        phones = tuple(re.sub('[012]', '', phones.split('#')[0]).split())
        if len(phones) < 2:
            continue
        for i in range(len(phones)):
            patterns[phones[:i] + ('*',) + phones[i + 1:]].add(word)
    neighbors = defaultdict(dict)
    for members in patterns.values():
        if len(members) < 2:
            continue
        for a in members:
            for b in members:
                if a == b or abs(len(a) - len(b)) > 2 or (a[0] != b[0] and a[-1] != b[-1]):
                    continue
                distance = DamerauLevenshtein.distance(a, b, score_cutoff=3)
                if distance in (2, 3):
                    neighbors[a][b] = (distance, True)
    for a in frequencies:
        for i in range(len(a)):
            for j in range(i + 2, len(a)):
                if a[i] == a[j]:
                    continue
                b = a[:i] + a[j] + a[i+1:j] + a[i] + a[j+1:]
                if b in frequencies and b not in neighbors[a]:
                    neighbors[a][b] = (2, False)
    result = {}
    for word, peers in neighbors.items():
        # Bound rescoring and filter the least plausible forms in very dense neighborhoods.
        best = sorted(peers, key=lambda w: (peers[w][0], -frequencies[w], w))[:24]
        if best:
            encoded = bytearray([len(best)])
            for peer in best:
                encoded.append(len(peer) | (0x80 if peers[peer][1] else 0))
                encoded.extend(peer.encode())
            result[base.hash_word(word)] = encoded
    return result


def build(args):
    assert hashlib.sha256(args.names.read_bytes()).hexdigest() == '1d5c601fa3c5177f4d9edb4c8c2f08fddc8d9bf04372b8a40dc6aecf92bfa324'
    data = rdata.read_rda(args.names)['babynames']
    counts = data.groupby('name').n.sum()
    names = {name.lower() for name, n in counts.items() if n >= 25 and name.isascii() and name.isalpha()}
    with gzip.open(PREVIOUS / 'given-names.txt.gz', 'rt') as source:
        names.update(w for row in source if (w := row.strip()).isalpha())
    names = {base.hash_word(w) for w in names}

    hyphenated = set()
    for part in ['noun', 'adj', 'verb', 'adv']:
        for row in (args.wordnet / 'dict' / f'index.{part}').read_text().splitlines():
            if row.startswith(' '):
                continue
            word = row.split()[0]
            sides = word.split('-')
            if len(sides) == 2 and all(w.isascii() and w.isalpha() for w in sides):
                hyphenated.add(base.hash_word(''.join(sides)))
    original = bytearray(args.resource.read_bytes())
    header, n, pairs, old_extra = struct.unpack_from('<4sIII', original)
    body_end = 16 + 16*n + 6*pairs
    assert header == b'MBL2' and len(original) == body_end + old_extra
    del original[body_end:]
    entries = {key: (freq, flags) for key, freq, _id, flags in struct.iter_unpack('<QHHB3x', original[16:16+n*16])}
    adjacent = phonetic_neighbors(args.cmu, entries)
    extra = bytearray()
    n_names = n_compounds = 0
    for i in range(n):
        start = 16 * (i+1)
        key, = struct.unpack_from('<Q', original, start)
        offset = start + 12
        original[offset] &= 31
        if key in names:
            original[offset] |= 32
            n_names += 1
        if key in hyphenated:
            original[offset] |= 64
            n_compounds += 1
        offset = len(extra) + 1 if key in adjacent else 0
        original[start+13:start+16] = offset.to_bytes(3, 'little')
        if offset:
            extra.extend(adjacent[key])
    struct.pack_into('<I', original, 12, len(extra))
    original.extend(extra)
    out = args.resource.with_suffix('.tmp')
    out.write_bytes(original)
    out.replace(args.resource)
    print('ambiguous name flags', n_names, 'possible split forms', n_compounds, 'phonetic source words', len(adjacent), 'adjacency bytes', len(extra))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cmu', type=Path, required=True)
    parser.add_argument('--names', type=Path, required=True)
    parser.add_argument('--wordnet', type=Path, required=True)
    parser.add_argument('--resource', type=Path, default=ROOT / 'Keyboard/Resources/lexical55-context.bin')
    build(parser.parse_args())
