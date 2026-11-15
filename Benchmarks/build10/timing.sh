#!/bin/bash
set -eu
cd "$(dirname "$0")/../.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
arch="$(uname -m)"
lib="$(keyboard-engine/build-ios.sh iphonesimulator "$arch")"
SDKROOT="$sdk" xcrun --sdk iphonesimulator swiftc -parse-as-library -O -sdk "$sdk" -target "$arch-apple-ios18.0-simulator" -I keyboard-engine/include Benchmarks/build10/Timing.swift "$lib" -o "$work/timing"
xcrun simctl spawn "${SIMULATOR_UDID:-booted}" "$work/timing"
