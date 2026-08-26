#!/usr/bin/env bash
# =============================================================================
# release.sh — cut an XPRS release.
#
# Bumps pubspec.yaml, syncs lib/version.dart, commits, tags vX.Y.Z and pushes.
# Pushing the tag is what triggers everything else: release.yml builds the three
# platforms as xprs-<version>-<platform>, the site repo's sync.yml hashes them
# into the xprs.dev feed, and a super-archiver with the mirror enabled seeds
# them over Reticulum. Phones fetch the bytes by sha256 from that station and
# never make an HTTPS request for a binary. See releases.md.
#
# Usage:
#   ./release.sh                 # auto-bump patch (or prerelease counter)
#   ./release.sh 1.2.0           # stable release
#   ./release.sh 1.2.0-beta.1    # beta (pre-release; shows in the beta channel)
#   ./release.sh 1.2.0 -y        # skip confirmation
# =============================================================================
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

YES=0
VERSION=""
for a in "$@"; do
  case "$a" in
    -y|--yes) YES=1 ;;
    *) VERSION="$a" ;;
  esac
done

current=$(grep '^version:' pubspec.yaml | sed 's/version:[[:space:]]*//' | cut -d+ -f1)

# Auto-bump if no version given.
if [[ -z "$VERSION" ]]; then
  if [[ "$current" == *-* ]]; then
    base="${current%-*}"; label="${current##*-}"
    name="${label%.*}"; num="${label##*.}"
    VERSION="${base}-${name}.$((num + 1))"
  else
    IFS=. read -r MA MI PA <<<"$current"
    VERSION="${MA}.${MI}.$((PA + 1))"
  fi
fi

# Validate: X.Y.Z or X.Y.Z-(alpha|beta|rc).N
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$ ]]; then
  echo "error: invalid version '$VERSION' (use X.Y.Z or X.Y.Z-beta.N)"; exit 1
fi

CODE=$(git rev-list --count HEAD)
echo ">> current: $current   new: $VERSION+$CODE"
if [[ "$YES" -ne 1 ]]; then
  read -r -p ">> proceed? [y/N] " ans; [[ "$ans" == "y" || "$ans" == "Y" ]] || exit 1
fi

sed -i "s/^version:.*/version: ${VERSION}+${CODE}/" pubspec.yaml
dart run tool/update_version.dart

git add pubspec.yaml lib/version.dart
git commit -m "Release v${VERSION}"
git tag "v${VERSION}"

branch=$(git rev-parse --abbrev-ref HEAD)
git push origin "$branch"
git push origin "v${VERSION}"

# From here it is automatic. release.yml attaches the artifacts to a GitHub
# Release; the site repo's sync.yml (cron every 3h, or run it manually) hashes
# them into https://xprs.dev/updates/{stable,beta}.json; a super-archiver with
# the mirror on downloads each artifact once and seeds it by content address.
echo ">> done. release.yml is building v${VERSION}."
echo ">>   feed:   gh workflow run sync.yml -R xprs-dev/xprs-dev.github.io"
echo ">>   verify: curl -s https://xprs.dev/updates/beta.json | jq .version"
