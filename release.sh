#!/usr/bin/env bash
# =============================================================================
# release.sh — cut an XPRS release.
#
# Bumps pubspec.yaml, syncs lib/version.dart, pins ../reticulum-dart, ../core
# and ../apps by commit, adds the F-Droid changelog copies, commits, tags vX.Y.Z
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

# dart comes with Flutter; a non-interactive shell often lacks it on PATH.
if ! command -v dart >/dev/null 2>&1; then
  for d in "${FLUTTER_ROOT:-}/bin" "$HOME/flutter/bin" "$(dirname "$(command -v flutter 2>/dev/null || echo /x)")"; do
    [[ -x "$d/dart" ]] && { PATH="$d:$PATH"; break; }
  done
  command -v dart >/dev/null 2>&1 || { echo "error: dart not found (install Flutter or set FLUTTER_ROOT)"; exit 1; }
fi

YES=0
VERSION=""
LOCK_CHANGED=0
for a in "$@"; do
  case "$a" in
    -y|--yes) YES=1 ;;
    --lock-changed) LOCK_CHANGED=1 ;;   # a deliberate pubspec.lock fix
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

# The build number: the commit count, raised by a fixed base. Each APK's
# versionCode is CODE x 10 plus an ABI digit (android/app/build.gradle.kts),
# and F-Droid asked for the ABI digit in the lowest position. The base keeps
# those codes above the ones already released under the older scheme (up to
# 4000370), which Android would otherwise refuse as a downgrade.
CODE=$(( $(git rev-list --count HEAD) + 400000 ))

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
CORE_PIN=$(pin_of ../core)
ZX_PIN=$(pin_of ../../x1watt/zx)
WAPPS_PIN=$(pin_of ../apps)
# xcc is not ours: its pin moves by hand, in .xcc-commit (the compiler build).
XCC_PIN=$(git show HEAD:.xcc-commit)

# F-Droid shows changelogs/<versionCode>.txt, and each per-ABI APK has its own
# versionCode (CODE x 10 plus an ABI digit, android/app/build.gradle.kts). The
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
# The changelog itself is written from the commits (tool/changelog_auto.sh):
# this repository since the last tag and the pinned siblings since the pins
# that tag recorded, without docs, tests and tools, at most 80 words and
# F-Droid's 500 characters. Nobody writes it, so no release goes out without
# one. A file written by hand ($CL, above) is replaced by it and dropped.
CLBLOB=""
if prev_tag=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null); then
  CLTEXT=$(tool/changelog_auto.sh "$prev_tag" "$CORE_PIN" "$RD_PIN" "$WAPPS_PIN")
  CLBLOB=$(printf '%s\n' "$CLTEXT" | git hash-object -w --stdin)
  echo ">> changelog (from the commits since $prev_tag):"
  printf '%s\n' "$CLTEXT" | sed 's/^/     /'
elif [[ -z "$CL" ]]; then
  echo "warning: no previous tag and no $CL_DIR/$CODE.txt; F-Droid will show no changelog" >&2
fi

# F-Droid builds a release from fdroiddata's recipe and srclibs, not from
# fdroid/ here. A srclib added to the template and not to fdroiddata breaks
# every F-Droid build from this release on, silently (xprs-core for v1.5.0,
# xprs-zx for v1.7.0, xcc for v1.12.0; docs/f-droid.md section 2).
for s in fdroid/srclibs/*.yml; do
  [[ -e "$s" ]] || continue
  n=$(basename "$s")
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    "https://gitlab.com/fdroid/fdroiddata/-/raw/master/srclibs/$n" || echo 000)
  if [[ "$code" == 404 ]]; then
    echo "warning: srclibs/$n is not in fdroiddata: F-Droid cannot build this" >&2
    echo "         release until an fdroiddata MR adds it (docs/f-droid.md section 2)" >&2
  fi
done

echo ">> current: $current   new: $VERSION+$CODE"
echo ">> pins: reticulum-dart $RD_PIN, core $CORE_PIN, zx $ZX_PIN, wapps $WAPPS_PIN, xcc $XCC_PIN"
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

# The lock file must be the one F-Droid's pinned Flutter resolved. A local
# `flutter test` or `flutter build` with another Flutter rewrites it, the
# build then fails `pub get --enforce-lockfile` in the buildserver, and the
# release has to be cut again (v1.3.0 and v1.3.4 both died this way). A lock
# change is legitimate only when pubspec.yaml changed too.
if [[ "$LOCK_CHANGED" -ne 1 ]] && last_tag=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null); then
  if ! git diff --quiet "$last_tag" HEAD -- pubspec.lock && \
     git diff --quiet "$last_tag" HEAD -- pubspec.yaml; then
    echo "error: pubspec.lock changed since $last_tag with no change to pubspec.yaml;" >&2
    echo "       restore it (git show $last_tag:pubspec.lock > pubspec.lock) before releasing" >&2
    exit 1
  fi
fi

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
  [.core-commit]=$(echo "$CORE_PIN" | git hash-object -w --stdin)
  [.zx-commit]=$(echo "$ZX_PIN" | git hash-object -w --stdin)
  [.wapps-commit]=$(echo "$WAPPS_PIN" | git hash-object -w --stdin) )
# The same pins as git submodules under deps/ (mode 160000), which F-Droid's
# build checks out (recipe `submodules: true`, tool/fdroid_deps.sh). They need
# no checkout here: only the gitlink is written.
declare -A link=( [deps/reticulum-dart]="$RD_PIN" [deps/core]="$CORE_PIN"
  [deps/zx]="$ZX_PIN" [deps/apps]="$WAPPS_PIN" [deps/xcc]="$XCC_PIN" )
drop=()
clblob="$CLBLOB"
if [[ -z "$clblob" && -n "$CL" ]]; then clblob=$(git rev-parse "HEAD:$CL"); fi
if [[ -n "$clblob" ]]; then
  put["$CL_DIR/$CODE.txt"]=$clblob
  for digit in 1 2 3; do put["$CL_DIR/$((CODE * 10 + digit)).txt"]=$clblob; done
  if [[ -n "$CL" && "$CL" != "$CL_DIR/$CODE.txt" ]]; then drop+=("$CL"); fi
fi
GIT_INDEX_FILE="$tmpidx" git read-tree HEAD
for p in "${!put[@]}"; do
  GIT_INDEX_FILE="$tmpidx" git update-index --add --cacheinfo 100644,"${put[$p]}","$p"
done
for p in "${!link[@]}"; do
  GIT_INDEX_FILE="$tmpidx" git update-index --add --cacheinfo 160000,"${link[$p]}","$p"
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
for p in "${!link[@]}"; do
  git update-index --add --cacheinfo 160000,"${link[$p]}","$p"
  mkdir -p "$p"
done
for p in "${drop[@]}"; do git update-index --force-remove "$p"; rm -f "$p"; done
git tag "v${VERSION}"

branch=$(git rev-parse --abbrev-ref HEAD)
git push origin "$branch"
git push origin "v${VERSION}"

# release.yml attaches the artifacts to a GitHub Release; xprs-dev/downloads
# publishes them on https://xprs.dev/downloads/<tag>/; the site repo's sync.yml
# hashes them into https://xprs.dev/updates/{stable,beta}.json; an always-on
# archiver with the mirror on downloads each artifact once and seeds it by
# content address. Those two repositories only run on a schedule (GitHub drops
# scheduled runs when busy, and no token here can dispatch across repos), so
# tool/release_follow.sh drives them with the local gh login as soon as the
# release is built. Without it, phones are told the old version for hours.
log="${TMPDIR:-/tmp}/xprs-release-follow-v${VERSION}.log"
nohup tool/release_follow.sh "v${VERSION}" >"$log" 2>&1 &
echo ">> done. release.yml is building v${VERSION}; the feed follows on its own"
echo ">>   (tool/release_follow.sh, log: $log)."
