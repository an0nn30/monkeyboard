#!/bin/bash
# Compare with the preserved build 39 output on exactly the same messages.
set -euo pipefail
cd "$(dirname "$0")/../.."
sim="${SIMULATOR_UDID:?Set SIMULATOR_UDID to a booted iPhone simulator}"
work="${1:?Provide a scratch output directory}"
mkdir -p "$work"; work=$(cd "$work" && pwd)
export BENCHMARK_APP="$work/build/Build/Products/Debug-iphonesimulator/MonkeyBoard.app"
export REPLAY_EXECUTABLE="$work/replay"
xcodebuild -project MonkeyBoard.xcodeproj -scheme MonkeyBoard -destination "platform=iOS Simulator,id=$sim" -derivedDataPath "$work/build" build > "$work/build.log"
printf 'id\ttyped\nsmoke\tThe lights are on.\n' > "$work/smoke.tsv"
BENCHMARK_CASES="$work/smoke.tsv" Benchmarks/build17/run.sh > "$work/smoke.jsonl"
xcrun simctl spawn "$sim" "$work/replay" "$BENCHMARK_APP/PlugIns/MonkeyBoardKeyboard.appex" "$PWD/Benchmarks/build40/fresh.json" > "$work/fresh.jsonl"
python3 Benchmarks/build22/blind/score.py Benchmarks/build40/fresh.json \
    --baseline Benchmarks/build40/fresh-39.jsonl.gz --candidate "$work/fresh.jsonl" --report "$work/comparison.json"
