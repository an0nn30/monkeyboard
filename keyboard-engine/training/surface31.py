"""Learn case surfaces and character/word evidence for local bidirectional cloze slots.

The mandatory SHA[0] split excludes the customer reservation. The optional
shadow model also excludes SHA[1]<44. Context features use at most two observed
neighbors (within distance two); the serialization never stores a message.
"""

import argparse
import bz2
import hashlib
import re
import struct
import tarfile
from collections import Counter, defaultdict
from pathlib import Path

from paired_text import key, pairs

ROOT = Path(__file__).resolve().parents[1]
WORD = re.compile(r"[^\W_]+(?:['’\-;:][^\W_]+)*")
OFFSETS = (
    (-1, 1),
    (-2, -1),
    (1, 2),
    (-2, 1),
    (-1, 2),
    (-1, 0),
    (1, 0),
    (-2, 0),
    (2, 0),
)


def surfaces(s):
    return WORD.findall(s.replace("’", "'"))


def fit(path, out, shadow, wordnet):
    paired, public = Counter(), Counter()
    records = []
    forms = defaultdict(Counter)
    for s, g in pairs(path):
        h = hashlib.sha256(key(g).encode()).digest()
        if h[0] < 38 or shadow and h[1] < 44:
            continue
        rows = surfaces(g)
        ws = [w.lower() for w in rows]
        paired.update(ws)
        for i, w in enumerate(rows):
            forms[w.lower(), int(i == 0)][w] += 1
        records.append((True, rows))
    public_rows = []
    with bz2.open(ROOT / "training/eng_sentences_CC0.tsv.bz2", "rt") as f:
        for row in f:
            text = row.split("\t")[2]
            ws = surfaces(text)
            public.update(w.lower() for w in ws)
            public_rows.append((False, ws))
    vocab = sorted(
        w
        for w, n in (paired + public).items()
        if len(w) <= 30 and (w in paired or w.isalpha() and n >= 1)
    )
    ids = {w: i for i, w in enumerate(["<unk>", "^", *vocab])}
    out.mkdir(exist_ok=True, parents=True)
    # WordNet contributes only literal protection, never a candidate target.
    # The dictionary's existing redistributable license is in model/semantics.
    if (
        hashlib.sha256(wordnet.read_bytes()).hexdigest()
        != "640db279c949a88f61f851dd54ebbb22d003f8b90b85267042ef85a3781d3a52"
    ):
        raise ValueError("Expected the Princeton WordNet 3.0 source archive")
    lexicon = set()
    with tarfile.open(wordnet, "r:gz") as z:
        for pos in ("noun", "verb", "adj", "adv"):
            for l in z.extractfile("WordNet-3.0/dict/index." + pos):
                if l.startswith(b" "):
                    continue
                w = l.split(None, 1)[0].decode("ascii")
                if w.isalpha() and w not in ids:
                    lexicon.add(w)
    with (out / "protect.txt").open("w") as f:
        for w in sorted(lexicon):
            f.write(w + "\n")
    with (out / "vocab.tsv").open("w") as f:
        for w in ids:
            displays = []
            for pos in (0, 1):
                c = forms[w, pos]
                candidate, support = c.most_common(1)[0] if c else (w, 0)
                displays.append(
                    candidate
                    if support >= 2 and support >= sum(c.values()) * 0.92
                    else w
                )
            f.write(f"{w}\t{paired[w]}\t{public[w]}\t{displays[0]}\t{displays[1]}\n")
    # Public trigrams only ship when at least two occurrences agree; the
    # source corpus still supplies a broad one-edit dictionary.
    tables = [Counter() for _ in OFFSETS]
    pub = [Counter() for _ in OFFSETS]
    for ispair, ws in records + public_rows:
        ts = [0, 1] + [ids.get(w.lower(), 0) for w in ws] + [0, 0]
        for i in range(2, len(ts) - 2):
            w = ts[i]
            if not w:
                continue
            for k, (a, b) in enumerate(OFFSETS):
                x = ts[i + a]
                y = ts[i + b] if b else 0
                if x and (not b or y):
                    (tables if ispair else pub)[k][(x, y, w)] += 1
    with (out / "context.bin").open("wb") as f:
        for core, general in zip(tables, pub):
            entries = defaultdict(Counter)
            for (x, y, w), n in general.items():
                if n >= 3:
                    entries[(x << 16) | y][w] += min(12, n * 0.275)
            for (x, y, w), n in core.items():
                entries[(x << 16) | y][w] += n
            keep = []
            for k, cs in entries.items():
                ranked = [
                    (w, min(65535, round(n * 2)))
                    for w, n in cs.most_common(14)
                    if n >= 1.45
                ]
                if ranked:
                    keep.append((k, ranked))
            f.write(struct.pack("<I", len(keep)))
            for k, rs in sorted(keep):
                f.write(struct.pack("<IB", k, len(rs)))
                for w, n in rs:
                    f.write(struct.pack("<HH", w, n))
    print(
        len(records),
        "paired sentences,",
        len(ids),
        "words,",
        sum(p.stat().st_size for p in out.iterdir()),
        "bytes",
    )


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("source", type=Path)
    ap.add_argument("--output", type=Path, default=ROOT / "model/surface31")
    ap.add_argument("--shadow", action="store_true")
    ap.add_argument("--wordnet", required=True, type=Path)
    a = ap.parse_args()
    fit(a.source, a.output, a.shadow, a.wordnet)
