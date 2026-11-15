# Reproduce the candidate models

Run the following from the repository root in a Python environment with PyTorch, NumPy and SciPy and an installed Rust toolchain. Use a separate working checkout for refits: the trainers replace exported weights. The shipped models and simulator replay do not require Python, network access, or a copy of any training message.

- PAIRED: the original desktop S:/C: file. The reserved group is determined by the SHA-256 of the normalized clean sentence, as in build 16. The scorer counts all 100,000 rows; it does not drop repetitions or punctuation.
- CONVERSATIONS: build 21’s frozen Taskmaster training file (see [build 21](../build21/README.md)). WINDOW: a scratch working directory. SMS: the checksummed UCI SMS zip used by [the benchmark](../build22/blind/README.md). WORDNET: the checksummed original WordNet 3.0 archive used by the existing project.
- The compact cloze and conversational ranker families select calibration examples separately from development examples. The casual-spelling counts explicitly exclude both sides of every review/final message; other SMS trainers exclude challenge-eligible messages and normalized duplicates. The source audit and fresh fixtures are in [the benchmark directory](../build22/blind/README.md).

~~~sh
mkdir -p "$WINDOW"
python3 keyboard-engine/training/train_wordnet22.py "$PAIRED" "$WINDOW" "$CONVERSATIONS"
python3 keyboard-engine/training/wordnet22_surface.py "$PAIRED"
python3 keyboard-engine/training/casual22.py "$SMS" "$PAIRED" Benchmarks/build22/blind
python3 keyboard-engine/training/spelling22.py "$PAIRED"
python3 keyboard-engine/training/denoise22.py "$PAIRED"
python3 keyboard-engine/training/real25.py "$CONVERSATIONS" "$PAIRED" "$SMS"
python3 keyboard-engine/training/cloze27.py "$CONVERSATIONS" "$PAIRED" "$SMS"
python3 keyboard-engine/training/refine26.py "$PAIRED"
python3 keyboard-engine/training/surface31.py "$PAIRED" --wordnet "$WORDNET"
python3 keyboard-engine/training/window34.py "$PAIRED"
python3 keyboard-engine/training/textspell30.py "$CONVERSATIONS" "$PAIRED" "$SMS"
~~~

The UCI SMS Spam Collection (Tiago Almeida and José María Gómez Hidalgo, CC BY 4.0) supplies historical English texting; see [dataset and terms](https://archive.ics.uci.edu/dataset/228/sms+spam+collection). The keyboard’s prediction credits and earlier [model documentation](../../keyboard-engine/MODEL.md) give the additional English dialogue, vocabulary and WordNet sources.

A score from an individual model is not a keyboard result. The simulator replays every character and delimiter; the end-to-end report also includes the decisions made by the host spell checker, pre-existing transformer review, undo safeguards and the literal-preservation policy.
