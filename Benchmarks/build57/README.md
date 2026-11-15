# Build 57 apostrophe restoration

The iPhone Duo simulator replay typed each input, pressed space, and waited for sentence review. The 50-case contraction suite is a focused regression test. Build 56 produced the exact target for 4/23 messages missing apostrophes and preserved 26/27 clean messages. Build 57 produced the exact target for 23/23 and preserved 27/27. The two installed keyboard UI tests also passed, including immediate backspace undo. [Inputs and expected text](contractions.tsv) · [Build 56 outputs](build56.contractions.jsonl.gz) · [Build 57 outputs](build57.contractions.jsonl.gz).

Across the previous [276-input full-message benchmark](../build56/confirmation/report.json), the [build 57 simulator outputs](build57.regression.jsonl.gz) matched build 56 on every message. It fixed 200/213 typos and 59/67 correctly spelled wrong words, made 125/138 typo-containing messages entirely correct, and preserved 138/138 clean messages.

The engine learns where apostrophes appear by collapsing attested contractions to the letters that were typed. For ambiguous words it compares how often the literal and the contraction occur with their neighbours. Uppercase initials, explicit literal prompts, and the user's undo pass through the keyboard's normal editing rules. The sentence reviewer uses the same restoration model when it revisits earlier words.

The [training script](../../keyboard-engine/training/contractions.py) uses Tatoeba English CC0 sentences, [Taskmaster-1](https://github.com/google-research-datasets/Taskmaster/tree/d92cb6af3005f1dc09c39e75e7daf4a04905e00b), the [Universal Dependencies English Web Treebank r2.15 training split](https://github.com/UniversalDependencies/UD_English-EWT/tree/r2.15), wordfreq 3.1.1, and Princeton WordNet 3.0. The derived contraction and context table is distributed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/), with attribution to the English Web Treebank contributors and Robyn Speer's wordfreq. The training sources and licenses for the other resources are documented in the [model notices](../build56/model/NOTICE.txt) and [lexical data notes](../build56/lexical/README.md).

To regenerate the 48 KiB table, use wordfreq 3.1.1, the dialogue and WordNet inputs documented above, and the EWT r2.15 training CoNLL-U file (SHA-256 `a049fc40822e21593ff89ccd0a4b081443f09fae71b61f813c624aa598f6c566`).

```sh
python3 keyboard-engine/training/contractions.py self-dialogs.json en_ewt-ud-train.conllu WordNet-3.0/dict
```
