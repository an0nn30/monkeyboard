# Build 55 blind paired-message benchmarks

Two independently authored cohorts each contain 138 noisy messages and their 138 verbatim clean companions. Both were fixed before the author saw any keyboard predictions. Each cohort has 213 intentional errors, with 67 wrong but correctly spelled words, 45 missing spaces and 101 ordinary misspellings. Seventy-five noisy messages contain two errors each. Each cohort contains 76 protected name occurrences, 58 shorthand or dialect occurrences and 48 valid-word control occurrences across its noisy and clean companions. Valid-word controls include less common English vocabulary and genuine intended uses of confusable words. All references represent simulated texting.

The primary set and confirmation set have 67 distinct real-word confusion families apiece. An unordered pair of case-folded intended and typed words defines a family. The two sets share zero such families. The historical-source checks in the two manifests cover both the typed and intended form of every message, using the build 53 normalized exact-match audit. The confirmation audit also checks both forms against the primary set. Ordered-word similarity covers each cohort internally and comparisons with builds 53 and 54. The confirmation audit includes primary reference comparisons. These checks quantify exact overlaps and similarity in the enumerated sources; they cannot establish absence of every similar paraphrase elsewhere.

The author encrypted each annotated source independently using random keys. The manifests publicize source, fixture and scoring-code hashes. The author releases the requested cohort after the candidate is frozen and the coordinator explicitly requests release. Until then, the workspace contains neither plaintext benchmark file. Keep the second set sealed if primary results are used to make another candidate.

## Reproduction

Run from the repository root. After release, the primary fixture lives in this folder and the independent one in its confirmation subfolder. Both are JSON arrays in the build 54 schema and can be passed to the existing iOS replay harness. Each paired message gets a fresh replay. Case, punctuation and spacing are part of document equality. The protected array uses the additional category `valid-word` for the intended-vocabulary controls.

~~~sh
python3 Benchmarks/build55/holdout/freeze.py
python3 Benchmarks/build55/holdout/freeze.py --cohort confirmation
python3 -B Benchmarks/build55/holdout/test_score.py
python3 Benchmarks/build55/holdout/score.py \
  Benchmarks/build55/holdout/cases.json BASELINE.jsonl.gz CANDIDATE.jsonl.gz --out SCORE.json
~~~

Each replay log must cover every ID exactly once with a string in `final`. The result includes the fixture and both log hashes. Event metrics require all reference words in the marked span, with exact case and no intervening word. A correctly restored missing space earns one repair. Whole-message exactness is byte-for-byte string equality. The per-category `gained` count records baseline misses corrected by the candidate, and `lost` records former successes it damaged. Scores for originally correct and protected positions use the same reference-word alignment as build 54. The reference scorer retains its longstanding convention of scoring word spans separately from punctuation. A punctuation difference therefore affects whole-message exactness.

The freeze process checks case-sensitive labels against the original strings and runs two scoring endpoints on each fixture. Echoing every input must recover zero events. Returning every exact reference must recover all 213. The separate scorer regression tests cover partial joins, intervening words, literal punctuation and shifts before protected positions.

To repeat the source-overlap audit, pass `--audit` and any required data-path overrides to the appropriate verification command. The corpus flags and default paths match those used by the build 54 audit. A quick verification without `--audit` requires only the released files and repository scorer. These controlled samples do not estimate all real-world keyboard usage.
