"""Verify paired outputs, compare aligned words, and account for the 63 archived changes."""
import argparse
from collections import Counter, defaultdict
import gzip
import json
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
BENCH = HERE.parent
sys.path.insert(0, str(BENCH / "build22/blind"))
from score import groups, load_outputs, observe, scan, score_sentence


def write(name, obj):
    (HERE / name).write_text(json.dumps(obj, indent=2, sort_keys=True) + "\n")


def compare(cases, files, candidate="44"):
    rows = json.loads(cases.read_bytes())
    ids = {r["id"] for r in rows}
    assert len(ids) == len(rows)
    outs = {n: load_outputs([p], ids) for n, p in files.items()}
    totals = {n: defaultdict(Counter) for n in outs}
    pairs = {n: defaultdict(Counter) for n in files if n != candidate}
    for row in rows:
        ref = scan(row["expected"])
        before = observe(ref, scan(row["typed"]))
        marks = observe(ref, ref).punctuation
        output = {n: out[row["id"]] for n, out in outs.items()}
        cache = {s: score_sentence(row, s, ref, before, marks) for s in set(output.values())}
        keys = list(groups(row))
        for k in keys:
            for n, s in output.items():
                totals[n][k].update(cache[s])
        for n, p in pairs.items():
            a, b = output[n], output[candidate]
            if a == b:
                continue
            first, last = [observe(ref, scan(s)).slots for s in (a, b)]
            counts = Counter(changed_outputs=1, newly_exact=int(b == row["expected"]),
                             lost_exact=int(a == row["expected"]))
            for w, t, x, y in zip(ref.words, before.slots, first, last):
                if x == y:
                    continue
                if t == w:
                    counts["newly_harmed"] += x == w != y
                    counts["restored_intended"] += x != w == y
                else:
                    counts["newly_fixed"] += x != w == y
                    counts["lost_fix"] += x == w != y
            for k in keys:
                p[k].update(counts)
    return {"totals": totals, "paired_against_" + candidate: pairs}


def check_archive(cases, candidate="44", location=HERE):
    rows = list(map(json.loads, gzip.open(BENCH/"build40/desktop-changes.jsonl.gz", "rt")))
    fixes = {n: load_outputs([location/f"desktop-{n}.jsonl.gz"], {r["id"] for r in cases})
             for n in ("39", "40", candidate)}
    report = {"archive_vs_rerun_changed_sentences": {}, "historical_slots": {}}
    for n in ("39", "40"):
        archived = load_outputs([BENCH/f"build{n}"/f"desktop-{n}.jsonl.gz"], set(fixes[n]))
        report["archive_vs_rerun_changed_sentences"][n] = sum(archived[i] != s for i, s in fixes[n].items())
    for n in fixes:
        counts = Counter()
        for r in rows:
            ref = scan(r["expected"])
            typed, old, new, current = [observe(ref, scan(s)).slots for s in
                                       (r["typed"], r["build39"], r["build40"], fixes[n][r["id"]])]
            for w, t, a, b, now in zip(ref.words, typed, old, new, current):
                if w == t:
                    continue
                if a == w != b:
                    counts["archived_losses"] += 1
                    counts["archived_losses_correct_now"] += now == w
                if a != w == b:
                    counts["archived_gains"] += 1
                    counts["archived_gains_correct_now"] += now == w
        report["historical_slots"][n] = counts
    return report


def main(corpus):
    for name, fixture in [("desktop", corpus), ("fresh", BENCH/"build41/fresh.json"),
                          ("regressions", BENCH/"build41/regressions.json")]:
        report = compare(fixture, {n: HERE/f"{name}-{n}.jsonl.gz" for n in ("39", "40", "44")})
        write(f"{name}-comparison.json", report)
    write("archive-audit.json", check_archive(json.loads(corpus.read_bytes())))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("prepared_corpus", type=Path)
    main(parser.parse_args().prepared_corpus)
