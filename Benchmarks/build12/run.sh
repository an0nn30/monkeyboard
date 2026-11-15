#!/bin/bash
set -eu
cd "$(dirname "$0")/../.."
device="${SIMULATOR_UDID:-booted}"
app="$(xcrun simctl get_app_container "$device" dev.dustin.monkeyboard app)"
resources="$app/PlugIns/MonkeyBoardKeyboard.appex"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
arch="$(uname -m)"
lib="$(keyboard-engine/build-ios.sh iphonesimulator "$arch")"
SDKROOT="$sdk" xcrun --sdk iphonesimulator swiftc -O -sdk "$sdk" -target "${arch}-apple-ios18.0-simulator" \
    -I keyboard-engine/include Keyboard/{WordCorrections,SentenceDecoder,KeyboardView,KeyboardModel,KeyPreview}.swift \
    Benchmarks/build12/Review.swift "$lib" -o "$work/review"
fixture="${1:-Benchmarks/build12/review.tsv}"
[[ "$fixture" == /* ]] || fixture="$PWD/$fixture"
xcrun simctl spawn "$device" "$work/review" "$resources" "$fixture"
