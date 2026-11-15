#!/bin/bash
# Run the *offline* checkpoint on the same candidate pool. The large weights
# are research artifacts and are never copied into an iPhone target.
set -eu
cd "$(dirname "$0")/../.."
python="${MB_PYTHON:-python3}"
root="$PWD/Benchmarks/build10"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
for suite in fresh replay general dialogue; do
    case "$suite" in
        fresh) old="$root/build9.tsv"; fixture="$root/fresh.tsv";;
        replay) old="$root/build9-replay.tsv"; fixture="$root/replay.tsv";;
        general) old="$root/build9-general.tsv"; fixture="$PWD/Benchmarks/held-out.tsv";;
        dialogue) old="$root/build9-dialogue.tsv"; fixture="$PWD/Benchmarks/texting/dialogue-holdout.tsv";;
    esac
    MB_DUMP="$work/$suite.json" MB_FIXTURE="$fixture" Benchmarks/run.sh > "$work/candidate.tsv"
    for window in 32 4; do
        out="$root/decoder-$suite-$window.tsv"
        "$python" keyboard-engine/training/neural/eval_decoder.py keyboard-engine/research/decoder15m "$work/$suite.json" "$old" "$out" --window "$window" --policy 2.5 2 3
        python3 Benchmarks/score.py "$out" --baseline "$old"
    done
done
