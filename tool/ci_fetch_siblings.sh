#!/bin/bash
# tool/ci_fetch_siblings.sh [--pinned]
#
# Clone the path dependencies a CI job needs next to the workspace, where
# pubspec.yaml (and the core's own pubspec) expect them:
#   ../reticulum-dart, ../core       (xprs-dev)
#   ../../x1watt/zx                  (zx, the stores' database; core and
#                                     reticulum-dart reach it as ../../x1watt/zx)
#
# Default: the branches named in tool/ci_siblings.env (main once the branches
# this app branch needs are merged). --pinned: the commits a release pinned
# (.core-commit, .reticulum-dart-commit, .zx-commit, written by release.sh);
# a pin file that does not exist falls back to the branch.
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-}"
# shellcheck source=/dev/null
. tool/ci_siblings.env

fetch() {
  local url="$1" dir="$2" ref="$3" pin="$4"
  if [[ "$mode" == --pinned && -f "$pin" ]]; then
    git clone -q --filter=blob:none "$url" "$dir"
    git -C "$dir" checkout -q "$(cat "$pin")"
  else
    git clone -q --depth 1 --branch "$ref" "$url" "$dir"
  fi
  echo "$dir: $(git -C "$dir" rev-parse --short HEAD)"
}

fetch https://github.com/xprs-dev/reticulum-dart.git ../reticulum-dart \
  "$RETICULUM_REF" .reticulum-dart-commit
fetch https://github.com/xprs-dev/core.git ../core "$CORE_REF" .core-commit
mkdir -p ../../x1watt
fetch https://github.com/x1watt/zx.git ../../x1watt/zx "$ZX_REF" .zx-commit
