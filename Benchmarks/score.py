"""Score a simulator run. --baseline compares to saved outputs for identical cases."""
import argparse
import csv
from collections import Counter

p = argparse.ArgumentParser()
p.add_argument("comparison")
p.add_argument("--baseline", help="compare the candidate column of an earlier simulator run")
p.add_argument("--gate", action="store_true")
args = p.parse_args()

def load(path):
    with open(path, encoding="utf-8") as f:
        rows = list(csv.DictReader(f, delimiter="\t"))
    assert rows and all(r["kind"] in ("fix", "keep", "next") for r in rows), path
    return rows

rows = load(args.comparison)
baseline = load(args.baseline) if args.baseline else rows
def cases(rs):
    return [(r["kind"], r["context"], r["expected"]) for r in rs]
assert cases(baseline) == cases(rows), "Baseline must have exactly the same ordered test cases and labels"

def score(rs, side):
    counts = Counter()
    for row in rs:
        kind, expected, output = row["kind"], row["expected"], row[side]
        counts[kind] += 1
        if kind == "next":
            accepted = set(expected.casefold().split("|"))
            offered = output.casefold().split("|") if output else []
            assert len(offered) <= 3, "Only the first three suggestions are visible"
            counts["top3"] += not accepted.isdisjoint(offered)
            counts["top1"] += bool(offered) and offered[0] in accepted
        elif kind == "keep":
            counts["false_change"] += output != expected
        else:
            counts["corrected"] += output == expected
            typed = row["context"].split()[-1]
            counts["wrong_fix"] += output not in (typed, expected)
    return counts

old = score(baseline, "candidate" if args.baseline else "build6")
new = score(rows, "candidate")
for name, m in [("baseline", old), ("candidate", new)]:
    print(f"{name}: fixed {m['corrected']}/{m['fix']}; wrong replacement on typo {m['wrong_fix']}; "
          f"unwanted changes {m['false_change']}/{m['keep']}; next word top 3 {m['top3']}/{m['next']}, first {m['top1']}")
if args.gate:
    if new["false_change"] > old["false_change"] or new["wrong_fix"] > old["wrong_fix"]:
        raise SystemExit("Wrong replacement rate increased")
    if new["corrected"] < old["corrected"] or new["top3"] < old["top3"]:
        raise SystemExit("Correction or next-word score regressed")
