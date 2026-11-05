#!/bin/bash
# Renders the app icon from code (Startup/ArtRenderer.swift): every .icns size through iconutil,
# and an Icon Composer document (Resources/AppIcon.icon) with the loop and the drop as glass
# layers, which scripts/build.sh compiles into Assets.car for macOS 26's light, dark, clear and
# tinted looks. Previews land in .build/icon-art. Run it after changing the mark or the icon.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
swift build -c debug --scratch-path "$ROOT/.build"
OUT="$ROOT/.build/icon-art"
rm -rf "$OUT"
"$ROOT/.build/debug/BrowserPOC" --render-art "$OUT"
iconutil -c icns "$OUT/AppIcon.iconset" -o "$ROOT/Resources/AppIcon.icns"
rm -rf "$ROOT/Resources/AppIcon.icon"
cp -R "$OUT/AppIcon.icon" "$ROOT/Resources/AppIcon.icon"
echo "Wrote Resources/AppIcon.icns and Resources/AppIcon.icon (previews in $OUT)"
