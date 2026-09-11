#!/usr/bin/env bash
# =============================================================================
# release.sh — cut an XPRS release.
#
# Bumps pubspec.yaml, syncs lib/version.dart, pins ../reticulum-dart and
# ../wapps by commit, adds the F-Droid changelog copies, commits, tags vX.Y.Z
# and pushes. Pushing the tag is what triggers everything else: release.yml
# builds the three platforms as xprs-<version>-<platform> (Android in F-Droid's
# own buildserver image, so F-Droid reproduces it), xprs-dev/downloads puts them
# on xprs.dev/downloads, the site repo's sync.yml hashes them into the xprs.dev
# feed, and an always-on archiver with the mirror enabled seeds them over
# Reticulum. Phones fetch the bytes by sha256 from that station and make an
# HTTPS request for a binary only when none holds it. See releases.md.
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

# The sibling repositories the release is built from, pinned by commit in the
# release itself. release.yml and F-Droid both check these out, so the two
# build the same bytes (docs/f-droid.md, reproducible builds). A pin must be a
# commit the world can fetch: pushed, on origin/main.
pin_of() {
  local repo="$1" sha
  sha=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" fetch -q origin main
  if ! git -C "$repo" merge-base --is-ancestor "$sha" origin/main; then
    echo "error: $repo HEAD ($sha) is not on origin/main; push it first" >&2
    exit 1
  fi
  if [[ -n "$(git -C "$repo" status --porcelain --untracked-files=no)" ]]; then
    echo "warning: $repo has uncommitted changes; the release pins $sha without them" >&2
  fi
  echo "$sha"
}
RD_PIN=$(pin_of ../reticulum-dart)
WAPPS_PIN=$(pin_of ../wapps)

# F-Droid shows changelogs/<versionCode>.txt, and each per-ABI APK has its own
# versionCode (ABI digit x 1,000,000 + CODE, android/app/build.gradle.kts). The
# notes are written once as <CODE>.txt; the release commit adds the per-ABI
# copies. A notes file named for a stale count (commits landed after it) is
# still found: it is the one added since the last tag.
CL_DIR=fastlane/metadata/android/en-US/changelogs
CL=""
if git cat-file -e "HEAD:$CL_DIR/$CODE.txt" 2>/dev/null; then
  CL="$CL_DIR/$CODE.txt"
elif last_tag=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null); then
  CL=$(git diff --name-only --diff-filter=A "$last_tag" HEAD -- "$CL_DIR" \
    | grep -E '/[0-9]{1,6}\.txt$' | sort -t/ -k6 -n | tail -1 || true)
fi
if [[ -z "$CL" ]]; then
  echo "warning: no $CL_DIR/$CODE.txt; F-Droid will show no changelog for this release" >&2
fi

echo ">> current: $current   new: $VERSION+$CODE"
echo ">> pins: reticulum-dart $RD_PIN, wapps $WAPPS_PIN; changelog: ${CL:-none}"
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
# the commit is built from HEAD plus the files below, and the rest of the
# working tree is left exactly as it was found.
tmpidx="$(mktemp -u)"
pubblob=$(git show HEAD:pubspec.yaml | sed "s/^version:.*/version: ${VERSION}+${CODE}/" | git hash-object -w --stdin)
verblob=$(git hash-object -w lib/version.dart)
# Path to blob, for everything the release commit adds or changes, and the
# paths it removes (a changelog named for a stale count).
declare -A put=( [pubspec.yaml]="$pubblob" [lib/version.dart]="$verblob"
  [.reticulum-dart-commit]=$(echo "$RD_PIN" | git hash-object -w --stdin)
  [.wapps-commit]=$(echo "$WAPPS_PIN" | git hash-object -w --stdin) )
drop=()
if [[ -n "$CL" ]]; then
  clblob=$(git rev-parse "HEAD:$CL")
  put["$CL_DIR/$CODE.txt"]=$clblob
  for digit in 1 2 4; do put["$CL_DIR/$((digit * 1000000 + CODE)).txt"]=$clblob; done
  if [[ "$CL" != "$CL_DIR/$CODE.txt" ]]; then drop+=("$CL"); fi
fi
GIT_INDEX_FILE="$tmpidx" git read-tree HEAD
for p in "${!put[@]}"; do
  GIT_INDEX_FILE="$tmpidx" git update-index --add --cacheinfo 100644,"${put[$p]}","$p"
done
for p in "${drop[@]}"; do GIT_INDEX_FILE="$tmpidx" git update-index --force-remove "$p"; done
tree=$(GIT_INDEX_FILE="$tmpidx" git write-tree)
rm -f "$tmpidx"
git update-ref HEAD "$(git commit-tree "$tree" -p HEAD -m "Release v${VERSION}")"
# Keep the real index and working tree in step with the new HEAD, or the next
# `git status` in this tree shows a phantom revert of the version. Only files
# the release itself owns are written (the pins, the changelog copies).
for p in "${!put[@]}"; do
  git update-index --add --cacheinfo 100644,"${put[$p]}","$p"
  [[ "$p" == pubspec.yaml ]] || git cat-file blob "${put[$p]}" > "$p"
done
for p in "${drop[@]}"; do git update-index --force-remove "$p"; rm -f "$p"; done
git tag "v${VERSION}"

branch=$(git rev-parse --abbrev-ref HEAD)
git push origin "$branch"
git push origin "v${VERSION}"

# From here it is automatic. release.yml attaches the artifacts to a GitHub
# Release; xprs-dev/downloads (cron hourly) publishes them on
# https://xprs.dev/downloads/<tag>/; the site repo's sync.yml (cron every 3h)
# then hashes them into https://xprs.dev/updates/{stable,beta}.json, once the
# files are there; an always-on archiver with the mirror on downloads each
# artifact once and seeds it by content address.
echo ">> done. release.yml is building v${VERSION}. Once it has published:"
echo ">>   files:  gh workflow run publish.yml -R xprs-dev/downloads"
echo ">>   feed:   gh workflow run sync.yml -R xprs-dev/xprs-dev.github.io"
echo ">>   verify: curl -s https://xprs.dev/updates/beta.json | jq .version"
