#!/bin/bash
# Packs the Claude Desktop extension into integrations/claude-desktop/browser-knowledge.mcpb.
# Needs Node for npx. The bundle holds only the manifest and the launcher, which finds the app,
# so it doesn't go stale when the app is rebuilt.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
"$DIR/../sync-launcher.sh" >/dev/null
npx --yes @anthropic-ai/mcpb validate "$DIR/mcpb/manifest.json"
npx --yes @anthropic-ai/mcpb pack "$DIR/mcpb" "$DIR/browser-knowledge.mcpb"
echo "Packed $DIR/browser-knowledge.mcpb. Double-click it to install in Claude Desktop."
