# Build 53 literal protection

The keyboard scores a proposed automatic edit using the typed word and its current left and right context. A positive decision retains the typed spelling. The same model handles the initial delimiter, later revisions, and boundary edits. Suggestions remain available for a tap.

The trainer creates word-frequency and capitalization counts from 60,146 desktop training references, 37,408 English CC0 references and 3,222 unique non-spam UCI SMS messages. The SMS source excludes the entire historical public challenge eligibility class, including normalized equivalents. Desktop references in the reserved 15% hash partition do not enter training. A regularized logistic classifier learns the SMS register of a short context from the remaining corpora. Its weights use word and adjacent-word features seen at least three times.

A second logistic classifier estimates when a proposed replacement changes an intentional spelling. Its 52 shared numerical features include name frequency, how often the neighboring word precedes or follows a name, texting frequency, the register estimate, casing, edit distance and counts of the proposed correction in desktop training. It sees examples with and without right context. The fit includes 31,818 desktop repairs, 666 decisions from historical development replays and 1,075 generated alternatives to names and informal terms attested in independent corpus text. Half of the latter word types have their input word statistics masked during fitting to teach the classifier to use context for unfamiliar spellings. Runtime stores aggregate hashed feature counts, domain weights, and one vector of veto weights. Resources total 1,280,802 bytes, excluding this report and fit metadata.

Calibration uses 21,010 desktop repair opportunities held out of the edit-channel counts and veto fit. These references can contribute to auxiliary lexical and register statistics. It also uses 78 decisions from the earlier build 51 public and hand-written fixtures as replayed by build 52. Casing-equivalent proposals are skipped. Separate thresholds cover apostrophe-only edits, frequent SMS literals, tokens absent from the general vocabulary, and remaining edits. At each threshold, losing a correct public repair costs three times as much as missing a damaged literal. The trainer caps desktop vetoes in each group.

The selected model vetoed 7 of 16 historical changes to intentional words, 0 of 62 correct repairs in those prior fixtures, and 12 of the 21,010 desktop repair opportunities. These figures score individual proposals, using the higher of the immediate and right-context scores. The end-to-end replay determines what the keyboard actually does as the sentence evolves. Neither fit nor calibration opens a build 53 final fixture.

## Reproduce

Use Python with NumPy and SciPy, the original S:/C: corpus and the pinned UCI SMS archive. The fit command overwrites the four packed resources and fit metadata.

```sh
python keyboard-engine/training/literal53.py fit "$PAIRED" "$SMS"
rustc --edition 2021 --crate-type cdylib -O keyboard-engine/src/literal53.rs -o /tmp/libliteral53.dylib
python keyboard-engine/training/literal53.py verify /tmp/libliteral53.dylib
rustc --edition 2021 --test keyboard-engine/src/literal53.rs -o /tmp/literal53-tests
/tmp/literal53-tests
```

Verification compares the compiled C ABI to the Python feature implementation on 1,210 historical decisions. The Rust tests also check unfamiliar names, ordinary corrections, case-only edits, malformed inputs, and null pointers.
