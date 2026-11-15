# MonkeyBoard build 56: sentence-level autocorrect

The keyboard uses a bidirectional on-device English encoder and a trained detector that assesses whether a word looks like an accidental replacement in its sentence. It compares short edits using both left and right context. The decoder receives only the user's text. A suggested correction must win against the literal spelling; after the highest-confidence edit, the model can reconsider the remaining words. The keyboard checks the text, document and cursor before changing the owned suffix, and stores enough information for backspace to undo it. No evaluation labels are part of the runtime.

The three targets are separate: complete annotated typo events fixed, correctly spelled but contextually wrong words fixed, and noisy messages made byte-for-byte correct. Clean texts and collateral changes to originally correct words are counted separately.

## Fresh confirmation on the iPhone Duo simulator

Build 56 and the test sentences were frozen separately before the confirmation inputs were opened. Both builds received the same keystrokes for 138 typo-containing messages and 138 clean companions. Their final text was scored against the references after replay. This set used different real-word confusion pairs from the development set.

| Measure | Build 54 | Build 56 |
|---|---:|---:|
| All typo events fixed | 121/213 (56.8%) | **200/213 (93.9%)** |
| Correctly spelled but wrong words fixed | 5/67 (7.5%) | **59/67 (88.1%)** |
| Messages with typos made entirely correct | 49/138 (35.5%) | **125/138 (90.6%)** |
| Clean messages left exactly as typed | 128/138 (92.8%) | **138/138 (100%)** |

All 79 additional typo fixes were gains; none of build 54's fixes were lost. Build 56 fixed 99/101 ordinary errors and 42/45 missing spaces. All 2,400 originally correct word positions were preserved, including every marked name and instance of texting shorthand. For example, “reading grasses” became “reading glasses” in a sentence about tiny print; “he fell of his stool” still missed “off.”

On a **separate, previously released** 149-pair build 53 stress set, build 56 fixed 212/244 typo events (86.9%) and 52/62 correctly spelled wrong words (83.9%); 120/149 noisy messages (80.5%) were entirely correct, and all 149 clean companions were preserved. This is a regression check, not a second blind test. Results apply to these English message sets. The full training corpus was not scored here. Four installed-keyboard UI tests passed on the simulator. The four replay processes each peaked at approximately 604–611 MiB, including simulator and harness overhead; physical extension memory and typing latency remain unmeasured.

[Fresh comparison and protection counts](confirmation/report.json) · [Confirmation inputs and references](../build55/holdout/confirmation/cases.json) · [Historical stress-set counts](validation/historical53-metrics.jsonl) · [Installed keyboard tests](validation/ui.json).

## Released development set

The original 55 release missed the target on two measures despite a large gain over 54. Its blinded primary became development data for 56. The following scores come from the actual keyboard controller in the Duo simulator, not the standalone model.

| On the same 138 typo-containing messages and 138 clean companions | Build 54 | Build 55 | Build 56 |
|---|---:|---:|---:|
| All typo events fixed (213) | 115 | 188 | 199 |
| Wrong but correctly spelled words fixed (67) | 4 | 48 | 55 |
| Noisy messages entirely correct (138) | 40 | 105 | 123 |
| Clean messages preserved (138) | 125 | 130 | 137 |
| Originally correct word positions damaged (2,454) | 28 | 19 | 2 |

The meaning of each error is set by the authored reference. A missing space earns one fix only if all resulting words are correct. Equally reasonable readings do not get extra credit. The controller replay presses individual keys and waits for an already-scheduled sentence review; it does not model a finger landing between two keys. A physical device was not deployed or benchmarked.

[Build 55 primary report](../build55/primary/report.json) · [Build 56 development replay](validation/released55.jsonl.gz) · [Trained model and provenance](model/README.md) · [Lexical search and pronunciation data](lexical/README.md) · [Frozen simulator artifact manifest](candidate-freeze.json).
