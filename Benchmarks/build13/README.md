# Build 13 spelling in context

In “There is a leek under the sink”, pressing Space after “sink” now changes “leek” to “leak”. “There is a leek in the soup” keeps the vegetable spelling. Both given examples are development checks, excluded from the fresh headline results.

| Result on 49 held-out messages | Build 12 transformer | Build 13 transformer |
| --- | ---: | ---: |
| Typos corrected | 4/22 | 8/22 |
| Typos left as typed | 18/22 | 14/22 |
| Typos changed to another wrong spelling | 0 | 0 |
| Intended spellings changed | 0/27 | 0/27 |

All four extra fixes were intended “leak” in sentences about a pipe, radiator, drain or tank. Each changed at the third following word. Build 13 preserved all 16 intended instances of “leek”, including a toy leek under a sink and a real leek found near the sink while cleaning out groceries. It still missed 12 of the 16 targeted typos, including the tenant reporting a leak behind the toilet. Results are for marked tokens in these authored messages.

[Held-out inputs](holdout.tsv) · [Build 12 outputs](build12-holdout.tsv) · [Build 13 outputs](build13-holdout.tsv)

**Method.** The initial 65 new sentences and labels were fixed before any model changes. The unmodified build 12 keyboard code ran first. An early candidate failed to improve that set and changed an intentional “leek” after “on”. Those 65 cases became development data. We froze a second 49-message fixture before revising the policy, then scored it once with the final candidate. The second baseline used the restored build 12 Swift review path with the original decoder weights. It reproduced the entire captured build 12 output on the first set byte for byte. Both comparisons used the same English Duo simulator, joined layout, Core ML decoder and word-boundary replay. The benchmark isolates one marked token per message and allows up to three following words. It does not simulate tapping errors, host-side changes or asynchronous cancellation.

On the first set the final candidate fixed 11/30 typos versus 8/30 with build 12, and both preserved 35/35 intended spellings. Those numbers are separate from the held-out result. Replaying the existing 87 build 12 messages changed one decision, the originally reported sink example. The old unwanted correction of the literal code word “teh” persisted.

[Development inputs](fresh.tsv) · [Build 12 outputs](build12.tsv) · [Final build 13 outputs](build13.tsv)

With build 13 installed on the booted Duo simulator, reproduce the candidate column from the repository root with `Benchmarks/build12/run.sh Benchmarks/build13/holdout.tsv`. Compare the resulting `after_context` column with the saved build 12 column of the same name. The normal keyboard extension also has a typing test covering the wait for “sink”, revision, Undo, subsequent typing and the soup sentence.
