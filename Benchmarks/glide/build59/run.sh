#!/usr/bin/env bash
# Rebuild both shipping decoders and score the fixed fresh cohort on iOS Simulator.
set -euo pipefail
cd "$(dirname "$0")/../../.."
device=${1:?Pass the UDID of a booted iPhone simulator}
work=${2:?Pass a directory for downloaded data and results}
mkdir -p "$work"
work=$(cd "$work" && pwd)
benchmark="$PWD/Benchmarks/glide/build59"
base=https://huggingface.co/datasets/futo-org/swipe.futo.org/resolve/d71bf5fd7f45b3e7c2ed2d76a21b0dbd3b4ba566

curl -fsSL "$base/swipe-5/layouts/qwerty.json" -o "$work/qwerty.json"
curl -fsSL --range 0-8388607 "$base/test.jsonl" -o "$work/original.jsonl"
curl -fsSL --range 0-16777215 "$base/dev.jsonl?mbdev=16m" -o "$work/dev.jsonl"
curl -fsSL --range 33554432-67108863 "$base/test.jsonl?mbtest=32m" -o "$work/fresh-range.jsonl"
(cd "$work" && shasum -a 256 -c "$benchmark/inputs.sha256")
python3 "$benchmark/cohort.py" "$work/original.jsonl" "$work/dev.jsonl" "$work/fresh-range.jsonl" "$work/cohorts"

sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
arch=$(uname -m)
for build in 58 59; do
    engine="$work/engine$build"
    mkdir -p "$engine/src"
    cp -R keyboard-engine/src/. "$engine/src/"
    cp keyboard-engine/Cargo.{toml,lock} keyboard-engine/build-ios.sh "$engine/"
    if [[ $build == 58 ]]; then
        cp "$benchmark/baseline/glide.rs" "$engine/src/glide.rs"
    else
        cp "$benchmark/../build60/baseline/glide.rs" "$engine/src/glide.rs"
    fi
    for dataset in model training; do
        ln -sfn "$PWD/keyboard-engine/$dataset" "$engine/$dataset"
    done
    lib=$(MB_ENGINE_OUT="$work/lib$build" "$engine/build-ios.sh" iphonesimulator "$arch")
    xcrun --sdk iphonesimulator swiftc -O -sdk "$sdk" -target "$arch-apple-ios18.0-simulator" \
        -import-objc-header keyboard-engine/include/monkeyboard.h "$benchmark/replay.swift" "$lib" -o "$work/replay$build"
    codesign --force --sign - "$work/replay$build"
    xcrun simctl spawn "$device" "$work/replay$build" "$work/qwerty.json" \
        < "$work/cohorts/fresh.jsonl" > "$work/predictions$build.jsonl"
done
python3 "$benchmark/compare.py" "$work/cohorts/fresh.jsonl" "$work/predictions58.jsonl" \
    "$work/predictions59.jsonl" > "$work/results.json"
