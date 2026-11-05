#!/bin/bash
# Builds the Swift package and wraps it in build/BrowserPOC.app, signed ad hoc.
# Usage: scripts/build.sh [release|debug]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
cd "$ROOT"

# Pin the Xcode SDK so the build doesn't pick up a newer Command Line Tools SDK.
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"

swift build -c "$CONFIG" --disable-keychain --scratch-path "$ROOT/.build"
BIN_DIR="$(swift build -c "$CONFIG" --disable-keychain --scratch-path "$ROOT/.build" --show-bin-path)"

APP="$ROOT/build/BrowserPOC.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/BrowserPOC" "$APP/Contents/MacOS/BrowserPOC"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# llama.cpp ships as a dynamic framework. It goes in Contents/Frameworks, and the binary
# looks there through an extra rpath.
if [ -d "$BIN_DIR/llama.framework" ]; then
  mkdir -p "$APP/Contents/Frameworks"
  cp -R "$BIN_DIR/llama.framework" "$APP/Contents/Frameworks/"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/BrowserPOC" 2>/dev/null || true
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad hoc by default. Ad hoc signatures change on every build, so macOS may ask again for
# permissions like reading Chrome's data. Set SIGN_IDENTITY to a code signing identity
# from your keychain (for example an "Apple Development" certificate) to keep them.
IDENTITY="${SIGN_IDENTITY:--}"
# Copied files can carry extended attributes, which codesign refuses.
xattr -cr "$APP"
if [ -d "$APP/Contents/Frameworks/llama.framework" ]; then
  codesign --force --sign "$IDENTITY" --timestamp=none "$APP/Contents/Frameworks/llama.framework"
fi
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
echo "Built $APP (signed with ${IDENTITY/#-/ad hoc})"
