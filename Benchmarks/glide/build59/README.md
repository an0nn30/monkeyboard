# Build 59 glide comparison

Build 59 recognized **665 of 821 longer words** on the first try, up from **615** in build 58. Both builds decoded the same 3,072 recorded swipes on the iPhone Duo simulator. The test contains 133 sessions, with no shared gesture IDs, touch paths, sessions, or source sentences with the original benchmark or the development data.

| Word length | Swipes | First choice, 58 → 59 | In first three, 58 → 59 | New first-choice catches | Lost first-choice catches |
|---|---:|---:|---:|---:|---:|
| 2–3 characters | 1,131 | 77.4% → 77.5% | 86.5% → 86.6% | 4 | 3 |
| 4–6 characters | 1,120 | 72.4% → 74.4% | 84.6% → 86.0% | 37 | 15 |
| 7+ characters | 821 | 74.9% → 81.0% | 80.5% → 86.7% | 58 | 8 |
| **All** | **3,072** | **74.9% → 77.3%** | **84.2% → 86.4%** | **99** | **26** |

New catches included *concerned*, *spokespeople*, and *crossroads*. One swipe for *following* now produced *flowing*. Another for *independence* produced *independance*. The paired report includes every gain and loss for longer words. A swipe with no candidate counts as a miss, including a stroke too short to distinguish from a tap correction. Abstentions fell from 72 to 68. [Full results](results.json)

## What changed

Of the 35 original misses on words of seven or more characters, 22 were absent from the build 58 vocabulary. Build 59 adds the next 120,000 eligible longer English entries from wordfreq to the existing vocabulary. For paths that travel at least eight key pitches, it considers changes of direction and compares against rounded corners. It also allows more variation at the first and last key. The keyboard supplies the actual key positions. Grouping words by their first and last key and keeping a bounded list of candidates limits temporary storage. The vocabulary and decoder run locally. [Vocabulary generator](../../../keyboard-engine/training/glide_lexicon.py) · [Data attribution](../../build55/model/NOTICE.txt)

Decoder selection used the original 512 swipes and 2,048 separate development swipes. On the 581 longer development words, the first-choice count was 428 for build 58, 451 with the expanded vocabulary alone, and 467 for the selected decoder. The final test was scored after choosing the decoder.

## How the comparison works

The recordings use the public English QWERTY layout. The test preserves the original word mix, including names and uncommon words. It measures isolated gestures with no preceding sentence. It does not measure the accuracy of a human swiping across the Duo hinge. The offline geometry tests exercise both contiguous keys and a split with a gap. [Dataset](https://huggingface.co/datasets/futo-org/swipe.futo.org)

The replay executable links the Rust library for each build. It receives the same touch samples, timestamps, and key centers, and never passes the intended word to the decoder. The 95th-percentile time from preparing the samples to returning candidates was 0.55 ms for build 58 and 3.16 ms for build 59 on this simulator. Physical touch-to-display latency remains unmeasured.

To reproduce on an Apple Silicon Mac, run the following from the repository root. Supply the UDID of a booted iPhone simulator. The script verifies the downloaded byte ranges, rebuilds both libraries, replays the same ordered gesture IDs, and writes a paired report.

```sh
Benchmarks/glide/build59/run.sh "$SIMULATOR_UDID" /tmp/monkeyboard-glide-comparison
```

The fresh cohort takes the 3,072 lowest SHA-256 hashes of eligible gesture IDs from bytes 33,554,432–67,108,863 of the pinned FUTO test file after the exclusions above. The original development material comes from the first 8 MiB of the test split and first 16 MiB of the development split. The published cohort digest allows later runs to verify identical input. [Cohort selection](cohort.py) · [Download checksums](inputs.sha256)
