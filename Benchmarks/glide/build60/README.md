# Long glide words in build 60

Build 60 recovered all eight longer swipes that build 59 had lost and retained all 58 longer swipes it had newly recognized. The original *following* swipe now inserts *following* and offers *flowing* as an alternative. These 66 recordings were used to fit the decision rule. [Per-swipe regression results](regression.json)

On 4,096 fresh recorded swipes from 91 sessions, both builds ran through the same decoder interface on the iPhone Duo simulator. Build 60 picked 12 more intended words first and lost five, for seven additional correct first choices. The gain was confined to words of seven or more characters.

| Fresh swipes | Count | Build 59 first | Build 60 first | Build 59 top three | Build 60 top three |
|---|---:|---:|---:|---:|---:|
| 2–3 characters | 1,496 | 1,200 (80.21%) | 1,200 (80.21%) | 1,333 (89.10%) | 1,333 (89.10%) |
| 4–6 characters | 1,459 | 1,136 (77.86%) | 1,136 (77.86%) | 1,279 (87.66%) | 1,279 (87.66%) |
| 7+ characters | 1,141 | 941 (82.47%) | 948 (83.09%) | 1,018 (89.22%) | 1,028 (90.10%) |
| **All words** | **4,096** | **3,277 (80.00%)** | **3,284 (80.18%)** | **3,630 (88.62%)** | **3,640 (88.87%)** |

New first-choice catches included *football*, *jackets*, and *difference*. The five new losses were *volleyball*, *clontarf*, *embossed*, *americanized*, and *sandbags*. Each build returned no guess on 73 swipes, all counted as misses. The 95th-percentile time from path preparation to a result was 3.09 ms for 59 and 3.25 ms for 60. These are simulator measurements from web-recorded QWERTY gestures. Accuracy and latency for a thumb crossing the physical Duo's split layout remain unmeasured. [Paired results and individual changes](results.json)

## How the choice is learned

The decoder starts with build 59's vocabulary and rounded swipe paths. If its first choice is a long word, it also checks the earlier, smaller dictionary and straighter path templates. When the two first choices are different long words, a small logistic model decides whether to promote the alternative. It compares the lead each candidate had over the runner-up, relative word frequency, how closely the finger visited each letter in order, length and endpoint errors, and the number of distinct consecutive key visits. Both candidates are evaluated with the actual layout. The model contains an intercept and nine coefficients. It has no access to example IDs or word strings as input features.

Training processed 35,304 gestures in two FUTO training ranges. There were 770 disagreements where one of the two long-word candidates was the labeled word. These examples supplied the training loss. The 51 applicable disagreements among the 66 earlier regressions supplied constraints that protected both old and new catches. The other 15 already kept the build 59 result without invoking the choice model. Regularization and feature selection used development gestures. The final test contains no matching session, gesture ID, touch sequence, or source sentence in the training or previously examined benchmark data. The replay supplies empty sentence context to both builds. [Cohort selection](cohorts.py) · [Training code](train.py) · [Pinned data source](https://huggingface.co/datasets/futo-org/swipe.futo.org/tree/d71bf5fd7f45b3e7c2ed2d76a21b0dbd3b4ba566)

## Reproduction

With a booted simulator and Rust's iOS Simulator target installed, run the following from the repository root. The script checks the data hashes, builds the saved 59 decoder and the frozen 60 decoder, and writes both reports and per-gesture predictions to the specified directory.

```sh
Benchmarks/glide/build60/run.sh "$SIMULATOR_UDID" /tmp/monkeyboard-build60
```

To refit the shipped coefficients, use a Python environment with NumPy and SciPy, and the files produced by the replay script. The optional Rust feature exports training evidence for the host tool.

```sh
work=/tmp/monkeyboard-build60
cargo rustc --offline --locked --manifest-path "$work/engine60/Cargo.toml" --lib --release --features glide-training --crate-type cdylib
for split in training extra regression; do
    python3 Benchmarks/glide/build60/features.py "$work/engine60/target/release/libmonkeyboard_engine.dylib" \
        "$work/qwerty.json" "$work/cohorts/$split.jsonl" "$work/features-$split.jsonl"
done
python3 Benchmarks/glide/build60/train.py "$work/features-regression.jsonl" "$work/glide-choice.weights" \
    "$work/features-training.jsonl" "$work/features-extra.jsonl"
```
