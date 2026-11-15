"""Fit the bidirectional context and boundary statistics used by refine26.rs.

The external reserved SHA partition is never used. Pass --internal-split for
a model that also excludes the family of canonical messages with hash byte 1 < 44.
Only token frequencies, two-word statistics, and neighbor-case counts ship.
"""

import argparse
import bz2
import hashlib
import re
import struct
from collections import Counter, defaultdict
from pathlib import Path

from paired_text import key, pairs

ROOT = Path(__file__).resolve().parents[1]
WORD = re.compile(r"[\w]+(?:['’\-;:][\w]+)*")


def train(source, out, internal):
    paired, public = Counter(), Counter()
    contexts = [Counter() for _ in range(3)]
    everyday = [Counter() for _ in range(3)]
    caps = defaultdict(Counter)
    prevcase = defaultdict(Counter)
    for s, g in pairs(source):
        h = hashlib.sha256(key(g).encode()).digest()
        if h[0] < 38 or internal and h[1] < 44:
            continue
        surface = WORD.findall(g)
        ws = [w.lower() for w in surface]
        paired.update(ws)
        seq = ["^", *ws]
        for d, table in enumerate(contexts, 1):
            table.update(zip(seq, seq[d:]))
        for i, w in enumerate(surface):
            if i:
                caps[w.lower()][w] += 1
            if i + 1 < len(surface) and i:
                prevcase[(w.lower(), ws[i + 1])][w] += 1
    with bz2.open(ROOT / "training/eng_sentences_CC0.tsv.bz2", "rt") as f:
        for l in f:
            ws = WORD.findall(l.split("\t")[2].lower())
            public.update(ws)
            seq = ["^", *ws]
            for d, table in enumerate(everyday, 1):
                table.update(zip(seq, seq[d:]))
    vocab = sorted(
        w
        for w, n in (paired + public).items()
        if w.isascii()
        and len(w) <= 27
        and (w in paired or n >= 2 and (len(w) > 3 or n >= 6))
    )
    ids = {w: i + 1 for i, w in enumerate(["^", *vocab])}
    out.mkdir(parents=True, exist_ok=True)
    with (out / "vocab.tsv").open("w") as f:
        for w in ids:
            c = caps[w]
            dis = c.most_common(1)[0][0] if c else w
            if c and c[dis] < sum(c.values()) * 0.96:
                dis = w
            f.write(f"{w}\t{dis}\t{paired[w]}\t{public[w]}\n")
    with (out / "case.tsv").open("w") as f:
        for (w, b), forms in sorted(prevcase.items()):
            if w not in ids or b not in ids:
                continue
            winner, n = forms.most_common(1)[0]
            if winner != w and n >= 2 and n >= 0.97 * sum(forms.values()):
                f.write(f"{w}\t{b}\t{winner}\n")
    with (out / "context.bin").open("wb") as f:
        for k, (domain, outside) in enumerate(zip(contexts, everyday)):
            values = {}
            for (a, b), n in outside.items():
                if a not in ids or b not in ids or n < 2 or k > 0 and n < 3:
                    continue
                values[(ids[a] << 16) | ids[b]] = 0.28 * n
            for (a, b), n in domain.items():
                if a not in ids or b not in ids:
                    continue
                idx = (ids[a] << 16) | ids[b]
                values[idx] = values.get(idx, 0) + n
            f.write(struct.pack("<I", len(values)))
            for idx, n in sorted(values.items()):
                f.write(struct.pack("<IH", idx, min(65535, round(n * 4))))
    print(
        "vocab",
        len(ids),
        "paired tokens",
        sum(paired.values()),
        "public tokens",
        sum(public.values()),
    )


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("source", type=Path)
    p.add_argument("--internal-split", action="store_true")
    p.add_argument("--output", type=Path, default=ROOT / "model/refine26")
    a = p.parse_args()
    train(a.source, a.output, a.internal_split)
