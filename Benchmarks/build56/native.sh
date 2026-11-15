#!/bin/bash
# Faster iteration only: feed the native sentence finisher the build 54
# controller's rendered text plus original keys. Full release tests use the simulator.
set -euo pipefail
cd "$(dirname "$0")/../.."
tmp="$1"; out="$2"; mkdir -p "$out/resources"
cargo build --release --manifest-path keyboard-engine/Cargo.toml --lib
cp Keyboard/Resources/{lexical55.tsv,lexical55-context.bin,contextual55-vocab.txt,contextual55-embeddings.bin} "$out/resources/"
xcrun coremlcompiler compile Keyboard/Resources/MBMaskedEncoder.mlpackage "$out/resources" >"$out/compile.log"
swiftc -O -parse-as-library -I keyboard-engine/include Keyboard/{Contextual55,Lexical55,SentenceSurface,SentenceFinisher}.swift Benchmarks/build56/NativeOverlay.swift keyboard-engine/target/release/libmonkeyboard_engine.a -o "$out/probe"
for n in 55 53 54;do
 "$out/probe" "$tmp/$n.json" "$out/resources" > "$out/$n.jsonl"
 gzip -nc "$out/$n.jsonl" >"$out/$n.jsonl.gz"
 python3 Benchmarks/build55/metrics.py "Benchmarks/build$n/holdout/cases.json" "$out/$n.jsonl.gz"
done >"$out/metrics.jsonl"
