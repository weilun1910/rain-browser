#!/bin/bash
# Builds Rain and puts it in /Applications. Your tabs, history, notes and cookies aren't inside
# the app, so swapping it never touches them, and the new build backs them up the first time it
# opens. Rain has to be closed for the swap, so this waits until you quit it.
# The copy it replaces goes to build/previous/Rain.app, in case you want to go back.
# Usage: scripts/install.sh [--no-build]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${RAIN_INSTALL_DIR:-/Applications}/Rain.app"
BUILT="$ROOT/build/Rain.app"

if [ "${1:-}" != "--no-build" ]; then
  "$ROOT/scripts/build.sh" release
fi
[ -d "$BUILT" ] || { echo "No build at $BUILT. Run scripts/build.sh first." >&2; exit 1; }

running() { pgrep -f "$DEST/Contents/MacOS/BrowserPOC" >/dev/null 2>&1; }
if running; then
  echo "Rain is open. Quit it (Cmd-Q) and the new build goes in."
  while running; do sleep 2; done
fi

# Copied without iCloud's extended attributes, so the signature checks out and macOS doesn't
# treat it as downloaded.
NEW="$DEST.installing"
rm -rf "$NEW"
ditto --noextattr --noqtn "$BUILT" "$NEW"
xattr -cr "$NEW"
codesign --verify --deep --strict "$NEW"

if [ -d "$DEST" ]; then
  mkdir -p "$ROOT/build/previous"
  rm -rf "$ROOT/build/previous/Rain.app"
  mv "$DEST" "$ROOT/build/previous/Rain.app"
fi
mv "$NEW" "$DEST"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :RainBuild' "$DEST/Contents/Info.plist" 2>/dev/null || echo unknown)"
echo "Installed build $BUILD at $DEST."
[ -d "$ROOT/build/previous/Rain.app" ] && echo "The copy it replaced is in build/previous/Rain.app."
echo "The first time it opens, it backs up your profile to Backups in ~/Library/Application Support/BrowserPOC."
