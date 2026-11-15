"""Build small US-English backoff tables from the pinned English CC0 export."""
import bz2, hashlib, json, re, sys
from collections import Counter, defaultdict
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = root / "training/eng_sentences_CC0.tsv.bz2"
assert hashlib.sha256(source.read_bytes()).hexdigest() == "c2e2edd063a31cbbc8e416a4858225e934bbb0afff485031821e59f230ccf1ca"
words = Counter()
contexts = defaultdict(Counter)
predictions = defaultdict(Counter)
seen = set()
held = []
# Don't suggest arbitrary raw corpus tokens: predictions use a reviewed display vocabulary.
original_display = set((root / "training/display-words.txt").read_text().split())
display = original_display | set((root / "training/texting-display-words.txt").read_text().split())
# Expand the displayed vocabulary for newly authored phrase counts only.
everyday_display = display | set((root / "training/everyday-words.txt").read_text().split())
def tokens(s):
    return re.findall(r"[a-z]+(?:'[a-z]+)*", s.lower().replace("’", "'"))
fixtures = (root.parent / "Benchmarks/cases.tsv").read_text().splitlines()
excluded = {" ".join(tokens(f[1] + " " + f[2])) for row in fixtures if (f := row.split("\t"))[0] == "next"}
# Prevent direct label leakage into the authored prior or external training counts.
eval_rows = [row.split("\t") for name in ["development", "check"]
             for row in (root.parent / f"Benchmarks/texting/{name}.tsv").read_text().splitlines()
             if row.startswith("next\t")]
prediction_excluded = excluded | {" ".join(tokens(ctx + " " + w)) for _,ctx,ws in eval_rows for w in ws.split("|")}
def count_predictions(ts, *, texting=False, vocabulary=everyday_display):
    for i, w in enumerate(ts):
        if w not in vocabulary: continue
        for n in range(1, min(4, i) + 1):
            context = " ".join(ts[i-n:i])
            predictions[context][w] += 4 if texting and n >= 2 else 1

for row in bz2.open(source, "rt", encoding="utf-8"):
    _, lang, sentence, _ = row.rstrip("\n").split("\t", 3)
    if lang != "eng" or len(sentence) > 180 or re.search(r"[@#/<>0-9]", sentence): continue
    ts = tokens(sentence)
    if not 3 <= len(ts) <= 25: continue
    key = " ".join(ts)
    if key in seen or key in excluded: continue
    seen.add(key)
    digest = hashlib.sha256(key.encode()).digest()
    if digest[0] < 26:
        if len(ts) >= 5: held.append((digest, ts))
        continue
    words.update(ts)
    if key not in prediction_excluded: count_predictions(ts)
    for i, w in enumerate(ts):
        if w not in original_display: continue
        for n in range(1, min(2, i) + 1):
            contexts[" ".join(ts[i-n:i])][w] += 1
# Preserve the original lexical tables. Only the prediction backend gets the
# text-message prior. Exact duplicate messages contribute no extra votes.
texting_source = (root / "training/texting-en.txt").read_text().splitlines()
texting_seen = set()
for line in texting_source:
    if line.startswith("#") or not line.strip(): continue
    ts = tokens(line)
    key = " ".join(ts)
    if key in seen or key in texting_seen or key in prediction_excluded: continue
    texting_seen.add(key)
    count_predictions(ts, texting=True)

# Taskmaster-1 2019 written USER turns only. Whole dialogs split by id before counts.
# Only aggregate predictions are bundled. Retain no addresses, phone numbers or handles.
tm_path = Path(sys.argv[1]) if len(sys.argv) == 2 else root / "training/self-dialogs.json"
assert hashlib.sha256(tm_path.read_bytes()).hexdigest() == "1e590ed0ccee279e40c2fb9e083d3b9417477c6bfe35ce5b2277167698dd858d"
tm_test, tm_train = {}, set()
for dialog in json.loads(tm_path.read_text()):
    test = hashlib.sha256(dialog["conversation_id"].encode()).digest()[0] < 26
    for turn in dialog["utterances"]:
        line = turn["text"]
        if turn["speaker"] != "USER" or len(line) > 160 or re.search(r"[@#/<>0-9]",line): continue
        for sentence in re.split(r"[.!?;:]",line):
            ts = tokens(sentence)
            if not 4 <= len(ts) <= 20: continue
            key = " ".join(ts)
            if key in seen or key in texting_seen or key in prediction_excluded: continue
            if test: tm_test[key] = ts
            else: tm_train.add(key)
for key in sorted(tm_train - tm_test.keys()): count_predictions(key.split())
samples = sorted((hashlib.sha256(key.encode()).digest(), ts) for key,ts in tm_test.items())
check = []
for digest,ts in samples:
    # Export only reviewed-vocabulary examples: this public test slice measures
    # in-vocabulary prediction, and cannot leak a source speaker's name/address.
    if len(ts) < 5 or not all(w in display for w in ts): continue
    pos = 2 + digest[1] % (len(ts)-2)
    check.append("next\t"+" ".join(ts[:pos])+"\t"+ts[pos])
    if len(check) == 256: break
(root.parent / "Benchmarks/texting/dialogue-holdout.tsv").write_text("\n".join(check)+"\n")
print(f"{len(tm_train - tm_test.keys())} external training turns/segments; {len(check)} independent in-vocabulary prompts")

for line in (root / "training/everyday-phrases.txt").read_text().splitlines():
    if line.startswith("#") or not line.strip(): continue
    ts = tokens(line)
    key = " ".join(ts)
    if key in texting_seen or key in prediction_excluded: continue
    texting_seen.add(key)
    count_predictions(ts, texting=True, vocabulary=everyday_display)

def emit(file, entries):
    (root / "model" / file).write_text("".join(f"{key}\t{v}\n" for key,v in sorted(entries)))
emit("words.tsv", ((w,n) for w,n in words.items() if n >= 2 and len(w) <= 28))
emit("next.tsv", ((key," ".join(w + ":" + str(n) for w,n in sorted(cs.items(),key=lambda x:(-x[1],x[0]))[:5]))
                  for key,cs in contexts.items() if sum(cs.values()) >= 3 and max(cs.values()) >= 2))
emit("predict.tsv", ((key, " ".join(w + ":" + str(n) for w,n in sorted(cs.items(),key=lambda x:(-x[1],x[0]))[:6]))
                    for key,cs in predictions.items() if max(cs.values()) >= 2))
# One deterministic interior position per held-out sentence; no vocabulary-based target selection.
rows = []
for digest, ts in sorted(held)[:256]:
    pos = 2 + digest[1] % (len(ts) - 2)
    rows.append("next\t" + " ".join(ts[:pos]) + "\t" + ts[pos])
(root.parent / "Benchmarks/held-out.tsv").write_text("\n".join(rows) + "\n")
print(f"{len(seen)} distinct eligible sentences; {len(rows)} holdout predictions")
