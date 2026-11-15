"""Make a fixed challenge from authored messages and the decoder's reserved CC0 bucket."""
import bz2
import csv
import hashlib
import random
import re
from pathlib import Path

here = Path(__file__).resolve().parent
root = here.parents[1]
source = root / "keyboard-engine/training/eng_sentences_CC0.tsv.bz2"
assert hashlib.sha256(source.read_bytes()).hexdigest() == "c2e2edd063a31cbbc8e416a4858225e934bbb0afff485031821e59f230ccf1ca"
rows = []
seen = set()
fields = "split origin task difficulty kind left typed gold right".split()
def add(split, origin, task, difficulty, kind, left, typed, gold, right):
    sentence = " ".join((left, gold.split("|")[0], right)).lower().split()
    key = " ".join(sentence).strip(".?!")
    if key in seen:
        return False
    seen.add(key)
    rows.append([split, origin, task, difficulty, kind, left, typed, gold, right])
    return True

for line in (here / "texts.txt").read_text().splitlines():
    if not line or line.startswith("#"):
        continue
    if line.startswith("@"):
        split = line[1:]
        continue
    left, typed, gold, right = re.fullmatch(r"(.*?)\[([^>\]]*)>([^\]]+)\](.*)", line).groups()
    task = "next" if not typed else "keep" if typed == gold else "fix"
    kind = {"next": "text_prediction", "keep": "text_control", "fix": "text_typo"}[task]
    assert add(split, "authored", task, "everyday", kind, left.strip(), typed, gold, right.strip()), line

# These are user-reported regressions, kept apart from the evaluation.
for left, typed, gold, right in [
    ("This is", "amanor", "another", "test of the new keyboard"),
    ("", "Lets", "Let's", "try this out"), ("Let's try", "yhid", "this", "out and see"),
    ("Let's try this out and see what", "were", "we've", "got"),
]:
    add("reported", "screenshot", "fix", "everyday", "reported", left, typed, gold, right)

layout = {c: (i + indent, j) for j, (row, indent) in enumerate(
    [("qwertyuiop", 0), ("asdfghjkl", .5), ("zxcvbnm", 1.35)]) for i, c in enumerate(row)}
neighbors = {c: [d for d, (u, v) in layout.items() if 0 < (x-u)**2 + (y-v)**2 < 2]
             for c, (x, y) in layout.items()}
def mistype(word, kind, rng):
    i = rng.randrange(len(word))
    if kind == "double":
        return word[:i] + word[i] + word[i:]
    if kind == "omit":
        return word[:i] + word[i+1:]
    if kind == "swap":
        i = min(i, len(word)-2)
        return word[:i] + word[i:i+2][::-1] + word[i+2:]
    if kind == "neighbor":
        return word[:i] + rng.choice(neighbors[word[i]]) + word[i+1:]
    if kind == "two_neighbors":
        chars = list(word)
        for j in rng.sample(range(len(chars)), 2):
            chars[j] = rng.choice(neighbors[chars[j]])
        return "".join(chars)
    if kind == "omit_and_swap" and len(word) >= 5:
        v = word[:i] + word[i+1:]
        v2 = mistype(v, "swap", rng)
        return v2 if v2 != v else word
    return word

# Bucket assignment matches train.py. Do not hand-pick labels from the model's vocabulary.
pool = {}
with bz2.open(source, "rt") as f:
    for line in f:
        _, lang, s, _ = line.rstrip("\n").split("\t", 3)
        if lang != "eng" or not re.fullmatch("[A-Za-z ,.!?'’-]+", s):
            continue
        if re.search(r"[.!?].+\w|[;-]", s.rstrip(".!? ")):
            continue
        words = re.findall(r"[a-z]+(?:'[a-z]+)*", s.lower().replace("’", "'"))
        key = " ".join(words)
        digest = hashlib.sha256(key.encode()).digest()
        if digest[0] < 26 and 4 <= len(words) <= 24:
            pool[key] = words
kinds = ["swap","omit","double","neighbor","two_neighbors","omit_and_swap","join","literal","prediction","prediction"]
for split, wanted in [("development", 640), ("holdout", 1800)]:
    count = 0
    for key in sorted(pool, key=lambda s: hashlib.sha256(("mb15/" + s).encode()).digest()):
        if count == wanted:
            break
        if key in seen:
            continue
        words = pool[key]
        kind = kinds[count % len(kinds)]
        rng = random.Random("mb15/" + key)
        if kind == "prediction":
            i = rng.randrange(2, len(words))
            typed, gold = "", words[i]
            task, difficulty, end = "next", "open", i+1
        else:
            positions = [j for j,w in enumerate(words) if j > 0 and j < len(words)-1
                         and w.isalpha() and 3 <= len(w) <= 13]
            if not positions:
                continue
            i = rng.choice(positions)
            gold, end = words[i], i+1
            if kind == "join":
                if not words[i+1].isalpha(): continue
                gold, end = " ".join(words[i:i+2]), i+2
                typed = gold.replace(" ", "")
            else:
                typed = gold if kind == "literal" else mistype(gold, kind, rng)
            if kind != "literal" and typed == gold: continue
            task = "keep" if kind == "literal" else "fix"
            difficulty = ("clean" if task == "keep" else "hard" if kind in ("join","two_neighbors","omit_and_swap")
                          else "moderate" if kind in ("swap","neighbor") else "easy")
        count += add(split, "CC0", task, difficulty, kind, " ".join(words[:i]), typed, gold, " ".join(words[end:]))
    assert count == wanted, (count, wanted)

# Combinatorial texting challenge. Keep entire frame families in one split.
# Appended after the locked original cases so previous IDs stay stable.
lines = [s for s in (here / "scenarios.txt").read_text().splitlines() if s and not s.startswith("#")]
assert len(lines) % 2 == 0
for group, (frames, nouns) in enumerate(zip(lines[::2], lines[1::2])):
    split = "development" if group % 4 == 0 else "holdout"
    for j, frame in enumerate(frames.split("|")):
        left, right = (v.strip() for v in frame.split("{}"))
        for k, gold in enumerate(nouns.split()):
            kind = ["neighbor", "double", "prediction", "two_neighbors", "literal", "omit", "swap", "prediction"][(k+j*3+group)%8]
            rng = random.Random(frame + gold)
            if kind == "prediction":
                # One prompt per frame. Score any of the named substitutions.
                if k != next(n for n in range(8) if (n+j*3+group)%8 in (2,7)): continue
                task, typed, target = "next", "", "|".join(nouns.split())
            elif kind == "literal":
                task, typed, target = "keep", gold, gold
            else:
                task, typed, target = "fix", mistype(gold, kind, rng), gold
                if typed == gold: continue
            add(split, "text_family", task, "everyday", "family_"+kind, left, typed, target, right)
for term in ("ngl idk tbh btw tbf rn ttyl lmk smh brb imo imho yall kinda sorta gonna wanna gotta "
             "yep yup nah nope heyyy sooo okie oops meh ugh lol lmao boba ramen gnocchi kimchi pho "
             "git vim tmux rustc nginx kubectl awk sed pytest pnpm YAML SQLite iCloud AirTag FaceTime "
             "Nia Inez Aoife Siobhan Zuri Anouk Minh Jules Noor Miko").split():
    left = "I texted" if term.islower() else "The note says"
    add("holdout", "authored", "keep", "intentional", "literal_stress", left, term, term, "yesterday")
with (here / "cases.tsv").open("w") as f:
    writer = csv.writer(f, delimiter="\t", lineterminator="\n")
    writer.writerow(fields)
    writer.writerows(rows)
