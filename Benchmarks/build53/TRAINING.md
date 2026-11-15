# How build 53 was trained and compared

The Core ML transformer is the same as build 52. This round changed smaller local models and the keyboard's word-boundary decisions. None of the trainers read the build 53 holdout. The phone was not required.

1. Generate [the 69 old erroneous positions and 15 clean regressions](old-failures.json) by running `python3 Benchmarks/build53/development.py`. Labels come from the two build 51 fixtures; the typed output is the saved build 52 simulator replay. A missing space can damage two reference positions but represents a single edit operation. The entire 196-input old suite is now development data.
2. The spelling and missing-space ranker uses that operation mix to corrupt other clean messages, then fits 33 shared features to competing candidates. Its training, calibration, and synthetic test partition by message. See the [residual trainer](../../keyboard-engine/model/residual53/README.md).
3. The intentional-spelling classifier fits on earlier keyboard decisions, clean informal text and desktop repairs. It uses word shape, case, the surrounding sentence, name-like positions and characteristics of conversational writing. The 15 clean messages help select the automatic-edit thresholds. The model can veto the initial change or a later revision of the same word. The companion [fit statistics](../../keyboard-engine/model/literal53/fit.json) are candidate-level statistics, not keyboard accuracy.
4. The accidental-space model learns which inside-word cuts are plausible from distinct source sentences and observed developmental errors. It counts actual adjacent words as counterevidence, excludes implausible capitalization and never joins across a host-owned boundary. The frame model learns which surrounding words and grammatical categories distinguish the alternatives observed in the old real-word misses. It tests each direction against clean uses in a separate calibration fold. These models export aggregate statistics; there is no table of benchmark sentences.

To refit in a separate checkout with the same sources/environment as [build 39](../build39/TRAINING.md):

~~~sh
python3 Benchmarks/build53/development.py
python3 Benchmarks/build22/prepare.py "$PAIRED" "$PREPARED"
python3 keyboard-engine/training/rejoin53.py "$PREPARED/all.json" "$CONVERSATIONS"
python keyboard-engine/training/frames53.py "$PAIRED" "$CONVERSATIONS" "$SMS"
python keyboard-engine/training/residual53.py "$CONVERSATIONS" "$PAIRED" "$SMS"
python keyboard-engine/training/literal53.py "$PAIRED" "$SMS"
~~~

For end-to-end comparison set `SIMULATOR_UDID` to the booted simulator, then use `Benchmarks/build53/replay.sh build "$WORK"`. The replay binary is `$WORK/replay`; the extension is inside the resulting app in `$WORK/dd/Build/Products/Debug-iphonesimulator`. The `run` subcommand accepts that binary, extension directory, fixture JSON and destination JSONL.gz. Use the archived 52 binary and matching extension for the baseline; their hashes are in the candidate freeze. To rescore the bundled holdout outputs, run:

~~~sh
python3 Benchmarks/build53/score.py Benchmarks/build53/holdout/cases.json \
  Benchmarks/build53/holdout-52.jsonl.gz Benchmarks/build53/holdout-53.jsonl.gz /tmp/holdout-comparison.json
python3 Benchmarks/build53/verify.py
~~~

The large replay types through the production correction controller with a simulated text document and synchronous decoder completion; the separate XCTest suite taps keys in the installed extension. Replay does not measure touch accuracy, power or latency on a physical phone. Historical aggregate SMS features may overlap the public source. The original authored test sentences are independent of both model outputs and of previously checked full training references.
