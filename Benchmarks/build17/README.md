# Build 17 · full-sentence autocorrect on the iPhone Duo simulator

Build 17 waits until the next word is committed before changing “this is amanor test” to “this is another test”. It leaves “Her username is amanor today”, “Amanor is the family name on the sign”, and “This is a minor test before launch” intact. This particular repair uses the user's confirmed spelling and short context rules on both sides. It is not a new transformer checkpoint. Other changes use aggregate training evidence, native misspelling checks and a calendar-word check gated by the preceding word. A phrase seen in multiple clean training messages can veto an unwanted edit, for example “pad thai”.

## Untouched confirmation sample

Both builds replayed the same [1,800 full sentences](confirmation.tsv) after the policy was frozen. Build 17 recovered 62 additional complete sentences and lost none that build 16 had recovered. [Build 16 final text](confirmation16.jsonl) · [Build 17 final text](confirmation17.jsonl).

| Outcome | Build 16 | Build 17 |
|---|---:|---:|
| Exact final text, 1,200 noisy inputs | 460 (38.3%) | 522 (43.5%) |
| Corrected reference words, 2,382 originally wrong or missing | 1,252 | 1,377 |
| Wrong replacements at those positions (includes case-only errors) | 84 | 83 |
| Of those, correct letters but incorrect case | 21 | 26 |
| Changes to 5,614 already-correct words inside noisy inputs | 0 | 0 |
| Exact final text, 600 intentionally clean inputs | 599 | 600 |
| Word edit distance remaining across all noisy inputs | 1,172 | 1,047 |

A recovery: “Want to gl to the aquraium on Tiuesday?” became “Want to go to the aquarium on Tuesday?” A miss: “My landlord us a barista.” still contained “us”; “Let's pick up the kidsin the morning.” retained “kidsin”. Short valid words, names, spaces, capitalization and missing punctuation still matter. Exact-sentence scores reflect them all. This is an in-domain estimate on the supplied corpus, which reuses sentence patterns; it is not a comparison with Apple's keyboard or a guarantee about free typing.

## Development and regressions

The [first sample](sentences.tsv) contained another 1,200 noisy and 600 clean reserved messages, plus 40 separately reported/authored cases. An [initial candidate](candidate.jsonl) improved exact noisy messages from 455 to 524, but retained a false correction of “pad thai” and increased wrong replacements from 81 to 87. We used that evidence to revise the policy, so we report a **different**, untouched set above. Final build 17 scored 526/1,200 exact here (build 16: 455), and 600/600 clean (599). Wrong replacements on noisy slots were 84 versus 81; 28 versus 23 were correct letters with wrong case. The first set is not independent confirmation. [Build 16 output](build16.jsonl) · [Final build 17 output](build17.jsonl).

The separately authored/reported subset scored 3/3 exact on the user's examples (up from 1/3), 15/18 exact on other noisy messages (from 12/18), and 19/19 clean (from 15/19). Several cases specifically exercise known issues, so these are regression checks.

On [build 16's original one-word benchmark](../build16/README.md), correct fixes increased from 225 to 254 of 420; wrong replacements remained at 9. Both builds kept 180/180 intended spellings and placed the target in the top three on 134/240 next-word prompts. [Build 17 outputs for the old cases](previous-cases.tsv).

## How to reproduce

The 3,600 held-out targets are distinct after normalization. Both samples use the existing build 16 holdout hash on the **corrected sentence**, excluding previously benchmarked messages before choosing examples. No variants of those targets entered the new training table. The source file SHA-256 is `3923227845fa16c0314f9282ec14eed8d3b94042b728dc8efd1ddf72a2c70df4`. Both builds use the same 15M Core ML weights. No supplementary personal lexicon or learned host text is supplied to the replay.

Each simulator replay invokes the production key handler for every supplied character, retaining case, punctuation, and previous edits. A single extra Space commits any pending final word and is removed from the scored string. The harness uses a memory-backed document proxy, skips repaint and suggestion-strip work, and runs decoder reviews to completion at each boundary. It measures correction decisions, not touch accuracy or typing-speed latency. Real key-tap UI tests separately exercise the installed extension, asynchronous revisions, and undo.

Exact sentence matching includes case, punctuation and spacing. For word metrics, the scorer aligns each input and output to the expected words (unit insert/delete/substitute cost, diagonal wins ties, internal apostrophes preserved). “Wrong replacement” means an already-wrong aligned slot changed without matching the reference. Ambiguous splits and joins can affect individual counts; word edit distance also accounts for extra words.

From the project root, with a booted **simulator** and the matching build installed:

```sh
python3 keyboard-engine/training/attested_edits.py /path/to/typo_sentences.md
python3 Benchmarks/build17/make_sentences.py /path/to/typo_sentences.md
export SIMULATOR_UDID='your-booted-simulator-uuid'
BENCHMARK_CASES="$PWD/Benchmarks/build17/confirmation.tsv" Benchmarks/build17/run.sh > /tmp/final17.jsonl
python3 Benchmarks/build17/score.py --cases Benchmarks/build17/confirmation.tsv Benchmarks/build17/confirmation16.jsonl /tmp/final17.jsonl
```

The archived build 16 output was produced from its original Swift/Rust sources before updating the policy. Pointing build 17 source at the build 16 app bundle only changes the supplied model resources; it does not recreate the build 16 policy.
