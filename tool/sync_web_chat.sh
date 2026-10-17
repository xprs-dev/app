#!/bin/sh
# Refresh assets/web_chat/chat_page.html from the sibling repo ../webchat,
# where the page is developed (it is the same page the firmware serves). The
# plain file, not the .gz the build also writes: F-Droid's scanner refuses any
# archive in the source tree. The share server gzips it when it starts.
# Run after changing anything in webchat/page; test/web_chat_page_test.dart
# fails when the bundled copy has drifted.
set -e
HERE="$(cd "$(dirname "$0")/.." && pwd)"
WEB="$HERE/../webchat"
[ -f "$WEB/tool/build.py" ] || { echo "webchat is not checked out next to this repo" >&2; exit 1; }
OUT="$(mktemp -d)"
python3 "$WEB/tool/build.py" --out "$OUT"
mkdir -p "$HERE/assets/web_chat"
rm -f "$HERE/assets/web_chat/chat_page.html.gz"
cp "$OUT/chat_page.html" "$HERE/assets/web_chat/chat_page.html"
rm -rf "$OUT"
