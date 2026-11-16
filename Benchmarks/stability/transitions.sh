#!/bin/bash
# Run on dedicated, booted, English iPhone simulators with the keyboard enabled.
set -euo pipefail
cd "$(dirname "$0")/../.."
sim=${SIMULATOR_UDID:?Set SIMULATOR_UDID to the main test simulator UUID}
wide=${WIDE_SIMULATOR_UDID:-$sim}
runs=${STABILITY_RUNS:-1}
[[ "$runs" =~ ^[1-9][0-9]*$ ]] || { echo "STABILITY_RUNS must be a positive integer" >&2; exit 2; }
out=${RESULTS_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/monkeyboard-stability.XXXXXX")}
mkdir -p "$out"
out=$(cd "$out" && pwd)
touch "$out/start"
started=$(date '+%Y-%m-%d %H:%M:%S')
echo "Stability results: $out"
for id in "$sim" "$wide"; do
    # A physical iPhone cannot be a destination for this runner.
    xcrun simctl getenv "$id" SIMULATOR_UDID >/dev/null
done
xcodebuild -scheme MonkeyBoard -destination "platform=iOS Simulator,id=$sim" \
    -derivedDataPath "$out/build" -parallel-testing-enabled NO \
    'OTHER_SWIFT_FLAGS=$(inherited) -D MONKEYBOARD_SOUND_BENCHMARK' \
    build-for-testing >"$out/build.log" 2>&1 || { tail -35 "$out/build.log"; exit 1; }
bundles=("$out"/build/Build/Products/MonkeyBoard_iphonesimulator*.xctestrun)
suite=MonkeyBoardUITests/KeyboardStabilityTests
layout=$suite/testSplitAndJoinedLayoutsKeepDraftThroughModeChanges
failed=0
exercise() {
    local id=$1 group=$2
    shift 2
    # Continue to the other group even if a test fails, retaining both result bundles.
    local base="$out/run-$iteration-$group"
    if ! xcodebuild test-without-building -xctestrun "${bundles[0]}" \
        -destination "platform=iOS Simulator,id=$id" -parallel-testing-enabled NO \
        -test-timeouts-enabled YES -default-test-execution-time-allowance 300 \
        -maximum-test-execution-time-allowance 300 \
        -resultBundlePath "$base.xcresult" "$@" >"$base.log" 2>&1; then failed=1; fi
    if [[ -d "$base.xcresult" ]]; then
        xcrun xcresulttool get test-results summary --path "$base.xcresult" >"$base.json"
        python3 - "$base.json" <<'PY' || failed=1
import json, sys
data = json.load(open(sys.argv[1]))
print(f"{sys.argv[1]}: {data['passedTests']} passed, {data['failedTests']} failed, {data['skippedTests']} skipped")
if not data["passedTests"] or data["skippedTests"] or data["failedTests"]:
    sys.exit(1)
PY
    else
        echo "Missing result bundle: $base.xcresult" >&2
        failed=1
    fi
}
for (( iteration=1; iteration<=runs; iteration++ )); do
    if [[ "$wide" == "$sim" ]]; then
        exercise "$sim" all "-only-testing:$suite"
    else
        exercise "$sim" cover "-only-testing:$suite" "-skip-testing:$layout"
        exercise "$wide" wide "-only-testing:$layout"
    fi
done
if ! SIMULATOR_UDID="$sim" Benchmarks/stability/pressure.sh >"$out/memory-pressure.log" 2>&1; then
    tail -12 "$out/memory-pressure.log"
    failed=1
fi
ids=("$sim")
[[ "$wide" == "$sim" ]] || ids+=("$wide")
for id in "${ids[@]}"; do
    # RunningBoard also logs ordinary host dismissals. Preserve its evidence for triage.
    xcrun simctl spawn "$id" log show --start "$started" --style compact --predicate \
        '(process == "runningboardd" OR process == "ReportCrash" OR process == "kernel") AND (eventMessage CONTAINS[c] "monkeyboard.keyboard" OR eventMessage CONTAINS[c] "MonkeyBoardKeyboard") AND (eventMessage CONTAINS[c] "exited" OR eventMessage CONTAINS[c] "termination reason" OR eventMessage CONTAINS[c] "jetsam_reason_memory" OR eventMessage CONTAINS[c] "per-process-limit" OR eventMessage CONTAINS[c] "memorystatus: killing" OR eventMessage CONTAINS[c] "crash report")' \
        >"$out/$id-process.log" || failed=1
done
python3 Benchmarks/stability/check_exits.py "$out" "${ids[@]}" || failed=1
exit "$failed"
