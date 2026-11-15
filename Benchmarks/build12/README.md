# Build 12 lookback replay

With build 12 installed on the booted Duo simulator, run `Benchmarks/build12/run.sh`. It runs the Swift correction policy and the compiled Core ML model from the installed keyboard. Each row compares the immediate delimiter commit with subsequent reviews after one, two and three following words. The first accepted revision ends that row. The replay isolates one marked word per case. The host UI test additionally exercises typing, caret placement, undo and retaining the reverted spelling.

The 26 authored cases include the reported sentence, additional inflection examples, everyday slips and correctly spelled controls. In this diagnostic set the immediate policy fixed 5 of 19 typos. Lookback fixed 11. Both made one wrong replacement and preserved all seven controls. Five new fixes were the targeted `gos` inflection, and one was `paor → pair` before “of socks”. Both left “The app gos offline overnight” unchanged. Both chose “train” for “Follow the traim through the woods”, where the intended word was “trail”. These results measure this small development set. They do not establish a general typing accuracy rate.

The extension includes the original five-block checkpoint as an FP16 Core ML program with 8,192 vocabulary entries. The conversion script compares all 8,192 next-token logits at four prefixes with the PyTorch checkpoint. All four top predictions agreed, and the largest absolute difference was 0.060. The simulator UI test types “The novel gos beside ”, observes the later change to “goes”, taps Delete, then types “my book.” after the restored text.

## Fresh everyday messages beyond “gos”

Build 12 on the physical iPhone Duo (iOS 27.2.1) passed the installed-keyboard typing test: it revised “The novel gos beside ”, restored the original spelling on Delete, and appended “my book.” at the expected caret position.

The separate [fresh fixture](everyday-fresh.tsv) has 87 English messages with one marked spelling each. The prompts and intended words were fixed before scoring, with no “gos” examples and no model or threshold changes. Cases cover everyday slips, real-word substitutions, plausible alternatives, and intentionally preserved words including slang, names and a literal code word. The benchmark ran the compact setting and the transformer on the same Duo simulator (iOS 27.2). It scores the marked word at word boundaries and supplies up to three following words. Each row records the first automatic revision. The replay uses the simulator dictionary and does not import personal lexicon entries.

| Marked-word outcome | Compact | Transformer |
| --- | ---: | ---: |
| Typos corrected | 28/47 | 29/47 |
| Typos left as typed | 17/47 | 16/47 |
| Typos replaced with another wrong spelling | 2/47 | 2/47 |
| Intended spellings kept | 39/40 | 39/40 |
| Intended spellings changed | 1/40 | 1/40 |

The sole difference was “She already padi for the tickets”. Both committed “padi” initially. The transformer revised it to “paid” after “for”. A separate test tapped both the “paid” sentence and the “leek” soup sentence through the installed simulator extension and verified the full text after each edit. Both preserved “leek” in soup, and both missed “leek” when a sink had a leak. Both changed the deliberately literal code word “teh” to “the”. Both guessed “plans” for “plams” where the writer wanted “palms” and “candle” for “cadle” where the writer wanted “cable”.

These results describe this authored sample. For the [row-by-row outputs](everyday-fresh-results.tsv), run `Benchmarks/build12/run.sh Benchmarks/build12/everyday-fresh.tsv` from the repository root with build 12 installed in the booted simulator. The compact column is a separate pass with transformer reviews disabled.
