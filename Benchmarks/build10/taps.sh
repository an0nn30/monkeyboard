#!/bin/bash
set -eu
cd "$(dirname "$0")/../.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
SDKROOT="$sdk" xcrun --sdk iphonesimulator swiftc -sdk "$sdk" -target "$(uname -m)-apple-ios18.0-simulator" -O Keyboard/{KeyboardView,KeyboardModel,KeyPreview}.swift Benchmarks/build10/Taps.swift -o "$work/taps"
xcrun simctl spawn "${SIMULATOR_UDID:-booted}" "$work/taps"
