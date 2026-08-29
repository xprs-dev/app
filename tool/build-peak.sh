#!/usr/bin/env bash
# Report the peak resident memory of an Android/Flutter build.
#
# Exists because on this machine "the build died" and "the build used too much
# memory" look identical from the outside: earlyoom is configured to kill
# java/dart/gradle first (--prefer=...), so an over-generous JVM ceiling shows
# up as a build that vanishes mid-flight rather than as an OOM message. This
# turns that into a number you can act on.
#
# Usage:  tool/build-peak.sh ~/bin/android-build-locked ./launch-android.sh
set -u
RUN="$(mktemp -d)"
PEAKFILE="$RUN/peak"
echo 0 > "$PEAKFILE"
touch "$RUN/running"

(
  peak=0
  while [ -f "$RUN/running" ]; do
    t=$(ps -eo rss,args 2>/dev/null |
        grep -aE '[g]radle|[d]artaotruntime|[k]otlin|[j]ava|[a]apt2|[R]8' |
        awk '{s+=$1} END {print s+0}')
    if [ "${t:-0}" -gt "$peak" ]; then peak="$t"; echo "$peak" > "$PEAKFILE"; fi
    sleep 2
  done
) &
SAMPLER=$!

"$@"
STATUS=$?

rm -f "$RUN/running"
wait "$SAMPLER" 2>/dev/null
echo ">> peak build RSS: $(( $(cat "$PEAKFILE") / 1024 )) MB" >&2
rm -rf "$RUN"
exit "$STATUS"
