"""Compare the keyboard's final spelling or final three suggestions on matched cases."""
import argparse
import csv
from collections import defaultdict
from pathlib import Path

root = Path(__file__).resolve().parent
def read(path):
    with path.open() as f:
        return list(csv.DictReader(f, delimiter="\t"))

def outcome(case, result):
    if case["task"] == "next":
        gold = {w.lower() for w in case["gold"].split("|")}
        strip = [w.lower() for w in result["strip"].split("|")]
        return "top1" if strip[0] in gold else "rank2or3" if gold.intersection(strip[:3]) else "miss"
    if result["final"] == case["gold"]:
        return "correct"
    return "miss" if result["final"] == case["typed"] else "wrong"

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results", type=Path, nargs="+")
    parser.add_argument("--split", choices=["development", "holdout", "reported"], default="holdout")
    parser.add_argument("--detail", action="store_true")
    parser.add_argument("--cases", type=Path, default=root / "cases.tsv")
    args = parser.parse_args()
    cases = read(args.cases)
    for path in args.results:
        data = read(path)
        results = {int(r["id"]): r for r in data}
        if len(results) != len(data):
            raise ValueError(f"Duplicate case IDs in {path}")
        groups = defaultdict(list)
        for i, case in enumerate(cases):
            if case["split"] != args.split: continue
            result = results[i]
            status = outcome(case, result)
            groups[case["task"]].append(status)
            groups[case["kind"]].append(status)
            if args.detail and status in {"wrong", "miss"}:
                print(case["kind"], case["left"], case["typed"], case["right"], "=>", result["final"] or result["strip"], "expected", case["gold"], sep="\t")
        print(path.name, args.split)
        for group, values in groups.items():
            summary = "  ".join(f"{key} {values.count(key)}" for key in sorted(set(values)))
            if group in {"next", "prediction", "family_prediction", "text_prediction", "paired_next"}:
                summary += f"  top3 {values.count('top1') + values.count('rank2or3')}"
            print(group, len(values), summary)
if __name__ == "__main__":
    main()
