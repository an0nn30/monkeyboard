#!/bin/bash
# Replay complete messages through the production key and correction handlers on iOS Simulator.
set -euo pipefail
cd "$(dirname "$0")/../.."
sim=${SIMULATOR_UDID:?Specify a booted simulator UUID}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
arch=$(uname -m)
lib=$(MB_ENGINE_OUT="$work" keyboard-engine/build-ios.sh iphonesimulator "$arch")
app=$(xcrun simctl get_app_container "$sim" dev.dustin.monkeyboard app)
ext="$app/PlugIns/MonkeyBoardKeyboard.appex"
for resource in MonkeyDecoder.mlmodelc decoder-vocab.tsv leek-review.bin; do ln -s "$ext/$resource" "$work/$resource"; done
controller=${CONTROLLER_SOURCE:-Keyboard/KeyboardViewController.swift}
correction_flags=()
if rg -q 'func contactTarget\(at' Keyboard/KeyboardView.swift; then correction_flags+=(-D MB_CONTACT_REPLAY); fi
if rg -q 'func press\(.*nearbyLetters' "$controller"; then correction_flags+=(-D MB_SPATIAL_CORRECTION); fi
sed 's/^final class KeyboardViewController:/class KeyboardViewController:/' "$controller" > "$work/Controller.swift"
sed -e '/^final class ReplayWorker/,$d' -e '/    var text = ""/a\
    var autocapitalizationType: UITextAutocapitalizationType = .sentences\
    var autocorrectionType: UITextAutocorrectionType = .yes\
    var keyboardType: UIKeyboardType = .default
' Benchmarks/build17/Adapter.swift >> "$work/Controller.swift"
cat Benchmarks/typing-repair/FingerSentences.swift >> "$work/Controller.swift"
cat Keyboard/KeyboardView.swift Benchmarks/typing-repair/ReleaseReplay.swift > "$work/KeyboardView.swift"
sources=()
for file in Keyboard/*.swift; do
    case "$file" in
        Keyboard/KeyboardView.swift|Keyboard/KeyboardViewController.swift) ;;
        *) sources+=("$file") ;;
    esac
done
xcrun --sdk iphonesimulator swiftc ${correction_flags[@]+"${correction_flags[@]}"} -O -sdk "$sdk" -target "${arch}-apple-ios18.0-simulator" -I keyboard-engine/include \
    "${sources[@]}" Shared/*.swift "$work/KeyboardView.swift" "$work/Controller.swift" "$lib" -o "$work/sentences"
xcrun simctl spawn "$sim" "$work/sentences" "$ext" "$@"
