#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
sim=${SIMULATOR_UDID:?Specify a booted simulator UUID}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
lib=$(MB_ENGINE_OUT="$work" keyboard-engine/build-ios.sh iphonesimulator "$(uname -m)")
source_view=${KEYBOARD_VIEW_SOURCE:-Keyboard/KeyboardView.swift}
contact_flags=()
if rg -q 'func contactTarget\(at' "$source_view"; then contact_flags+=(-D MB_CONTACT_REPLAY); fi
if rg -q 'var edgeLetterContext:' "$source_view"; then contact_flags+=(-D MB_EDGE_PREFIX_REPLAY); fi
if rg -q 'func nearbyLetters\(at' "$source_view"; then contact_flags+=(-D MB_SPATIAL_CORRECTION); fi
cat "$source_view" Benchmarks/typing-repair/{ReleaseReplay,FingerReplay}.swift > "$work/Replay.swift"
xcrun --sdk iphonesimulator swiftc ${contact_flags[@]+"${contact_flags[@]}"} -O -sdk "$sdk" -target "$(uname -m)-apple-ios18.0-simulator" \
    -I keyboard-engine/include Keyboard/{KeyboardModel,KeyPreview,GlideTrail}.swift Shared/*.swift \
    "$work/Replay.swift" "$lib" -o "$work/replay"
xcrun simctl spawn "$sim" "$work/replay" "$@"
