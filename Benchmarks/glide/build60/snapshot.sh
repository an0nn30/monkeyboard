#!/usr/bin/env bash
# Assemble the frozen build 60 glide decoder without changing the working tree.
set -euo pipefail
cd "$(dirname "$0")/../../.."
engine=${1:?Pass an absolute scratch path}
[[ "$engine" = /* && "$engine" != "$PWD/keyboard-engine" ]]
mkdir -p "$engine/src"
cp -R keyboard-engine/src/. "$engine/src/"
cp keyboard-engine/Cargo.{toml,lock} keyboard-engine/build-ios.sh "$engine/"
frozen=$PWD/Benchmarks/glide/build60/shipping
cp "$frozen/glide.rs" "$frozen/glide-choice.weights" "$engine/src/"
sed 's|../model/glide-choice.weights|glide-choice.weights|' "$frozen/glide_choice.rs" > "$engine/src/glide_choice.rs"
for data in model training; do
    ln -sfn "$PWD/keyboard-engine/$data" "$engine/$data"
done
