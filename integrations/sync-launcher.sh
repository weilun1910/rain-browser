#!/bin/bash
# Copies the launcher into each package, so each one installs on its own.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
for dest in \
  "$DIR/claude-code/plugins/browser-knowledge/scripts" \
  "$DIR/claude-desktop/mcpb/server" \
  "$DIR/codex/plugin/scripts"; do
  mkdir -p "$dest"
  cp "$DIR/launcher/browser-mcp" "$dest/browser-mcp"
  chmod +x "$dest/browser-mcp"
done
# The skill is the same for Claude Code and Codex.
mkdir -p "$DIR/codex/plugin/skills/browser-knowledge"
cp "$DIR/claude-code/plugins/browser-knowledge/skills/browser-knowledge/SKILL.md" "$DIR/codex/plugin/skills/browser-knowledge/SKILL.md"
echo "Launcher and skill copied."
