#!/bin/bash
set -eu
cd "$(dirname "$0")/../.."
sim=${SIMULATOR_UDID:?Set SIMULATOR_UDID to a booted Duo simulator}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun --sdk iphonesimulator swiftc -target "$(uname -m)-apple-ios18.0-simulator" -sdk "$sdk" \
    Keyboard/{KeyboardView,KeyboardModel,KeyPreview,GlideTrail}.swift Shared/*.swift \
    Benchmarks/stability/keyboard-surface.swift -o "$work/check"
xcrun simctl spawn "$sim" "$work/check"
