# English glide typing · build 58

The keyboard captures the path from first contact to lift and supplies the centers of the 26 visible letter keys. The Rust decoder compares that path with dictionary words, using dynamic time warping, word frequency and the preceding word. It returns up to three candidates. The preceding word and finger path stay on the device.

## Recorded gestures

On 512 English gestures from 15 sessions, the decoder ranked the intended word first **406 times (79.3%)** and in the first three **440 times (85.9%)**. It returned no candidates 12 times. Those gestures count as misses in both metrics. These recordings come from the public test split collected on a web keyboard. Accuracy on the Duo and its split layout still needs a separate finger-typing trial. [FUTO dataset](https://huggingface.co/datasets/futo-org/swipe.futo.org)

| Word length | Gestures | First choice correct | In first three |
|---|---:|---:|---:|
| 2–3 characters | 189 | 150 | 163 |
| 4–6 characters | 175 | 143 | 159 |
| 7+ characters | 148 | 113 | 118 |

The sample consists of the 512 lowest SHA-256 hashes of gesture IDs among eligible, complete records in the first 8 MiB of the pinned test file. Eligibility covers words of 2–24 English letters and internal apostrophes. Labels are lowercased and surrounding punctuation is stripped. Unknown words stay in the denominator. The decoder receives an empty sentence context and sees only the layout and path. The scorer uses the public QWERTY centers, converts normalized coordinates to key pitches, and applies the keyboard’s minimum reach for recognizing a glide. Timings in [results.json](results.json) measure a host-side call including Python path preparation. They do not measure iOS touch-to-display latency.

## Reproduce on macOS

Run from the repository root with the build 58 decoder. Later builds can use the [frozen build 58 source and paired replay](build59/README.md). The download uses the same revision and byte range on each run.

```sh
data_dir=$(mktemp -d)
source_url=https://huggingface.co/datasets/futo-org/swipe.futo.org/resolve/d71bf5fd7f45b3e7c2ed2d76a21b0dbd3b4ba566
curl -fsSL "$source_url/swipe-5/layouts/qwerty.json" -o "$data_dir/qwerty.json"
curl -fsSL --range 0-8388607 "$source_url/test.jsonl" -o "$data_dir/test-prefix.jsonl"
shasum -a 256 "$data_dir/test-prefix.jsonl"
cargo rustc --offline --locked --manifest-path keyboard-engine/Cargo.toml --lib --release --crate-type cdylib
python3 Benchmarks/glide/score.py keyboard-engine/target/release/libmonkeyboard_engine.dylib "$data_dir/qwerty.json" "$data_dir/test-prefix.jsonl"
```

The expected prefix digest is `6057480f6127fed3083b8e848fd4f16273c5b912057e531629dee867e17f3e01`. The evaluation data is separate from the shipping vocabulary. The added 40,000-word frequency table is adapted from wordfreq 3.1.1 and distributed under CC BY-SA 4.0. The generator records the filtering and rounding steps. [Generator](../../keyboard-engine/training/glide_lexicon.py) · [Source credits and license](../build55/model/NOTICE.txt)
