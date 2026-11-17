#!/bin/bash
set -eu
cd "$(dirname "$0")/../.."
sim=${SIMULATOR_UDID:?Set SIMULATOR_UDID to a booted simulator}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun --sdk iphonesimulator swiftc -target "$(uname -m)-apple-ios18.0-simulator" -sdk "$sdk" \
    Keyboard/EmojiCatalog.swift Benchmarks/stability/emoji-suggestions.swift -o "$work/check"
xcrun simctl spawn "$sim" "$work/check" "$PWD/Keyboard/Resources/emoji-en.tsv"
