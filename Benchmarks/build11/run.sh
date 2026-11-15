#!/bin/bash
set -eu
cd "$(dirname "$0")/../.."
root="$PWD/Benchmarks/build11"
out="${1:-$(mktemp -d)}"
mkdir -p "$out"
for suite in pairs texts replay; do
    MB_FIXTURE="$root/$suite.tsv" Benchmarks/run.sh > "$out/build11-$suite.tsv"
    python3 Benchmarks/score.py "$out/build11-$suite.tsv" --baseline "$root/build10-$suite.tsv" --gate
done
python3 "$root/score.py" "$out"
echo "Build 11 run: $out"
