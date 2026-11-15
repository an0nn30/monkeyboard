# Build 52: reproducing the fitted assets

The shipped 15M Core ML transformer is unchanged from build 40. The improvements in this series come from retraining the contextual scorer, a new context evidence model, calibration using old errors, and changes to how the keyboard commits and preserves model decisions. The phone is not needed to reproduce the experiments.

Start in a separate checkout with the inputs and Python environment described in [build 39's training notes](../build39/TRAINING.md), including PyTorch, NumPy and SciPy. Set `CONVERSATIONS` to the Taskmaster training utterances and `SMS` to the pinned UCI ZIP (the earlier training notes use `TASKMASTER_TRAIN` and `SMS_ZIP` for the same two paths). The Python trainers overwrite their exported resources. The keyboard loads bundled weights offline.

~~~sh
python3 Benchmarks/build22/prepare.py "$PAIRED" "$PREPARED"
python keyboard-engine/training/contrast42.py "$PAIRED" "$CONVERSATIONS" "$SMS" \
  Benchmarks/build40/training-misses.json "$PREPARED/all.json" Benchmarks/build44/desktop-40.jsonl.gz
python keyboard-engine/training/evidence45.py "$PAIRED" "$CONVERSATIONS" "$SMS"
python keyboard-engine/training/calibrate47.py
python3 keyboard-engine/training/trust50.py
~~~

The contrast trainer mines only the training partition of the desktop reference corpus. It excludes its calibration bucket, deduplicates recurring windows and uses 224 examples representing 42 recurring directions. Its 67 classifiers share a feature dictionary. The evidence model uses 230,048 clean messages, comparing usage of competing words relative to their overall frequencies rather than preferring the more frequent word unconditionally; 48,354 signed context votes are packed into the binary. It observes confusion directions (not full sentences) from the earlier 142-case challenge. The runtime chooses between candidates as more right-hand context arrives; conflicting candidates abstain.

Threshold calibration uses earlier development material and the already-disclosed SMS tests. The six original build-40 positives are regression gates. An additional trust gate prevents newly introduced classifier directions with multiple distinct, demonstrated regressions on intended words from automatically rewriting text. Its decisions are derived from aligned output and independently correct literal positions, not hand-authored substitutions.

The final two fixtures in build51 were frozen before its model replay. Build 52 changes only how the controller records the first character in a host that returns no text context for an empty field. It uses the identical trained model and replays those same fixed fixtures. Earlier rounds, including the 63 archived changes, must not be reported as independent final evidence. SMS and synthetic paired controls have different noise distributions; the scorer intentionally preserves authentic spelling, names, punctuation, and slang verbatim.
