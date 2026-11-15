"""Freeze/verify the third build 55–56 cohort using the published build 55 schema and scorer."""
import argparse
import importlib.util
import json
import sys
from itertools import product
from pathlib import Path

HERE = Path(__file__).resolve().parent
B55 = HERE.parents[1] / "build55/holdout"
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("fixture55", B55 / "freeze.py")
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class AuditPipe:
    """An anonymous pipe from the custodian permits only an aggregate cross-cohort audit."""

    def read_text(self):
        return sys.stdin.read()


def audit(rows, args):
    # The primary build 55 audit verifies the same 138/213 composition without
    # consulting previous build 55 material. Add both cross-cohort checks below.
    args.cohort = "primary"
    stats = fixture.audit(rows, args.source, args)
    stats["cohort"] = "third-confirmation"
    stats["authoring"] = ("Independent authoring after the coordinator reported two unmet primary gates. "
                          "No baseline or candidate output, case-level failures or model material was viewed.")
    keys = {fixture.old.norm(r[k]) for r in rows for k in ("typed", "expected")}
    references = fixture.refs(rows)
    families = fixture.real_families(rows)
    for label, directory, prefix, source in (
        ("primary55", B55, "new55", B55 / "authored.txt"),
        ("confirmation55", B55 / "confirmation", "confirm55", AuditPipe() if args.reserve_stdin else B55 / "confirmation/authored.txt"),
    ):
        prior = fixture.make_pairs(source, prefix)
        digest = fixture.sha(fixture.encoded(prior))
        expected_digest = json.loads((directory / "freeze.json").read_bytes())["fixture_sha256"]
        assert digest == expected_digest
        prior_keys = {fixture.old.norm(r[k]) for r in prior for k in ("typed", "expected")}
        stats["exclusion_normalized_key_counts"][label] = len(prior_keys)
        matches = len(keys & prior_keys)
        stats["normalized_form_overlaps"][label] = matches
        shared = len(families & fixture.real_families(prior))
        stats["real_word_families_also_in_prior_holdouts"][label] = shared
        max_sim = fixture.max_similarity(product(references, fixture.refs(prior)))
        stats["maximum_reference_word_sequence_similarity"][label] = max_sim
        assert matches == shared == 0 and max_sim < .75, (label, matches, shared, max_sim)
    stats["build55_fixture_audit_sha256"] = fixture.sha((B55 / "freeze.py").read_bytes())
    return stats


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--freeze", action="store_true")
    mode.add_argument("--release", action="store_true")
    mode.add_argument("--audit", action="store_true")
    parser.add_argument("--source", type=Path, default=HERE / "authored.txt")
    parser.add_argument("--reserve-stdin", action="store_true", help="read build 55 confirmation in memory solely during overlap audit")
    parser.add_argument("--desktop", type=Path, default=Path.home() / "Desktop/typo_sentences.md")
    parser.add_argument("--conversations", type=Path, default=Path("/tmp/mb21/train.txt"))
    parser.add_argument("--sms", type=Path, default=Path("/tmp/mb22/blind/sms.zip"))
    args = parser.parse_args()
    rows = fixture.make_pairs(args.source, "reserve56")
    manifest = HERE / "freeze.json"
    if args.freeze:
        data = fixture.encoded(audit(rows, args))
        with manifest.open("xb") as file:
            file.write(data)
    else:
        frozen = json.loads(manifest.read_bytes())
        data = fixture.encoded(rows)
        assert fixture.sha(data) == frozen["fixture_sha256"]
        assert fixture.sha(args.source.read_bytes()) == frozen["source_annotation_sha256"]
        assert fixture.sha((B55 / "score.py").read_bytes()) == frozen["scorer_sha256"]
        if args.audit:
            assert fixture.encoded(audit(rows, args)) == manifest.read_bytes()
        for target, content in ((HERE / "authored.txt", args.source.read_bytes()), (HERE / "cases.json", data)):
            if args.release and not target.exists():
                with target.open("xb") as file:
                    file.write(content)
            assert target.read_bytes() == content
    print("Third confirmation:", len(rows), "rows, SHA-256", fixture.sha(fixture.encoded(rows)))


if __name__ == "__main__":
    main()
