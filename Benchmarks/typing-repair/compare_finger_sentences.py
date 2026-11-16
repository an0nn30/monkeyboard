"""Compare complete simulator traces by their intended sentences, including capitalization."""
import argparse
import json
from collections import Counter
from pathlib import Path

from finger_report import distance


def read_trials(path):
    trials = {}
    for line in path.read_text().splitlines():
        record = json.loads(line)
        key = tuple(record[k] for k in ("seed", "sentence", "profile", "layout", "mode"))
        if key in trials:
            raise ValueError(f"Duplicate trace {key}")
        trials[key] = record
    return trials


def compare(before, after):
    if not before or before.keys() != after.keys():
        raise ValueError("Missing paired traces")
    counts = {mode: Counter() for mode in ("off", "on")}
    for key, base in before.items():
        candidate = after[key]
        target = base["expected"]
        if candidate["expected"] != target:
            raise ValueError(f"Mismatched target for {key}")
        score = counts[key[-1]]
        score["trials"] += 1
        errors_before = distance(base["observed"], target)
        errors_after = distance(candidate["observed"], target)
        score["fewerCharacterErrors"] += errors_before > errors_after
        score["moreCharacterErrors"] += errors_before < errors_after
        for name, row, errors in (("baseline", base, errors_before), ("candidate", candidate, errors_after)):
            actual = row["observed"]
            score[name + "Exact"] += actual == target and row["completed"]
            score[name + "ExactIgnoringCase"] += actual.lower() == target.lower() and row["completed"]
            score[name + "CharacterErrors"] += errors
            score[name + "CharacterErrorsIgnoringCase"] += distance(actual.lower(), target.lower())
            score[name + "Incomplete"] += not row["completed"]
            if key[-1] == "on":
                raw = (before if name == "baseline" else after)[(*key[:-1], "off")]
                clean = raw["completed"] and raw["observed"] == target
                score[name + "CleanInputs"] += clean
                score[name + "CleanInputsChangedByAutocorrect"] += clean and (not row["completed"] or actual != target)
        was_exact = base["completed"] and base["observed"] == target
        now_exact = candidate["completed"] and candidate["observed"] == target
        score["newlyExact"] += now_exact and not was_exact
        score["previouslyExactLost"] += was_exact and not now_exact
        was_exact_ignoring_case = base["completed"] and base["observed"].lower() == target.lower()
        now_exact_ignoring_case = candidate["completed"] and candidate["observed"].lower() == target.lower()
        score["newlyExactIgnoringCase"] += now_exact_ignoring_case and not was_exact_ignoring_case
        score["previouslyExactLostIgnoringCase"] += was_exact_ignoring_case and not now_exact_ignoring_case
    return counts


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    args = parser.parse_args()
    print(json.dumps(compare(read_trials(args.baseline), read_trials(args.candidate)), indent=2))
