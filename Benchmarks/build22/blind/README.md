# Full-sentence iPhone Duo benchmark

The review and final fixtures were frozen before the first keyboard replay. Each has **356 distinct messages**, including 236 noisy inputs and 120 literal controls. Both fixtures mix the following two sources.

- **52 newly authored messages per suite.** These cover multiple simultaneous mistakes, short words, valid-word substitutions, word boundaries and contractions. Twenty clean controls per suite call for keeping names, slang, real words, casing and punctuation literally. The intended wording is supplied for every case, including ambiguous substitutions.
- **304 public SMS messages per suite.** The references are trimmed non-spam messages from the UCI SMS Spam Collection by Tiago Almeida and José María Gómez Hidalgo. The project selected 6–26-word messages containing only English letters and basic punctuation, with a final period, question mark or exclamation mark. Original capitalization, wording, abbreviations and punctuation are the reference. Each suite includes 100 unmodified messages and 204 reproducibly corrupted messages. The generator changes 2–3 different words in each of 68 public multi-typo cases. It corrupts one position in the remaining public cases. The source is historical and geographically mixed. The sample and error mix do not estimate present-day population accuracy. [Dataset, attribution and CC BY 4.0 license](https://archive.ics.uci.edu/dataset/228/sms+spam+collection)

Public source messages are assigned to separate pools by the hash of their normalized wording before sampling. The generator excludes both the typed and expected forms of earlier cases and full known training sentences under the project's normalized-word key. Exclusion sources include both sides of the desktop S:/C: corpus, prior repository benchmark fixtures, the Tatoeba training snapshot, the Taskmaster-1 and Taskmaster-2 dialog sources, build 21's training and validation text, and project-authored training text. The suites share no normalized source message or typed message. Phrases and vocabulary naturally recur. Punctuation-only and casing differences alone do not constitute fresh text.

The source archive checksum, eligible pool sizes, 826,031 blocked normalized keys, counts and frozen case hashes are in [freeze.json](freeze.json). Each public record's source_line points to its one-based line in SMSSpamCollection. There is one record per original message. [Review inputs](review.json) and [final inputs](final.json).

## Simulator replay

The benchmark replays each character through the simulator keyboard controller and commits its last boundary. It uses an in-memory text document and synchronous decoder work. The recorded final text excludes the benchmark's trailing commit space. The simulator runner accepts an array of records with id and typed, and writes one JSON line per row with id and final. The following runs the recorded baseline on the iPhone Duo.

```sh
b=Benchmarks/build22/blind
bundle=/tmp/MonkeyBoard-Build21/Build/Products/Debug-iphonesimulator/MonkeyBoard.app/PlugIns/MonkeyBoardKeyboard.appex
for suite in review final; do
    xcrun simctl spawn 5B57DE6C-7FDE-4319-863A-F74D3FC4476B /tmp/mb21/stable "$bundle" \
        "$PWD/$b/$suite.json" > "$b/$suite-21.jsonl"
done
```

The final suite is reserved until candidate freeze. Only the review cases should guide tuning. Source reconstruction with the already-pinned project Tatoeba and Taskmaster files uses the following commands.

```sh
curl -fL 'https://archive.ics.uci.edu/static/public/228/sms+spam+collection.zip' -o /tmp/mb22/blind/sms.zip
python3 Benchmarks/build22/blind/freeze.py ~/Desktop/typo_sentences.md \
    /tmp/mb-taskmaster-self-dialogs.json /tmp/mb20 /tmp/mb21 /tmp/mb22/blind/sms.zip
```

## Scoring

```sh
b=Benchmarks/build22/blind
python3 "$b/test_score.py"
python3 "$b/score.py" "$b/final.json" --baseline "$b/final-21.jsonl" \
    --candidate /path/to/candidate-final.jsonl --report /path/to/comparison.json
python3 "$b/score.py" /tmp/mb22/all.json --baseline /tmp/mb22/build21-*.jsonl \
    --candidate /path/to/candidate-shards/*.jsonl --report /path/to/complete-100k.json
```

The scorer rejects duplicate, missing and extra IDs. It scores every input, including repeated source rows in the original desktop corpus. Omit the candidate flag to score just the baseline. Pass --details FILE to write an optional JSONL diagnostic with the exact inputs, outputs and counts for every row. Results include overall, training/reserved or review/final split, source and case-kind totals where available.

- **Exact** requires identical Unicode strings, including case, punctuation and whitespace. Noisy exact counts completely repaired messages. Clean exact counts byte-for-byte preservation of controls.
- **Word slots** use deterministic case-sensitive minimum-edit alignment to reference words (letters/digits, including internal apostrophes). Ties preserve common prefix/suffix matches and favor the diagonal in the remaining span. A slot typed wrong or missing is either fixed, missed unchanged or changed to another wrong value. A word initially equal to its reference is an intended word. Any later difference at its slot counts as collateral. Multiword joins can damage several slots.
- **Insertions and deletions** are reported separately for the input and output relative to the reference. Insertions do not disappear from word-edit counts just because they fall between reference slots. New insertions, removed or changed input insertions, and new deletions of previously correct words have their own counts. Final unit word-edit distance is substitutions plus insertions plus deletions.
- **Punctuation** is compared by exact character at word boundaries and by apostrophe position inside words. The report counts damaged or repaired sentences and mismatched punctuation sites. Whitespace differences still fail whole-sentence exactness.
- **Paired comparisons** report newly exact and lost exact rows, rows with more/fewer remaining word edits, and how often outputs changed. Rates should include the corresponding numerator and denominator.

## Build 21 baseline

| Fixture | Exact noisy | Clean preserved | Damaged word slots fixed | Intended words changed | Wrong revisions of damaged slots | Final inserted / deleted words | Final punctuation exact |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Review | 66/236 | 88/120 | 207/396 | 126/3,724 | 15 | 5 / 13 | 325/356 |
| Final | 61/236 | 88/120 | 197/383 | 128/3,656 | 10 | 6 / 19 | 327/356 |

An original public message containing informal casing or spelling establishes that form as its reference, so an automatic style change counts against preservation. The summary includes every frozen row, both source groups and all challenge kinds. [Review outputs](review-21.jsonl), [review counts](review-21-summary.json), [final outputs](final-21.jsonl), [final counts](final-21-summary.json).

The separate desktop clean controls replay all 10,764 distinct exact reference strings from the 15,184 reserved S:/C: rows. Build 21 preserved 10,758 messages completely and changed six of 71,476 intended words. All six changes were substitutions. These source-corpus controls are separate from the two fresh fixtures. The fixture produced by build22/prepare.py has SHA-256 f5b0d9ca25923ab3040d1e2596003fd1d456a5e44c9e843f94f248db4a1dfeb5. The preserved baseline JSONL has SHA-256 fcae4bb8dead25311d1c79fcdbe21850cf5f3d96b05b8a7bd1663d67baf33f6d after decompression. [Clean replay outputs](clean-21.jsonl.gz) and [metrics](clean-21-summary.json).

All 100,000 original S:/C: input strings differ from their references. They contain 84,816 training rows and 15,184 reserved rows. Build 21 exactly recovered 41,802 training sentences and 7,279 reserved sentences. It recovered 19,572 of 31,054 damaged reference word slots on the reserved rows and changed one of 68,303 originally correct words there. There are zero unused reserved references after prior benchmark exclusions, so these results measure recovery on the supplied corpus. [Complete build 21 counts by split](desktop-100k-21-summary.json).

## Reproduce the complete corpus replay

Prepare the original desktop S:/C: file with [prepare.py](../prepare.py). The SHA-256 of the original file is 3923227845fa16c0314f9282ec14eed8d3b94042b728dc8efd1ddf72a2c70df4. Pass a compiled simulator harness and its matching compiled keyboard extension to [run_full.sh](../run_full.sh). The wrapper checks all ten 10,000-row shards against all.json, joins the output in fixture order, scores all IDs and saves the summary and a deterministic compressed JSONL. Logs are retained per shard. Set JOBS to change the default parallelism of three workers.

```sh
python3 Benchmarks/build22/prepare.py ~/Desktop/typo_sentences.md /tmp/replay-inputs
Benchmarks/build22/run_full.sh "$SIMULATOR_UDID" "$REPLAY_EXECUTABLE" "$KEYBOARD_APPEX" \
    /tmp/replay-inputs /tmp/replayed-build
python3 Benchmarks/build22/blind/score.py /tmp/replay-inputs/all.json \
    --baseline Benchmarks/build22/blind/desktop-100k-21.jsonl.gz \
    --candidate /tmp/replayed-build/replay.jsonl.gz --report /tmp/comparison.json
```

The archived build 21 output was checked in original input order against all 100,000 IDs. It yields the same summary as the ten original simulator shards. Its uncompressed SHA-256 is 90a58bf31607a1b19e40f73b11ce51e9a2f4c1ef9542ce72a40cfcb8b9016c58. [Complete compressed build 21 outputs](desktop-100k-21.jsonl.gz).

## Training-source audit

The audit independently checks both the typed and expected form of every review and final input against the normalized training-source texts. No complete fixture message occurred among the 170,698 normalized forms in the paired file, the 41,495 Tatoeba references, the 130,931 Taskmaster training messages (including the exact 52,000 sampled neural negatives), or the supplemental SMS training messages. The audit rebuilt the shipped casual-literal feature counts byte-for-byte from 3,892 separate SMS messages. The real-word model's source filter excludes all 1,277 eligible normalized SMS reference messages, even those that did not enter either fixture. SMS training and evaluation come from the same public collection. Common words, phrases, people, dialect and style can recur. Exact-message disjointness does not establish independence at the sender, topic, paraphrase or collection level. [Reproducible audit](audit_sources.py) and [counts](source-audit.json).

All 10,709 distinct normalized references in the reserved paired-file partition had already appeared in earlier benchmark fields. Normalization collapses 10,764 distinct exact strings to those 10,709 forms. The paired-file training partition excludes all 10,709, and no reserved gold message occurs in the Tatoeba or Taskmaster source files checked. The reserved partition was also used for policy development. Report reserved results as corpus coverage; the frozen final fixture measures performance on previously unexamined messages. The public SMS reference texts were originally written by people. Their introduced mistakes were generated for this evaluation; the remaining challenge messages, inputs and intended corrections were newly authored. Correctness on real typing mistakes at their natural frequency requires a separately sampled source of such mistakes.

```sh
python3 Benchmarks/build22/blind/audit_sources.py ~/Desktop/typo_sentences.md \
    /tmp/mb21/train.txt /tmp/mb22/blind/sms.zip
```
