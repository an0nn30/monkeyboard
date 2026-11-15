# MonkeyBoard build 20 · short words and missing spaces

Build 19 was installed and verified on the physical iPhone Duo. Build 20 was installed on the iPhone Duo **simulator only**. It adds a straight double quote to the 123 and #+= pages, and keeps a single deliberately lowercase word lowercase when its selection is deleted in a sentence-capitalized field. Caps Lock and the host’s all-capitals mode retain precedence.

## Final comparison against build 19

After the policy was frozen, we ran both keyboards on **1,680 previously unused full sentences**: 1,020 with a single introduced error and 660 unmodified. Source: unseen user utterances in Taskmaster-2 restaurant search, food ordering, and movie dialogues. One space was removed or one word was substituted, preserving the rest of the source. Each build received the same characters, casing, punctuation, and final commit. Build 19 was the archived, pre-change executable. These are targeted error families, not their prevalence in everyday typing.

| Intended edit / control | Build 19 | Build 20 |
|---|---:|---:|
| Missing space recovered | 200/400 | 222/400 |
| if → of | 0/160 | 113/160 |
| id → is | 0/160 | 121/160 |
| od → of | 0/160 | 147/160 |
| ti → to | 0/120 | 113/120 |
| be → by | 0/20 | 2/20 |
| All labeled repairs | 200/1,020 | 718/1,020 |
| Entire noisy sentence exactly correct | 200/1,020 | 716/1,020 |
| Unmodified sentences left exactly as supplied | 658/660 | 656/660 |
| Unwanted splits across all sentences | 1 | 1 |
| Previously correct word slots changed across all sentences | 5 | 8 |

The shared split was “atleast” → “at least”. Both builds are penalized because the reference was the original, untouched transcript. The two additional changes on untouched sentences were “an I think” → “and I think” and “It it can be” → “If it can be.” They count as unwanted, even when the source looks disfluent. There were no new false splits in this final set. The valid-word cost is real and **be/by remains weak**. On noisy space cases, recovery requires both intact words and exactly the right boundary; approximate matches do not count. A word-level edit alignment separately scores collateral changes. Case/punctuation differences affect exact matching.

[Final sentences](final.tsv) · [Build 19 outputs](final19.jsonl) · [Build 20 outputs](final20.jsonl) · [Scorer](score.py)

## Beyond the named examples

We replayed **1,280 actual short-word errors covering 627 distinct typed/intended pairs** from the supplied S:/C: data, plus 240 controls. Each input isolates one observed error in its otherwise corrected sentence. Build 19 recovered **618/1,280 (48.3%)**, versus **1,037/1,280 (81.0%)** in build 20. Both preserved 240/240 clean messages. False splits elsewhere in this test went from two to three. Some cases have two edits or a target outside the one-edit search and are intentionally still scored. These references were excluded from training but previously used in older benchmarks, so this is a **regression test**, not a second independent estimate.

The supplied 100,000 example pairs contain 7 isolated if/of replacements, 32 id/is, 4 od/of, 86 ti/to and 94 tl/to under single-token sequence alignment, and no be/by examples. These are counts in the supplied file, not a log of the owner’s typing. Cases marked [examples](examples.txt) are development reproductions and deliberate-word controls, not part of the headline counts. They include “We metin Phoenix years ago”, the name Metin, literal spellings, an ID badge, and “if work will end early”.

[Paired cases](short.tsv) · [Build 19](short19.jsonl) · [Build 20](short20.jsonl) · [Case generator](short_cases.py)

## What actually runs in the extension

The Rust [short-word model](../../keyboard-engine/src/short_words.rs) generates insertions, deletions, substitutions and adjacent transpositions for two- and three-letter inputs, against common one- to four-letter vocabulary entries. Its [trainer](../../keyboard-engine/training/short_channel.py) learned from 84,781 training pairs, including 78,510 single-character edit observations across 274 edit classes. Observed word-confusion counts are *soft evidence*, not an instruction to replace a word. The character model can propose pairs not observed in training. A backoff language model compares the literal and nearby candidates using the preceding and following words. The existing on-device 15M transformer checks real-word revisions against the sentence. Its weights did not change. Unknown-word fallback can compare missing-letter alternatives in the transformer, without using its unknown token as a replacement score. The model files contain aggregate counts; no typing logs, network access, or personalization were added.

Changes are applied only when the policy has enough evidence, with stricter requirements for already-valid spellings. Explicit personal words, literal prompts and case are protected. Some prior canonical casing/apostrophe and longer-word policies remain. No source-specific if/of, od/of, id/is, be/by, us/is or gos/goes correction table or hand-authored phrase triggers are used for these decisions. Space repair separately checks exact segmentation and context; a dictionary-listed lowercase word such as “metin” can be reconsidered in a verb frame once the following word supports it.

## Data, validation and reproduction

The original [934 written](fresh.tsv) and [961 spoken](spoken.tsv) cases, the [1,930 additional-domain cases](audit.tsv), and two 1,770-sentence rounds ([initial](general.tsv), [confirmation](confirmation.tsv)) informed the development policy. Only final.tsv was unexamined until the final model and thresholds were frozen. Earlier tuning outputs are not independent tests. The final dataset excludes normalized earlier gold and noisy cases and normalized source training sentences; ordinary phrases and dialogue domains recur. The four-domain set uses hotels, flights, music and sports. Results need not transfer to personal notes or literal identifiers. No latency or device memory benchmark is claimed.

Public text: [Taskmaster-1](https://github.com/google-research-datasets/Taskmaster/tree/d92cb6af3005f1dc09c39e75e7daf4a04905e00b/TM-1-2019) and [Taskmaster-2](https://github.com/google-research-datasets/Taskmaster/tree/d92cb6af3005f1dc09c39e75e7daf4a04905e00b/TM-2-2020), Google LLC and contributors, [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The benchmark segments, filters and introduces artificial errors in public utterances. See [model credits](../../keyboard-engine/MODEL.md) for the other pinned training sources.

The simulator harness calls the production key handler and document-editing path for each character. It uses a memory-backed document with synchronous review scheduling so both builds finish pending corrections before scoring. Separate XCUITests physically tap the installed extension, including selecting and deleting text, typing a straight quote, undoing corrections, and keeping or replacing short words. Simulator measurements do not measure Duo touch accuracy.

From the project root, to regenerate the model and score the saved simulator outputs:

```sh
python3 keyboard-engine/training/short_channel.py /path/to/typo_sentences.md /path/to/self-dialogs.json
python3 Benchmarks/build20/score.py Benchmarks/build20/final.tsv Benchmarks/build20/final19.jsonl Benchmarks/build20/final20.jsonl
python3 Benchmarks/build20/score.py Benchmarks/build20/short.tsv Benchmarks/build20/short19.jsonl Benchmarks/build20/short20.jsonl
```

To run a new simulator comparison, compile each version in its matching checkout. Use the extension resources installed for that version:

```sh
SIMULATOR_UDID=your-booted-simulator-uuid BENCHMARK_CASES="$PWD/Benchmarks/build20/final.tsv" Benchmarks/build17/run.sh > /tmp/result.jsonl
```

[make_cases.py](make_cases.py) verifies the pinned public files. Generate in order: pass the self-dialogue JSON and paired file for the written set; add the WOZ JSON for the spoken set; add the directory with the four Taskmaster-2 JSON files for the initial audit. With the other three Taskmaster-2 domain files in that directory, append `general`, `confirmation`, and `final` in successive calls to generate the three disjoint sets.
