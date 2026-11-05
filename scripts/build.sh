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
# macOS 26 draws the icon from the Icon Composer document, compiled into Assets.car, so it can
# show its dark, clear and tinted looks. The .icns above stays as the fallback.
if [ -d "$ROOT/Resources/AppIcon.icon" ]; then
  ICONTMP="$(mktemp -d)"
  if xcrun actool "$ROOT/Resources/AppIcon.icon" --compile "$ICONTMP" --platform macosx \
       --minimum-deployment-target 26.0 --app-icon AppIcon --output-partial-info-plist "$ICONTMP/partial.plist" \
       --errors >/dev/null 2>&1 && [ -f "$ICONTMP/Assets.car" ]; then
    cp "$ICONTMP/Assets.car" "$APP/Contents/Resources/Assets.car"
  else
    echo "actool couldn't compile Resources/AppIcon.icon; using AppIcon.icns only." >&2
  fi
  rm -rf "$ICONTMP"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad hoc by default. Ad hoc signatures change on every build, so macOS may ask again for
# permissions like reading Chrome's data. Set SIGN_IDENTITY to a code signing identity
# from your keychain (for example an "Apple Development" certificate) to keep them.
# Copied resources can carry extended attributes that codesign refuses.
xattr -cr "$APP"
IDENTITY="${SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
echo "Built $APP (signed with ${IDENTITY/#-/ad hoc})"
