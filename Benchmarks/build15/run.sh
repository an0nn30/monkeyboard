#!/bin/bash
set -eu
cd "$(dirname "$0")/../.."
device="${SIMULATOR_UDID:-booted}"
app="${BENCHMARK_APP:-$(xcrun simctl get_app_container "$device" dev.dustin.monkeyboard app)}"
resources="$app/PlugIns/MonkeyBoardKeyboard.appex"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
arch="$(uname -m)"
lib="$(keyboard-engine/build-ios.sh iphonesimulator "$arch")"
SDKROOT="$sdk" xcrun --sdk iphonesimulator swiftc -O -sdk "$sdk" -target "${arch}-apple-ios18.0-simulator" \
    -I keyboard-engine/include Keyboard/{WordCorrections,SentenceDecoder,KeyboardView,KeyboardModel,KeyPreview}.swift \
    Benchmarks/build15/Replay.swift "$lib" -o "${REPLAY_EXECUTABLE:-$work/review}"
xcrun simctl spawn "$device" "${REPLAY_EXECUTABLE:-$work/review}" "$resources" "${BENCHMARK_CASES:-$PWD/Benchmarks/build15/cases.tsv}" "$@"
