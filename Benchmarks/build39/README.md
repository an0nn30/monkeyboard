# Build 39: simulator autocorrect benchmark

**Release status: hold.** The candidate cleared the 90% damaged-word recovery target on the supplied file. Fresh-message recovery and strict whole-sentence exactness are different outcomes, and the keyboard does not achieve 90% accuracy on unfamiliar messages.

| Same inputs, same scoring | Build 21 | Build 39 |
|---|---:|---:|
| S:/C: damaged word slots recovered | 130,793 / 204,918 (63.83%) | 194,705 / 204,918 (95.02%) |
| S:/C: entirely correct sentences | 49,081 / 100,000 (49.08%) | 88,697 / 100,000 (88.70%) |
| Reserved: damaged words recovered | 19,572 / 31,054 (63.03%) | 29,136 / 31,054 (93.82%) |
| Reserved: entirely correct sentences | 7,279 / 15,184 (47.94%) | 13,202 / 15,184 (86.95%) |
| S:/C: originally correct words changed | 22 / 451,446 (0.0049%) | 24 / 451,446 (0.0053%) |
| S:/C: damaged words changed to another wrong word | 6,659 | 1,484 |
| Distinct reserved clean sentences preserved | 10,758 / 10,764 (99.94%) | 10,764 / 10,764 (100.00%) |
| Fresh: damaged words recovered | 197 / 383 (51.44%) | 212 / 383 (55.35%) |
| Fresh: entirely correct noisy messages | 61 / 236 (25.85%) | 84 / 236 (35.59%) |
| Fresh: clean messages preserved | 88 / 120 (73.33%) | 96 / 120 (80.00%) |
| Fresh: originally correct words changed | 128 / 3,656 (3.5011%) | 75 / 3,656 (2.0514%) |
| Fresh: damaged words changed to another wrong word | 10 | 17 |

| Targeted slices | Build 21 | Build 39 |
|---|---:|---:|
| S:/C: two- or three-letter targets recovered | 33,125 / 53,617 (61.78%) | 50,287 / 53,617 (93.79%) |
| S:/C: exact sentences with two or more damaged slots | 20,992 / 61,651 (34.05%) | 51,999 / 61,651 (84.34%) |
| Fresh real-word challenge: damaged slots recovered | 9 / 38 | 10 / 38 |
| Fresh short challenge: damaged slots recovered | 20 / 36 | 22 / 36 |
| Fresh multi challenge: damaged slots recovered | 122 / 197 | 136 / 197 |
| Fresh multi-typo messages fully repaired | 17 / 78 | 27 / 78 |

Exactness includes case, punctuation and spacing. **92,773/100,000** supplied sentences matched every reference word in order (including case and internal apostrophes). **4,051** failed strict exactness solely on terminal punctuation. A single Space does not imply that the person has finished their sentence. The 90% measure was specified as recovery of damaged word slots, not the fraction of mostly-correct words copied unchanged.

On the frozen blind set, “Wehre did the tin of materess patches end pu?” became “Where did the tin of mattress patches end up?” Build 21 kept “materess” and “pu.” Across all 356 blind messages, build 39 gained 40 exact results and lost nine previously exact results. It overcorrected fewer correct words overall but more damaged words ended in a different wrong form. The largest recovery gain was on multi-typo messages; valid-word disambiguation remains weak. Of the 52 original authored challenges, exactness **fell from 27 to 26**; UCI SMS exactness rose from 122 to 154 of 304. Do not extrapolate the pooled result to an individual user's typing.

## Verification and artifacts

The final candidate was fingerprinted before opening the blind results. Both builds replayed final text by ID with the same iPhone Duo simulator. The complete build 39 run used the compiled extension resources of the candidate. All 100,000 input IDs, including repeated source rows, were included. The source contains 84,816 training pairs and 15,184 reserved pairs by normalized clean-reference hash. The reserved references had been used for earlier evaluations; only the separate 356-message blind suite was new to this tuning round. The desktop clean benchmark consists of 10,764 distinct exact reserved reference strings. We did not use the blind errors to tune build 39.

Build 39 passed 17 Rust unit tests, nine scorer tests, and five installed-extension key-tap tests: delayed multiple-word correction and undo, original short-word behavior, ambiguous spellings, contractions, and tense/meaning preservation. No build was sent to a physical phone. No claim is made about device latency or memory headroom.

[Fresh inputs and data credits](../build22/blind/README.md) · [Training](TRAINING.md) · [Replay instructions](../build22/README.md) · [Freeze](freeze.json) · [Verification](verification.json) · [Development history](development.json)

| Evidence | Comparison | Candidate outputs |
|---|---|---|
| Original 100k pairs | [All counts and both splits](desktop-comparison.json) · [Short-word and multi-typo slices](desktop-slices.json) | [100,000 outputs](desktop-39.jsonl.gz) |
| Clean controls | [Clean comparison](clean-comparison.json) | [Clean outputs](clean-39.jsonl.gz) |
| Fresh development | [Review comparison](review-comparison.json) | [Review outputs](review-39.jsonl.gz) |
| Fresh blind | [Final comparison](final-comparison.json) | [Final outputs](final-39.jsonl.gz) |
