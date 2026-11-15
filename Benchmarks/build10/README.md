# Build 10: sentence context and key targeting

Frozen before training or changing the keyboard: build 9 simulator outputs, 70 project-authored texting cases, and scripted key-edge probes. The second correction replay has 384 held-out CC0 sentences with deterministic nearby-key substitutions, omissions, duplications and transpositions, including 94 untouched controls. A **different** 384 examples calibrate the commit policy. Synthetic mistakes and authored texts aren't a measurement of a user's typing. This experiment never collects it.

| Automatic correction | Build 9 | Build 10 compact | 15.2M decoder, offline |
|---|---:|---:|---:|
| Fresh texting typos fixed / 39 | 12 | 16 | 16 |
| Wrong words inserted on those typos | 5 | 5 | 5 |
| Unwanted changes to 23 controls | 0 | 0 | 0 |
| Correct fixes on 290 held-out synthetic typos | 163 | 184 | 197 |
| Wrong words inserted on those typos | 2 | 3 | 5 |
| Unwanted changes to 94 controls | 0 | 0 | 0 |
| Fresh next-word prompts, acceptable top 3 / 8 | 5 | 5 | 5 |
| General next-word top 3 / 256 | 62 | 62 | 69 |
| Dialogue next-word top 3 / 256 | 147 | 147 | 151 |

These are the **committed words**, not hits hidden in a suggestion list. Build 10 newly corrected “dsd” to “dad”, “tabke” to “table”, “tickey” to “ticket” and “sohg” to “song” on the texting slice. Its one additional wrong replacement on the public replay was “dout” → “out” when the intended word was “doubt”. Personal-lexicon/field/undo safeguards remain; real-word errors generally abstain. The two model families have separately calibrated margins; model comparisons measure the entire policy, not raw language-model skill. Build 10 keeps the statistical next-word strip; next-word gains in the last column are offline only.

**Does earlier context actually matter?** With the same model, candidates and thresholds, restricting context to the final four words produced 182 correct / 5 wrong for compact and 194 correct / 7 wrong for the decoder on the 290 typos. Longer context produced 184 / 3 and 197 / 5 respectively. The fresh texting slice went the other way: four words gave 17 and 18 correct respectively, versus 16 each at full context. On the three matched pairs (beach/bench, slice/slide, book/boot), none of the three systems got both halves of a pair right. One of six individual answers was correct for each system. Candidate coverage, domain balance, and semantic ranking all still need work. Do not treat these fixtures as fresh after further tuning.

**Taps.** Same scripted input on build 9 and 10, in both joined and split layouts: 172 coordinates per layout (centers, interior edges, and 0.75 pt outside each eligible edge of every letter). Build 9: 78 correct, 94 dropped, 0 wrong per layout. Build 10: 172 correct, 0 dropped, 0 wrong per layout. The split center stays inactive. A keyboard extension also needs its hosting surface to receive the touch: near-transparent tinted backing (2.5% alpha) prevents touches from passing through the clear space between caps. A UI test taps opposite sides of the E/R gap and checks that the host receives “er”. These are intentionally adversarial hit tests, not a general 55% drop rate. No per-user touch data or inferred finger-overlap percentages.

**Cost.** The shipped 64-dimensional causal attention model uses 2,637,932 bytes of int8 weights plus 62,610 bytes of vocabulary. For eight candidates, warm p95 Rust scorer calls in the Duo simulator took 0.006 ms at 12 context words and 0.017 ms at 128; first call ~0.87 ms. This is scorer-only on a Mac host, not real-phone end-to-end time or peak extension memory. No new model runs on touch-down.

**Reproduce.** Boot a Duo simulator and run `Benchmarks/build10/run.sh /tmp/mb10-rerun`. This compares the current compiled Swift/Rust path to the frozen build 9 output, runs the four-word control, and replays key coordinates. `MB_PYTHON=/path/to/python Benchmarks/build10/research.sh` evaluates the checked-in FP16 research checkpoint using PyTorch; it is not linked into the iOS app. Inspect the TSVs for row-by-row outputs, including wrong/unchanged words. See [training notes](../../keyboard-engine/MODEL.md). Fixtures and baselines must have identical ordered labels. Build 9 columns named `candidate` are its actual results; the legacy `build6` column is not the baseline here.
