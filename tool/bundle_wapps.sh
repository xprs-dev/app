#!/usr/bin/env bash
# =============================================================================
# bundle_wapps.sh — rebuild assets/wapps/*.wapp from ../wapps/<name>/
#
# The bundled packages are what a device installs on first run, and what
# upgradeBundledWapps replaces an installed copy with. They are BUILD OUTPUT,
# and they were being edited by hand: after the transport-permission rework the
# source manifests were updated and the bundles were not, so the bundled `mail`
# still declared the pre-gate `network`, and `social` and `xprs` declared
# nothing at all. Under the gate that refuses their imports, and the wapp dies
# on instantiation with "unknown import: hal::<x> has not been defined".
#
# Their versions matched source too, so the upgrade pass — which only fires on
# a strictly newer version — could never repair them. Three wapps shipped dead.
#
# Usage:  tool/bundle_wapps.sh [name ...]     (default: every bundled name)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=../wapps
OUT=assets/wapps

names=("$@")
if [ ${#names[@]} -eq 0 ]; then
  names=()
  for f in "$OUT"/*.wapp; do names+=("$(basename "$f" .wapp)"); done
fi

for n in "${names[@]}"; do
  d="$SRC/$n"
  if [ ! -f "$d/manifest.json" ]; then
    echo "  $n: no source, left as-is"; continue
  fi
  if [ ! -f "$d/app.wasm" ]; then
    echo "  $n: no app.wasm — build it first"; exit 1
  fi
  ver=$(python3 -c "import json;print(json.load(open('$d/manifest.json'))['version'])")
  ( cd "$d" && rm -f /tmp/_bundle.wapp && \
    zip -qr /tmp/_bundle.wapp . -x '*.o' '*.wapp' '.*' 'tests/integration/*' )
  mv /tmp/_bundle.wapp "$OUT/$n.wapp"
  echo "  $n $ver -> $OUT/$n.wapp"
done
