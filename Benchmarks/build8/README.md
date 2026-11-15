# Build 8: everyday texting

We added **133 project-authored texting cases**: 42 typos/contractions, 39 intentional spellings (including slang, acronyms, names, handles and identifiers), and 52 conversational prompts. Prompts accept one or more plausible next words. A hit means at least one accepted word is visible in the first three suggestions; a different reasonable continuation can still be scored as a miss.

| Cases | Build 7 | Build 8 |
|---|---:|---:|
| New texting typos replaced correctly | 27/42 | 41/42 |
| Wrong replacements on those typos | 0/42 | 0/42 |
| Unwanted edits on protected examples | 0/39 | 0/39 |
| Next word in top three on new texting prompts | 17/52 | 38/52 |
| Next word ranked first on new texting prompts | 11/52 | 26/52 |
| Top three on older conversational prompts | 10/24 | 17/24 |
| Top three on general-English holdout | 61/256 | 62/256 |
| Top three on separate written-dialogue holdout | 67/256 | 147/256 |

The new texting results were identical in joined and split mode. The older 30-typo fixture retained 28 correct joined and 27 split; its 30 protected cases retained zero unintended edits. Gates check matched ordered cases, no increase in wrong replacements, and no decrease in aggregate correction or top-three hits.

**What changed.** Build 7 left “Im”, “Sorry im”, and “Ive” literal; build 8 supplies “I'm”, “Sorry I'm”, and “I've”. “Send me an IM” stays intact. After “I'll pick you” the top suggestion changed from “have” to “up”; after “I'm on my” it changed from “phone” to “way”. The ranker now uses longer contexts and conversational counts, with general English as the fallback for a lone context word. No typed messages were used for training.

**What this shows.** The 81 development cases were used to investigate misses; the 52 check cases were written before measuring and compared after selecting an implementation. These are author-written fixtures, not an independent human typing study. Development next-word top-three rose 12/32 → 28/32; the separate check rose 5/20 → 10/20. The remaining typo miss was “hedve” → “he'd've”. On “Just got off the”, build 8 still misses “bus”, “train” and “phone”. The general-English holdout was used as a non-regression gate. The external dialogue test uses exact next words from held-out Taskmaster conversations within the reviewed vocabulary. These results should not be generalized to all private messages.

**Reproduce.** With the Duo simulator booted, run `Benchmarks/build8/run.sh`. It compiles the shipping extension's Swift and Rust inference for the simulator, scores both layouts against the archived build 7 rows, and writes fresh TSVs into a temporary directory. A directory argument overrides the output location. In raw files, `build6` is the older historical comparison column; use `candidate` from each release for build 7 → 8. Build 7 texting snapshots were taken before changing the engines. For the later external dialogue holdout, run `python3 Benchmarks/texting/build7_next.py` to reconstruct the old result from the unchanged build 7 frequency table. The script first checks it reproduces all 256 recorded build 7 general predictions exactly.

For dataset attribution, exclusions and reproducibility see the [model notes](../../keyboard-engine/MODEL.md). Swift UI tests exercise keyboard insertion, selecting a suggestion and immediate Delete-to-undo in a real host field. Rankings and UI tests are from the simulator; these are not device latency or battery measurements.
