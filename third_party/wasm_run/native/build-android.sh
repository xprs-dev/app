#!/usr/bin/env bash
# Build libwasm_run_dart.so for Android from this crate.
#
#   build-android.sh <ndk-dir> <min-sdk> <jniLibs-out-dir> <abi>...
#
# Called by third_party/wasm_run_flutter/android/build.gradle for the ABIs the
# Flutter build targets. Replaces upstream's CMake step, which downloaded a
# prebuilt library from github.com. See third_party/wasm_run/README.xprs.md.
#
# 64-bit ABIs get wasmtime (Cargo.toml + Cargo.lock). wasmtime has no 32-bit
# ARM or x86 backend, so 32-bit ABIs get the wasmi interpreter
# (Cargo.wasmi.toml + Cargo.wasmi.lock, api_wasmi.rs as api.rs), which is what
# upstream's own release shipped for them.
#
# Both lockfiles are --locked: a build never resolves a dependency anew.
# The cargo target dir is native/target, outside Gradle's build dir, so
# `flutter clean` does not cost a full Rust rebuild.
set -euo pipefail

if [ $# -lt 4 ]; then
    echo "usage: $0 <ndk-dir> <min-sdk> <jniLibs-out-dir> <abi>..." >&2
    exit 2
fi
ndk=$1; api=$2; out=$3; shift 3
here=$(cd "$(dirname "$0")" && pwd)
target_dir=$here/target

prebuilt=("$ndk"/toolchains/llvm/prebuilt/*)
bin=${prebuilt[0]}/bin
[ -x "$bin/clang" ] || { echo "no NDK clang under $ndk" >&2; exit 1; }

# Memory, not cores, is the limit on a small build machine: several heavy
# wasmtime/cranelift crates compiling at once is what pushes it over.
export CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS:-4}

# Copy $1 to $2 only when the bytes differ, so an unchanged tree keeps its
# mtimes and cargo has nothing to rebuild.
sync_file() {
    cmp -s "$1" "$2" 2>/dev/null || { mkdir -p "$(dirname "$2")"; cp "$1" "$2"; }
}

# The wasmi variant is the same crate with another manifest, lockfile and
# engine binding, so it is assembled in a staging copy of the tree.
stage_wasmi() {
    local s=$target_dir/wasmi-src
    local f
    for f in "$here"/src/*.rs; do
        sync_file "$f" "$s/src/$(basename "$f")"
    done
    sync_file "$here/src/api_wasmi.rs" "$s/src/api.rs"
    sync_file "$here/Cargo.wasmi.toml" "$s/Cargo.toml"
    sync_file "$here/Cargo.wasmi.lock" "$s/Cargo.lock"
    echo "$s"
}

for abi in "$@"; do
    case $abi in
        arm64-v8a)   triple=aarch64-linux-android;   cc=aarch64-linux-android;    engine=wasmtime ;;
        x86_64)      triple=x86_64-linux-android;    cc=x86_64-linux-android;     engine=wasmtime ;;
        armeabi-v7a) triple=armv7-linux-androideabi; cc=armv7a-linux-androideabi; engine=wasmi ;;
        x86)         triple=i686-linux-android;      cc=i686-linux-android;       engine=wasmi ;;
        *) echo "unsupported ABI: $abi" >&2; exit 1 ;;
    esac
    if [ $engine = wasmtime ]; then crate=$here; else crate=$(stage_wasmi); fi

    if command -v rustup >/dev/null &&
        ! rustup target list --installed | grep -qx "$triple"; then
        rustup target add "$triple"
    fi

    linker=$bin/$cc$api-clang
    t=$(echo "$triple" | tr 'a-z-' 'A-Z_')
    u=$(echo "$triple" | tr '-' '_')
    echo "wasm_run: $abi ($engine, $triple)"
    env "CARGO_TARGET_${t}_LINKER=$linker" \
        "CC_$u=$linker" \
        "AR_$u=$bin/llvm-ar" \
        cargo build --release --locked \
            --manifest-path "$crate/Cargo.toml" \
            --target "$triple" \
            --target-dir "$target_dir/$engine"
    mkdir -p "$out/$abi"
    cp "$target_dir/$engine/$triple/release/libwasm_run_dart.so" "$out/$abi/"
done
