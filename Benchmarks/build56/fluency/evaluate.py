"""Report real-word repairs, exact messages and collateral for fixed scoring policies."""

import argparse
import gzip
import json
import sys
from pathlib import Path

from wordfreq import zipf_frequency

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "Benchmarks/build55"))
from metrics import evaluate


def corrections(rows, weight, threshold, conditional, min_margin=0.0, min_length=0):
    def score(option):
        word, masked, left, right = option
        # A variant predicts the observed word and up to six following tokens.
        # The prefix and context-free frequency bias cancel in pair comparison.
        likelihood = left + sum(right[:6]) - conditional * zipf_frequency(word, "en")
        return masked + weight * likelihood

    changes = {}
    for line, a, b, options in rows:
        if len(options[0][0]) < min_length:
            continue
        ranked = sorted(options[1:], key=score, reverse=True)
        best = ranked[0]
        gain = score(best) - score(options[0])
        margin = score(best) - score(ranked[1]) if len(ranked) > 1 else float("inf")
        if gain >= threshold and margin >= min_margin and best[1] > -14:
            changes.setdefault(line, []).append((a, b, best[0]))
    return changes


def output(rendered, changes):
    results = {}
    for key, line in rendered.items():
        revised = line
        for a, b, word in reversed(changes.get(line, [])):
            revised = revised[:a] + word + revised[b:]
        results[key] = revised
    return results


def read_rendered(path):
    with gzip.open(path, "rt") as stream:
        return {r["id"]: r["final"] for r in map(json.loads, stream)}


def datasets():
    b = ROOT / "Benchmarks"
    for build, legacy, shipped in [
        (
            "55",
            b / "build55/primary/baseline.jsonl.gz",
            b / "build55/primary/candidate.jsonl.gz",
        ),
        (
            "54",
            b / "build54/holdout-54.jsonl.gz",
            b / "build55/validation/historical54.jsonl.gz",
        ),
    ]:
        cases = json.loads((b / f"build{build}/holdout/cases.json").read_bytes())
        for label, path in [("legacy", legacy), ("shipped", shipped)]:
            rendered = read_rendered(path)
            yield f"{build}-{label}", cases, rendered


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("scores", type=Path)
    p.add_argument("--weight", type=float, nargs="+", default=[0.0, 0.5, 1.0, 2.0])
    p.add_argument("--threshold", type=float, nargs="+", default=[4.0, 6.0, 8.0, 10.0])
    p.add_argument("--conditional", type=float, default=0.5)
    p.add_argument("--min-margin", type=float, default=0.0)
    p.add_argument("--min-length", type=int, default=0)
    p.add_argument("--overlay-55", type=Path)
    p.add_argument("--overlay-54", type=Path)
    args = p.parse_args()
    rows = json.loads(args.scores.read_bytes())
    data = list(datasets())
    for number, path in [(55, args.overlay_55), (54, args.overlay_54)]:
        if path:
            cases = json.loads(
                (ROOT / f"Benchmarks/build{number}/holdout/cases.json").read_bytes()
            )
            rendered = read_rendered(path)
            data.append((f"{number}-overlay", cases, rendered))
    for w in args.weight:
        for t in args.threshold:
            changes = corrections(
                rows, w, t, args.conditional, args.min_margin, args.min_length
            )
            record = {}
            for name, cases, rendered in data:
                m = evaluate(cases, output(rendered, changes))
                record[name] = [
                    m["real-word_fixed"],
                    m["noisy_exact"],
                    m["clean_exact"],
                    m["collateral"],
                ]
            print(json.dumps({"causal_weight": w, "threshold": t, **record}))
