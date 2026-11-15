# Third confirmation cohort

This independently authored reserve contains 138 everyday English texts, each with an annotated noisy input and a clean companion. The author knew two aggregate acceptance gates on the first cohort had been missed. The author had no access to candidate or baseline predictions or individual failures. Messages and error locations were written by hand before scoring, including informal phrasing and contextual valid-word controls. This is a constructed sample of texting.

The corpus has 213 events across 138 noisy messages. There are 67 valid-word substitutions, 45 missing spaces and 101 ordinary misspellings. Seventy-five noisy messages have two events. Across all 276 replays the protected annotations cover 76 name occurrences, 58 shorthand or dialect occurrences, and 52 intended valid-word occurrences. Both sides together have 2,652 originally correct word positions.

All 67 unordered valid-word confusion families are distinct. None occur in either preceding build 55 cohort. An aggregate pre-freeze check found one family shared with the reserved build 55 confirmation. The author replaced that family before freezing. There are zero normalized exact text overlaps in any of the 11 enumerated comparison groups. The build 55 confirmation was compared in memory without disclosing any example to developers. Maximum word-sequence similarities and the source hashes are in the manifest.

The coordinator can request this cohort after the earlier confirmation. Until then, the plaintext source and fixture are sealed. Upon release, the fixture path is `Benchmarks/build56/holdout/cases.json`. Its frozen SHA-256 is `ed4a1df85e6a719d3a73ed3cd1b168fd3c09ce7002be2f3507278c7a771fe0c8`. Verification uses the existing schema and scorer.

~~~sh
python3 Benchmarks/build56/holdout/freeze.py
python3 Benchmarks/build55/holdout/score.py Benchmarks/build56/holdout/cases.json BASELINE.jsonl.gz CANDIDATE.jsonl.gz --out SCORE.json
~~~

After both earlier datasets have been released, `python3 Benchmarks/build56/holdout/freeze.py --audit` repeats the source-overlap check, annotation validation and scoring endpoints. The corpus path overrides match the build 55 freeze tool.

The original encryption passphrase was held in temporary agent state that later expired. The custodian recovered the exact original source from its private authoring record, checked both original SHA-256 digests, and encrypted a recovery copy. The recovery key can be reconstructed from a specific record in the original curator's private on-disk task history. Keep that archive with the workspace until release. Running `python3 -B Benchmarks/build56/holdout/custody.py` in a new process verifies recovery in memory without writing any benchmark text. The `--release` option materializes the verified originals when separately authorized.
