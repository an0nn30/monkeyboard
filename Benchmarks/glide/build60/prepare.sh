#!/usr/bin/env bash
# Fetch and verify the inputs also used to exclude historical data from newer tests.
set -euo pipefail
cd "$(dirname "$0")/../../.."
work=${1:?Pass a data directory}
mkdir -p "$work"
work=$(cd "$work" && pwd)
benchmark="$PWD/Benchmarks/glide/build60"
base=https://huggingface.co/datasets/futo-org/swipe.futo.org/resolve/d71bf5fd7f45b3e7c2ed2d76a21b0dbd3b4ba566
fetch() {
    local name="$1" url="$2"
    shift 2
    if [[ ! -f "$work/$name" ]]; then
        curl -fsSL "$@" "$url" -o "$work/$name"
    fi
}
fetch qwerty.json "$base/swipe-5/layouts/qwerty.json"
fetch original.jsonl "$base/test.jsonl" --range 0-8388607
fetch dev.jsonl "$base/dev.jsonl?mbdev=16m" --range 0-16777215
fetch previous.jsonl "$base/test.jsonl?mbtest=32m" --range 33554432-67108863
fetch train.jsonl "$base/train.jsonl?mb60train=64m" --range 0-67108863
fetch extra.jsonl "$base/train.jsonl?mb60more=128m" --range 134217728-268435455
fetch blind.jsonl "$base/test.jsonl?mb60test=112m" --range 117440512-167772159
(cd "$work" && shasum -a 256 -c "$benchmark/inputs.sha256")
python3 "$benchmark/cohorts.py" "$work/original.jsonl" "$work/dev.jsonl" "$work/previous.jsonl" \
    "$work/train.jsonl" "$work/extra.jsonl" "$work/blind.jsonl" "$work/cohorts"
