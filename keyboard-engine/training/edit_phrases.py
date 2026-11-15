"""Count adjacent pairs for typo repair using the existing English training split."""
import bz2
import hashlib
import re
from collections import Counter
from pathlib import Path

engine = Path(__file__).resolve().parents[1]
src = engine / "training/eng_sentences_CC0.tsv.bz2"
assert hashlib.sha256(src.read_bytes()).hexdigest() == "c2e2edd063a31cbbc8e416a4858225e934bbb0afff485031821e59f230ccf1ca"
counts = Counter()
seen = set()
for line in bz2.open(src, "rt"):
    _, lang, sentence, _ = line.rstrip("\n").split("\t", 3)
    if lang != "eng" or len(sentence) > 180 or re.search(r"[@#/<>0-9]", sentence):
        continue
    words = re.findall(r"[a-z]+(?:'[a-z]+)*", sentence.lower().replace("’", "'"))
    key = " ".join(words)
    if not 3 <= len(words) <= 25 or key in seen or hashlib.sha256(key.encode()).digest()[0] < 35:
        continue
    seen.add(key)
    counts.update(zip(words, words[1:]))
with (engine / "model/edit-phrases.tsv").open("w") as f:
    for (left, right), count in sorted(counts.items()):
        if count >= 2:
            f.write(f"{left} {right}\t{count}\n")
