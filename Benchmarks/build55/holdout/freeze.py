"""Create or verify an independently authored paired-message fixture."""
import argparse
import hashlib
import importlib.util
import json
import re
import sys
from collections import Counter
from difflib import SequenceMatcher
from itertools import combinations, product
from pathlib import Path

HERE = Path(__file__).resolve().parent
BENCH = HERE.parents[1]
sys.dont_write_bytecode = True


def imported(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


old = imported("annotation53", BENCH / "build53/holdout/freeze.py")
metrics = imported("metrics55", HERE / "score.py")


def sha(data):
    return hashlib.sha256(data).hexdigest()


def encoded(data):
    return (json.dumps(data, indent=2, ensure_ascii=False, sort_keys=True) + "\n").encode()


def make_pairs(source, prefix):
    pairs = []
    for i, line in enumerate(source.read_text().splitlines(), 1):
        # The legacy parser has two protected categories. Extend its labels after
        # parsing so every annotation uses the identical whitespace-index rule.
        labels = [m[1] for m in re.finditer(r"\[(name|slang|valid)\|", line)]
        typed, gold, marks, edits = old.parse_template(line.replace("[valid|", "[slang|"))
        for mark, label in zip(marks, labels, strict=True):
            if label == "valid":
                mark["category"] = "valid-word"
        kinds = {e["category"] for e in edits}
        kind = kinds.pop() if len(kinds) == 1 else "mixed"
        pair = f"{prefix}-{i:04d}"
        common = dict(pair_id=pair, split="blind", source="independently-authored", source_id=i, expected=gold)
        noisy = dict(id=pair + "-n", kind=kind, typed=typed, protected=marks, edits=edits, **common)
        clean = dict(id=pair + "-c", kind="clean", typed=gold,
                     protected=[dict(m, typed_index=m["expected_index"]) for m in marks], edits=[], **common)
        pairs.append((noisy, clean))
    # Stable, interleaved delivery order across the hand-authored categories.
    return [r for pair in sorted(pairs, key=lambda pair: sha(pair[0]["pair_id"].encode())) for r in pair]


def refs(rows):
    return [old.norm(r["expected"]).split() for r in rows if r["kind"] == "clean"]


def real_families(rows):
    return {tuple(sorted((e["expected"].casefold(), e["typed"].casefold())))
            for r in rows for e in r["edits"] if e["category"] == "real-word"}


def max_similarity(pairs):
    return round(max(SequenceMatcher(None, left, right, autojunk=False).ratio() for left, right in pairs), 6)


def audit(rows, source, args):
    historical = old.exclusion_groups(args.desktop, args.conversations)
    historical["uci_sms_ham"] = {old.norm(msg) for msg in old.read_sms(args.sms).values()}
    prior_sets = {}
    for key, path in (("build53_holdout", "build53/holdout/cases.json"),
                      ("build53_development", "build53/development.json"),
                      ("build53_desktop_check", "build53/desktop-check.json"),
                      ("build54_holdout", "build54/holdout/cases.json")):
        source_rows = json.loads((BENCH / path).read_bytes())
        historical[key] = {old.norm(r[k]) for r in source_rows for k in ("typed", "expected")}
        if key.endswith("holdout"):
            prior_sets[key] = source_rows
    if args.cohort == "confirmation":
        previous = make_pairs(args.comparison_source, "new55")
        expected_hash = json.loads((HERE / "freeze.json").read_bytes())["fixture_sha256"]
        assert sha(encoded(previous)) == expected_hash, "Wrong primary source for cross-cohort comparison"
        prior_sets["primary55"] = previous
        historical["primary55"] = {old.norm(r[k]) for r in previous for k in ("typed", "expected")}
    stats = old.validate(rows, historical)
    new_refs = refs(rows)
    similarities = {"within_cohort": max_similarity(combinations(new_refs, 2))}
    for key, previous in prior_sets.items():
        similarities[key] = max_similarity(product(new_refs, refs(previous)))
    assert max(similarities.values()) < 0.75, similarities
    families = real_families(rows)
    labels = Counter(e["category"] for r in rows for e in r["edits"])
    stats.update(
        cohort=args.cohort, authoring="Independent authorship before viewing outputs of any model.",
        fixture_sha256=sha(encoded(rows)), source_annotation_sha256=sha(source.read_bytes()),
        scorer_sha256=sha((HERE / "score.py").read_bytes()),
        source_audit_sha256=sha((BENCH / "build53/holdout/freeze.py").read_bytes()),
        word_alignment_sha256=sha((BENCH / "build22/blind/score.py").read_bytes()),
        desktop_sha256=sha(args.desktop.read_bytes()), taskmaster_sha256=sha(args.conversations.read_bytes()),
        uci_archive_sha256=old.SMS_SHA256, noisy_edit_categories=labels, total_labelled_events=sum(labels.values()),
        edits_per_noisy_sentence=Counter(len(r["edits"]) for r in rows if r["kind"] != "clean"),
        unique_unordered_real_word_families=len(families),
        real_word_families_also_in_prior_holdouts={k: len(families & real_families(v)) for k, v in prior_sets.items()},
        maximum_reference_word_sequence_similarity=similarities,
    )
    # The literal verified reference gets all credit. Echoed input must get
    # none on every annotated event, including multiword joins and mixed cases.
    identity = {r["id"]: r["typed"] for r in rows}
    oracle = {r["id"]: r["expected"] for r in rows}
    sanity = metrics.compare(rows, identity, oracle)
    for kind, c in sanity["events_fixed"].items():
        assert c["baseline"] == 0 and c["candidate"] == c["total"]
    assert sanity["events_fixed"]["all"]["total"] == stats["total_labelled_events"]
    assert sanity["messages_exact"]["clean"]["baseline"] == len(new_refs)
    assert sanity["messages_exact"]["noisy"]["baseline"] == 0
    assert sanity["messages_exact"]["noisy"]["candidate"] == len(new_refs)
    assert all(m["candidate"] == m["baseline"] == m["total"] for m in sanity["protected_preserved"].values())
    stats["originally_correct_word_positions"] = sanity["originally_correct_words_preserved"]["total"]
    if args.cohort == "primary":
        assert len(new_refs) == 138 and labels == {"ordinary": 101, "real-word": 67, "missing-space": 45}
        assert stats["edits_per_noisy_sentence"] == {1: 63, 2: 75}
    if args.cohort == "confirmation":
        assert stats["real_word_families_also_in_prior_holdouts"]["primary55"] == 0
    return stats


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cohort", choices=("primary", "confirmation"), default="primary")
    parser.add_argument("--source", type=Path, help="annotated plaintext; defaults to released authored.txt")
    parser.add_argument("--comparison-source", type=Path, default=HERE / "authored.txt")
    parser.add_argument("--desktop", type=Path, default=Path.home() / "Desktop/typo_sentences.md")
    parser.add_argument("--conversations", type=Path, default=Path("/tmp/mb21/train.txt"))
    parser.add_argument("--sms", type=Path, default=Path("/tmp/mb22/blind/sms.zip"))
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--freeze", action="store_true", help="write a new aggregate manifest; emits no fixture")
    mode.add_argument("--release", action="store_true", help="materialize the files if they match the frozen hashes")
    mode.add_argument("--audit", action="store_true", help="repeat the full historical-source exclusion audit")
    args = parser.parse_args()
    dest = HERE / "confirmation" if args.cohort == "confirmation" else HERE
    dest.mkdir(exist_ok=True)
    source = args.source or dest / "authored.txt"
    rows = make_pairs(source, "confirm55" if args.cohort == "confirmation" else "new55")
    manifest = dest / "freeze.json"
    if args.freeze:
        data = encoded(audit(rows, source, args))
        with manifest.open("xb") as file:
            file.write(data)
    else:
        frozen = json.loads(manifest.read_bytes())
        assert sha(source.read_bytes()) == frozen["source_annotation_sha256"]
        assert sha(encoded(rows)) == frozen["fixture_sha256"]
        assert sha((HERE / "score.py").read_bytes()) == frozen["scorer_sha256"]
        if args.audit:
            assert encoded(audit(rows, source, args)) == manifest.read_bytes()
        for path, data in ((dest / "authored.txt", source.read_bytes()), (dest / "cases.json", encoded(rows))):
            if args.release and not path.exists():
                with path.open("xb") as file:
                    file.write(data)
            assert path.read_bytes() == data
    print(f"{args.cohort}: {len(rows)} rows, SHA-256 {sha(encoded(rows))}")


if __name__ == "__main__":
    main()
