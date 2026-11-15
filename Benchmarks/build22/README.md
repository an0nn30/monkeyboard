# Full-sentence autocorrect on iPhone Duo Simulator

Compare each candidate to the frozen build 21 keyboard on the same keystrokes. Every row in the desktop S:/C: file is scored, including duplicates. The original split puts 84,816 pairs into training and 15,184 in the reserved partition, grouped by normalized reference. Every reserved reference had appeared in earlier benchmarks. Neither the whole-file nor the reserved score estimates accuracy on unfamiliar conversations.

The two independently frozen sets contain 356 fresh complete messages each (236 noisy, 120 deliberately unchanged). The review set guided development. The final set scores one frozen candidate. Cases include short words, wrong dictionary words, missing spaces, multiple errors, contractions, names, slang and deliberate casing. The SMS references are human-written with injected mistakes; the remaining cases are original challenges. See [data, exclusions and scoring](blind/README.md) and the [training overlap audit](blind/source-audit.json).

The keyboard continues to use build 21’s 15M Core ML transformer. This round trains additional Rust models alongside it: a character spelling network, an edit and spacing decoder, a short-word bidirectional neural model, and conversational spelling and phrase rankers. Weights and aggregate counts are fitted offline. No live typing log was added. We did not retrain the next-word transformer in this experiment.

## Reproduce

Run from the repository root on a Mac with Xcode and the Rust simulator targets installed. The replay uses the production controller, Rust library and Core ML decoder; an in-memory document and deterministic review scheduler stand in for a host. Installed-extension UI tests separately exercise key taps, host text and undo. Neither simulation measures physical touch accuracy.

~~~sh
export SIMULATOR_UDID=YOUR_BOOTED_SIMULATOR_UDID
work=$(mktemp -d)
python3 Benchmarks/build22/prepare.py ~/Desktop/typo_sentences.md "$work"
xcodebuild -project MonkeyBoard.xcodeproj -scheme MonkeyBoard -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" -derivedDataPath "$work/build" build
export BENCHMARK_APP="$work/build/Build/Products/Debug-iphonesimulator/MonkeyBoard.app"
export REPLAY_EXECUTABLE="$work/replay" BENCHMARK_CASES="$work/dev.tsv"
Benchmarks/build17/run.sh > "$work/dev-output.jsonl"
extension="$BENCHMARK_APP/PlugIns/MonkeyBoardKeyboard.appex"
Benchmarks/build22/run_full.sh "$SIMULATOR_UDID" "$work/replay" "$extension" "$work" "$work/output"
python3 Benchmarks/build22/blind/score.py "$work/all.json" --baseline Benchmarks/build22/blind/desktop-100k-21.jsonl.gz --candidate "$work/output/replay.jsonl.gz" --report "$work/comparison.json"
python3 Benchmarks/build22/slices.py "$work/all.json" Benchmarks/build22/blind/desktop-100k-21.jsonl.gz "$work/output/replay.jsonl.gz" "$work/slices.json"
~~~

For either fresh fixture, pass its JSON directly to the simulator replay binary with the extension path. The scorer requires each case exactly once. See the [trainers](../../keyboard-engine/training) and [build 21 sources](../build21/README.md).
