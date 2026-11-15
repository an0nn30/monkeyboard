# Everyday typing benchmark

The [sentence list](cases.tsv) contains 3,092 scored decisions. Each row gives the text before the marked word, the user's input, the intended spelling or acceptable next words, and the rest of the sentence. The split contains 825 development cases, 2,263 evaluation cases and four separate examples from the Notes screenshot. [Build 14 outputs](build14.tsv) · [Build 15 outputs](build15.tsv) · [Build 16 outputs](../build16/independent.tsv).

| Outcome on the 2,263 evaluation cases | Build 14 | Build 15 | Build 16 |
|---|---:|---:|---:|
| Typos corrected | 741/1,553 | 894/1,553 | 915/1,553 |
| Typos left as typed | 718 | 561 | 540 |
| Typos changed to another wrong spelling | 94 | 98 | 98 |
| Deliberately typed words changed | 3/310 | 4/310 | 4/310 |
| Expected next word first | 59/400 | 72/400 | 74/400 |
| Expected next word anywhere in the three suggestions | 98/400 | 107/400 | 112/400 |

On just the authored and generated texting scenarios, the three builds fixed 177, 188 and 192 of 293 typos. They offered an accepted next word in 14, 20 and 22 of 40 prompts, and changed 3, 4 and 4 of 130 intended spellings. All builds wrongly edited “sooo”, “tmux” and “pnpm”. Builds 15 and 16 also changed the deliberately typed puzzle code “yhid” before its explanation had been typed.

Among the generated English examples, missing spaces went from 0/180 to 87/180, two neighboring-key substitutions from 2/180 to 37/180, and a dropped letter plus a transposition from 32/180 to 64/180 in build 16. These categories emphasize hard errors, so the combined success rate is specific to this mix.

The public English sentences come from the existing pinned CC0 source. Their hash places them in the decoder's reserved bucket. One deterministic typing error is injected per typo example. Clean sentences and next-word prompts are also included. The texts file contains separately authored messages. The scenario generator makes variations on everyday activities and reserves whole families of frames for evaluation. Some sentence frames in the public data or the paired-data experiment can resemble one another. The fixture is fixed for comparing future builds.

The joined-layout replay uses the Swift correction policy, Rust ranker and Core ML decoder in the iPhone Duo simulator. The final three suggestions are scored after the transformer finishes. A prediction receives credit for any listed alternative. Public examples use the observed next word and can have other reasonable completions. Each replay starts with clean preceding text and scores one decision. The separate Notes UI test types the whole line and exercises undo through the installed keyboard extension.

From the repository root, regenerate the list with `python3 Benchmarks/build15/make_cases.py`. With the matching app installed on a booted simulator, run `Benchmarks/build15/run.sh > /tmp/typing-results.tsv` and `python3 Benchmarks/build15/score.py /tmp/typing-results.tsv`. Use `--detail` for misses and incorrect replacements. Set `SIMULATOR_UDID` when multiple simulators are running.
