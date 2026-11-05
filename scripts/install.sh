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

# Only the app itself has to close, which runs with no flags. AI clients run Rain's MCP server
# from the same binary (BrowserPOC --mcp) for as long as they're open, and evals and other tools
# run it with flags too. Those keep the old build until they restart, and the swap doesn't
# disturb them.
running() {
  ps -axo command= | awk -v bin="$DEST/Contents/MacOS/BrowserPOC" '$0 == bin || index($0, bin " -psn") == 1 { found = 1 } END { exit !found }'
}
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
if pgrep -f "$DEST/Contents/MacOS/BrowserPOC --mcp" >/dev/null 2>&1; then
  echo "AI clients still running Rain's MCP server keep the old build until you restart them."
fi
