# Build 40: when a correctly spelled word is wrong for the sentence

Build 39 was signed and installed on the physical iPhone Duo; CoreDevice reported bundle version 39 afterward. Build 40 is a simulator candidate. It uses the same 15M Core ML transformer as 39 and trains an additional contextual scorer in the Rust engine.

| Frozen, paired simulator comparison | Build 39 | Build 40 |
|---|---:|---:|
| Wrong real words corrected (and full messages exactly correct) | 10/48 (20.8%) | 16/48 (33.3%) |
| Already-correct versions of those messages preserved | 48/48 | 48/48 |
| Other intentional-word messages preserved | 42/43 | 42/43 |
| Originally correct words changed, across all 139 replays | 1/1,263 | 1/1,263 |
| Damaged targets replaced with a different wrong word | 0 | 0 |
| Previously missed targets recovered, **training diagnostics only** | 0/28 | 10/28 |
| Distinct, clean desktop sentences preserved | 10,764/10,764 | 10,764/10,764 |

The six additional fixes were be → by, wish → with, not → now, us → is, tour → your and hope → home. These were the only six fresh outputs that differed. For example, “I plan to go hope after the last speech” became “I plan to go home after the last speech.” Both keyboards changed “hose” to “house” in “There's a leak in the hose that feeds the greenhouse.” Both also left “The painters are coming in Wednesday after lunch” unchanged. Build 40 still missed 32/48; this is a targeted gain, not an estimate of general texting accuracy.

The two versions received identical keystrokes on the Duo simulator. The replay invokes the production keyboard controller and decoder with an in-memory text document and synchronous model scheduling; it does not measure real finger accuracy, device latency or energy. There are 139 inputs from 91 newly authored messages. Each of 48 noisy messages has a clean counterpart; the additional 43 are independent clean controls. They were frozen before model fitting and checked against the paired corpus, previous challenge suites, public sources and this round's practice material. A noisy case and its clean control are not independent reference messages. The final model and replay binaries were fingerprinted before inspecting candidate results. These are targeted cases, not a random sample of user input.

**Desktop regression.** Across the same 100,000 S:/C: messages, 39 fixed 194,705/204,918 damaged slots and 40 fixed 194,681 (24 fewer). Fully correct messages went from 88,697 to 88,689; on the reserved partition they went from 13,202 to 13,206, with identical typo recovery. Both changed 24 of 451,446 intended words. Comparing the same aligned slots on both builds identified 0 newly damaged and 0 restored originally correct words. Wrong guesses on already damaged slots rose from 1,484 to 1,487. This targeted improvement does not justify replacing build 39 on the phone. [Full comparison](desktop-comparison.json) · [63 changed outputs](desktop-changes.jsonl.gz) · [All 100,000 outputs](desktop-40.jsonl.gz).

**Validation.** An independent rebuild reproduced the fresh score report byte for byte. All 17 Rust tests, nine scorer tests and three installed-extension key-tap tests passed. [Verification](verification.json).

**Training.** The [28 earlier misses](training-misses.json) are training examples in this round. [The trainer](../../keyboard-engine/training/contrast40.py) derives competing words from aligned S:/C: training pairs and these misses; it fits classifiers on contexts from a pool of 230,048 source messages plus [103 practice sentences](../../keyboard-engine/training/context40-practice.txt) with both meanings. It uses the two words on each side and their learned grammar classes. A context must beat a separately calibrated threshold for that word pair; competing winners keep the literal. No complete example sentence or unconditional replacement is exported. The 51 fitted contrasts use shared feature IDs and quantized weights. The existing keyboard's protection for literal prompts, shortcuts and user words still applies. [Calibration](../../keyboard-engine/training/calibrate40.py) uses build 39's old review set and results to protect intended words and earlier correct repairs. Neither those examples nor the 28 training examples count as fresh evidence. See [corpus provenance](../build39/TRAINING.md).

**Reproduce.** On a Mac with Xcode and the project's Swift/Rust toolchains, set SIMULATOR_UDID and run Benchmarks/build40/replay.sh with a scratch output directory. The script rebuilds and replays the candidate, then compares against the archived baseline. For model refitting, run these commands from the repository root with the same Python/PyTorch/SciPy environment used for build 39:

~~~sh
python Benchmarks/build40/prepare.py "$PAIRED" "$TASKMASTER_TRAIN" "$SMS_ZIP"
python keyboard-engine/training/contrast40.py "$PAIRED" "$TASKMASTER_TRAIN" "$SMS_ZIP" Benchmarks/build40/training-misses.json
python keyboard-engine/training/calibrate40.py Benchmarks/build22/blind/review.json Benchmarks/build39/review-39.jsonl.gz
~~~

[Fresh inputs](fresh.json) · [Fixture freeze](fixture-freeze.json) · [Candidate freeze](candidate-freeze.json) · [39 outputs](fresh-39.jsonl.gz) · [40 outputs](fresh-40.jsonl.gz) · [Paired scores](comparison.json) · [Per-message diagnostics](fresh-details.jsonl.gz) · [Old misses replay](training-replay-comparison.json) · [Clean controls](clean-comparison.json) · [Development review](development-review-comparison.json)
