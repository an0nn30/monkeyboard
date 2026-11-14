#!/bin/bash
set -eu
cd "$(dirname "$0")"
cargo_bin="${CARGO:-${HOME}/.cargo/bin/cargo}"
if [[ ! -x "$cargo_bin" ]]; then cargo_bin=cargo; fi
platform="$1"; shift
out="${MB_ENGINE_OUT:-$PWD/target/apple/$platform}"
mkdir -p "$out"
libs=()
for arch in "$@"; do
    case "$platform:$arch" in
        iphoneos:arm64) target=aarch64-apple-ios ;;
        iphonesimulator:arm64) target=aarch64-apple-ios-sim ;;
        iphonesimulator:x86_64) target=x86_64-apple-ios ;;
        *) echo "Unsupported target: $platform:$arch" >&2; exit 1 ;;
    esac
    CARGO_TARGET_DIR="$PWD/target" IPHONEOS_DEPLOYMENT_TARGET=18.0 "$cargo_bin" build --offline --locked --release --target "$target" >&2
    libs+=("$PWD/target/$target/release/libmonkeyboard_engine.a")
done
xcrun lipo -create "${libs[@]}" -output "$out/libmonkeyboard_engine.a"
echo "$out/libmonkeyboard_engine.a"
