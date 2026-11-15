#!/usr/bin/env bash
# Replay the recorded regressions and the reserved gestures on a booted iPhone simulator.
set -euo pipefail
cd "$(dirname "$0")/../../.."
device=${1:?Pass a booted simulator UDID}
work=${2:?Pass a directory for downloaded data and reports}
mkdir -p "$work"
work=$(cd "$work" && pwd)
benchmark="$PWD/Benchmarks/glide/build60"
"$benchmark/prepare.sh" "$work"

sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
arch=$(uname -m)
for build in 59 60; do
    engine="$PWD/keyboard-engine"
    if [[ $build == 59 ]]; then
        engine="$work/engine59"
        mkdir -p "$engine/src"
        cp -R keyboard-engine/src/. "$engine/src/"
        cp keyboard-engine/Cargo.{toml,lock} keyboard-engine/build-ios.sh "$engine/"
        cp "$benchmark/baseline/glide.rs" "$engine/src/glide.rs"
        for dataset in model training; do
            ln -sfn "$PWD/keyboard-engine/$dataset" "$engine/$dataset"
        done
    else
        engine="$work/engine60"
        "$benchmark/snapshot.sh" "$engine"
    fi
    lib=$(MB_ENGINE_OUT="$work/lib$build" "$engine/build-ios.sh" iphonesimulator "$arch")
    xcrun --sdk iphonesimulator swiftc -O -sdk "$sdk" -target "$arch-apple-ios18.0-simulator" \
        -import-objc-header keyboard-engine/include/monkeyboard.h "$benchmark/../build59/replay.swift" \
        "$lib" -o "$work/replay$build"
    codesign --force --sign - "$work/replay$build"
    for cohort in regression blind; do
        xcrun simctl spawn "$device" "$work/replay$build" "$work/qwerty.json" \
            < "$work/cohorts/$cohort.jsonl" > "$work/$cohort-$build.jsonl"
    done
done
python3 "$benchmark/check_regressions.py" "$work/cohorts/regression.jsonl" "$work/regression-60.jsonl" \
    "$work/regression-59.jsonl" > "$work/regression.json"
python3 "$benchmark/../build59/compare.py" "$work/cohorts/blind.jsonl" "$work/blind-59.jsonl" \
    "$work/blind-60.jsonl" --builds 59 60 > "$work/results.json"
