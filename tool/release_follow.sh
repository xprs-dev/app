#!/usr/bin/env bash
# =============================================================================
# release_follow.sh <tag> — take a pushed release tag all the way to the feed.
#
# The three steps live in three repositories and none can start the next one
# (GITHUB_TOKEN cannot dispatch across repositories), so each used to wait for
# its own schedule: xprs-dev/downloads hourly, the feed sync every three hours,
# and GitHub drops scheduled runs when it is busy. v1.9.0 sat on GitHub for
# hours with phones told 1.8.0 was the newest. This drives the chain with the
# local `gh` login instead:
#
#   1. wait for app's release.yml run for the tag to succeed
#   2. dispatch xprs-dev/downloads publish.yml, wait until the APK is served
#   3. dispatch the feed sync for the tag, wait until stable/beta.json name it
#
# release.sh starts it in the background; run it by hand to resume a release
# that stalled. Safe to repeat: each step only dispatches what is missing.
# =============================================================================
set -euo pipefail
TAG="${1:?usage: release_follow.sh vX.Y.Z}"
VER="${TAG#v}"
APP=xprs-dev/app
DL=xprs-dev/downloads
SITE=xprs-dev/xprs-dev.github.io
FILE="https://xprs.dev/downloads/${TAG}/xprs-${VER}-android-arm64-v8a.apk"
# X.Y.0 is stable, X.Y.Z with Z above 0 a beta (releases.md section 4); a
# labelled version is one of the older betas.
[[ "$VER" == *-* || "${VER##*.}" != 0 ]] && FEED=beta.json || FEED=stable.json

say() { echo "$(date '+%H:%M:%S') release_follow $TAG: $*"; }
until_ok() { # <seconds> <description> <command...>
  local limit="$1" what="$2" t=0; shift 2
  until "$@"; do
    (( t >= limit )) && { say "gave up waiting for $what"; exit 1; }
    sleep 30; t=$((t + 30))
  done
}

# 1. The release build.
run_id() {
  gh run list -R "$APP" --workflow release.yml --branch "$TAG" --limit 1 \
    --json databaseId -q '.[0].databaseId // empty'
}
# A function, not `test -n "$(run_id)"`: that argument is expanded once, before
# the loop, so a run that had not started yet was never seen (v1.12.0-beta.4).
has_run() { [[ -n "$(run_id)" ]]; }
until_ok 600 "the release run to start" has_run
say "waiting for release run $(run_id)"
gh run watch "$(run_id)" -R "$APP" --exit-status >/dev/null ||
  { say "release run failed"; exit 1; }

# 2. The downloads site.
served() { curl -sfI -m 20 "$FILE" >/dev/null; }
if ! served; then
  say "dispatching $DL"
  gh workflow run publish.yml -R "$DL"
  until_ok 1800 "$FILE" served
fi
say "files served"

# 3. The feed.
named() {
  curl -s -m 20 "https://xprs.dev/updates/${FEED}?$(date +%s)" |
    grep -q "\"version\": \"${VER}\""
}
if ! named; then
  say "dispatching the feed sync"
  gh workflow run sync.yml -R "$SITE" -f tag="$TAG"
  until_ok 1800 "the feed to name $VER" named
fi
say "done: xprs.dev/updates/${FEED} names ${VER}"
