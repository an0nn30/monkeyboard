"""Select recorded regression gestures and reserve a disjoint sample before fitting."""
import argparse
import itertools
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "build60"))
from cohorts import records, sample, signature, write

def prepare(previous, train_range, test_range, output):
    output.mkdir(parents=True, exist_ok=True)
    excluded = {key: set() for key in ("id", "sentence", "session")}
    paths = set()
    def exclude(rows):
        for row in rows:
            for field, values in excluded.items():
                values.add(row[field])
            paths.add(signature(row))
    exclude(itertools.chain.from_iterable(records(previous / name) for name in
            ("original.jsonl", "dev.jsonl", "previous.jsonl", "train.jsonl", "extra.jsonl", "blind.jsonl")))
    training = sample((r for r in records(train_range) if signature(r) not in paths), 30000, excluded)
    exclude(training)
    blind = sample((r for r in records(test_range) if signature(r) not in paths), 8192, excluded)
    results = json.loads((Path(__file__).resolve().parents[1] / "build60/results.json").read_bytes())
    ids = {r["id"] for group in ("long_lost", "long_gained") for r in results[group]}
    new_cases = [r for r in records(previous / "cohorts/blind.jsonl") if r["id"] in ids]
    inherited = list(records(previous / "cohorts/regression.jsonl"))
    assert {r["id"] for r in new_cases} == ids and len(new_cases) == 17
    assert len({r["id"] for r in new_cases + inherited}) == 83
    assert training and blind
    write(output / "regression.jsonl", new_cases + inherited)
    write(output / "training.jsonl", training)
    write(output / "blind.jsonl", blind)

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    for name in ("previous", "train_range", "test_range", "output"):
        parser.add_argument(name, type=Path)
    prepare(**vars(parser.parse_args()))
