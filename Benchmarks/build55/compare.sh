#!/bin/bash
# Run only after the candidate has been frozen and the cohort released.
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${SIMULATOR_UDID:?Set the Duo simulator UDID}"
base="$1"; candidate="$2"; cases="$3"; out="$4"
mkdir -p "$out"; base_ext="$base/dd/Build/Products/Debug-iphonesimulator/MonkeyBoard.app/PlugIns/MonkeyBoardKeyboard.appex"
new_ext="$candidate/dd/Build/Products/Debug-iphonesimulator/MonkeyBoard.app/PlugIns/MonkeyBoardKeyboard.appex"
Benchmarks/build53/replay.sh run "$base/replay" "$base_ext" "$cases" "$out/baseline.jsonl.gz" &
pid=$!
SIMCTL_CHILD_MB_REQUIRE_SENTENCE_MODEL=1 SIMCTL_CHILD_MB_REPLAY_TIMING=1 Benchmarks/build53/replay.sh run "$candidate/replay" "$new_ext" "$cases" "$out/candidate.jsonl.gz" 2>"$out/replay.log"
wait "$pid"
python3 Benchmarks/build55/metrics.py "$cases" "$out/baseline.jsonl.gz" "$out/candidate.jsonl.gz" >"$out/metrics.jsonl"
