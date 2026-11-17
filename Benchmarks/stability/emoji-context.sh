#!/bin/bash
set -eu
cd "$(dirname "$0")/../.."
sim=${SIMULATOR_UDID:?Set SIMULATOR_UDID to a booted simulator}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
lib=$(keyboard-engine/build-ios.sh iphonesimulator "$(uname -m)")
cp Keyboard/Resources/emoji-en.tsv "$work/emoji-en.tsv"
sed 's/^final class KeyboardViewController:/class KeyboardViewController:/' Keyboard/KeyboardViewController.swift > "$work/Controller.swift"
cat Benchmarks/stability/emoji-context.swift >> "$work/Controller.swift"
sources=()
for f in Keyboard/*.swift; do
 [[ "$f" == Keyboard/KeyboardViewController.swift ]] || sources+=("$f")
done
xcrun --sdk iphonesimulator swiftc -sdk "$sdk" -target "$(uname -m)-apple-ios18.0-simulator" -I keyboard-engine/include "${sources[@]}" Shared/*.swift "$work/Controller.swift" "$lib" -o "$work/check"
xcrun simctl spawn "$sim" "$work/check"
