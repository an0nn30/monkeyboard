# Build 53 residual spelling and missing spaces

From the repository root, run the following in the same Python environment as the build 52 trainers. The command uses NumPy, SciPy, PyTorch, and rustc. It overwrites the two fitted files in this directory.

```sh
python keyboard-engine/training/residual53.py "$CONVERSATIONS" "$PAIRED" "$SMS"
```

The trainer aligns build 52 output to the build 51 hand-written and SMS references, then aggregates the residual error types. A joined token can span two reference slots and contributes one missing-space observation. Character substitutions, omissions, repetitions and transpositions set the mixture of synthetic errors sampled from other sentences. These development fixtures contribute no words, phrases, or replacement labels to the fitted feature matrix.

The independent normalized text comes from the existing Taskmaster, CC0, paired-training and SMS source loader. It excludes the reserved desktop partition and all challenge-eligible SMS. The trainer uses messages outside the count-building partition of the existing conversational n-gram model. It assigns complete references to separate fit, calibration and synthetic test partitions before generating errors. Unknown clean tokens and generated errors outside the vocabulary compete as abstentions.

The Rust extractor used during fitting is also the production candidate extractor. It considers every supported single-character edit, adjacent transposition and exact two-word division, scoring them jointly against the untouched input. The 33 features measure word frequency, conversational frequency, character edit evidence, casing, relative word lengths, and word sequences across both sides of the edit. The exported linear weights optimize grouped cross entropy. Calibration separately estimates commit thresholds for spelling, segmentation, sole possible divisions and transpositions. The two narrower estimates apply when their conditions hold.

The synthetic test counts in `fit.json` describe this ranker in isolation. The 21,768 generated test cases include 13,008 positions with competing candidates. The production controller also considers the displayed text, native spellchecker, personal dictionary, literal protection, document ownership and alignment.
