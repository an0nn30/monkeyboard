"""Score geometry and paired installed-keyboard runs. Character errors use edit distance."""
import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path


def distance(first, second):
    row = list(range(len(second) + 1))
    for i, a in enumerate(first, 1):
        next_row = [i]
        for j, b in enumerate(second, 1):
            next_row.append(min(row[j] + 1, next_row[-1] + 1, row[j-1] + (a != b)))
        row = next_row
    return row[-1]


def report(geometry, log):
    by_profile = defaultdict(Counter)
    for case in geometry["results"]:
        score = case["score"]
        by_profile[case["profile"]].update({k: v for k, v in score.items() if isinstance(v, int)})
    pairs = defaultdict(dict)
    for line in log.splitlines():
        if line.startswith("FINGERCASE "):
            case = json.loads(line.removeprefix("FINGERCASE "))
            key = case["seed"], case["profile"], case["intended"]
            if case["mode"] in pairs[key]:
                raise ValueError("Duplicate typing result for " + str(key))
            pairs[key][case["mode"]] = case
    expected = {(f["seed"], f["profile"], f["text"]) for f in geometry["fixtures"]}
    controls = pairs.pop((0, "autocorrect-control", "teh "), {})
    if tuple(controls.get(mode, {}).get("observed", "").lower() for mode in ("off", "on")) != ("teh ", "the "):
        raise ValueError("Unverified autocorrection controls")
    if set(pairs) != expected or any(set(p) != {"on", "off"} for p in pairs.values()):
        raise ValueError("Missing installed-keyboard trials")
    messages, totals = [], Counter()
    for (seed, profile, target), modes in sorted(pairs.items()):
        raw, corrected = modes["off"], modes["on"]
        before, after = (distance(target.lower(), case["observed"].lower()) for case in [raw, corrected])
        record = dict(seed=seed, profile=profile, intended=target, raw=raw["observed"], final=corrected["observed"],
                      rawEdits=before, finalEdits=after, rawTaps=raw["completedTaps"], correctedTaps=corrected["completedTaps"])
        if "sentences" in geometry:  # New fixtures retain what the text field actually displayed.
            canonical = " ".join("I" if w == "i" else w for w in target.split(" "))
            canonical = canonical[:1].upper() + canonical[1:]
            record["expectedDisplay"] = canonical
            for name, case in (("raw", raw), ("final", corrected)):
                totals[name + "ExactWithCase"] += case["observed"] == canonical and case["completedTaps"] == len(target)
        messages.append(record)
        totals.update(cases=1, intendedCharacters=len(target), tappedCharacters=raw["completedTaps"]+corrected["completedTaps"],
                      rawEdits=before, finalEdits=after, rawExact=int(before == 0), finalExact=int(after == 0),
                      improved=int(after < before), worsened=int(after > before), cleanChanged=int(before == 0 and after > 0))
    return {"geometry": by_profile, "installed": totals, "messages": messages}


def compare_geometry(baseline, candidate, contact=False, both_contacts=False, original=None):
    def indexed(source):
        trials = {(c["layout"], c["profile"], c["seed"]): c for c in source["results"]}
        if not trials or len(trials) != len(source["results"]):
            raise ValueError("Empty or duplicate geometry trials")
        return trials

    def draws(source):
        return {(f["profile"], f["seed"], f["text"]): [
            tuple(t[k] for k in ("key", "dx", "dy", "radiusX", "radiusY", "angle")) for t in f["taps"]
        ] for f in source["fixtures"]}

    after = indexed(candidate)
    def matched(source):
        trials = indexed(source)
        if (trials.keys() != after.keys() or draws(source) != draws(candidate)
                or source.get("sentences") != candidate.get("sentences")):
            raise ValueError("Layout, profile, seed or replay inputs differ")
        return trials
    before = matched(baseline)
    prior = matched(original) if original else None
    grouped = defaultdict(lambda: {"before": Counter(), "after": Counter()})
    for trial, base in before.items():
        current = after[trial]
        if base["score"]["attempts"] != current["score"]["attempts"]:
            raise ValueError("Intended keystroke counts differ")
        if "releases" in base and "releases" in current and base["releases"] != current["releases"]:
            raise ValueError(f"Unpaired release locations or radii in {trial}")
        profile = grouped[trial[1]]
        if contact or both_contacts:
            changes = profile.setdefault("paired", Counter(recovered=0, lost=0, dropToWrong=0))
            old_targets = base["circularTargets" if both_contacts else "targets"]
            if prior:
                archived = profile.setdefault("archived", Counter(previousGains=0, gainsRetained=0,
                    previouslyDroppedToWrong=0, nowCorrect=0, nowDropped=0, stillWrong=0))
            for i, (sentence, old, new) in enumerate(zip(candidate["sentences"], old_targets, current["circularTargets"], strict=True)):
                for j, (key, previous, revised) in enumerate(zip(sentence + " ", old, new, strict=True)):
                    if prior:
                        first = prior[trial]["targets"][i][j]
                        if first != key and previous == key:
                            archived["previousGains"] += 1
                            archived["gainsRetained"] += revised == key
                        if first == "drop" and previous not in (key, "drop"):
                            archived["previouslyDroppedToWrong"] += 1
                            archived["nowCorrect" if revised == key else "nowDropped" if revised == "drop" else "stillWrong"] += 1
                    changes["recovered"] += previous != key and revised == key
                    changes["lost"] += previous == key and revised != key
                    changes["dropToWrong"] += previous == "drop" and revised not in (key, "drop")
                    for name, value in (("before", previous), ("after", revised)):
                        profile[name].update(attempts=1, correct=value == key, dropped=value == "drop",
                                             wrong=value not in (key, "drop"))
            continue
        for name, score in (("before", base["score"]), ("after", current["score"])):
            correct, dropped, total = score["pointCorrect"], score["dropped"], score["attempts"]
            profile[name].update(attempts=total, correct=correct, dropped=dropped, wrong=total-correct-dropped)
    return {"seeds": sorted({trial[2] for trial in before}), "layouts": sorted({trial[0] for trial in before}),
            "profiles": dict(grouped)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("geometry", type=Path)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("typing_log", type=Path, nargs="?", help="Score an installed-keyboard replay")
    mode.add_argument("--compare-to", type=Path, metavar="BASELINE", help="Compare two geometry runs on the same traces")
    contacts = parser.add_mutually_exclusive_group()
    contacts.add_argument("--contact", action="store_true", help="Compare baseline point targets with candidate release-time contact targets")
    contacts.add_argument("--both-contacts", action="store_true", help="Compare release-time contact targets in both versions")
    parser.add_argument("--previous-points", type=Path, help="Track the individual gains and wrong neighbors relative to an earlier point-only reference")
    args = parser.parse_args()
    geometry = json.loads(args.geometry.read_text())
    if (args.contact or args.both_contacts) and not args.compare_to:
        parser.error("A contact comparison requires --compare-to")
    if args.previous_points and not args.both_contacts:
        parser.error("--previous-points requires --both-contacts")
    prior = json.loads(args.previous_points.read_text()) if args.previous_points else None
    results = (compare_geometry(json.loads(args.compare_to.read_text()), geometry, args.contact, args.both_contacts, prior) if args.compare_to
               else report(geometry, args.typing_log.read_text()))
    print(json.dumps(results, indent=2))
