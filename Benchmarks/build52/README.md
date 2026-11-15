# MonkeyBoard build 52: full-sentence autocorrect on the Duo simulator

**Build 52 retains all six build-40 catches. It also corrects every one of the 42 lost fixes and 18 gained fixes in the archived comparison.** Compared with the same-session replay of build 40, it fixed 785 more damaged positions on the full corpus and six more on the two final fresh sets. The fresh sets do not establish near-perfect typing. No physical device was updated.

| Identical input and full-sentence scoring | Build 39 | Build 40, rerun | Build 52 |
|---|---:|---:|---:|
| Full S:/C: — damaged positions fixed | 194,705/204,918 | 194,723/204,918 | 195,508/204,918 |
| Full S:/C: — exact messages | 88,697/100,000 | 88,708/100,000 | 89,244/100,000 |
| Full S:/C: — intended words changed | 24/451,446 | 24/451,446 | 23/451,446 |
| Full S:/C: — wrong replacements of damaged words | 1,484 | 1,485 | 1,298 |
| Reserved S:/C: — exact messages | 13,202/15,184 | 13,207/15,184 | 13,281/15,184 |
| Final fresh — damaged positions fixed | 61/141 | 66/141 | 72/141 |
| Final fresh — noisy messages exactly corrected | 22/90 | 27/90 | 33/90 |
| Final fresh — clean messages preserved | 91/106 | 91/106 | 91/106 |
| Final fresh — intended words changed | 32/1,961 | 32/1,961 | 32/1,961 |
| Final fresh — wrong replacements of damaged words | 8 | 8 | 8 |

**Which “24 lost” were recovered?** The historical report measured a net difference: 42 individually lost fixes and 18 gains, across 63 changed messages. This round reran both frozen baseline binaries. All 100,000 build-39 outputs matched its archive. Build 40 differed from its own archive on 44 messages, and already recovered all 42 losses while preserving all 18 gains. Isolated replays reproduced the same result. The reason the older build-40 run differed is unconfirmed. The table therefore uses the rerun rather than taking credit for those recovered words. The six additional previously fresh catches are separate; all six remain correct. [Slot audit](archive-audit.json) · [Known regression comparisons](regressions-comparison.json).

Across the intermediate candidates, improvements were not monotonic. See the [per-build history, including rejected candidates](iteration-history.json).

**Gains and losses on the full corpus.** Against rerun 40, build 52 recovered 812 previously missed positions and lost 27 previously correct repairs. It newly harmed 0 originally correct words and restored 1. The old 63 cases are diagnostic, not fresh. The whole corpus includes training data; the reserved partition groups normalized references and is reported separately. All 10,764 unique clean desktop controls were preserved. An exact sentence includes capitalization and punctuation, and a repaired word position is case-sensitive. The archive records raw outputs and the same alignment scorer across all builds. [Full scores](desktop-comparison.json) · [New build outputs](desktop-52.jsonl.gz) · [Scope and methodology of the desktop corpus](../build39/TRAINING.md).

**Fresh results.** The final hand-written set has 76 inputs from 46 distinct new references: 18 real-word errors, 12 multi-error messages, and 46 clean controls. The new build fixed 7/18 real-word substitutions (40: 4/18), and kept all 46 clean messages. For example, it fixed “a pear of safety glasses,” and corrected both “Diid” and “lugagge” in the same message. It can still fix an opening without recovering a later typo. [Hand-written cases](../build51/fresh.json) · [Scores](fresh-comparison.json).

The final SMS check uses 60 previously unused non-spam UCI messages: one clean and one mechanically corrupted version per reference, with separate categories for real-word typos, ordinary misspellings, multiple typos, and missing spaces. Build 52 fixed 53/99 damaged positions (40: 51/99), including “Get my out of this dump heap” → “Get me out of this dump heap.” All three builds preserved only 45/60 verbatim clean SMS messages. Intentional names and texting shorthand still get rewritten. The SMS references were excluded from the new contextual trainers, but the older, unchanged casual phrase-frequency table used aggregates from the same SMS source; this is a fresh replay, not proof of independence from every legacy component. Combined: 196 inputs from 106 reference messages. These are targeted test samples with clean/noisy pairs, not 196 independent users or messages. [SMS cases](../build51/public.json) · [SMS scores](public-comparison.json) · [Combined scores](final-fresh-combined.json).

**What changed.** Build 52 keeps the shipped 15M Core ML transformer. This round retrained and calibrated the local Rust contextual scorer (224 windows mined from the training split, 42 recurring confusion directions, 67 fitted contrasts), and added a separate compact context-evidence model fitted on 230,048 clean messages. Votes compare the relative frequency of both senses in local contexts. Competing winners abstain. Confidence calibration protects the six original catches; previously unseen automatic directions with repeated collateral errors are withheld. This is a learned policy, not a table of complete test sentences. The installed extension also handles an empty text field whose host returns nil before the first keystroke, so sentence context includes the opening word. We verified this with actual key taps; the previous build only passed this case in replay. The keyboard also rechecks token alignment after joining a word and preserves a validated spelling when a later sentence review abstains about it. Names, shortcuts, literal input fields and keyboard undo continue to use their existing protections.

**How to reproduce.** Run these in the project root. The build-39 and build-40 same-session outputs are preserved in the benchmark archives. Selected build source, models, binaries, and final fixtures have [recorded hashes](candidate-freeze.json). The large comparisons replay real simulator keyboard code on an in-memory text field with synchronous model scheduling; installed-extension XCTest runs tap actual keys. These do not measure physical-device latency, finger placement or energy.

~~~sh
python3 Benchmarks/build22/prepare.py "$PAIRED" /tmp/mb-dataset
SIMULATOR_UDID="$SIM" Benchmarks/build52/replay.sh /tmp/mb-dataset /tmp/mb-replay52
python3 Benchmarks/build52/report.py /tmp/mb-dataset/all.json
~~~

The report command rescores the recorded artifacts; the replay command writes independent outputs to the supplied scratch directory for comparison. Earlier suites (builds 41, 45, 46, 47, 48, 49, 50) informed subsequent development. The final two fixtures were blind to the selected model at build 51. Build 52 only changed handling of an initially empty UIKit text field, and repeated both with byte-identical outputs. [Training details](TRAINING.md) · [Verification](verification.json).
