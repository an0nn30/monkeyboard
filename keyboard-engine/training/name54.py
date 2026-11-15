"""Fit a capitalization-based name veto for new residual proposals only."""

import argparse
import bz2
import hashlib
import json
import re
import struct
from collections import Counter, defaultdict
from pathlib import Path

from paired_text import engine, key, pairs

OUT = engine / "model/name54"
TOKEN = re.compile(r"[A-Za-z]+(?:'[A-Za-z]+)*")


def digest(s):
    return hashlib.sha256(s.encode()).digest()


def fit(paired, propernames):
    basic = {
        w.lower()
        for w in propernames.read_text().splitlines()
        if w.isascii() and w.isalpha()
    }
    stable = set()
    for row in (engine / "model/surface31/vocab.tsv").read_text().splitlines():
        w, _, _, medial, _ = row.split("\t")
        if medial.istitle() and len(w) > 1:
            stable.add(w)
    train, cal = defaultdict(Counter), defaultdict(Counter)
    withheld = set()
    seen = set()

    def count(s, cc0=False):
        norm = key(s)
        if norm in seen or norm in withheld:
            return
        seen.add(norm)
        h = digest(norm)
        if h[0] < (26 if cc0 else 38):
            return
        target = cal if h[1] < 48 else train
        for w in TOKEN.findall(s.replace("’", "'"))[1:]:
            if len(w) > 1 and w.isalpha() and (w.islower() or w.istitle()):
                target[w.lower()][int(w.istitle())] += 1

    observed_typos = Counter()
    for typed, s in pairs(paired):
        if digest(key(s))[0] < 38:
            withheld.add(key(s))
        else:
            count(s)
            # Exclude the established desktop calibration bucket from this
            # reliability estimate. A token removed in a real S:/C: pair
            # is evidence against unconditional protection of that spelling.
            if digest("lit53/calibrate/" + key(s))[0] >= 36:
                raw = Counter(TOKEN.findall(typed.lower()))
                gold = Counter(TOKEN.findall(s.lower()))
                observed_typos.update(raw - gold)
    with bz2.open(engine / "training/eng_sentences_CC0.tsv.bz2", "rt") as f:
        for line in f:
            count(line.split("\t")[2], True)

    def group(w):
        return (w in basic) + 2 * (w in stable)

    classes = [[] for _ in range(4)]
    for w, c in train.items():
        classes[group(w)].append((c[1] + 0.5) / (c.total() + 1))
    prior = [sum(a) / len(a) if a else 0.5 for a in classes]
    vocab = set(train) | basic | stable

    def score(w):
        c = train.get(w, {})
        return (c.get(1, 0) + 3 * prior[group(w)]) / (c.get(0, 0) + c.get(1, 0) + 3)

    # Learn the cut on separate references. Penalize a lowercased common word
    # being tagged as a name five times as much as one missed capitalized token.
    options = {}
    for t in (0.66, 0.7, 0.74, 0.78, 0.82, 0.86, 0.9, 0.94, 0.97):
        tp = fp = 0
        for w, c in cal.items():
            if w in vocab and score(w) >= t:
                tp += c[1]
                fp += c[0]
        options[t] = (tp - 5 * fp, tp, fp)
    t = max(options, key=lambda x: options[x][0])
    # A dictionary name with no corpus observations still has positive evidence.
    # Assign its operating point from comparable, observed names in that class.
    # Mixed-use words must pass the same calibrated surface threshold as others.
    names = sorted(
        w
        for w in vocab
        if score(w) >= t or (w in basic and w not in train and prior[group(w)] >= 0.5)
    )

    def h64(s):
        h = 14695981039346656037
        for b in s.encode():
            h = ((h ^ b) * 1099511628211) & 0xFFFFFFFFFFFFFFFF
        return h

    vals = sorted(map(h64, names))
    assert len(set(vals)) == len(vals)
    OUT.mkdir(exist_ok=True)
    (OUT / "names.bin").write_bytes(b"".join(struct.pack("<Q", h) for h in vals))
    strong = [
        w
        for w in names
        if len(w) >= 4
        and observed_typos[w] == 0
        and (
            (train.get(w, {}).get(0, 0) == 0 and w in basic)
            or (train.get(w, {}).get(1, 0) >= 4 and score(w) >= max(t, 0.95))
        )
    ]
    sv = sorted(map(h64, strong))
    (OUT / "originals.bin").write_bytes(b"".join(struct.pack("<Q", h) for h in sv))
    report = {
        "strong_originals": len(sv),
        "known_names": len(vals),
        "capitalized_training_tokens": sum(c[1] for c in train.values()),
        "lowercase_training_tokens": sum(c[0] for c in train.values()),
        "threshold": t,
        "priors": prior,
        "calibration_title_matches": options[t][1],
        "calibration_lowercase_matches": options[t][2],
        "propername_source_sha256": hashlib.sha256(
            propernames.read_bytes()
        ).hexdigest(),
    }
    (OUT / "fit.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))
    return names


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("paired", type=Path)
    p.add_argument(
        "--propernames", type=Path, default=Path("/usr/share/dict/propernames")
    )
    args = p.parse_args()
    fit(args.paired, args.propernames)
