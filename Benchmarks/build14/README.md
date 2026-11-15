# Build 14 contextual spelling benchmark

## Fresh sentences

| Outcome on 64 messages | Build 13 | Build 14 |
| --- | ---: | ---: |
| Typos corrected | 6/31 | 12/31 |
| Of those, intended “leak” corrected from “leek” | 2/24 | 8/24 |
| Typos left as typed | 24/31 | 18/31 |
| Typos changed to another wrong spelling | 1/31 | 1/31 |
| Intended spellings changed | 0/33 | 0/33 |

Build 14 gained seven corrections and lost one. It fixed “A guest texted about a leek behind our toilet” at “toilet” and “Please tell maintenance about the leek behind the bathroom sink” at “sink”. It preserved all 22 intentional lowercase instances of “leek”, including “The tenant reported a leek in the soup” and “The landlord complained about a leek stuck in the toilet”. It also preserved the name “Leek” and the uppercase spelling “LEEK”.

Build 13 caught “The folks downstairs reported a leek from their ceiling”. Build 14 left it as typed. Both builds also left “We smelled a gas leek outside the building” untouched. On the seven unrelated typos both fixed four, missed two and changed “timr” to “time” where the writer meant “timer”.

[Fresh inputs](fresh.tsv) · [Build 13 outputs](build13.tsv) · [Build 14 outputs](build14.tsv)

## The 12 earlier misses

The earlier 49-message set was used for development. Build 14 recovered 11 of the 12 previously missed “leak” typos and retained all four previous fixes. It kept all 27 intended spellings. The remaining miss was “We finally found the leek near the boiler”. The proximity alone can describe a vegetable, so the keyboard waits for stronger evidence there. On the earlier 65-message set, correct fixes rose from 11 to 12 with all 35 intended spellings preserved. All 87 marked-word outcomes on the older everyday set matched build 13, including its three existing wrong replacements.

[Build 13 on the earlier 49](../build13/build13-holdout.tsv) · [Build 14 on the same 49](prior-misses.tsv)

## Method

The 64 authored messages, their intended spellings and the build 13 predictions were saved before changing the classifier. The fixture has one marked word per message and emphasizes the “leek” and “leak” distinction. The requested tenant/toilet example belongs to the earlier set. No complete fresh message duplicates those earlier sets or a spelling-classifier training example. Common phrases occur in both training and evaluation.

Both builds replayed the same English messages at successive word boundaries using the keyboard's Swift correction path, Rust ranker and installed Core ML model on the same iPhone Duo simulator. The replay records the first accepted revision. Build 13 can see three following words. Build 14 can see five for this spelling pair. The separate UI tests exercise the keyboard extension through actual key taps. These counts measure marked-word decisions on authored messages. They do not estimate typing accuracy across everyday use.

With build 14 installed on the booted simulator, run `Benchmarks/build12/run.sh Benchmarks/build14/fresh.tsv` from the project root. The `after_context` column is the final automatic spelling. The original baseline output is archived above.
