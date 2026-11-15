"""Freeze full S/C pairs from the existing reserved bucket and matching clean controls."""
import argparse
import csv
import hashlib
import random
import sys
from pathlib import Path

here = Path(__file__).resolve().parent
sys.path.insert(0, str(here.parents[1] / "keyboard-engine/training"))
from paired_text import key, pairs

def digest(text):
    return hashlib.sha256(text.encode()).digest()

def collect(source):
    prior = set()
    for version in (15, 16):
        for row in csv.DictReader((here.parent / f"build{version}/cases.tsv").open(), delimiter="\t"):
            prior.add(key(" ".join([row["left"], row["gold"].split("|")[0], row["right"]])))
    selected = {}
    for typed, target in pairs(source):
        canonical = key(target)
        # Identical to the split in the build 16 trainer. Exclude prior benchmark texts.
        if digest(canonical)[0] >= 38 or canonical in prior or len(typed) > 120:
            continue
        priority = digest("mb17/noise/" + typed)
        if canonical not in selected or priority < selected[canonical][0]:
            selected[canonical] = priority, typed, target
    ordered = sorted(selected, key=lambda k: digest("mb17/sentences/" + k))
    assert len(ordered) >= 3600
    for i, canonical in enumerate(ordered[:3600]):
        _, typed, target = selected[canonical]
        group = "noisy" if i % 1800 < 1200 else "clean"
        yield (f"pair{i:04}", "holdout", group, typed if group == "noisy" else target, target)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    args = parser.parse_args()
    rows = list(collect(args.source))
    header = ["id", "split", "kind", "typed", "expected"]
    with (here / "confirmation.tsv").open("w") as f:
        w = csv.writer(f, delimiter="\t", lineterminator="\n")
        w.writerow(header)
        w.writerows(rows[1800:])
    with (here / "sentences.tsv").open("w") as f:
        w = csv.writer(f, delimiter="\t", lineterminator="\n")
        w.writerow(header)
        w.writerows(rows[:1800])
        for i, line in enumerate((here / "texts.tsv").read_text().splitlines()):
            group, typed, target = line.split("\t")
            w.writerow((f"text{i:03}", "reported" if group == "reported" else "authored", group, typed, target))
