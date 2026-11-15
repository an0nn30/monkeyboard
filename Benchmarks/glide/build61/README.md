# Glide typing: build 60 vs. 61

Build 61 puts **volleyball** first on the recorded swipe where build 60 inserted *comeback*. It also recovers *clontarf*, *embossed*, *americanized*, and *sandbags*. It keeps all twelve new catches from build 60 and all 66 earlier cases, including *following*. These are regression checks: the applicable examples were used in fitting. They are separate from the accuracy estimates below. [Ranked choices for all 83 cases](regression.json)

## Fresh simulator comparison

The frozen build 60 decoder and build 61 decoded the same 8,192 recorded human swipes from 175 sessions, in the same order with no preceding sentence. A first-choice hit means the word that would be inserted was exactly the intended word. “Top three” includes an intended word the user would still have to select. The 96 gestures with no guess from either build count as misses.

| Word length | Swipes | First: 60 | First: 61 | Top three: 60 | Top three: 61 |
|---|---:|---:|---:|---:|---:|
| 2–3 letters | 2,891 | 2,345 | 2,345 | 2,604 | 2,604 |
| 4–6 letters | 2,996 | 2,361 | 2,361 | 2,654 | 2,656 |
| 7+ letters | 2,305 | 1,920 (83.30%) | 1,930 (83.73%) | 2,063 (89.50%) | 2,067 (89.67%) |
| **All words** | **8,192** | **6,626 (80.88%)** | **6,636 (81.01%)** | **7,321 (89.37%)** | **7,327 (89.44%)** |

Fourteen fresh gestures gained a correct first choice, including *headquarters*, *banking*, and *eventually*. Four regressed: *deceived*, *Worcester*, *strangers*, and *Bavaria*. Three of these remained second; *Worcester* dropped out of the first three. The net gain is ten gestures. This is a small improvement on one sample of standard QWERTY traces; it does not estimate thumb accuracy on the Duo's split layout. [Paired results, timings, and changed words](results.json)

Separately, the unfolded Duo simulator passed the keyboard UI test: a T-to-O drag across the central gap inserted *to*, and the split and joined layouts both accepted input after switching. This checks the gesture and layout controls; it is not part of the 8,192-swipe accuracy measurement.

## What the decoder learned

When the two existing decoders disagree about a long word, build 61 compares **both candidate paths against the same recorded swipe**, including where the finger turned and the intended key that the finger missed by the widest margin. It also considers how each candidate ranked under the other decoder. The model has 18 numeric inputs and an intercept. There are no word-specific promotion rules. It changes ranking only on a disagreement between two words of seven or more characters.

Training used 55,101 recordings: build 60's 35,304 plus 19,797 new ones. On 1,234 of those recordings the decoders disagreed about long words and one of the two was correct. Those observations supply the training loss. The 68 applicable cases among the 83 previous regressions have a minimum correct margin in fitting. Fifteen earlier cases need no tie-breaker. Feature selection used previous development/replay data; the new test recordings were reserved before fitting. Sessions, sentences, gesture IDs, and exact paths from earlier data and new training were excluded from the fresh test. Data come from a [pinned revision of the FUTO swipe corpus](https://huggingface.co/datasets/futo-org/swipe.futo.org/tree/d71bf5fd7f45b3e7c2ed2d76a21b0dbd3b4ba566).

## Reproduce

From the repository root, with Xcode, a booted iPhone simulator and the corresponding Rust simulator target:

```sh
Benchmarks/glide/build61/run.sh "$SIMULATOR_UDID" /tmp/monkeyboard-glide61
```

The script verifies the byte-range hashes, builds both simulator executables, checks the older ranks against the saved build 60 results, and writes per-gesture predictions, `regression.json`, and `results.json`. Pass an existing build 60 data directory as its optional third argument to reuse the earlier downloads.

To recompute the shipping weights, run `Benchmarks/glide/build61/refit.sh /tmp/monkeyboard-glide61` using a Python environment with NumPy and SciPy (set `PYTHON` to its interpreter if needed). Pass the same existing build 60 directory as the optional second argument if used above. The script compares the fitted coefficients with the shipping weights and never reads fresh test predictions.
