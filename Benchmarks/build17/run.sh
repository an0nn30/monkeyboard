#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
device="${SIMULATOR_UDID:?Set the UDID of a booted iPhone simulator}"
app="${BENCHMARK_APP:-$(xcrun simctl get_app_container "$device" dev.dustin.monkeyboard app)}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
arch="$(uname -m)"
lib="$(keyboard-engine/build-ios.sh iphonesimulator "$arch")"
# Test seams only: replace the document and scheduler, skip repaint/strip work.
# Leave insertDelimiter, press, revision scheduling/validation and undo intact.
python3 - "$work/Controller.swift" <<'PY'
from pathlib import Path
import sys
code = Path('Keyboard/KeyboardViewController.swift').read_text()
for before,after in [('final class KeyboardViewController:', 'class KeyboardViewController:'),
                     ('private let decoder = DecoderWorker()', 'private let decoder = ReplayWorker()'),
                     ('        updateKeys()\n        scheduleSuggestions()\n    }\n\n    private func updateKeys', '    }\n\n    private func updateKeys'),
                     ('            self.scheduleSuggestions()\n        }\n    }\n\n    private func undoCorrection','        }\n    }\n\n    private func undoCorrection')]:
    assert code.count(before) == 1, before
    code = code.replace(before,after)
Path(sys.argv[1]).write_text(code+Path('Benchmarks/build17/Adapter.swift').read_text())
PY
python3 - "${BENCHMARK_CASES:-Benchmarks/build17/sentences.tsv}" "$work/input.json" <<'PY'
import csv,json,sys
with open(sys.argv[1]) as f,open(sys.argv[2],'w') as out:
    json.dump(list(csv.DictReader(f,delimiter='\t')),out)
PY
bin="${REPLAY_EXECUTABLE:-$work/replay}"
SDKROOT="$sdk" xcrun --sdk iphonesimulator swiftc -O -sdk "$sdk" -target "${arch}-apple-ios18.0-simulator" \
    -I keyboard-engine/include Keyboard/{WordCorrections,SentenceDecoder,SentenceFinisher,SentenceSurface,Lexical55,Contextual55,KeyboardView,KeyboardModel,KeyPreview}.swift \
    Shared/*.swift "$work/Controller.swift" "$lib" -o "$bin"
xcrun simctl spawn "$device" "$bin" "$app/PlugIns/MonkeyBoardKeyboard.appex" "$work/input.json"
