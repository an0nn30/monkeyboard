"""Compare per-gesture ranked outputs from two simulator executables."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import statistics

from cohort import label, records


def summarize(rows, builds):
    result = {"gestures": len(rows)}
    for slot, number in enumerate(builds, start=1):
        name = f"build{number}"
        sample = [(row[0], row[slot]) for row in rows]
        times = sorted(p["milliseconds"] for _, p in sample)
        result[name] = {
            "top1": sum(p["words"][:1] == [word] for word, p in sample),
            "top3": sum(word in p["words"] for word, p in sample),
            "no_guess": sum(not p["words"] for _, p in sample),
            "median_ms": round(statistics.median(times), 3),
            "p95_ms": round(times[math.ceil(0.95 * len(times)) - 1], 3),
        }
    result["gained"] = sum(old["words"][:1] != [w] and new["words"][:1] == [w] for w, old, new in rows)
    result["lost"] = sum(old["words"][:1] == [w] and new["words"][:1] != [w] for w, old, new in rows)
    return result


def compare(cohort, baseline, candidate, builds=(58, 59)):
    rows = list(records(cohort))
    ids = [r["id"] for r in rows]
    predictions = [list(records(path)) for path in (baseline, candidate)]
    if not ids or any([r["id"] for r in run] != ids for run in predictions) or len(set(ids)) != len(ids):
        raise ValueError("Simulator output IDs must exactly match the cohort in order")
    scored = [(label(row), old, new) for row, old, new in zip(rows, *predictions)]
    long_words = [r for r in scored if len(r[0]) >= 7]
    result = {"cohort_sha256": hashlib.sha256(cohort.read_bytes()).hexdigest(),
              "sessions": len({r["session"] for r in rows}), "overall": summarize(scored, builds)}
    for name, low, high in [("2-3", 2, 3), ("4-6", 4, 6), ("7+", 7, 24)]:
        group = [r for r in scored if low <= len(r[0]) <= high]
        if group:
            result[name] = summarize(group, builds)
    for tag in ("gained", "lost"):
        examples = []
        for w, old, new in long_words:
            good58, good59 = old["words"][:1] == [w], new["words"][:1] == [w]
            if good58 == good59 or good59 != (tag == "gained"):
                continue
            examples.append({"id": old["id"], "word": w, f"build{builds[0]}": old["words"], f"build{builds[1]}": new["words"]})
        result["long_" + tag] = examples
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    for name in ("cohort", "baseline", "candidate"):
        parser.add_argument(name, type=Path)
    parser.add_argument("--builds", type=int, nargs=2, default=(58, 59))
    print(json.dumps(compare(**vars(parser.parse_args())), indent=2))
