#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
sim="${SIMULATOR_UDID:?Set SIMULATOR_UDID to a booted simulator with MonkeyBoard installed}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
arch=$(uname -m)
lib=$(keyboard-engine/build-ios.sh iphonesimulator "$arch")
app=$(xcrun simctl get_app_container "$sim" dev.dustin.monkeyboard app)
extension="$app/PlugIns/MonkeyBoardKeyboard.appex"
for resource in MonkeyDecoder.mlmodelc decoder-vocab.tsv leek-review.bin; do
    ln -s "$extension/$resource" "$tmp/$resource"
done
# Substitute only the host document. Keep the real key path, tasks and model loaders.
sed 's/^final class KeyboardViewController:/class KeyboardViewController:/' Keyboard/KeyboardViewController.swift > "$tmp/Controller.swift"
sed '/^final class ReplayWorker/,$d' Benchmarks/build17/Adapter.swift >> "$tmp/Controller.swift"
cat Benchmarks/stability/pressure.swift >> "$tmp/Controller.swift"
sources=()
for f in Keyboard/*.swift; do
    [[ "$f" == Keyboard/KeyboardViewController.swift ]] || sources+=("$f")
done
xcrun --sdk iphonesimulator swiftc -sdk "$sdk" -target "${arch}-apple-ios18.0-simulator" -I keyboard-engine/include "${sources[@]}" Shared/*.swift "$tmp/Controller.swift" "$lib" -o "$tmp/pressure"
xcrun simctl spawn "$sim" "$tmp/pressure" "$extension"
