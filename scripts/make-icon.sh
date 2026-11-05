#!/bin/bash
# Renders the app icon from code (Startup/ArtRenderer.swift) in every size and builds
# Resources/AppIcon.icns with iconutil. Previews of the mark and the launch animation land
# next to the iconset in .build/icon-art. Run it after changing the mark or the icon.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
swift build -c debug --scratch-path "$ROOT/.build"
OUT="$ROOT/.build/icon-art"
rm -rf "$OUT"
"$ROOT/.build/debug/BrowserPOC" --render-art "$OUT"
iconutil -c icns "$OUT/AppIcon.iconset" -o "$ROOT/Resources/AppIcon.icns"
echo "Wrote Resources/AppIcon.icns (previews in $OUT)"
