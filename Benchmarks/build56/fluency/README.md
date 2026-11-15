# Historical causal fluency experiment

The offline experiment compares a masked-language-model shortlist with scores from pretrained autoregressive English-capable language models. The first stage reads the displayed text and the Swift lexical probe. It scores up to six spelling alternatives at each suspicious site. The second stage scores the spelling and its first six right-hand tokens. The comparison includes every subword of the spelling and subtracts a context-free word-frequency prior. The reference spellings and annotated error positions enter only the final evaluation.

The checkpoints are [SmolLM2-360M at f8027fd](https://huggingface.co/HuggingFaceTB/SmolLM2-360M/tree/f8027fd0eaeea54caa13c31d31b9fdc459c38b49), [Qwen2.5-0.5B at 060db64](https://huggingface.co/Qwen/Qwen2.5-0.5B/tree/060db6499f32faf8b98477b0a26969ef7d8b9987) and [SmolLM2-135M](https://huggingface.co/HuggingFaceTB/SmolLM2-135M). The causal weights stay outside the keyboard bundle. Each full checkpoint is Apache-2.0.

## Development results

A conservative operating point uses equal weight for the cloze and causal log gains, total gain of at least 12, a margin of 3 over the next spelling, and a source length of at least 3. The two released development suites each have 67 real-word errors, 138 noisy messages and 138 clean messages. Collateral counts originally correct words changed. All entries in this table are Python overlays on pre-recorded outputs.

| Fixture and input | Scorer | Real-word fixes | Exact noisy | Exact clean | Collateral |
| --- | --- | ---: | ---: | ---: | ---: |
| 55, build 54 rendered | Baseline | 4 | 40 | 125 | 28 |
| 55, build 54 rendered | SmolLM2-360M | 51 | 92 | 127 | 25 |
| 55, build 55 rendered | Baseline | 48 | 105 | 130 | 19 |
| 55, build 55 rendered | SmolLM2-360M | 55 | 114 | 131 | 17 |
| 55, build 55 rendered | SmolLM2-135M | 55 | 115 | 131 | 17 |
| 55, build 55 rendered | Qwen2.5-0.5B | 52 | 111 | 130 | 21 |
| 54, build 55 rendered | Baseline | 62 | 124 | 135 | 10 |
| 54, build 55 rendered | SmolLM2-360M | 61 | 127 | 135 | 8 |
| 54, build 55 rendered | SmolLM2-135M | 62 | 126 | 135 | 9 |
| 54, build 55 rendered | Qwen2.5-0.5B | 61 | 127 | 135 | 8 |

The development shortlist includes the names-aware build 56 lexical component. Swapping lexical snapshots can change which spelling alternatives reach the causal scorer. Overlay inference runs on Apple Silicon PyTorch, with the same candidate source and scoring policy for both suites. Parameter size and the number of candidate evaluations per message matter for a keyboard extension. SmolLM2-360M alone is 724 MB at source precision, excluding runtime allocations.

## Reproduction

Use the torch and transformers environment described in the build 55 model exporter. Set the checkpoint paths to locally downloaded snapshots. The work directory holds intermediate rows and scores.

```sh
mkdir -p "$WORK"
swiftc -O Keyboard/Lexical55.swift Benchmarks/build56/lexical/main.swift -o "$WORK/lexical"
python Benchmarks/build56/fluency/proposals.py "$ROBERTA" "$WORK/lexical" Keyboard/Resources "$WORK/sites.json" \
  Benchmarks/build55/primary/baseline.jsonl.gz Benchmarks/build55/primary/candidate.jsonl.gz \
  Benchmarks/build54/holdout-54.jsonl.gz Benchmarks/build55/validation/historical54.jsonl.gz
python Benchmarks/build56/fluency/causal.py "$CAUSAL" "$WORK/sites.json" "$WORK/scores.json"
python Benchmarks/build56/fluency/evaluate.py "$WORK/scores.json" \
  --weight 1 --threshold 12 --min-margin 3 --min-length 3
```

For a candidate pipeline's own rendered messages, include its recorded output in the proposal command and pass it to the evaluator using `--overlay-55` or `--overlay-54`. The inference scripts take no fixture or expected-text argument.

The small regression-head experiment reuses the existing frozen RoBERTa hidden states at layers 4, 8 and 12. A 96-unit hidden layer predicts the causal teacher’s target and right-context likelihood differences. It learns from synthetic substitutions in public Tatoeba and Taskmaster text, using the corpus sampler and resource provenance in the [detector documentation](../model/README.md).

The included research checkpoint weighs 906,865 bytes. The student trained on 12,000 pairs with 10% held aside to select an epoch. On the historical proposal pool, its predicted gain agreed with the causal teacher's sign on 88.5% of 6,338 comparisons and had Pearson correlation 0.772. The full scorer verifies finite probabilities at every site. The teacher used bfloat16 for its longer public training examples.

An exploratory gain threshold of 16 retained the calibrated pipeline's 137 clean exact messages and two collateral words on each fixture. It moved build 55 from 55 to 56 real-word repairs and 123 to 125 exact noisy messages. It moved build 54 from 57 to 58 real-word repairs and 125 to 127 exact noisy messages. The trained head and scripts are research assets. These measurements cover the released historical fixtures and use no simulator or production runtime for the overlay.

```sh
python Benchmarks/build56/fluency/distill.py train "$ROBERTA" "$WORK/student" \
  --teacher "$CAUSAL" --corpus keyboard-engine/training/eng_sentences_CC0.tsv.bz2 \
  --dialogue "$TASKMASTER" --count 12000
python Benchmarks/build56/fluency/distill.py predict "$ROBERTA" "$WORK/student" \
  --proposals "$WORK/sites.json" --output "$WORK/student.json"
```
