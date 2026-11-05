#!/bin/bash
# Builds the Swift package and wraps it in build/BrowserPOC.app, signed ad hoc.
# Usage: scripts/build.sh [release|debug]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
cd "$ROOT"

# Pin the Xcode SDK so the build doesn't pick up a newer Command Line Tools SDK.
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"

swift build -c "$CONFIG" --scratch-path "$ROOT/.build"
BIN_DIR="$(swift build -c "$CONFIG" --scratch-path "$ROOT/.build" --show-bin-path)"

APP="$ROOT/build/BrowserPOC.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/BrowserPOC" "$APP/Contents/MacOS/BrowserPOC"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# The icon is drawn in code; scripts/make-icon.sh renders it into Resources/AppIcon.icns.
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
  echo "Resources/AppIcon.icns is missing. Run scripts/make-icon.sh." >&2
  exit 1
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad hoc by default. Ad hoc signatures change on every build, so macOS may ask again for
# permissions like reading Chrome's data. Set SIGN_IDENTITY to a code signing identity
# from your keychain (for example an "Apple Development" certificate) to keep them.
IDENTITY="${SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
echo "Built $APP (signed with ${IDENTITY/#-/ad hoc})"
