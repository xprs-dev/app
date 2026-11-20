#!/bin/sh
# Put the source dependencies where the build expects them, from the git
# submodules under deps/ (F-Droid's recipe runs this in prebuild, with
# `submodules: true`; fdroiddata asked for submodules in GitHub issue #2).
#
#   deps/reticulum-dart  -> ../reticulum-dart    Dart path dependency
#   deps/core            -> ../core              Dart path dependency
#   deps/zx              -> ../../x1watt/zx      reached by core and
#                                                reticulum-dart at that path
#   deps/apps            -> ../apps              wapp sources (bundled wapps,
#                                                the compiler's headers)
#   deps/xcc             -> ../xcc               the bundled C compiler
#
# Each is a clone of the submodule at its gitlink, which must equal the pin
# file release.sh writes beside it (.reticulum-dart-commit, .core-commit,
# .zx-commit, .wapps-commit, .xcc-commit); the build refuses a mismatch. A
# clone, not a move: a submodule's .git is a relative pointer into the app's
# .git/modules, and the wapp and compiler builds run git in their sources.
#
# deps/ is removed afterwards, so the tree holds one copy of each, the one
# that is built. The steps live here and not in the recipe so that F-Droid's
# checkupdates can copy the recipe's build blocks to a new version unchanged
# when a dependency is added or moved. See docs/f-droid.md.
set -eu
cd "$(dirname "$0")/.."

place() {
  src="deps/$1" dst="$2" pin="$3"
  want=$(cat "$pin")
  have=$(git -C "$src" rev-parse HEAD)
  if [ "$have" != "$want" ]; then
    echo "fdroid_deps: $src is at $have, $pin says $want" >&2
    exit 1
  fi
  rm -rf "$dst"
  mkdir -p "$(dirname "$dst")"
  git -c advice.detachedHead=false clone -q "$src" "$dst"
  git -c advice.detachedHead=false -C "$dst" checkout -q --detach "$want"
  echo "fdroid_deps: $dst at $want"
}

place reticulum-dart ../reticulum-dart .reticulum-dart-commit
place core ../core .core-commit
place zx ../../x1watt/zx .zx-commit
place apps ../apps .wapps-commit
place xcc ../xcc .xcc-commit
rm -rf deps
