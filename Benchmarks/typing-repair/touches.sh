#!/bin/bash
set -eu
cd "$(dirname "$0")/../.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
sim=${SIMULATOR_UDID:?Specify a booted iPhone simulator UUID}
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun --sdk iphonesimulator swiftc -sdk "$sdk" -target "$(uname -m)-apple-ios18.0-simulator" \
    "${1:-Keyboard/KeyboardView.swift}" Keyboard/{KeyboardModel,KeyPreview,GlideTrail}.swift \
    Shared/*.swift Benchmarks/typing-repair/TouchTargets.swift -o "$tmp/touches"
xcrun simctl spawn "$sim" "$tmp/touches"
