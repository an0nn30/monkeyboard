"""Score paired replay logs using the build 54 complete-event convention."""
import argparse
import importlib.util
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("historical_scorer", HERE.parents[1] / "build22/blind/score.py")
scorer = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = scorer
spec.loader.exec_module(scorer)


def positions(whitespace_tokens, word_matches, start, count):
    first, last = whitespace_tokens[start].start(), whitespace_tokens[start + count - 1].end()
    return [i for i, word in enumerate(word_matches) if first <= word.start() < last]


def record(counter, before, after):
    counter["total"] += 1
    counter["baseline"] += bool(before)
    counter["candidate"] += bool(after)
    counter["gained"] += after and not before
    counter["lost"] += before and not after


def matches(indices, reference, observation):
    return (all(observation.slots[i] == reference.words[i] for i in indices)
            and not any(observation.extras.get(i) for i in indices[1:]))


def compare(rows, baseline, candidate):
    events, messages, protected, former_correct = [defaultdict(Counter) for _ in range(4)]
    residual = {key: Counter() for key in ("baseline", "candidate")}
    for row in rows:
        gold = row["expected"]
        reference = scorer.scan(gold)
        whitespace_tokens = list(re.finditer(r"\S+", gold))
        word_matches = list(scorer.WORD.finditer(gold))
        original = scorer.observe(reference, scorer.scan(row["typed"]))
        a, b = (values[row["id"]] for values in (baseline, candidate))
        left, right = [scorer.observe(reference, scorer.scan(text)) for text in (a, b)]
        group = "clean" if row["kind"] == "clean" else "noisy"
        record(messages[group], a == gold, b == gold)
        for edit in row["edits"]:
            words = scorer.scan(edit["expected"]).words
            indices = positions(whitespace_tokens, word_matches, edit["expected_index"], len(edit["expected"].split()))
            assert words == [reference.words[i] for i in indices] and indices
            assert not matches(indices, reference, original)
            before, after = matches(indices, reference, left), matches(indices, reference, right)
            for key in ("all", edit["category"]):
                record(events[key], before, after)
        for item in row["protected"]:
            indices = positions(whitespace_tokens, word_matches, item["expected_index"], 1)
            assert indices and matches(indices, reference, original)
            before, after = matches(indices, reference, left), matches(indices, reference, right)
            record(protected[item["category"]], before, after)
        for i, word in enumerate(reference.words):
            if original.slots[i] == word:
                record(former_correct["all"], left.slots[i] == word, right.slots[i] == word)
        for label, text, obs in (("baseline", a, left), ("candidate", b, right)):
            metrics = residual[label]
            for i, word in enumerate(reference.words):
                if original.slots[i] == word and obs.slots[i] != word:
                    metrics["originally_correct_words_changed"] += 1
                if original.slots[i] != word and obs.slots[i] not in (word, original.slots[i]):
                    metrics["damaged_words_replaced_with_another_wrong_word_or_deleted"] += 1
            metrics["exact"] += text == gold
            for key in ("originally_correct_words_changed", "damaged_words_replaced_with_another_wrong_word_or_deleted"):
                metrics.setdefault(key, 0)
    return dict(events_fixed=events, messages_exact=messages, protected_preserved=protected,
                originally_correct_words_preserved=former_correct["all"], other_metrics=residual)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ("fixture", "baseline", "candidate"):
        parser.add_argument(arg, type=Path)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    rows = json.loads(args.fixture.read_bytes())
    ids = {row["id"] for row in rows}
    if not ids or len(ids) != len(rows):
        raise ValueError("Expected nonempty fixture with unique IDs")
    baseline, candidate = (scorer.load_outputs([path], ids) for path in (args.baseline, args.candidate))
    report = compare(rows, baseline, candidate)
    report["inputs_sha256"] = {}
    import hashlib
    for key in ("fixture", "baseline", "candidate"):
        report["inputs_sha256"][key] = hashlib.sha256(getattr(args, key).read_bytes()).hexdigest()
    data = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.out:
        args.out.write_text(data)
    else:
        print(data, end="")


if __name__ == "__main__":
    main()
