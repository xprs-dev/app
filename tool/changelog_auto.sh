#!/usr/bin/env bash
# =============================================================================
# changelog_auto.sh <previous-tag> [core-pin] [reticulum-dart-pin] [wapps-pin]
#
# The release's changelog, written from the commits themselves: nobody types
# it, so it cannot be forgotten, and it says what the history says. Prints
# plain lines, one change per line, newest first across all four
# repositories, for
# fastlane/metadata/android/en-US/changelogs/<CODE>.txt. F-Droid shows that
# file as it is; release.yml turns its lines into the bullets the update
# centre shows under "What's new" (the feed copies the release text).
#
# Where it looks: this repository since <previous-tag>, and the three
# repositories a release pins (../core, ../reticulum-dart, ../apps) from the
# commit <previous-tag> pinned to the one given (default: their HEAD).
#
# What it leaves out: commits that touch only documentation, tests, tools or
# changelogs (a change nobody using the app can see), the release's own
# bookkeeping commits, and a subject seen twice.
#
# How much: MAX_WORDS words (default 80) and MAX_CHARS characters (default
# 500, F-Droid's limit), cut at a whole line, and "...and N more changes."
# when anything was cut, so the size is fixed whatever the history holds.
# =============================================================================
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PREV="${1:?usage: changelog_auto.sh <previous-tag> [core-pin] [rd-pin] [wapps-pin]}"
MAX_WORDS="${MAX_WORDS:-80}"
MAX_CHARS="${MAX_CHARS:-500}"

# Paths whose changes nobody sees in the app.
QUIET=(':(exclude)docs' ':(exclude)*.md' ':(exclude)test' ':(exclude)tests'
       ':(exclude)tool' ':(exclude)fastlane' ':(exclude).github'
       ':(exclude)deps' ':(exclude).*-commit')

subjects() { # <repo> <from> <to>
  local repo="$1" from="$2" to="$3"
  [[ -n "$from" && -d "$repo/.git" ]] || return 0
  git -C "$repo" cat-file -e "$from^{commit}" 2>/dev/null || return 0
  git -C "$repo" log --no-merges --format='%ct %s' "$from..$to" -- . "${QUIET[@]}" || true
}

pin_at() { git show "$PREV:$1" 2>/dev/null | tr -d '[:space:]' || true; }

{
  subjects . "$PREV" HEAD
  subjects ../core "$(pin_at .core-commit)" "${2:-HEAD}"
  subjects ../reticulum-dart "$(pin_at .reticulum-dart-commit)" "${3:-HEAD}"
  subjects ../apps "$(pin_at .wapps-commit)" "${4:-HEAD}"
} | sort -rn -k1,1 | cut -d' ' -f2- \
  | { grep -Ev '^(Release v|Changelog for |Merge |Revert "Release|feed: )' || true; } \
  | sed -e 's/[[:space:]]\+$//' -e 's/^[[:space:]]\+//' \
  | awk 'NF && !seen[$0]++' \
  | awk -v maxw="$MAX_WORDS" -v maxc="$MAX_CHARS" '
      { line[NR] = $0 }
      END {
        n = NR; words = 0; chars = 0; kept = 0
        for (i = 1; i <= n; i++) {
          w = split(line[i], _, /[[:space:]]+/)
          c = length(line[i]) + 1
          # Room is kept for the closing line whenever something may follow.
          tail = (i < n) ? 40 : 0
          if (kept > 0 && (words + w > maxw || chars + c + tail > maxc)) break
          if (kept == 0 && (w > maxw || c > maxc)) {
            # One subject alone is too long: its first words.
            out = ""
            m = split(line[i], parts, /[[:space:]]+/)
            for (j = 1; j <= m && j <= maxw; j++) {
              if (length(out) + length(parts[j]) + 2 > maxc - tail - 3) break
              out = out (j > 1 ? " " : "") parts[j]
            }
            line[i] = out "..."
            w = split(line[i], _, /[[:space:]]+/); c = length(line[i]) + 1
          }
          print line[i]; words += w; chars += c; kept++
        }
        if (n == 0) print "Maintenance and small fixes."
        else if (kept < n) printf "...and %d more change%s.\n", n - kept, (n - kept == 1 ? "" : "s")
      }'
