#!/bin/bash
# Rebuild the current simulator candidate, or replay a previously frozen binary.
set -euo pipefail
cd "$(dirname "$0")/../.."
sim="${SIMULATOR_UDID:?Set SIMULATOR_UDID to a booted simulator}"
case "$1" in
  build)
    dir="$2"; mkdir -p "$dir"; dir=$(cd "$dir" && pwd)
    app="$dir/dd/Build/Products/Debug-iphonesimulator/MonkeyBoard.app"
    xcodebuild build -project MonkeyBoard.xcodeproj -scheme MonkeyBoard -destination "platform=iOS Simulator,id=$sim" -derivedDataPath "$dir/dd" > "$dir/xcode.log"
    printf 'id\ttyped\nsmoke\tPlease take a seat.\n' > "$dir/smoke.tsv"
    BENCHMARK_CASES="$dir/smoke.tsv" BENCHMARK_APP="$app" REPLAY_EXECUTABLE="$dir/replay" Benchmarks/build17/run.sh > "$dir/smoke.jsonl"
    ;;
  run)
    # run BINARY EXTENSION FIXTURE OUTPUT.jsonl.gz ; don't produce a partial archive
    tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
    xcrun simctl spawn "$sim" "$2" "$3" "$4" > "$tmp"
    gzip -n -c "$tmp" > "$5"
    ;;
  *) exit 2;;
esac
