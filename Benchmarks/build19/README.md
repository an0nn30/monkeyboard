# Build 19 · missing spaces without breaking intentional words

Build 18 was installed on the physical Duo and verified from its installed-app inventory. Build 19 was built and exercised on the iPhone Duo simulator. The change is in the Swift/Rust spelling policy; the 15M transformer and next-word model were not retrained.

## Final blind test

After fixing two rounds of unwanted compound splits, we froze the policy and replayed **528 previously unused full sentences**. Each noisy input has exactly one labelled missing space; clean controls have none. Both builds received identical characters, case, punctuation, and final commit. The score measures whether the right words survived with a space at exactly the intended position.

| Outcome | Build 18 | Build 19 |
|---|---:|---:|
| Intended missing spaces restored | 187/342 (54.7%) | 203/342 (59.4%) |
| Noisy sentences exactly correct, including surrounding text | 186/342 | 201/342 |
| Unwanted splits anywhere in the 528 sentences | 0 | 0 |
| Clean sentences left exactly as supplied | 185/186 | 185/186 |

Both keyboards changed “diarrhoea” to “diarrhea” in the same clean sentence; that was not a space insertion. New recoveries include “bring ajacket” → “bring a jacket” and “my planner inmy other bag” → “my planner in my other bag”. The gain is net: build 19 sometimes abstains where build 18 succeeded, e.g. “We metin Phoenix years ago.” The checks also preserved deliberate “papermaking”. No observed false splits in this set is not a guarantee for unseen text.

[Final test inputs and expected text](audit.tsv) · [Build 18 outputs](audit18.jsonl) · [Build 19 outputs](audit19.jsonl)

## What informed the release policy

Build 18's public challenge missed 54 of 120 inserted word boundaries. Some correct splits, including “dog laughed”, appeared in UIKit's dictionary guesses but could not compete with a proposed change of letters. Build 19 looks for a *unique* supported split spelling both original parts without changing any letters. Rust considers native guess rank, nearby words and observed phrase counts. Lower-evidence combinations need grammatical evidence. Words already accepted by the system spell checker are not fed to the new search; explicit shortcuts, literal contexts, and the personal lexicon retain precedence. A separate dictionary veto removes automatic, suggested and deferred exact splits of known whole words, without suppressing unrelated spelling corrections.

- **Original development challenge:** 66/120 → 88/120 exact; both preserved 120/120 clean sentences. [Cases](../build18/challenge.tsv) · [Build 18](../build18/challenge18.jsonl) · [Final build 19](development19.jsonl).
- **First 2,002 new sentences:** an [early candidate](candidate.jsonl) improved recall but introduced “cow house” and “super volcano” in clean messages. The final policy restored 986/1,300 missing spaces vs 929/1,300; both builds had one incorrect split in noisy text and zero in 702 clean messages. Both left 700/702 clean messages exactly unchanged. [Inputs](sentences.tsv) · [Build 18](build18.jsonl) · [Final build 19](build19.jsonl).
- **Next 1,013 new sentences:** the [intermediate policy](before-dictionary.jsonl) split “papermaking” elsewhere in a noisy sentence. On this same set, the final policy restored 535/676 spaces vs 512/676 with zero false splits for both builds. Both preserved 337/337 clean messages. [Inputs](confirmation.tsv) · [Build 18](confirmation18.jsonl) · [Final build 19](confirmation19.jsonl).

These two new sets informed refinements. Only the last 528-sentence set is the independent estimate for the final policy. The audit has a different proportion of public and paired data and admits shorter and longer messages, so percentages across sets need not match.

## Data and reproduction

The paired-data targets are sampled by normalized corrected sentence from the existing training holdout (SHA-256 first byte <38). The independent English text uses the decoder's public CC0 holdout (<26) and excludes the user corpus. Prior build 15–18 cases, already selected targets, and variants in earlier build 19 rounds are excluded by the generators. One space per noisy target is removed deterministically; one third of corpus messages remain completely unmodified. Authored clean cases stress compounds, uncommon spellings, identifiers and explicit codes. This isolates the effect of space loss; these rates do not estimate all real-world typing errors.

The supplemental whole-word veto is an exact sorted subset of the macOS system web2 word list, restricted to whole entries that also decompose into two terms in the shipped vocabulary. Its 41,373 entries occupy 391,454 bytes. The source file SHA-256 was `be41ad97963bf8dabedd5871d5d691596175269d540956b0f9965a885c2bbab9`. Regenerate with `python3 keyboard-engine/training/whole_compounds.py /usr/share/dict/web2`; the generated file ships with the Rust library, so installation needs no dictionary download.

The simulator harness calls the production key handler for every supplied character, using a memory-backed document, a final Space to commit the last word, and synchronous model reviews. Real UI tests separately exercise keyboard taps, continuation-based revisions and Delete. The scorer aligns non-whitespace characters case-insensitively, requires both labelled words intact and correctly separated, and counts additional internal spaces in otherwise intact intended words. Exact sentence matching also catches spelling, punctuation and case changes. The archived build 18 executable was compiled before the policy was changed.

From the project root, with the matching build installed on a booted simulator:

```sh
python3 Benchmarks/build19/make_cases.py /path/to/typo_sentences.md
python3 Benchmarks/build19/make_cases.py /path/to/typo_sentences.md --confirmation
python3 Benchmarks/build19/make_audit.py /path/to/typo_sentences.md
export SIMULATOR_UDID='your-booted-simulator-uuid'
BENCHMARK_CASES="$PWD/Benchmarks/build19/audit.tsv" Benchmarks/build17/run.sh > /tmp/build19-audit.jsonl
python3 Benchmarks/build19/score.py --cases Benchmarks/build19/audit.tsv Benchmarks/build19/audit18.jsonl /tmp/build19-audit.jsonl
```
