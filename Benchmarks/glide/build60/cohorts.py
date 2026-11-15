"""Create separate training, regression and blind replay files from pinned FUTO byte ranges."""
import argparse
import json
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "build59"))
from cohort import label, records, sample, signature

def write(path, rows):
    with path.open("w") as stream:
        for row in rows:
            print(json.dumps(row, separators=(",", ":")), file=stream)
    print(path.name, len(rows), "swipes,", len({r["session"] for r in rows}), "sessions")

def fresh(rows, exposed, limit):
    exclusions = {key: {row[key] for row in exposed} for key in ("id", "session", "sentence")}
    paths = {signature(row) for row in exposed}
    return sample((r for r in rows if signature(r) not in paths), limit, exclusions)

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    for name in ("original", "dev", "previous", "training", "extra", "blind", "out"):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    previous = list(records(args.previous))
    exposed = previous + list(records(args.original)) + list(records(args.dev))
    training = fresh(records(args.training), exposed, 14000)
    holdout = fresh(records(args.blind), exposed + training, 4096)
    extra = fresh(records(args.extra), exposed + training + holdout, 25000)
    result = json.loads((Path(__file__).resolve().parents[1] / "build59/results.json").read_bytes())
    ids = {r["id"] for name in ("long_lost", "long_gained") for r in result[name]}
    regression = [r for r in previous if r["id"] in ids]
    assert len(regression) == len(ids) == 66
    args.out.mkdir(parents=True, exist_ok=True)
    write(args.out / "training.jsonl", training)
    write(args.out / "extra.jsonl", extra)
    write(args.out / "regression.jsonl", regression)
    write(args.out / "blind.jsonl", holdout)
