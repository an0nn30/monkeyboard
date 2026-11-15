#!/usr/bin/env bash
# Replay the same recorded paths on the two shipping engine interfaces.
set -euo pipefail
cd "$(dirname "$0")/../../.."
device=${1:?Pass a booted simulator UDID}
work=${2:?Pass a scratch directory}
mkdir -p "$work"
work=$(cd "$work" && pwd)
here="$PWD/Benchmarks/glide/build61"
previous=${3:-$work/previous}
"$here/../build60/prepare.sh" "$previous"
base=https://huggingface.co/datasets/futo-org/swipe.futo.org/resolve/d71bf5fd7f45b3e7c2ed2d76a21b0dbd3b4ba566
if [[ ! -f "$work/train-range.jsonl" ]]; then
    curl -fsSL --range 335544320-469762047 "$base/train.jsonl?mb61train=320m" -o "$work/train-range.jsonl"
fi
if [[ ! -f "$work/test-range.jsonl" ]]; then
    curl -fsSL --range 184549376-251658239 "$base/test.jsonl?mb61test=176m" -o "$work/test-range.jsonl"
fi
(cd "$work" && shasum -a 256 -c "$here/inputs.sha256")
python3 "$here/prepare.py" "$previous" "$work/train-range.jsonl" "$work/test-range.jsonl" "$work/cohorts"
arch=$(uname -m)
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
"$here/../build60/snapshot.sh" "$work/engine60"
for build in 60 61; do
    engine="$PWD/keyboard-engine"
    if [[ $build == 60 ]]; then engine="$work/engine60"; fi
    lib=$(MB_ENGINE_OUT="$work/lib$build" "$engine/build-ios.sh" iphonesimulator "$arch")
    xcrun --sdk iphonesimulator swiftc -O -sdk "$sdk" -target "$arch-apple-ios18.0-simulator" \
        -import-objc-header keyboard-engine/include/monkeyboard.h "$here/../build59/replay.swift" \
        "$lib" -o "$work/replay$build"
    codesign --force --sign - "$work/replay$build"
    for split in regression blind; do
        xcrun simctl spawn "$device" "$work/replay$build" "$previous/qwerty.json" \
            < "$work/cohorts/$split.jsonl" > "$work/$split-$build.jsonl"
    done
done
python3 "$here/score_regression.py" "$work/cohorts/regression.jsonl" "$work/regression-60.jsonl" \
    "$work/regression-61.jsonl" > "$work/regression.json"
python3 "$here/../build59/compare.py" "$work/cohorts/blind.jsonl" "$work/blind-60.jsonl" \
    "$work/blind-61.jsonl" --builds 60 61 > "$work/results.json"
