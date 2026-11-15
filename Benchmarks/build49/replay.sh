#!/bin/bash
# Rebuild the candidate; replay identical fixtures on an already booted simulator.
set -euo pipefail
cd "$(dirname "$0")/../.."
sim="${SIMULATOR_UDID:?Set the UDID of a booted simulator}"
prepared="${1:?Provide the prepared 100k corpus directory}"
work="${2:?Provide a scratch output directory}"
mkdir -p "$work"
work=$(cd "$work" && pwd)
app="$work/build/Build/Products/Debug-iphonesimulator/MonkeyBoard.app"
export BENCHMARK_APP="$app" REPLAY_EXECUTABLE="$work/replay"
xcodebuild -project MonkeyBoard.xcodeproj -scheme MonkeyBoard -destination "platform=iOS Simulator,id=$sim" -derivedDataPath "$work/build" build > "$work/xcode.log"
printf 'id\ttyped\nsmoke\tThe music stopped.\n' > "$work/smoke.tsv"
BENCHMARK_CASES="$work/smoke.tsv" Benchmarks/build17/run.sh > "$work/smoke.jsonl"
ext="$app/PlugIns/MonkeyBoardKeyboard.appex"
for name in fresh regressions practice1 practice2 practice3 public public1 public2; do
    case $name in
        fresh) p=build49/fresh;; regressions) p=build41/regressions;; practice1) p=build41/fresh;;
        practice2) p=build45/fresh;; practice3) p=build47/fresh;; public) p=build49/public;; public1) p=build46/public;; public2) p=build48/public;;
    esac
    xcrun simctl spawn "$sim" "$REPLAY_EXECUTABLE" "$ext" "$PWD/Benchmarks/$p.json" > "$work/$name.jsonl"
done
JOBS=3 Benchmarks/build22/run_full.sh "$sim" "$REPLAY_EXECUTABLE" "$ext" "$prepared" "$work/full"
