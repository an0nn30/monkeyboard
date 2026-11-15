# Training from noisy and corrected sentences

The local source supplied by the user contains 100,000 unique S/C pairs and 71,315 distinct corrected strings. The importer groups by normalized corrected sentence before assigning examples to training or evaluation. It used 84,781 training pairs across 60,143 normalized sentences, reserved 15,182 pairs across 10,708 normalized sentences, and excluded 37 pairs matching the independent benchmark.

Build 16 fits two small tables. The first contains 3,645 typo mappings. A mapping needs support in at least three different corrected messages, a clear lead over competing spellings, and a target that also occurs in lowercase. The second contains counts for 19,266 phrase contexts from deduplicated corrected sentences. The keyboard blends these counts with the transformer's next-word probabilities. It keeps the build 15 transformer checkpoint and ships only aggregate tables from the source. The corpus contains repeated sentence patterns and some ungrammatical target sentences, so its in-domain result is reported separately.

| Outcome on 840 reserved decisions | Build 14 | Build 15, before training on the file | Build 16 |
|---|---:|---:|---:|
| Corrected the typo | 211/420 | 212/420 | 225/420 |
| Left the typo untouched | 200 | 199 | 186 |
| Replaced a typo with another wrong word | 9 | 9 | 9 |
| Changed an intended spelling | 0/180 | 0/180 | 0/180 |
| Expected next word first | 43/240 | 48/240 | 122/240 |
| Expected word anywhere in three suggestions | 70/240 | 74/240 | 134/240 |

The evaluation samples one decision per reserved corrected sentence and preserves casing. Typo cases contain one marked mismatch from a supplied S/C pair. Other cases use clean words or prefixes from reserved corrected sentences. Surrounding words are clean and punctuation is omitted in replay. This measures individual corrections and next-word suggestions. It does not measure recovery of entire noisy sentences. Examples recovered by build 16 include “descripshun” to “description”, “tomarrow” to “tomorrow” and “openall” to “open all”. The separately authored and CC0 evaluation measured a smaller change in prediction after fitting the paired data, from 107/400 to 112/400 top-three hits. [Independent benchmark and corpus](../build15/README.md).

[Reserved cases](cases.tsv) · [Build 14 outputs](build14.tsv) · [Build 15 outputs](build15.tsv) · [Build 16 outputs](build16.tsv)

From the project root, run `python3 keyboard-engine/training/paired_text.py /path/to/typo_sentences.md` to regenerate the aggregate tables and the reserved sample. The input SHA-256 for this build is `3923227845fa16c0314f9282ec14eed8d3b94042b728dc8efd1ddf72a2c70df4`. With build 16 on the simulator, run `BENCHMARK_CASES="$PWD/Benchmarks/build16/cases.tsv" Benchmarks/build15/run.sh > /tmp/paired-results.tsv` and `python3 Benchmarks/build15/score.py --cases Benchmarks/build16/cases.tsv /tmp/paired-results.tsv`. The archived outputs contain row IDs into the corresponding fixture.
