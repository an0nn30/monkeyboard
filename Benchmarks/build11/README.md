# Build 11 vs build 10: does the sentence change the committed word?

On 493 fresh English samples, build 11 corrected **252 of 387 typos**, up from **224**. Wrong automatic replacements fell from **20 to 16**. Both builds preserved all **106** correctly typed tokens. No individual case lost a correct result or gained a new wrong replacement. “Correct” means the word committed on a delimiter, not a word merely offered in the strip.

| Frozen evaluation slice | Typos | Correct, 10 → 11 | Wrong, 10 → 11 | Left typo as typed, 10 → 11 | Unchanged controls |
|---|---:|---:|---:|---:|---:|
| 10 contrasting sentence pairs | 20 | 6 → 10 | 8 → 4 | 6 → 6 | — |
| Everyday authored messages | 24 | 15 → 15 | 0 → 0 | 9 → 9 | 20/20 both |
| Held-out public text with simulated slips | 343 | 203 → 227 | 12 → 12 | 128 → 104 | 86/86 both |

**Book versus boot.** Five pairs share the same typo and final words within each pair. Build 10 chose book every time (5/10, zero complete pairs). Build 11 preserved all five books and chose boot in four of the other five (9/10, four complete pairs). The cobbler/sole sentence still got book. The other ambiguity pairs (slice/slide, beach/bench, eye/ear, spoon/spool, roof/room) saw no improvement. With build 11 restricted to the last four words of context for both model scorers, all five boot cases went back to book. That check holds the candidate typo, settings and thresholds constant. Both original build 10 book/boot development examples also work, but they aren't counted as fresh.

The public replay improvements were exact tap swaps and doubles such as *wildlief → wildlife* and *ccopper → copper*. The gain on that slice should not be attributed to understanding sentence meaning. The 44 ordinary authored messages showed no overall change. These findings are evidence on these samples, not a bound on the error rate during real typing.

**Method.** Original Swift/Rust build 10 generated all frozen baseline outputs on the same Duo simulator before any model changes. Pairs/texts were written before development. Public-text replay continues beyond the first 384 examples per split from build 10 (same hash-based corpus exclusion and generator), with no row reused. The new 449-row development partition and old build 10 fixtures supported calibration; they are excluded from the numbers above. The [frozen policy](policy.txt) preceded candidate scoring on the three new evaluation sets. One keep-row gold label transcribed an interior word (*bass*) rather than the evaluated final token (*sounds*); both outputs were already *sounds*. Only the label was corrected. No case was removed. The automatic decisions aren't based on an enumerated list of book/boot cues.

**Reproduce.** With a booted Duo simulator, run `Benchmarks/build11/run.sh /tmp/mb11-check`. It builds the shipping correction code, compares identical ordered prompts, distinguishes wrong commits from abstentions, and checks for any new wrong edits per row. `MB_WINDOW=4 MB_FIXTURE="$PWD/Benchmarks/build11/pairs.tsv" Benchmarks/run.sh` runs the context ablation. The production dictionary is provided by the OS, so use the same English/iOS version for reproducibility. The TSV's legacy `build6` column is unrelated; compare the `candidate` columns of the two saved runs.

**Cost and integration.** Extra model assets are 1,444,810 bytes (int8 vectors and vocabulary). In the simulator the isolated refinement call took 1.3 ms on first use; warm p95 was 0.001 ms for the 14-word case and 0.006 ms for a 121-word case with repeated vocabulary. These are not full extension or hardware timings. Run `Benchmarks/build11/timing.sh`. The installed-extension UI check types two sentences with the same trailing words, commits *book* then *boot*, and restores *boog* with Delete. Existing build 10 fresh/replay correction suites and legacy joined/split, suggestions, and typing-session checks were also replayed.

See the [model notes](../../keyboard-engine/MODEL.md) for provenance and how the new scorer works.
