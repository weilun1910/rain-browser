#!/bin/bash
# End to end with real AI clients: Claude Code and Codex talk to `--mcp` on a throwaway profile
# with made-up content. Uses temporary configs only. Nothing is added to your Claude or Codex
# settings, and your own MCP servers stay off for these runs.
#
# Usage: scripts/mcp-e2e.sh [claude|plugin|codex|write ...]   (all by default)
# Needs `claude` and `codex` on PATH, signed in. Each run uses your normal model quota.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BIN="${BIN:-$ROOT/.build/debug/BrowserPOC}"
[ -x "$BIN" ] || { echo "Build first: swift build --scratch-path .build"; exit 2; }
OUT="$ROOT/tmp/e2e"
rm -rf "$OUT"
mkdir -p "$OUT"
PROFILE="$OUT/profile"
"$BIN" --mcp-fixture "$PROFILE" >/dev/null || { echo "fixture failed"; exit 2; }
WHICH="${*:-claude plugin codex write}"

PROMPT='Use the browser MCP tools only. What do my notes and the pages I read say about my sourdough starter, and what do I have open right now? Name every item you used by its exact title.'
pass=0
fail=0
expect() {
  local name="$1" file="$2"; shift 2
  for w in "$@"; do
    if ! grep -q -- "$w" "$file"; then echo "FAIL  $name: missing \"$w\" in $(basename "$file")"; fail=$((fail + 1)); return; fi
  done
  echo "PASS  $name"; pass=$((pass + 1))
}
served_to() { grep -c "\"client\":\"$1" "$PROFILE/mcp-log.jsonl" 2>/dev/null || echo 0; }

# BROWSERPOC_MODELS_DIR, if set, points the server at downloaded models (the reranker and
# EmbeddingGemma). Without it the server uses Apple's built-in embedding and no reranker.
MODELS_ENV=""
CODEX_ENV=()
if [ -n "${BROWSERPOC_MODELS_DIR:-}" ]; then
  MODELS_ENV=", \"env\": {\"BROWSERPOC_MODELS_DIR\": \"$BROWSERPOC_MODELS_DIR\"}"
  CODEX_ENV=(-c "mcp_servers.browser.env={BROWSERPOC_MODELS_DIR=\"$BROWSERPOC_MODELS_DIR\"}")
  echo "Using models in $BROWSERPOC_MODELS_DIR"
fi

cat > "$OUT/claude-mcp.json" <<EOF
{"mcpServers": {"browser": {"command": "$BIN", "args": ["--mcp", "--data-dir", "$PROFILE"]$MODELS_ENV}}}
EOF

if [[ " $WHICH " == *" claude "* ]]; then
  echo "Claude Code, plain server through --mcp-config ..."
  (cd "$OUT" && claude -p "$PROMPT" --strict-mcp-config --mcp-config "$OUT/claude-mcp.json" \
     --allowedTools "mcp__browser__*" --output-format stream-json --verbose --no-session-persistence) \
     > "$OUT/claude.jsonl" 2> "$OUT/claude.err"
  expect "claude code connects and lists the tools" "$OUT/claude.jsonl" '"name":"browser","status":"connected"' "mcp__browser__search"
  expect "claude code calls the tools" "$OUT/claude.jsonl" '"name":"mcp__browser__'
  expect "claude code answers from the fixture" "$OUT/claude.jsonl" '"type":"result"' "Sourdough plan"
fi

if [[ " $WHICH " == *" plugin "* ]]; then
  echo "Claude Code, the plugin through --plugin-dir ..."
  # A copy of the plugin whose options point at the fixture profile, since --plugin-dir
  # sessions don't ask for userConfig values.
  cp -R "$ROOT/integrations/claude-code/plugins/browser-knowledge" "$OUT/plugin"
  plutil -replace userConfig.app_path.default -string "$BIN" "$OUT/plugin/.claude-plugin/plugin.json"
  plutil -replace userConfig.data_dir.default -string "$PROFILE" "$OUT/plugin/.claude-plugin/plugin.json"
  echo '{"mcpServers": {}}' > "$OUT/empty-mcp.json"
  (cd "$OUT" && claude -p "$PROMPT" --plugin-dir "$OUT/plugin" --strict-mcp-config --mcp-config "$OUT/empty-mcp.json" \
     --allowedTools "mcp__plugin_browser-knowledge_browser__*" --output-format stream-json --verbose --no-session-persistence) \
     > "$OUT/plugin.jsonl" 2> "$OUT/plugin.err"
  expect "the plugin and its skill load" "$OUT/plugin.jsonl" '"name":"browser-knowledge","path"' '"browser-knowledge:browser-knowledge"'
  # --strict-mcp-config also turns off plugin servers, and running without it would start your
  # own MCP servers. So the plugin's server entry runs on its own: its .mcp.json with the
  # variables expanded the way Claude Code expands them, through the plugin's launcher.
  sed -e "s|\${CLAUDE_PLUGIN_ROOT}|$OUT/plugin|g" -e "s|\${user_config.app_path}|$BIN|g" \
      -e "s|\${user_config.data_dir}|$PROFILE|g" "$OUT/plugin/.mcp.json" > "$OUT/plugin-mcp.json"
  (cd "$OUT" && claude -p "$PROMPT" --strict-mcp-config --mcp-config "$OUT/plugin-mcp.json" \
     --allowedTools "mcp__browser__*" --output-format stream-json --verbose --no-session-persistence) \
     > "$OUT/plugin-server.jsonl" 2> "$OUT/plugin-server.err"
  expect "the plugin's server entry starts through the launcher" "$OUT/plugin-server.jsonl" '"name":"browser","status":"connected"'
  expect "the plugin's server answers" "$OUT/plugin-server.jsonl" '"name":"mcp__browser__' "Sourdough plan"
fi

if [[ " $WHICH " == *" codex "* ]]; then
  echo "Codex, codex exec with -c overrides ..."
  (cd "$OUT" && codex exec --skip-git-repo-check --ephemeral --ignore-user-config --json \
     -c "mcp_servers.browser.command=\"$BIN\"" \
     -c "mcp_servers.browser.args=[\"--mcp\", \"--data-dir\", \"$PROFILE\"]" \
     -c 'mcp_servers.browser.startup_timeout_sec=60' -c 'mcp_servers.browser.tool_timeout_sec=120' \
     ${CODEX_ENV[@]+"${CODEX_ENV[@]}"} \
     "$PROMPT") > "$OUT/codex.jsonl" 2> "$OUT/codex.err"
  expect "codex calls the tools without asking" "$OUT/codex.jsonl" '"server":"browser"' '"status":"completed"'
  expect "codex answers from the fixture" "$OUT/codex.jsonl" "Sourdough plan"
fi

if [[ " $WHICH " == *" write "* ]]; then
  echo "Claude Code, note editing turned on ..."
  plutil -replace allowWrites -bool true "$PROFILE/mcp.json"
  WRITE_PROMPT='Use the browser MCP tools only. Read my note "Bread bake log" with read_note, then use append_to_note with its version to add this exact line at the end: "Sunday: tried a longer cold proof." Then add a link from that note to the page "How to feed and maintain a sourdough starter" with add_link. Reply with done.'
  (cd "$OUT" && claude -p "$WRITE_PROMPT" --strict-mcp-config --mcp-config "$OUT/claude-mcp.json" \
     --allowedTools "mcp__browser__*" --output-format stream-json --verbose --no-session-persistence) \
     > "$OUT/write.jsonl" 2> "$OUT/write.err"
  expect "claude code appends to a note" "$PROFILE/Notes 🌱/Bread bake log.md" "Sunday: tried a longer cold proof."
  expect "claude code adds a link under Related" "$PROFILE/Notes 🌱/Bread bake log.md" "## Related" "sourdough-starter-guide"
fi

echo
echo "Served log: $(wc -l < "$PROFILE/mcp-log.jsonl" 2>/dev/null || echo 0) calls, transcripts in $OUT"
echo "$pass passed, $fail failed."
[ "$fail" -eq 0 ]
