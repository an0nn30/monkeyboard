"""Fit a bounded word-channel and class trigram model on the disjoint training partition."""

import argparse
import hashlib
import math
import re
import struct
import bz2
from collections import Counter, defaultdict
from functools import lru_cache
from pathlib import Path

from paired_text import key, pairs

ENGINE = Path(__file__).resolve().parents[1]


def words(s):
    return [
        w.strip('.,?!":()') for w in s.replace("’", "'").split() if w.strip('.,?!":()')
    ]


def distance(a, b):
    """Alignment only. The runtime channel separately models transpositions."""
    if a == b:
        return 0
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a):
        row = [i + 1]
        for j, y in enumerate(b):
            row.append(min(row[-1] + 1, prev[j + 1] + 1, prev[j] + (x != y)))
        prev = row
    return prev[-1]


def aligned(src, dst):
    # Boundary errors in this corpus are local. For unequal lengths, decide where
    # the missing or extra boundary lies by comparing both adjacent alignments.
    if len(src) == len(dst):
        yield from zip(src, [(w,) for w in dst])
        return
    if abs(len(src) - len(dst)) != 1:
        return
    s, d = (src, dst) if len(src) < len(dst) else (dst, src)
    losses = [0] * len(s)
    after = sum(distance(a, b) for a, b in zip(s, d[1:]))
    before = 0
    for i, w in enumerate(s):
        after -= distance(w, d[i + 1])
        losses[i] = before + after + distance(w, d[i] + d[i + 1])
        before += distance(w, d[i])
    j = losses.index(min(losses))
    for i in range(j):
        yield src[i], (dst[i],)
    if len(src) == len(s):
        yield src[j], tuple(dst[j : j + 2])
        yield from zip(src[j + 1 :], [(w,) for w in dst[j + 2 :]])
    else:
        yield " ".join(src[j : j + 2]), (dst[j],)
        yield from zip(src[j + 2 :], [(w,) for w in dst[j + 1 :]])


def induce_classes(bigrams, vocabulary):
    # Cluster words that repeatedly occur with the same immediate neighbors.
    # Normalize each context by its marginal frequency and each vector by L2.
    marginal = Counter()
    contexts = defaultdict(Counter)
    for (a, b), n in bigrams.items():
        contexts[a][("r", b)] += n
        contexts[b][("l", a)] += n
        marginal["r", b] += n
        marginal["l", a] += n
    vectors = {}
    postings = defaultdict(list)
    for w in vocabulary:
        v = {k: n**0.75 / marginal[k] ** 0.35 for k, n in contexts[w].items()}
        norm = math.sqrt(sum(x * x for x in v.values())) or 1
        vectors[w] = {k: x / norm for k, x in v.items()}
        for k, x in vectors[w].items():
            if x > 0.055:
                postings[k].append(w)
    links = []
    for i, w in enumerate(vocabulary):
        candidates = set(
            z for k, x in vectors[w].items() if x > 0.20 for z in postings[k] if z < w
        )
        if w in ("^", "$"):
            continue
        for z in candidates:
            if z in ("^", "$"):
                continue
            sim = sum(x * vectors[z].get(k, 0) for k, x in vectors[w].items())
            if sim >= 0.83:
                links.append((sim, w, z))
    # Greedily merge only when both cluster prototypes remain similar.
    root = {x: x for x in vocabulary}
    groups = {x: [x] for x in vocabulary}
    for sim, a, b in sorted(links, reverse=True):
        a, b = root[a], root[b]
        if a == b:
            continue
        if sum(x * vectors[b].get(k, 0) for k, x in vectors[a].items()) < 0.79:
            continue
        if len(groups[a]) < len(groups[b]):
            a, b = b, a
        for x in groups.pop(b):
            root[x] = a
            groups[a].append(x)
    ids = {w: i + 1 for i, w in enumerate(sorted(groups))}
    return {w: ids[root[w]] for w in vocabulary}


@lru_cache(maxsize=65536)
def blocks(gold, raw):
    """Segment aligned tokens into common character chunks. A 2:1, 1:2
    or 2:2 replacement captures repeated productive spelling confusions."""
    table = {(0, 0): (0.0, ())}
    for i in range(len(gold) + 1):
        for j in range(len(raw) + 1):
            if i == j == 0:
                continue
            best = (float("inf"), ())
            for a, b in ((1, 1), (1, 0), (0, 1), (2, 1), (1, 2), (2, 2)):
                if a > i or b > j:
                    continue
                x, y = gold[i - a : i], raw[j - b : j]
                if x == y:
                    cost = 0.0
                elif (a, b) == (1, 1):
                    cost = 1.1
                elif not a or not b:
                    cost = 1.0
                elif x and y and (x[0] == y[0] or x[-1] == y[-1]):
                    continue
                else:
                    cost = 1.45 if (a, b) != (2, 2) or x == y[::-1] else 1.95
                prev, path = table[i - a, j - b]
                if prev + cost < best[0]:
                    best = prev + cost, path + ((x, y),)
            table[i, j] = best
    return table[len(gold), len(raw)][1]


def train(source, dest):
    uni, bi, tri, channel = Counter(), Counter(), Counter(), Counter()
    internal, anywhere = defaultdict(Counter), defaultdict(Counter)
    ntrain = 0
    for noisy, clean in pairs(source):
        if hashlib.sha256(key(clean).encode()).digest()[0] < 38:
            continue
        raw = words(clean)
        ws = [w.lower() for w in raw]
        if not ws:
            continue
        ntrain += 1
        for i, (w, surface) in enumerate(zip(ws, raw)):
            anywhere[w][surface] += 1
            if i:
                internal[w][surface] += 1
        sentence = ["^", *ws, "$"]
        uni.update(sentence)
        bi.update(zip(sentence, sentence[1:]))
        tri.update(zip(sentence, sentence[1:], sentence[2:]))
        for observed, intended in aligned([w.lower() for w in words(noisy)], ws):
            if observed != " ".join(intended):
                channel[observed, intended] += 1

    dest.mkdir(parents=True, exist_ok=True)
    vocab = sorted(uni)
    ids = {w: i + 1 for i, w in enumerate(vocab)}
    classes = induce_classes(bi, vocab)
    # Count singleton English words in the same public CC0 corpus used to
    # build the base dictionary. Short, unattested strings are not added.
    public = Counter()
    public_bi, public_tri = Counter(), Counter()
    confusable = {raw for (raw, _), n in channel.items() if raw in ids and n >= 2}
    with bz2.open(ENGINE / "training/eng_sentences_CC0.tsv.bz2", "rt") as f:
        for line in f:
            fields = line.rstrip().split("\t")
            if len(fields) >= 3:
                ws = re.findall(r"[a-z]+(?:'[a-z]+)*", fields[2].lower())
                public.update(ws)
                sentence = ["^", *ws]
                public_bi.update(
                    (a, b)
                    for a, b in zip(sentence, sentence[1:])
                    if a in ids and b in ids and (a in confusable or b in confusable)
                )
                public_tri.update(
                    (a, b, c)
                    for a, b, c in zip(sentence, sentence[1:], sentence[2:])
                    if a in ids and b in confusable and c in ids
                )
    ordinary = {
        line.split("\t", 1)[0]
        for line in (ENGINE / "model/words.tsv").read_text().splitlines()
    }
    ordinary.update((ENGINE / "model/semantics/vocab.txt").read_text().splitlines())
    ordinary.update(vocab)
    with (dest / "literals.txt").open("w") as f:
        for w in sorted(public):
            if w not in ordinary and len(w) > 2:
                f.write(w + "\n")

    with (dest / "vocab.tsv").open("w") as f:
        for w in vocab:
            counts = internal[w] or anywhere[w]
            # A word seen only in first position carries no normal capitalization signal.
            surface = counts.most_common(1)[0][0] if internal[w] else w
            if counts and counts[surface] < 0.94 * sum(counts.values()):
                surface = w
            if not counts or w in ("^", "$"):
                surface = w
            f.write(f"{w}\t{surface}\t{uni[w]}\t{classes[w]}\n")

    cb, ct, cu = Counter(), Counter(), Counter()
    for w, n in uni.items():
        cu[(classes[w],)] += n
    for (a, b), n in bi.items():
        cb[classes[a], classes[b]] += n
    for (a, b, c), n in tri.items():
        ct[classes[a], classes[b], classes[c]] += n
    with (dest / "local.bin").open("wb") as f:
        for table in (bi, tri, cu, cb, ct, public_bi, public_tri):
            records = []
            for seq, n in table.items():
                packed = 0
                for w in seq:
                    packed = (packed << 16) | (ids[w] if isinstance(w, str) else w)
                records.append((packed, n))
            f.write(struct.pack("<I", len(records)))
            for packed, n in sorted(records):
                f.write(struct.pack("<QI", packed, n))
    # Aggregate local character substitutions across word types to recover
    # previously unseen phonetic variants and multi-letter misspellings.
    confusion = Counter()
    for (raw, intended), n in channel.items():
        if (
            len(intended) != 1
            or " " in raw
            or not raw.isascii()
            or not intended[0].isascii()
        ):
            continue
        for x, y in blocks(intended[0], raw):
            if x != y:
                confusion[x, y] += min(n, 8)
    with (dest / "chunks.tsv").open("w") as f:
        for (x, y), n in sorted(confusion.items()):
            if n < 3:
                continue
            den = (
                sum(v * max(1, len(w)) for w, v in uni.items())
                if not x
                else sum(v * w.count(x) for w, v in uni.items())
            )
            # Geometric mean of observed channel cost and a character edit
            # prior prevents common key errors from becoming free transitions.
            cost = max(0.40, (-math.log((n + 0.3) / (den + 4)) - 1.15) / 4.1)
            f.write(f"{x}\t{y}\t{cost:.4f}\n")
    with (dest / "channel.tsv").open("w") as f:
        for (observed, intended), n in sorted(channel.items()):
            # Single occurrences are handled by the generic edit channel, except
            # for longer nonphonetic edits for which the surface is unambiguous.
            if n < 2 and (
                not observed.isalpha()
                or len(observed) < 4
                or len(intended) > 1
                or distance(observed, intended[0]) <= 2
            ):
                continue
            f.write(f"{observed}\t{','.join(str(ids[w]) for w in intended)}\t{n}\n")
    print(
        f"{ntrain} training pairs, {len(vocab)} words, {len(cu)} classes, {len(bi)} bigrams, {len(tri)} lexical trigrams"
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--output", type=Path, default=ENGINE / "model/denoise22")
    args = parser.parse_args()
    train(args.source, args.output)
