# Build 54: more correctly repaired messages on the Duo simulator

**Build 54 fixed 121 of 213 intentional errors, compared with 100 for frozen build 52.** On the 138 independently authored fresh messages, it newly repaired 21 complete errors, lost zero former repairs, and produced 17 more fully correct messages. There were no new changes to originally correct word positions. All 138 clean inputs had identical outputs across builds, including eight clean messages both keyboards still changed. The keyboard runs locally and the physical phone was not updated.

| Final held-out sentence benchmark | Build 52 | Build 54 |
|---|---:|---:|
| Ordinary misspellings fixed | 73/101 | 82/101 |
| Missing spaces fixed (one entire join = one error) | 22/45 | 34/45 |
| Wrong but correctly spelled words fixed | 5/67 | 5/67 |
| All labelled errors fixed | 100/213 | 121/213 |
| Noisy messages fully correct | 40/138 | 57/138 |
| Clean messages preserved verbatim | 130/138 | 130/138 |
| Intended name occurrences preserved | 68/76 | 68/76 |
| Intended shorthand occurrences preserved | 52/58 | 52/58 |
| Originally correct word positions changed | 18/2,540 | 18/2,540 |
| Already-damaged positions replaced with a different wrong word | 12 | 13 |

Each message was entered twice: once with errors and once exactly as intended. Seventy-five of the noisy messages had two edits; name/shorthand denominators include the clean and noisy versions. In the earlier word-position scoring convention, 123/258 damaged positions were restored by 52 and 156/258 by 54. A single missing space can damage two positions. The event count instead requires recovering **both** parts with no intervening word. These results describe the constructed sample, not all users' typing.

Examples: “Your headphones are pluggedinto the screen on my left.” became “Your headphones are plugged into the screen on my left.” Both builds still changed the intended “moussa” and “yall” in clean texts. On one already-damaged word, build 54 changed “didh” to “did” where the reference called for “dish.” Real-word context and less familiar names are still clear weaknesses.

**Why two new builds?** Build 53 was trained using the prior 69 missed positions and 15 altered clean messages and checked on its own blind suite. It caught more typos and preserved more shorthand, but newly changed the same uncommon lowercase name in two replays. Build 54 added a learned name guard and now keeps the general spelling ranker from overriding words the iOS dictionary recognizes. Context-based correction remains enabled. The main transformer weights did not change. See [build 53 training and comparison](../build53/README.md) and [name gate fit and calibration](../../keyboard-engine/model/name54/README.md).

The first blind set was **development** for 54. On that set it fixed 177/297 word positions (52: 151), restored five shorthand occurrences, and introduced no additional name damage. On the **original** development data it recovered 24 of the original 69 missed word positions, lost none of the earlier fixes and preserved four of the original 15 affected clean messages. All six historical build 40 catches remained correct. On a separate desktop regression sample (714 reserved noisy inputs plus 1,200 clean controls) the typo-position count went from 1,395 to 1,397 and fully exact sentences from 1,852 to 1,851. All 1,200 clean controls were unchanged. This round did not rerun the full 100,000-message corpus.

**Reproduction.** [Fresh fixture and leakage audit](holdout/README.md) · [Paired scores and changed outputs](holdout-summary.json) · [Edit counts](edits.json) · [Selected binary/source hashes](candidate-freeze.json) · [Verification](verification.json) · [Installed extension tests](installed-tests.json).

Use the build 53 [training/replay instructions](../build53/TRAINING.md), followed by `python3 keyboard-engine/training/name54.py "$PAIRED"` for this version. The final test uses the same simulator controller replay for both versions, with the independently recorded build 52 binary and extension. The replay's document proxy and synchronous model queue do not measure touch accuracy, power or physical-device latency. Five installed-extension tests also tapped the real keys, exercising lowercase name preservation, combined spelling/name handling, rejoining words, delayed correction and undo.

~~~sh
python3 Benchmarks/build53/score.py Benchmarks/build54/holdout/cases.json \
  Benchmarks/build54/holdout-52.jsonl.gz Benchmarks/build54/holdout-54.jsonl.gz /tmp/build54-comparison.json 54
python3 Benchmarks/build54/edits.py
python3 Benchmarks/build54/verify.py
~~~
