#!/bin/bash
# Run from a checkout with a booted Duo simulator. Outputs go to a temporary directory unless specified.
set -eu
cd "$(dirname "$0")/../.."
out="${1:-$(mktemp -d)}"
mkdir -p "$out"
run() {
    MB_LAYOUT="$2" MB_FIXTURE="$PWD/Benchmarks/$3" Benchmarks/run.sh > "$out/$1.tsv"
    python3 Benchmarks/score.py "$out/$1.tsv" --baseline "Benchmarks/$4" --gate
}
for layout in joined split; do
    for suite in development check; do
        run "$suite-$layout" "$layout" "texting/$suite.tsv" "texting/build7-$suite-$layout.tsv"
    done
    old=build7-comparison.tsv
    if [[ "$layout" == split ]]; then old=build7-split.tsv; fi
    run "original-$layout" "$layout" cases.tsv "$old"
done
run general joined held-out.tsv build7-held-out.tsv
run dialogue joined texting/dialogue-holdout.tsv texting/build7-dialogue.tsv
echo "Results: $out"
