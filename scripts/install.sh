#!/bin/bash
# Builds Rain and puts it in /Applications. Your tabs, history, notes and cookies aren't inside
# the app, so swapping it never touches them, and the new build backs them up the first time it
# opens. Rain has to be closed for the swap, so this waits until you quit it.
# The new build replaces /Applications/Rain.app in place, so there's only ever one Rain in the app
# list. The copy it replaces goes to build.noindex/previous/Rain.app, in case you want to go back,
# and neither that nor the build itself stays on macOS's list of apps.
# Usage: scripts/install.sh [--no-build]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${RAIN_INSTALL_DIR:-/Applications}/Rain.app"
BUILT="$ROOT/build.noindex/Rain.app"
PREVIOUS="$ROOT/build.noindex/previous/Rain.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

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
  mkdir -p "$(dirname "$PREVIOUS")"
  rm -rf "$PREVIOUS"
  mv "$DEST" "$PREVIOUS"
fi
mv "$NEW" "$DEST"
# One Rain on the list of apps: the one in /Applications.
"$LSREGISTER" -u "$PREVIOUS" >/dev/null 2>&1 || true
"$LSREGISTER" -u "$BUILT" >/dev/null 2>&1 || true
"$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :RainBuild' "$DEST/Contents/Info.plist" 2>/dev/null || echo unknown)"
echo "Installed build $BUILD at $DEST."
[ -d "$PREVIOUS" ] && echo "The copy it replaced is in build.noindex/previous/Rain.app."
echo "The first time it opens, it backs up your profile to Backups in ~/Library/Application Support/BrowserPOC."
if pgrep -f "$DEST/Contents/MacOS/BrowserPOC --mcp" >/dev/null 2>&1; then
  echo "AI clients still running Rain's MCP server keep the old build until you restart them."
fi
