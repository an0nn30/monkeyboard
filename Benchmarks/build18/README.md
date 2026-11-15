# Build 18 · “my landlord us” and “the kidsin”

Build 18 corrects “my landlord us a barista” and “pick up the kidsin the morning”. On a booted iPhone Duo simulator, real key taps confirmed that both corrections wait for a continuation, Delete restores the original with intervening text intact, “my landlord sent us a map” remains unchanged, and an explicitly identified code keeps its spelling. The earlier “amanor” correction and undo also passed.

## Fresh everyday sentences

The same 3,600 messages were replayed through both builds. The 2,400 noisy messages contained errors from the supplied sentence pairs, often more than one. The 1,200 clean controls were distinct other messages. All normalized targets were in the original reserved training bucket; previously evaluated texts and the two user reports were excluded. The selection was frozen before build 18 was implemented; the policy was not tuned on these results. This tests the distribution in the provided corpus, which repeats sentence patterns.

| Outcome | Build 17 | Build 18 |
|---|---:|---:|
| Exact full text, 2,400 noisy messages | 995 (41.5%) | 1,022 (42.6%) |
| Originally wrong or missing reference words fixed, out of 4,956 | 2,786 | 2,862 |
| Wrong replacements among originally wrong positions | 148 | 146 |
| Already-correct words changed inside noisy messages, out of 10,923 | 0 | 0 |
| Clean messages preserved exactly | 1,200/1,200 | 1,200/1,200 |
| Remaining word edit distance on the noisy messages | 2,242 | 2,166 |

Twenty-seven new exact recoveries, zero previously exact sentences lost. Examples include “Let's sendthe invatations this evening.” → “Let's send the invitations this evening.” and “The slides are duetomorrow.” → “The slides are due tomorrow.” Exact matching includes capitalization, spacing and punctuation. The word counts use the [same alignment and scoring](../build17/score.py) as build 17; one missing space can produce two wrong reference positions.

[Full sentences and labels](sentences.tsv) · [Build 17 final text by ID](build17.jsonl) · [Build 18 final text by ID](build18.jsonl)

## How broadly do the two fixes work?

| Separate test | Build 17 exact | Build 18 exact |
|---|---:|---:|
| Both reported inputs | 0/2 | 2/2 |
| Authored variations on the errors | 2/17 | 17/17 |
| Authored intentional spellings and uses of “us” | 21/21 | 21/21 |
| Reserved sentences with a synthetic “is” → “us” typo before an article | 0/56 | 23/56 |
| Public English sentences with a randomly removed word boundary | 67/120 | 66/120 |
| Unchanged public English sentences | 120/120 | 120/120 |

The [examples](examples.tsv) exercise targeted behaviors; the [separate challenge](challenge.tsv) tests generalization and was not used to tune the model. The 56 copula examples come from unused reserved targets in the supplied corpus. The 240 public examples use the decoder's reserved bucket of the project's pinned CC0 English source, after excluding previously scored cases and all user-pair messages. Real-word corrections remain conservative: 33/56 were left untouched. There was no measurable gain on arbitrary missing spaces in the public set. The single divergent join was “letme”: one build output “let me” and the other “lethe”. A separate repeated-input check produced **both** outcomes in each build, so we cannot attribute that single-case difference to the new policy.

[Challenge baseline outputs](challenge17.jsonl) · [Challenge candidate outputs](challenge18.jsonl)

## Implementation and reproduction

The 15M Core ML weights are unchanged. For “us”, the keyboard admits a review only in a narrow subject position. After an article and one more word it compares the transformer's probability of “is” plus that article against “us” plus the same article. The threshold is a log-odds margin of 3.5. Verbs such as “sent” and “give” do not trigger the subject check.

For missing spaces, Rust enumerates splits of an unknown token into known words. It combines evidence from the public training text and a new aggregate table trained on 60,143 distinct corrected messages from the training partition. A well-supported pair can commit at a word boundary. A weaker candidate ending in a preposition waits for right-side evidence, e.g. “in the”. The keyboard preserves its existing dictionary, personal lexicon, literal-context and undo checks. Whole words seen in clean training text are excluded from the new split search. This does not train on new messages typed into the simulator or keyboard.

The simulator replay sends each supplied character through the production key handler, feeding previous edits forward and committing the final word with a space that is excluded from scoring. The document is in memory; the replay waits for each model review. UI tests exercise actual asynchronous typing separately; no physical-device or latency claim is made.

From the project root, with the corresponding simulator build installed:

```sh
python3 keyboard-engine/training/boundary_counts.py /path/to/typo_sentences.md
python3 Benchmarks/build18/make_sentences.py /path/to/typo_sentences.md
python3 Benchmarks/build18/make_challenge.py /path/to/typo_sentences.md
export SIMULATOR_UDID='your-booted-simulator-uuid'
BENCHMARK_CASES="$PWD/Benchmarks/build18/sentences.tsv" Benchmarks/build17/run.sh > /tmp/monkeyboard18.jsonl
python3 Benchmarks/build17/score.py --cases Benchmarks/build18/sentences.tsv Benchmarks/build18/build17.jsonl /tmp/monkeyboard18.jsonl
```

The baseline was compiled and replayed from build 17 source before the policy edits. Loading old model resources into current code alone does not reproduce build 17. The everyday fixture SHA-256 is `72232bc576fcb2ed3b5a994fab74d79d057f74675d086baf438e0c68f11c2b8b`.
