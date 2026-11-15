#!/usr/bin/env bash
# Run after run.sh, with Python, NumPy, and SciPy available.
set -euo pipefail
cd "$(dirname "$0")/../../.."
work=${1:?Pass the benchmark data directory}
previous=${2:-$work/previous}
here="$PWD/Benchmarks/glide/build61"
py=${PYTHON:-python3}
cargo rustc --offline --locked --release --manifest-path keyboard-engine/Cargo.toml \
    --lib --features glide-training --crate-type cdylib
extract() {
    "$py" "$here/../build60/features.py" keyboard-engine/target/release/libmonkeyboard_engine.dylib \
        "$previous/qwerty.json" "$1" "$work/features-$2.jsonl"
}
extract "$previous/cohorts/training.jsonl" old
extract "$previous/cohorts/extra.jsonl" extra
extract "$work/cohorts/training.jsonl" new
extract "$work/cohorts/regression.jsonl" guards
"$py" "$here/train.py" "$work/features-guards.jsonl" "$work/refit.weights" \
    "$work/features-old.jsonl" "$work/features-extra.jsonl" "$work/features-new.jsonl"
cmp keyboard-engine/model/glide-choice.weights "$work/refit.weights"
