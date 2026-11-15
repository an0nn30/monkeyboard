"""Replay the frozen build 7 next-word rule on the new external holdout."""
import csv
from pathlib import Path

root = Path(__file__).resolve().parents[2]
bench = root / "Benchmarks"
table = {}
for line in (root / "keyboard-engine/model/next.tsv").read_text().splitlines():
    key, values = line.split("\t")
    table[key] = [pair.split(":")[0] for pair in values.split()]

def predict(context):
    # Both holdouts use pretokenized lowercase ASCII, separated by single spaces.
    words = context.split()
    keys = [" ".join(words[-2:])] if len(words) > 1 else []
    keys.append(words[-1])
    candidates = [w for k in keys for w in table.get(k, [])] + ["i", "the", "you"]
    top = list(dict.fromkeys(candidates))[:3]
    return "|".join("I" + w[1:] if w == "i" or w.startswith("i'") else w for w in top)

with (bench / "build7-held-out.tsv").open() as f:
    for row in csv.DictReader(f, delimiter="\t"):
        assert predict(row["context"]) == row["candidate"], row
with (bench / "texting/build7-dialogue.tsv").open("w") as f:
    f.write("kind\tcontext\texpected\tbuild6\tcandidate\n")
    for line in (bench / "texting/dialogue-holdout.tsv").read_text().splitlines():
        f.write(line + "\tI|the|you\t" + predict(line.split("\t")[1]) + "\n")
