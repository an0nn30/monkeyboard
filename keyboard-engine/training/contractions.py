"""Learn English apostrophe placement and literal/contracted neighbour counts.
Inputs: the checked-in Tatoeba CC0 export, Taskmaster-1 self-dialogs.json
(revision and CC BY 4.0 attribution in Benchmarks/build56/model/NOTICE.txt),
and the Universal Dependencies English Web Treebank r2.15 training split
(https://github.com/UniversalDependencies/UD_English-EWT, CC BY-SA 4.0).
No correction examples or benchmark labels are used.
"""

import argparse
import bz2
import json
import re
from collections import Counter, defaultdict
from pathlib import Path
from wordfreq import iter_wordlist, zipf_frequency

TOKEN = re.compile(r"[a-zA-Z]+(?:'[a-zA-Z]+)*|[^\w\s]")
ROOT = Path(__file__).resolve().parents[1]


def grammatical_forms(treebank):
    """Find clitics from parsed multiword tokens; exclude noun possessives."""
    forms, suffixes = set(), set()
    for sentence in treebank.read_text().strip().split("\n\n"):
        rows = [
            line.split("\t")
            for line in sentence.splitlines()
            if not line.startswith("#")
        ]
        tokens = {r[0]: r for r in rows if len(r) == 10}
        for index, row in tokens.items():
            if "-" not in index:
                continue
            a, b = index.split("-")
            if a not in tokens or b not in tokens:
                continue
            word = row[1].lower().replace("’", "'")
            tail = tokens[b][1].lower().replace("’", "'")
            if not re.fullmatch("[a-z]+'[a-z]+", word) or "'" not in tail:
                continue
            if tokens[b][3] not in {"AUX", "PART", "PRON"} or tokens[b][4] == "POS":
                continue
            if tail == "'s" and tokens[a][3] in {"NOUN", "PROPN"}:
                continue
            forms.add(word)
            if tail != "'s":
                suffixes.add(tail)
    return forms, suffixes


def sentences(dialogues, treebank):
    with bz2.open(ROOT / "training/eng_sentences_CC0.tsv.bz2", "rt") as source:
        for line in source:
            yield line.split("\t")[2]
    for dialogue in json.loads(dialogues.read_bytes()):
        for turn in dialogue["utterances"]:
            yield turn["text"]
    for line in treebank.read_text().splitlines():
        if line.startswith("# text = "):
            yield line[9:]


def train(dialogues, treebank, wordnet, output):
    forms, suffixes = grammatical_forms(treebank)
    lines = {s.strip().replace("’", "'") for s in sentences(dialogues, treebank)}
    tokens = [TOKEN.findall(line) for line in lines]
    counts = Counter(w.lower() for line in tokens for w in line)
    # Productive clitics can attach to hosts unseen by the parser. Require
    # actual examples of the complete spelling in the independent corpora.
    forms.update(
        w
        for w, n in counts.items()
        if n >= 2
        and re.fullmatch("[a-z]+(?:'[a-z]+)+", w)
        and w.endswith(tuple(suffixes))
    )
    hosts = {w.split("'")[0] for w in forms}
    vocabulary = dict(
        line.split("\t") for line in (ROOT / "model/words.tsv").read_text().splitlines()
    )
    collapsed = {w.replace("'", "") for w in forms}
    for word in iter_wordlist("en"):
        if zipf_frequency(word, "en") < 3.0:
            break
        if not re.fullmatch("[a-z]+(?:'[a-z]+)+", word):
            continue
        host = word.split("'")[0]
        if (
            word.endswith(tuple(suffixes))
            and (host in hosts or host in vocabulary)
            or word.replace("'", "") in collapsed
        ):
            forms.add(word)
    # Different apostrophe positions can collapse to the same key sequence.
    # Include other attested spellings before selecting the most frequent form.
    collapsed = {w.replace("'", "") for w in forms}
    forms.update(
        w
        for w, n in counts.items()
        if n >= 2 and "'" in w and w.replace("'", "") in collapsed
    )
    forms.difference_update(suffixes)
    dictionary = {
        line.split()[0]
        for part in ("noun", "verb", "adj", "adv")
        for line in (wordnet / f"index.{part}").read_text().splitlines()
        if line and not line.startswith(" ")
    }
    groups = defaultdict(list)
    for word in forms:
        if zipf_frequency(word, "en") >= 2.7:
            groups[word.replace("'", "")].append(word)
    watched = set(groups) | forms
    casing, contexts = defaultdict(Counter), defaultdict(Counter)
    for line in tokens:
        for i, token in enumerate(line):
            w = token.lower()
            if w not in watched:
                continue
            if 0 < i and line[i - 1].isalpha():
                casing[w][token] += 1
            left = line[i - 1].lower() if i else "^"
            right = line[i + 1].lower() if i + 1 < len(line) else "$"
            contexts[w]["L" + left] += 1
            contexts[w]["R" + right] += 1
    rows = []
    for bare, alternatives in sorted(groups.items()):
        word = max(alternatives, key=lambda w: (zipf_frequency(w, "en"), counts[w], w))
        if counts[word] < 2 and zipf_frequency(word, "en") < 3.0:
            continue
        # Case preference measured mid-sentence to exclude automatic sentence caps.
        canonical = (
            word.capitalize()
            if casing[word][word.capitalize()] > casing[word][word] * 3
            else word
        )
        # A real homograph needs contextual evidence before adding punctuation.
        literal = (
            bare in dictionary
            or int(vocabulary.get(bare, 0)) >= 8
            or (counts[bare] >= 20 and counts[bare] > counts[word] * 0.25)
        )
        pairs = []
        for key in sorted(contexts[word].keys() | contexts[bare].keys()):
            a, b = contexts[word][key], contexts[bare][key]
            if max(a, b) >= 2:
                pairs.append(f"{key}:{a}:{b}")
        caps = sum(n for t, n in casing[bare].items() if t.isupper())
        plain = sum(casing[bare].values())
        rows.append(
            "\t".join(
                [
                    bare,
                    canonical,
                    str(counts[word]),
                    str(counts[bare]),
                    str(caps),
                    str(plain),
                    str(int(literal)),
                    " ".join(pairs),
                ]
            )
        )
    output.write_text("\n".join(rows) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("dialogues", type=Path)
    parser.add_argument("treebank", type=Path)
    parser.add_argument("wordnet", type=Path)
    parser.add_argument("--output", type=Path, default=ROOT / "model/contractions.tsv")
    args = parser.parse_args()
    train(args.dialogues, args.treebank, args.wordnet, args.output)
