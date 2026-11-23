#!/bin/sh
# Build the C compiler the app bundles for wapps (assets/compiler/):
#
#   cc.wasm     xcc's compiler and linker, compiled to WASI; entered by its
#               xprs_run export, which writes its messages to /tmp/cc.log
#   usr.zip     what it reads at /usr: its headers (include/) and C library
#               (lib/), the XPRS headers (xprs/) and the test runner
#               (xprs/sdk/)
#   LICENSE-xcc.txt
#
#   tool/build_compiler.sh [<apps checkout>]       (default: ../apps)
#
# xcc (https://github.com/tyfkda/xcc, MIT) is taken at the commit in
# .xcc-commit: from $XCC_SRC when set (F-Droid's srclib), else fetched into
# ~/.cache. tool/xcc/xcc.patch is applied to a copy:
#   - an import with __attribute__((import_name)) links by its C name, so
#     hal_log (imported as "log") is not bound to the C library's log()
#   - __attribute__((used)) keeps a static variable (test-case tables)
# It is built natively first (cc), and that build compiles it to WASI.
# Output is byte-for-byte the same on any machine (F-Droid rebuilds it and
# compares). Needs git, a C compiler, make, llvm-ar and python3.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APPS=$(cd "${1:-$ROOT/../apps}" && pwd)
COMMIT=$(cat "$ROOT/.xcc-commit")
OUT="$ROOT/assets/compiler"

AR=$(command -v llvm-ar || ls /usr/bin/llvm-ar-* 2>/dev/null | sort -V | tail -1)
[ -n "$AR" ] || { echo "build_compiler: llvm-ar not found" >&2; exit 1; }

SRC="$XCC_SRC"
if [ -z "$SRC" ]; then
    SRC="${XDG_CACHE_HOME:-$HOME/.cache}/xprs-compiler/xcc-$COMMIT"
    if [ ! -d "$SRC/.git" ]; then
        rm -rf "$SRC"
        git init -q "$SRC"
        git -C "$SRC" fetch -q --depth 1 https://github.com/tyfkda/xcc "$COMMIT"
        git -C "$SRC" checkout -q FETCH_HEAD
    fi
fi
[ "$(git -C "$SRC" rev-parse HEAD)" = "$COMMIT" ] || {
    echo "build_compiler: $SRC is not at $COMMIT" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
git -C "$SRC" archive --prefix=xcc/ HEAD | tar x -C "$WORK"
B="$WORK/xcc"
# (Outside any repository: git apply then patches the files as they are.)
(cd "$B" && GIT_CEILING_DIRECTORIES="$WORK" git apply "$ROOT/tool/xcc/xcc.patch")

# xcc's Makefile calls "llvm-ar" by that name; distros may only have llvm-ar-N.
mkdir "$WORK/bin" && ln -s "$AR" "$WORK/bin/llvm-ar"
PATH="$WORK/bin:$PATH" make -s -C "$B" -j2 wcc >/dev/null
make -s -C "$B" HOST_TARGET=wcc HOST_WCC=./wcc CC=./wcc WCC_TARGET= \
    wcc-self-hosting >/dev/null
# Relinked with the command's entry exported as xprs_run instead of _start:
# the app's runtime runs a _start while instantiating the module, and hands
# over captured output only some time after a call.
cp "$ROOT/tool/xcc/xprs_run.c" "$B/xprs_run.c"
(cd "$B" && ./wcc -c -o obj/xprs_run.o xprs_run.c &&
    ./wcc --entry-point= -e xprs_run -o cc.wasm obj/gen2wcc/*.o obj/xprs_run.o)

U="$WORK/usr"
mkdir -p "$U/lib" "$U/xprs/sdk"
cp -r "$B/include" "$U/include"
cp "$B/lib/wcrt0.a" "$B/lib/wlibc.a" "$U/lib/"
# The XPRS headers as of the wapps the app bundles (.wapps-commit), whatever
# the apps checkout has out.
mkdir "$WORK/apps"
git -C "$APPS" archive "$(cat "$ROOT/.wapps-commit")" hal sdk | tar x -C "$WORK/apps"
cp "$WORK"/apps/hal/*.h "$U/xprs/"
cp "$WORK"/apps/sdk/wapp_test.c "$WORK"/apps/sdk/wapp_test.h \
    "$WORK"/apps/sdk/wapp_i18n.h "$WORK"/apps/sdk/wapp_ai.h \
    "$WORK"/apps/sdk/wapp_json.h "$WORK"/apps/sdk/wapp_page_meta.h "$U/xprs/sdk/"

mkdir -p "$OUT"
cp "$B/cc.wasm" "$OUT/cc.wasm"
cp "$B/LICENSE" "$OUT/LICENSE-xcc.txt"
python3 "$ROOT/tool/xcc/pack_usr.py" "$U" "$OUT/usr.zip"
echo "build_compiler: cc.wasm $(wc -c < "$OUT/cc.wasm") bytes," \
    "usr.zip $(wc -c < "$OUT/usr.zip") bytes"
