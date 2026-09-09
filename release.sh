#!/usr/bin/env bash
# =============================================================================
# release.sh — cut an XPRS release.
#
# Bumps pubspec.yaml, syncs lib/version.dart, commits, tags vX.Y.Z and pushes.
# Pushing the tag is what triggers everything else: release.yml builds the three
# platforms as xprs-<version>-<platform>, the site repo's sync.yml hashes them
# into the xprs.dev feed, and an always-on archiver with the mirror enabled seeds
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

# The tree CI checks out has to compile, and the surest way it does not is an
# import naming a file that never got committed. That is invisible here — the
# file is on disk, so the build and the analyzer are happy — and fatal there.
# It cost v1.2.9: a rename staged in a shared working tree went into a commit
# that meant to change something else, and all three platforms failed on an
# import that had not changed in a release.
dart tool/check_tracked_imports.dart HEAD

sed -i "s/^version:.*/version: ${VERSION}+${CODE}/" pubspec.yaml
dart run tool/update_version.dart

# Commit ONLY the version bump. This working tree may hold somebody else's work
# in progress — pubspec.yaml included — and a release must never carry it. So
# the commit is built from HEAD plus these two files, and the working tree is
# left exactly as it was found.
tmpidx="$(mktemp -u)"
pubblob=$(git show HEAD:pubspec.yaml | sed "s/^version:.*/version: ${VERSION}+${CODE}/" | git hash-object -w --stdin)
verblob=$(git hash-object -w lib/version.dart)
GIT_INDEX_FILE="$tmpidx" git read-tree HEAD
GIT_INDEX_FILE="$tmpidx" git update-index --cacheinfo 100644,"$pubblob",pubspec.yaml
GIT_INDEX_FILE="$tmpidx" git update-index --cacheinfo 100644,"$verblob",lib/version.dart
tree=$(GIT_INDEX_FILE="$tmpidx" git write-tree)
rm -f "$tmpidx"
git update-ref HEAD "$(git commit-tree "$tree" -p HEAD -m "Release v${VERSION}")"
# Keep the real index in step with the new HEAD, or the next `git status` in
# this tree shows a phantom revert of the version.
git update-index --cacheinfo 100644,"$pubblob",pubspec.yaml
git update-index --cacheinfo 100644,"$verblob",lib/version.dart
git tag "v${VERSION}"

branch=$(git rev-parse --abbrev-ref HEAD)
git push origin "$branch"
git push origin "v${VERSION}"

# From here it is automatic. release.yml attaches the artifacts to a GitHub
# Release; the site repo's sync.yml (cron every 3h, or run it manually) hashes
# them into https://xprs.dev/updates/{stable,beta}.json; an always-on archiver with
# the mirror on downloads each artifact once and seeds it by content address.
echo ">> done. release.yml is building v${VERSION}."
echo ">>   feed:   gh workflow run sync.yml -R xprs-dev/xprs-dev.github.io"
echo ">>   verify: curl -s https://xprs.dev/updates/beta.json | jq .version"
