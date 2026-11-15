#!/bin/bash
set -eu
cd "$(dirname "$0")/.."
device="${SIMULATOR_UDID:-booted}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
arch="$(uname -m)"
args=()
if [[ "${1:-}" == --baseline-only ]]; then
    args+=(-D BASELINE_ONLY)
else
    lib="$(keyboard-engine/build-ios.sh iphonesimulator "$arch")"
    args+=(-D BENCHMARK -I keyboard-engine/include Keyboard/{WordCorrections,KeyboardView,KeyboardModel,KeyPreview}.swift "$lib")
fi
SDKROOT="$sdk" xcrun --sdk iphonesimulator swiftc -sdk "$sdk" -target "${arch}-apple-ios18.0-simulator" -O Benchmarks/{Build6WordCorrections,Compare}.swift "${args[@]}" -o "$work/compare"
SIMCTL_CHILD_MB_WINDOW="${MB_WINDOW:-}" SIMCTL_CHILD_MB_DUMP="${MB_DUMP:-}" SIMCTL_CHILD_MB_LAYOUT="${MB_LAYOUT:-joined}" xcrun simctl spawn "$device" "$work/compare" "${MB_FIXTURE:-$PWD/Benchmarks/cases.tsv}"
