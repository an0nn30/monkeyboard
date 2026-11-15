#!/bin/bash
set -eu
cd "$(dirname "$0")/../.."
root="$PWD/Benchmarks/build10"
out="${1:-$(mktemp -d)}"
mkdir -p "$out"
for suite in fresh replay; do
    old=build9
    if [[ "$suite" == replay ]]; then old=build9-replay; fi
    for window in full 4; do
        MB_WINDOW="$window" MB_FIXTURE="$root/$suite.tsv" Benchmarks/run.sh > "$out/$suite-$window.tsv"
        python3 Benchmarks/score.py "$out/$suite-$window.tsv" --baseline "$root/$old.tsv"
    done
done
"$root/taps.sh" > "$out/taps.tsv"
"$root/timing.sh" > "$out/timing.txt"
echo "Simulator outputs: $out"
