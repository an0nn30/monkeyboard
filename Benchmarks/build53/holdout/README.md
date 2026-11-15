# Build 53 paired-message holdout

Each of the 149 references appears once as an unchanged message and once with intentional errors. The 298 rows are paired for comparing corrections and damage on the same messages. The annotation files and expected strings were written before the author saw any baseline or candidate predictions. The authorship process did not use either model, model outputs, or reported model failures. Treat this set as seen after its first evaluation.

## Sources and scope

The 127 original references were written specifically for this evaluation by the benchmark-authoring agent. They are simulated everyday texts, with a mixture of casing, names, shorthand, and punctuation. The author wrote each error in its sentence without substitutions drawn from a model's errors. Subsets cover multiple ordinary spelling slips, contextually wrong valid words, missing spaces, and mixtures. Some valid-word errors will admit other plausible readings, so the reference records the sender's specified intent.

The 22 authentic references come from the ham portion of Almeida and Hidalgo's *SMS Spam Collection* (2011). Each reference preserves its source line's spelling, punctuation, and case after removing the class prefix and outer whitespace. The noisy companion, error ranges and protection labels are annotations added for this benchmark. The original researchers released the dataset under CC BY 4.0. [Dataset and attribution](https://doi.org/10.24432/C5CC84) · [License](https://creativecommons.org/licenses/by/4.0/)

The public subset uses the project's pinned UCI archive and the project's previous challenge-eligibility screen of 6–26 whitespace tokens, single spaces, restricted ASCII characters, and final punctuation. We filtered exact normalized overlap with the source groups listed below, then selected messages that could be annotated while retaining the original wording. This is a curated sample. The prior training process has used this public collection, including aggregate casual-language counts. Absence of matching references in prior fixtures and the checked training files cannot establish that this public subset is unseen by every historical training component. The independently authored subset has separate provenance and can be scored separately.

## Input schema

The replay input is a UTF-8 JSON array in `cases.json`.

- `id` identifies one message. `pair_id` links its clean and noisy companions. `split` is `blind`.
- `typed` is the input and `expected` is the exact intended message, including case and punctuation.
- `source` identifies either `independently-authored` or `uci-sms-ham`. `source_id` is the one-based line in `authored.txt` or the one-based line in the UCI archive member `SMSSpamCollection`.
- `kind` is `ordinary`, `real-word`, `missing-space`, `mixed`, or `clean`. A noisy row with multiple edits in a single category uses that category. `edits` records each typed and intended surface, category, and start indices. The clean companion has an empty edits list.
- `protected` identifies intended literal occurrences on both companions. Each object has `text` (case-sensitive spelling, without surrounding punctuation), `category` (`name` or `slang`), `typed_index`, and `expected_index`. All indices in the file are zero-based whitespace-token indices in the corresponding *full sentence*. They can differ after a missing space. An empty list means no targeted literal annotation. `name` includes named entities and `slang` includes conversational spellings and initialisms.

## Verification

Run `python3 Benchmarks/build53/holdout/freeze.py` to regenerate both artifacts in memory and verify their bytes. The command checks the source archive hash and source lines, pair identities, the distinct normalized forms, the spelling under each annotation index and the exclusion sets. Supply local source locations using `--desktop`, `--conversations` and `--sms` when needed. To verify the distributed file without those sources, run `shasum -a 256 cases.json` in this directory and compare with `fixture_sha256` in `freeze.json`.

The overlap check case-folds, removes accents and apostrophes, splits on other non-alphanumeric characters and joins tokens with one space. It compares both typed and expected messages against both sides of every S/C row in the desktop typo dataset, prior source fixtures explicitly enumerated in `freeze.py`, the whole bundled Tatoeba CC0 corpus, the Taskmaster training utterances, and local phrase/practice sources. Historical fixture inputs include whole-message pairs and reconstructed prefix or left/target/right examples. This checks full-message identity; it does not measure shared short phrases or near-paraphrases. The freeze manifest gives the exact counts and hashes.
