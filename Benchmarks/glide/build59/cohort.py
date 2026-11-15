"""Select the tuning and fresh cohorts before running any decoder."""
import argparse
import hashlib
import json
from pathlib import Path
import re

def records(path):
    with path.open("rb") as stream:
        for line in stream:
            if line.startswith(b"{") and line.endswith(b"\n"):
                yield json.loads(line)

def label(row):
    return row["word"].strip('.,:;!?“”"()').lower().replace("’", "'")

def signature(row):
    return hashlib.sha256(json.dumps(row["data"], separators=(",", ":")).encode()).digest()

def sample(rows, n, excluded):
    selected = []
    seen = set()
    for row in rows:
        word = label(row)
        if not (2 <= len(word) <= 24 and re.fullmatch("[a-z]+(?:'[a-z]+)*", word)):
            continue
        if any(row[field] in values for field, values in excluded.items()):
            continue
        key = signature(row)
        if key in seen:
            continue
        seen.add(key)
        selected.append(row)
    selected.sort(key=lambda r: hashlib.sha256(str(r["id"]).encode()).digest())
    return selected[:n]

def main():
    parser = argparse.ArgumentParser()
    for name in ("original", "development", "fresh", "output"):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    original = list(records(args.original))
    dev = list(records(args.development))
    tuning = sample(dev, 2048, {"session": {r["session"] for r in original}})
    used = original + dev
    forbidden = {key: {r[key] for r in used} for key in ("id", "session", "sentence")}
    previous_paths = {signature(r) for r in used}
    fresh = sample((r for r in records(args.fresh) if signature(r) not in previous_paths),
                   3072, forbidden)
    args.output.mkdir(exist_ok=True, parents=True)
    for name, rows in (("tune", tuning), ("fresh", fresh)):
        assert rows
        with (args.output / (name + ".jsonl")).open("w") as f:
            for row in rows:
                f.write(json.dumps(row, separators=(",", ":")) + "\n")
        print(name, len(rows), "swipes,", len({r["session"] for r in rows}), "sessions")

if __name__ == "__main__":
    main()
