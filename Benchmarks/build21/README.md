# Build 21: simulator candidate — hold

The frozen final policy corrected **1,039/1,389** single errors versus **909/1,389** for build 20. Every formerly recovered target stayed recovered. Both changed 76 previously correct word slots and introduced three false word splits. These counts include changes of capitalization. No build was deployed to a physical device.

| Final blind iPhone Duo simulator audit | Build 20 | Build 21 |
|---|---:|---:|
| Target typo fixed | 909 / 1,389 (65.4%) | 1,039 / 1,389 (74.8%) |
| Missing space fixed | 274 / 480 | 347 / 480 |
| Short errors (including real words) fixed | 460 / 705 | 517 / 705 |
| Longer word errors fixed | 175 / 204 | 175 / 204 |
| Deliberately clean sentence preserved exactly | 1,029 / 1,062 | 1,030 / 1,062 |
| Exact sentence among sentences the keyboard changed | 879 / 978 (89.9%) | 1,006 / 1,097 (91.7%) |
| Actual next word in first / top three suggestions | 218 / 341 of 1,062 | 243 / 389 of 1,062 |

The release check requires 99% target recovery, 99.9% exact preservation of clean sentences and 99.5% exact output when the keyboard changes a sentence, with no net increase in unintended word changes or false splits. **All three rates are below target.** These are simulator criteria, not a certification of performance in other apps, languages or typing styles. Top-three next-word prediction is a separate task with many reasonable answers and is not an autocorrect accuracy score.

The 2,451 [final inputs](audit-blind.tsv) came from held-out conversations. Both sides of conversations are represented. One controlled error was injected into each noisy input, including missing spaces, targeted short-word confusions and randomized insertion, deletion, substitution and transposition. Inputs are matched by ID, and their gold and noisy forms are excluded from earlier benchmark inputs. The standalone evaluator counts recovery of the specific target independently of end-of-sentence exactness; punctuation/case are included in exactness. A change that fixes the typo but also changes a correct word does not count as an exactly corrected sentence. Correct clean text means the transcript **as supplied**, including lowercase names and pronouns. Failures include turning “lyft” into “left”. Group rates are sensitive to how many examples of each error and dialogue domain are sampled.

[Paired simulator outputs: build 20](audit20.jsonl) · [build 21](audit21.jsonl) · [by error class](audit-summary.txt) · [release gate](release.json) · [remaining errors and unintended changes](misses.tsv)

## Checks beyond the headline

- On the owner's S:/C: corpus, 263 unused, distinct gold sentences were available under the existing training split and prior-benchmark exclusions. Of the 175 noisy sentences, both builds restored 198/368 labeled word slots (53.8%) and exactly fixed 59/175 sentences. Both preserved all 88 clean controls. These results did not improve. This set includes casing, names, merged words, and multiple simultaneous errors; it is not a comparable denominator to single injected errors. [Inputs](paired.tsv), [baseline](paired20.jsonl), [final candidate](paired21-stable.jsonl).
- On the older 1,280 natural short-word error regression, both builds fixed **exactly the same 1,037 target errors** and preserved 240/240 clean controls. The initial contextual candidate regressed on previously corrected examples such as “I need to by more coffee”. The final policy gives existing high-confidence corrections first priority. [Final replay](regression21-stable.jsonl).
- The initial 833-sentence development set, first 2,499 user-utterance blind set and a second 2,499 user-utterance confirmation set informed development or revealed regressions before the final audit. Do not combine their scores with the final audit. The first contextual candidate learned a frequency preference for “has” and overwrote valid uses of “had”. Literal-context support and a separate scoring head for existing spelling behavior prevent this class of regression. Previous candidate outputs are retained; filenames beginning with **audit** designate the frozen final audit.
- Next-word suggestions were scored at one deterministically chosen interior position per clean audit sentence. All targets are included, even if not in the strip vocabulary. [Scorer](predictions.py), [build 20 predictions](audit-predict20.jsonl), [build 21](audit-predict21.jsonl).

## What was trained

The [main transformer trainer](../../keyboard-engine/training/neural/adapt_decoder.py) updated the output projection (3,153,920 parameters) on 130,931 unique normalized conversational sentences. It used cross-entropy plus a penalty for moving too far from the original next-word distribution. On 26,118 in-vocabulary validation positions, negative log-likelihood fell from 4.476 to 3.691, and raw top-one accuracy rose from 23.1% to 28.2%. Validation is distinct from blind testing. The learned projection shares the five attention blocks and embeddings with the original readout. Keeping both readouts in a single Core ML package costs about 6 MiB extra without duplicating the encoder. The app uses the adapted projection for suggestions and for novel short-word reviews; it keeps the legacy projection for existing corrections. [Training log](../../keyboard-engine/research/decoder21/fit.json).

The [boundary trainer](../../keyboard-engine/training/context21.py) estimated compact lexical context counts on 104,409 messages and fitted its boundary scorer on 26,522 disjoint messages, using 189,083 positive and 94,139 negative examples. The [Rust decoder](../../keyboard-engine/src/context21.rs) evaluates candidate splits, protects known whole words, and uses quantized output embeddings to avoid replacing similar real words automatically. Short-word replacements are proposed by the existing generated edit neighborhood, ranked using left and right evidence, then checked against the sentence decoder. No new typo-pair lookup rules were added. No raw training sentences or personal typing logs ship in the keyboard. Training is offline; no model was trained from live keystrokes.

Prepared text comes from [Taskmaster-1](https://github.com/google-research-datasets/Taskmaster/tree/d92cb6af3005f1dc09c39e75e7daf4a04905e00b/TM-1-2019) and [Taskmaster-2](https://github.com/google-research-datasets/Taskmaster/tree/d92cb6af3005f1dc09c39e75e7daf4a04905e00b/TM-2-2020), Google LLC and contributors, [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Text was segmented, normalized and, in the benchmark, artificially corrupted. [prepare.py](prepare.py) checks source hashes, partitions whole conversations by ID, excludes known benchmark and prior training texts from fresh samples, and deduplicates normalized sentences across partitions. Both speakers in the last audit were checked against the exact frozen training sentence file. The original transformer and spelling sources are documented in [MODEL.md](../../keyboard-engine/MODEL.md).

## Reproduce and verify

Run the following from the project root. Model training uses PyTorch and SciPy. Export uses the project's coremltools environment. The preparation script expects the eight checksummed Google JSON files in DATA, the paired file in PAIRED, the Taskmaster-1 self-dialogs file in SELF, and a scratch directory WORK. The original training split and model checkpoints are required for retraining. Use a separate output directory or checkout when experimenting.

```sh
python3 Benchmarks/build21/prepare.py "$DATA" "$PAIRED" "$SELF" "$WORK"
python3 keyboard-engine/training/neural/adapt_decoder.py "$WORK" keyboard-engine/research/decoder15m keyboard-engine/research/decoder21
python3 keyboard-engine/training/context21.py "$WORK"
python3 keyboard-engine/training/neural/short_vectors.py keyboard-engine/research/decoder21 keyboard-engine/model/context21
python3 keyboard-engine/training/neural/export_decoder.py --checkpoint keyboard-engine/research/decoder21 --legacy-checkpoint keyboard-engine/research/decoder15m --out keyboard-engine/model/decoder21
python3 Benchmarks/build21/check_export.py
python3 Benchmarks/build21/paired_audit.py "$PAIRED" "$WORK/paired.json"
python3 Benchmarks/build21/prepare.py "$DATA" "$PAIRED" "$SELF" "$WORK/confirmation" --prefix confirmation-
python3 Benchmarks/build21/prepare.py "$DATA" "$PAIRED" "$SELF" "$WORK/audit" --prefix audit- --include-replies-excluding "$WORK/train.txt"
python3 Benchmarks/build20/score.py Benchmarks/build21/audit-blind.tsv Benchmarks/build21/audit20.jsonl Benchmarks/build21/audit21.jsonl
python3 Benchmarks/build21/predictions.py Benchmarks/build21/audit-blind.tsv Benchmarks/build21/audit-predict20.jsonl Benchmarks/build21/audit-predict21.jsonl
python3 Benchmarks/build21/release_check.py --gate
```

The last command intentionally exits nonzero on a release hold. Full typing replays use [the simulator harness](../build17/run.sh) with the matching version's frozen executable **and** matching compiled extension model. Set `SIMULATOR_UDID`, `BENCHMARK_APP`, and `BENCHMARK_CASES` to select them. It sends character events through production editing code with a memory document and synchronous review scheduler; UI tests also type with the installed extension. Sensor-level tap accuracy, physical-device latency and memory are not established by this run. [Model and benchmark digests](fingerprints.json).
