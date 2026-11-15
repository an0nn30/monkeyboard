"""Train an automatic-edit veto. Prior replay decisions are supervision only.

Source partitions match real25. Features summarize type frequencies, name slots,
texting register and generic edit shapes; the fitted model has no word IDs.
"""

import argparse
import bz2
import gzip
import hashlib
import itertools
import json
import math
import random
import re
import struct
import zipfile
from collections import Counter, defaultdict
from difflib import SequenceMatcher
from functools import lru_cache
from pathlib import Path

import numpy as np
from paired_text import engine, key, pairs
from scipy.optimize import minimize
from scipy.sparse import csr_matrix

OUT = engine / "model/literal53"
BENCH = engine.parent / "Benchmarks"
WORD = re.compile(r"[A-Za-z]+(?:'[A-Za-z]+)*")
FNV = 14695981039346656037


def hash64(s):
    h = FNV
    for b in s.encode():
        h = ((h ^ b) * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    return h


def split(s):
    return WORD.findall(s.replace("’", "'"))


def partition(s):
    return hashlib.sha256(s.encode()).digest()[0]


def normalized(s):
    return [w.lower() for w in split(s)]


def aligned(typed, rendered):
    a, b = split(typed), split(rendered)
    sm = SequenceMatcher(None, a, b, autojunk=False)
    for tag, i, j, k, m in sm.get_opcodes():
        if tag != "replace":
            continue
        if j - i == m - k:
            yield from ((ix, b[k + ix - i]) for ix in range(i, j))
        elif j == i + 1 and m == k + 2 and a[i].lower() == (b[k] + b[k + 1]).lower():
            yield i, " ".join(b[k:m])


def source_data(paired, sms):
    groups, wrong, withheld, seen = defaultdict(list), Counter(), set(), set()
    for x, y in pairs(paired):
        k = key(y)
        if partition(k) < 38:
            withheld.add(k)
            continue
        groups[k].append((x, y))
    records = []
    for k, group in groups.items():
        records.append((group[0][1], "paired"))
        seen.add(k)
        if partition("lit53/calibrate/" + k) < 36:
            continue
        for x, y in group:
            src = split(x)
            for i, rep in aligned(x, y):
                if i < len(src) and src[i].lower() != rep.lower():
                    wrong[src[i].lower(), rep.lower()] += 1
    cc0 = engine / "training/eng_sentences_CC0.tsv.bz2"
    with bz2.open(cc0, "rt") as stream:
        for line in stream:
            s = line.split("\t")[2]
            k = key(s)
            if partition(k) >= 26 and k not in seen and k not in withheld:
                records.append((s, "cc0"))
                seen.add(k)
    if (
        hashlib.sha256(sms.read_bytes()).hexdigest()
        != "1587ea43e58e82b14ff1f5425c88e17f8496bfcdb67a583dbff9eefaf9963ce3"
    ):
        raise ValueError("Unexpected SMS source digest")
    with zipfile.ZipFile(sms) as archive:
        ham = [
            s[4:].strip()
            for s in archive.read("SMSSpamCollection").decode().splitlines()
            if s.startswith("ham\t")
        ]
    eligible = {
        key(s)
        for s in ham
        if 6 <= len(s.split()) <= 26
        and "  " not in s
        and re.fullmatch(r"[a-zA-Z][A-Za-z ,'.!?-]+[.!?]", s)
    }
    for s in ham:
        k = key(s)
        if k and k not in eligible and k not in seen and k not in withheld:
            records.append((s, "sms"))
            seen.add(k)
    return groups, wrong, records


def statistics(records):
    lex = defaultdict(lambda: [0] * 5)
    for s, source in records:
        words = split(s)
        low = [w.lower() for w in words]
        for i, w in enumerate(words):
            stat = lex[low[i]]
            stat[source == "sms"] += 1
            if i and w.istitle() and len(w) > 1:
                stat[2] += 1
                lex[low[i - 1]][3] += 1
                if i + 1 < len(words):
                    lex[low[i + 1]][4] += 1
    return {k: tuple(min(65535, v) for v in row) for k, row in lex.items()}


def replay_examples(build, split_name, archive):
    fixture = json.loads((BENCH / f"build{build}/{split_name}.json").read_bytes())
    with gzip.open(BENCH / f"build52/{archive}-52.jsonl.gz", "rt") as stream:
        outputs = {r["id"]: r["final"] for r in map(json.loads, stream)}
    found = {}
    for r in fixture:
        a = split(r["typed"])
        changed = dict(aligned(r["typed"], r["expected"]))
        for i, rep in aligned(r["typed"], outputs[r["id"]]):
            if a[i].lower() == rep.lower():
                continue
            if i in changed and changed[i] != rep:
                continue
            label = i not in changed
            if label and r["typed"] != r["expected"]:
                # The clean counterpart supplies these positives with reliable offsets.
                continue
            left = " ".join(a[max(0, i - 12) : i])
            right = " ".join(a[i + 1 : i + 7])
            found[(key(r["expected"]), i, a[i], rep)] = (left, a[i], right, rep, label)
    return list(found.values())


def nearest_words(word, dictionary):
    letters = "abcdefghijklmnopqrstuvwxyz"
    opts = set()
    for i in range(len(word) + 1):
        for c in letters:
            opts.add(word[:i] + c + word[i:])
            if i < len(word):
                opts.add(word[:i] + c + word[i + 1 :])
        if i < len(word):
            opts.add(word[:i] + word[i + 1 :])
    return sorted(
        (w for w in opts if w != word and dictionary.get(w, (0,))[0] >= 5),
        key=lambda w: (-dictionary[w][0], w),
    )


def named_examples(lex, records):
    rng = random.Random(53231)
    found, seen = [], set()
    for s, source in sorted(records, key=lambda row: hash64(row[0])):
        a = split(s)
        for i, word in enumerate(a):
            w = word.lower()
            if w in seen or not 3 <= len(w) <= 12 or i == 0:
                continue
            gen, sms, cap, _, _ = lex[w]
            name = word.istitle() and cap * 2 >= gen + sms and cap >= 2
            casual = source == "sms" and sms >= 2 and sms >= gen
            if not (name or casual):
                continue
            seen.add(w)
            rivals = nearest_words(w, lex)
            if rivals:
                rep = rivals[0]
                left = " ".join(a[max(0, i - 12) : i])
                right = " ".join(a[i + 1 : i + 7])
                typed = word.lower() if rng.randrange(3) == 0 else word
                found.append((left, typed, right, rep, True))
    return found


def clipped_log_odds(num, den):
    return max(0.0, min(4.0, math.log((num + 0.08) / (den + 1.0) * 12)))


def register_features(words):
    limited = words[-16:]
    return list(
        dict.fromkeys(limited + [f"{a} {b}" for a, b in itertools.pairwise(limited)])
    )


def fit_register(groups, records):
    rows = []
    count = Counter()
    rng = random.Random(53294)
    for sentence, origin in records:
        # Include noisy paired inputs so an unfamiliar typo does not by itself
        # make an ordinary sentence look like an informal text.
        if origin == "paired" and rng.randrange(2):
            sentence = rng.choice(groups[key(sentence)])[0]
        ws = normalized(sentence)
        if not ws:
            continue
        end = rng.randint(1, len(ws))
        fs = register_features(ws[max(0, end - 16) : end])
        count.update(fs)
        rows.append((fs, origin == "sms"))
    vocab = sorted(w for w, n in count.items() if n >= 3)
    ids = {w: i for i, w in enumerate(vocab)}
    col, bounds, ys = [], [0], []
    for fs, label in rows:
        col.extend(ids[w] for w in fs if w in ids)
        bounds.append(len(col))
        ys.append(label)
    x = csr_matrix((np.ones(len(col)), col, bounds), shape=(len(rows), len(vocab)))
    y = np.array(ys)
    sw = np.where(y, 7.0, 1.0)

    def objective(b):
        z = x @ b[1:] + b[0]
        err = (1.0 / (1.0 + np.exp(-np.clip(z, -50, 50))) - y) * sw
        loss = np.dot(sw, np.logaddexp(0.0, z) - y * z) + b[1:] @ b[1:] * 2
        return loss / sw.sum(), np.r_[err.sum(), x.T @ err + 4 * b[1:]] / sw.sum()

    fitted = minimize(
        objective,
        np.zeros(1 + len(vocab)),
        jac=True,
        method="L-BFGS-B",
        options={"maxiter": 100, "ftol": 1.0e-11},
    ).x
    terms = {
        w: float(np.float32(v)) for w, v in zip(vocab, fitted[1:]) if abs(v) > 0.10
    }
    terms[""] = float(np.float32(fitted[0]))
    return terms


@lru_cache(maxsize=131072)
def distance(a, b):
    old = list(range(len(b) + 1))
    older = old
    for i, ch in enumerate(a):
        cur = [i + 1]
        for j, other in enumerate(b):
            x = min(old[j + 1] + 1, cur[-1] + 1, old[j] + (ch != other))
            if i and j and a[i - 1] == other and ch == b[j - 1]:
                x = min(x, older[j - 1] + 1)
            cur.append(x)
        older, old = old, cur
    return old[-1]


def features(lex, wrong, register, left, typed, right, proposal, mask=False):
    w, v = typed.lower(), proposal.lower()
    zero = (0,) * 5
    gen, sms, caps, _, _ = zero if mask else lex.get(w, zero)
    dst = lex.get(v, zero)
    bef, aft = normalized(left)[-8:], normalized(right)[:3]
    around = [lex.get(word, zero) for word in bef + aft]
    styles = [clipped_log_odds(c[1], c[0]) for c in around]
    style = max(styles, default=0.0)
    style_sum = min(8.0, sum(styles))
    unknown = min(3, sum(a[0] + a[1] == 0 for a in around))
    name = caps / (gen + sms + 0.5)

    def slot(x, i):
        c = lex.get(x, zero)
        return min(1.0, c[i] / (c[0] + c[1] + 2))

    name_slot = max(slot(bef[-1], 3) if bef else 0.0, slot(aft[0], 4) if aft else 0.0)
    direction = math.log1p(wrong.get((w, v), 0))
    upper = typed.istitle() and bool(bef)
    observed = math.log1p(gen)
    local = clipped_log_odds(sms, gen)
    stripped = w.replace("'", "") == v.replace("'", "")
    suffix = v == w + "g" and w.endswith("in")
    vowels = sum(c in "aeiou" for c in w) / max(len(w), 1)
    words = normalized(left)[-12:] + [w] + normalized(right)[:3]
    logit = sum(register.get(f, 0.0) for f in register_features(words)) + register[""]
    casualness = max(0.0, min(4.0, logit + 1.0))
    ed = min(4, distance(w, v.replace(" ", "")))
    # Non-identifying features are shared across all target and candidate words.
    return [
        1.0,
        min(len(w), 12) / 6.0,
        len(w) < 4,
        upper,
        typed.isupper() and len(w) > 1,
        observed,
        math.log1p(sms),
        math.log1p(dst[0]),
        local,
        style,
        style_sum,
        unknown,
        name,
        name_slot,
        upper * name_slot,
        upper * name,
        len(w) > 4 and gen == 0,
        math.log1p(dst[1]),
        stripped,
        suffix,
        " " in v,
        vowels,
        w[0] == v[0],
        abs(len(w) - len(v)),
        direction,
        direction * style,
        local * style,
        local * stripped,
        name_slot * (gen == 0),
        upper * (gen == 0),
        style * (gen == 0),
        unknown * (gen == 0),
        (len(w) < 4) * style,
        (sms > 0 and gen == 0),
        (gen == 0 and dst[0] < 5),
        suffix * style,
        stripped * style,
        w in normalized(left) or w in normalized(right),
        name * (not upper),
        float(sms > 0 and dst[0] == 0),
        casualness,
        casualness * stripped,
        casualness * (gen == 0),
        casualness * local,
        casualness * (sms > 0),
        casualness * direction,
        casualness * ed,
        ed,
        ed * (gen == 0),
        float(ed >= 2 and dst[0] < 4),
        float(ed >= 2) * upper,
        float(ed >= 2) * name_slot,
    ]


def write_binary(path, rows, fmt):
    values = sorted((hash64(k), v) for k, v in rows.items())
    assert len(values) == len({k for k, _ in values})
    with path.open("wb") as f:
        for k, v in values:
            f.write(struct.pack("<Q" + fmt, k, *v))


def train(args):
    OUT.mkdir(exist_ok=True)
    groups, wrong, records = source_data(args.paired, args.sms)
    lex = statistics(records)
    register = fit_register(groups, records)
    rng = random.Random(53328)
    desktop_fit, desktop_cal = [], []
    for k, group in groups.items():
        is_cal = partition("lit53/calibrate/" + k) < 36
        subset = desktop_cal if is_cal else desktop_fit
        for typed, gold in group:
            if not is_cal and rng.randrange(4):
                continue
            a = split(typed)
            for i, rep in aligned(typed, gold):
                if a[i].lower() == rep.lower():
                    continue
                subset.append(
                    (
                        " ".join(a[max(0, i - 12) : i]),
                        a[i],
                        " ".join(a[i + 1 : i + 7]),
                        rep,
                        False,
                    )
                )
    old, dev = [], []
    for n, archive in [
        (46, "public1"),
        (48, "public2"),
        (49, "public3"),
        (50, "public4"),
    ]:
        old.extend(replay_examples(n, "public", archive))
    for n, archive in [
        (41, "practice1"),
        (45, "practice2"),
        (47, "practice3"),
        (49, "practice4"),
        (50, "practice5"),
    ]:
        old.extend(replay_examples(n, "fresh", archive))
    dev += replay_examples(51, "public", "public") + replay_examples(
        51, "fresh", "fresh"
    )
    names = named_examples(lex, records)

    def matrix(rows, mask_names=False):
        return np.array(
            [
                features(
                    lex, wrong, register, l, w, rr, v, mask_names and hash64(w) % 2 == 0
                )
                for l, w, r, v, y in rows
                for rr in ("", r)
            ]
        )

    fit = desktop_fit + old + names
    x = np.concatenate((matrix(desktop_fit + old), matrix(names, mask_names=True)))
    y = np.repeat([row[-1] for row in fit], 2)
    weights = np.repeat(
        [0.34] * len(desktop_fit) + [12.0] * len(old) + [1.0] * len(names), 2
    )

    def objective(b):
        z = x @ b
        reg = 0.0008
        loss = np.dot(weights, np.logaddexp(0.0, z) - y * z) / weights.sum()
        err = (1.0 / (1.0 + np.exp(-np.clip(z, -50, 50))) - y) * weights
        return loss + reg * (b @ b) / 2, err @ x / weights.sum() + reg * b

    b = minimize(
        objective,
        np.zeros(x.shape[1]),
        jac=True,
        method="L-BFGS-B",
        options={"maxiter": 500, "ftol": 1e-12},
    ).x
    # The veto occurs at either decision time. Calibrate against unintended
    # loss of repairs on desktop references held out of veto fitting and on prior fresh decisions.
    cal_scores = (matrix(desktop_cal) @ b).reshape(-1, 2).max(1)
    dev_scores = (matrix(dev) @ b).reshape(-1, 2).max(1)
    positives = np.array([row[-1] for row in dev])

    def stratum(row):
        w, v = row[1].lower(), row[3].lower()
        if w.replace("'", "") == v.replace("'", ""):
            return 0
        gen, sms, *_ = lex.get(w, (0,) * 5)
        if sms > 0 and sms >= gen:
            return 1
        if gen == 0:
            return 2
        return 3

    ck = np.array(list(map(stratum, desktop_cal)))
    dk = np.array(list(map(stratum, dev)))
    thresholds = []
    for j in range(4):
        c = cal_scores[ck == j]
        d = dev_scores[dk == j]
        yj = positives[dk == j]
        cap = max(12, len(c) // 950)
        # Choose a broad half-logit bin. Give correct repairs triple the cost of
        # a single missed literal, with a separate collateral budget per stratum.
        print(
            "Calibration stratum",
            j,
            "desktop sample",
            len(c),
            "sweep",
            [
                (
                    t,
                    int((c >= t).sum()),
                    int(((d >= t) & yj).sum()),
                    int(((d >= t) & ~yj).sum()),
                )
                for t in (0, 1, 2, 3, 4, 5, 6, 9)
            ],
            flush=True,
        )
        candidates = [t for t in np.arange(-2.0, 15.5, 0.5) if (c >= t).sum() <= cap]
        threshold = max(
            candidates,
            key=lambda t: (
                int(((d >= t) & yj).sum()) - 3 * int(((d >= t) & ~yj).sum()),
                -(c >= t).sum(),
                -abs(t - 0.5),
            ),
        )
        thresholds.append(float(threshold))
    ct = np.array(thresholds)[ck]
    dt = np.array(thresholds)[dk]
    score_rows = [
        (r[1], r[3], bool(r[-1]), round(float(z), 2), float(t))
        for r, z, t in zip(dev, dev_scores, dt)
        if r[-1] or z >= t
    ]
    print(json.dumps(score_rows))
    report = {
        "source_messages": dict(Counter(source for _, source in records)),
        "fit_desktop": len(desktop_fit),
        "fit_replay": len(old),
        "fit_replay_literal": sum(r[-1] for r in old),
        "fit_named_and_casual": len(names),
        "calibration_desktop": len(desktop_cal),
        "calibration_desktop_vetoes": int((cal_scores >= ct).sum()),
        "development_decisions": len(dev),
        "development_literal_decisions": int(positives.sum()),
        "development_restored": int(((dev_scores >= dt) & positives).sum()),
        "development_correct_repairs_vetoed": int(
            ((dev_scores >= dt) & ~positives).sum()
        ),
        "feature_count": len(b),
        "thresholds": thresholds,
    }
    print(json.dumps(report, indent=2))
    write_binary(OUT / "register.bin", {w: (v,) for w, v in register.items()}, "f")
    write_binary(OUT / "lex.bin", lex, "HHHHH")
    write_binary(
        OUT / "channel.bin",
        {w + " " + v: (min(65535, n),) for (w, v), n in wrong.items()},
        "H",
    )
    (OUT / "rank.bin").write_bytes(
        struct.pack("<" + "f" * (len(b) + len(thresholds)), *thresholds, *b)
    )
    (OUT / "fit.json").write_text(json.dumps(report, indent=2) + "\n")


def verify_library(path):
    import ctypes

    class PackedTable:
        def __init__(self, filename, fmt, pair_key=False):
            self.rows = {
                k: vals if len(vals) > 1 else vals[0]
                for k, *vals in struct.iter_unpack(fmt, (OUT / filename).read_bytes())
            }
            self.pair_key = pair_key

        def get(self, term, default):
            return self.rows.get(
                hash64(" ".join(term) if self.pair_key else term), default
            )

        def __getitem__(self, term):
            return self.get(term, None)

    lex = PackedTable("lex.bin", "<QHHHHH")
    register = PackedTable("register.bin", "<Qf")
    channel = PackedTable("channel.bin", "<QH", pair_key=True)
    data = (OUT / "rank.bin").read_bytes()
    fitted = struct.unpack("<" + "f" * (len(data) // 4), data)
    abi = ctypes.CDLL(str(path.resolve())).mb_keep_literal53_v1
    abi.argtypes = [ctypes.c_char_p] * 4
    abi.restype = ctypes.c_int32
    count = 0
    for build, kind, archive in [
        (51, "fresh", "fresh"),
        (51, "public", "public"),
        (50, "public", "public4"),
        (48, "public", "public2"),
        (46, "public", "public1"),
        (49, "public", "public3"),
    ]:
        for l, t, r, v, _ in replay_examples(build, kind, archive):
            general, sms, *_ = lex.get(t.lower(), (0,) * 5)
            if t.lower().replace("'", "") == v.lower().replace("'", ""):
                group = 0
            elif sms and sms >= general:
                group = 1
            elif general == 0:
                group = 2
            else:
                group = 3
            for right in ("", r):
                x = features(lex, channel, register, l, t, right, v)
                expected = sum(a * b for a, b in zip(x, fitted[4:])) >= fitted[group]
                actual = abi(*(s.encode() for s in (l, t, right, v)))
                if actual != expected:
                    raise AssertionError((l, t, right, v, expected, actual))
                count += 1
    print(f"{count} Rust/Python decisions match")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    fit = actions.add_parser("fit")
    fit.add_argument("paired", type=Path)
    fit.add_argument("sms", type=Path)
    check = actions.add_parser("verify")
    check.add_argument("library", type=Path)
    args = parser.parse_args()
    if args.action == "fit":
        train(args)
    else:
        verify_library(args.library)
