Current comparison: [build 15 typing and prediction benchmark](build15/README.md).

# Tap typing benchmark · build 7

Measured in the iPhone Duo simulator, iOS 27.2, with the same installed English system dictionary for both builds and no injected personal lexicon. Build 6 is MonkeyBoard’s previous shipping logic, not Apple’s stock keyboard. The comparison runs on public/project-authored text only.

| Fixed fixture | Build 6 | Build 7 joined | Build 7 split |
|---|---:|---:|---:|
| Intended word automatically committed | 24/30 | 28/30 | 27/30 |
| Committed the wrong word on a typo | 0/30 | 0/30 | 0/30 |
| Unwanted changes on protected/correct spellings | 0/30 | 0/30 | 0/30 |
| Intended next word in first three, conversational prompts | 2/24 | 10/24 | 10/24 |

A separate 256-sentence next-word holdout scored **15/256** for build 6 and **61/256** for build 7. The holdout tests prediction, not autocorrect; the same next-word model runs in both layouts. These are exact next-word matches, so other reasonable suggestions score as misses. The small typo set is a development/regression fixture fixed before collecting the build 6 baseline; it is not independent evidence of general correction precision. No stock keyboard comparison or hardware latency claim.

The candidate uses actual letter frames from the keyboard view (393 pt joined, 900 pt split) to distinguish nearby substitutions from cross-bank ones. For example, in the build 7 run, `probablt` became `probably` in joined mode; T and Y are across the gap in split mode, so it stayed literal there. Both modes abstained on `thme` in “Please tell thme.” An early ranker incorrectly committed “the” there, motivating a guard against shortening ambiguous four-letter typos to very frequent three-letter words.

**Reproduce:** boot the Duo simulator, install the Rust simulator target as described in the project README, then run from the project root:

```sh
Benchmarks/run.sh > /tmp/mb-joined.tsv
MB_LAYOUT=split Benchmarks/run.sh > /tmp/mb-split.tsv
MB_FIXTURE="$PWD/Benchmarks/held-out.tsv" Benchmarks/run.sh > /tmp/mb-held-out.tsv
python3 Benchmarks/score.py /tmp/mb-joined.tsv --gate
python3 Benchmarks/score.py /tmp/mb-split.tsv --gate
python3 Benchmarks/score.py /tmp/mb-held-out.tsv --gate
```

The raw build 7 results are checked in alongside the fixtures. `Build6WordCorrections.swift` is frozen; do not refactor it with the candidate. `SIMULATOR_UDID` selects a specific booted simulator. `--baseline-only` runs just build 6 without a Rust toolchain. Per-case comparison is inference only; host-policy checks, actual key presses, punctuation commits, suggestion insertion and immediate Delete are verified separately via the iOS UI suite. System spelling data can differ across versions and devices.

Next quality gate: expand the evaluation with fresh, independently labeled conversational typos, acceptable alternatives, and mixed names/slang; measure incorrect replacements and typing latency on hardware before adding swipe.
