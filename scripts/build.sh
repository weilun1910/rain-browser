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
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP"
