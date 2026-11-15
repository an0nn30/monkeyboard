"""Rescore recorded builds by ID. Supply the normalized 100k desktop fixture."""
import argparse
import importlib.util
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
BENCH = HERE.parent
spec = importlib.util.spec_from_file_location("mb_round44", BENCH/"build44/compare.py")
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)

def write(name, obj):
    (HERE/name).write_text(json.dumps(obj, sort_keys=True, indent=2) + "\n")

def score_all(cases):
    for label, fixture in (("desktop", cases), ("fresh", BENCH/"build45/fresh.json"),
                           ("regressions", BENCH/"build41/regressions.json"),
                           ("practice", BENCH/"build41/fresh.json")):
        def artifact(n):
            if n == "46" or label == "fresh":
                return HERE/f"{label}-{n}.jsonl.gz"
            prefix = "fresh" if label == "practice" else label
            return BENCH/"build44"/f"{prefix}-{n}.jsonl.gz"
        write(label+"-comparison.json", audit.compare(fixture, {n:artifact(n) for n in ("39","40","44","46")}, "46"))
    results = json.loads((BENCH/"build44/archive-audit.json").read_bytes())
    cases = json.loads(cases.read_bytes())
    known = list(map(json.loads, audit.gzip.open(BENCH/"build40/desktop-changes.jsonl.gz","rt")))
    outputs = audit.load_outputs([HERE/"desktop-46.jsonl.gz"], {r["id"] for r in cases})
    counts = audit.Counter()
    for row in known:
        ref = audit.scan(row["expected"])
        typed, a, b, c = [audit.observe(ref, audit.scan(v)).slots for v in
                          (row["typed"], row["build39"], row["build40"], outputs[row["id"]])]
        for w,t,x,y,z in zip(ref.words,typed,a,b,c):
            if w == t: continue
            if x == w != y:
                counts["archived_losses"] += 1
                counts["archived_losses_correct_now"] += z == w
            if x != w == y:
                counts["archived_gains"] += 1
                counts["archived_gains_correct_now"] += z == w
    results["historical_slots"]["46"] = counts
    write("archive-audit.json", results)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("prepared_corpus", type=Path)
    score_all(parser.parse_args().prepared_corpus)
