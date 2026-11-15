# Build 53: more typo fixes, but a name regression

On a first blind, paired iPhone Duo simulator replay (149 reference sentences, each entered clean and with typos), build 53 recovered 178/297 erroneous word positions versus 151 for frozen build 52. Exact noisy sentences rose from 43/149 to 53/149; clean messages preserved rose from 136/149 to 137/149. Wrong guesses on already damaged words increased from 17 to 22.

Shorthand preservation improved from 111/118 to 116/118 occurrences. Name preservation fell from 71/78 to 69/78: one correctly typed lowercase personal name was rewritten in both versions of the same message. That regression triggered a follow-up candidate with a **separate** blind evaluation. [Build 54 report](../build54/README.md)

On the old build 52 development cases, 25 of the original 69 missed positions and four of the 15 changed clean messages were restored. All six historical build 40 catches were preserved. Four installed-extension tests passed, including mixed name/typo entry and undo. No physical device was updated.

[Full first blind scores and changed outputs](holdout-summary.json) · [First blind test design](holdout/README.md) · [Training](TRAINING.md) · [Original miss audit](verification.json) · [Candidate freeze](candidate-freeze.json)
