# AI client integrations

This is part of a proof of concept, not a finished product.

Rain can serve its knowledge base to AI clients over MCP. The app's binary does it with `--mcp`, reading the same profile the app uses (add `--data-dir <dir>` for a separate profile). It reads the index without changing it, and writes to notes only if you turn that on in Settings.

The app's Settings, under AI clients, shows every step below with your app's real path and copy buttons. These folders are what those steps install.

| Client | What to use |
|---|---|
| Claude Code | The plugin in `claude-code/` (server plus a skill), or one `claude mcp add` line |
| Claude Desktop | The extension in `claude-desktop/mcpb/`, packed with `claude-desktop/pack.sh`, or the config entry in `claude-desktop/claude_desktop_config.example.json` |
| Codex CLI | The block in `codex/config.toml.example`, or the plugin in `codex/plugin/` |
| ChatGPT for Mac | The same Codex config or plugin. See `chatgpt/README.md` |
| ChatGPT on the web | Only through OpenAI's Secure MCP Tunnel. See `chatgpt/README.md` |

## Claude Code

```
claude plugin marketplace add <this repo>/integrations/claude-code
claude plugin install browser-knowledge@browser-poc --config app_path=<path to Rain.app>
```

`app_path` is optional. Without it the launcher finds the app on its own. To try it for one session without installing: `claude --plugin-dir <this repo>/integrations/claude-code/plugins/browser-knowledge`.

The plugin's tools show up as `mcp__plugin_browser-knowledge_browser__<tool>`. The skill teaches Claude when to search, how to cite items and how to look after your notes.

## Claude Desktop

Run `claude-desktop/pack.sh` (it needs Node) and double-click `claude-desktop/browser-knowledge.mcpb`. Or open Settings, then Developer, then Edit Config, add the entry from `claude_desktop_config.example.json` with your app's path, and restart Claude.

Claude Desktop's chat doesn't load servers from Claude Code plugins, so it needs one of these two.

## Codex

Add the block from `codex/config.toml.example` to `~/.codex/config.toml`, or run `codex mcp add browser -- <path to the binary> --mcp`. For the plugin with the skill: `codex plugin marketplace add <this repo>/integrations/codex`, then `codex plugin add browser-knowledge@browser-poc`.

Every read tool says `readOnlyHint`, so Codex runs them without asking, in `codex exec` too. `codex/AGENTS.snippet.md` is a short section you can paste into an `AGENTS.md`.

## The launcher

Each package carries a copy of `launcher/browser-mcp`. It finds the app (from `BROWSER_POC_APP`, the copy of the app that last ran, `/Applications`, `~/Applications`, then Spotlight) and starts it with `--mcp`. After editing the launcher or the skill, run `sync-launcher.sh` to update the copies. The self test checks they match.

## Tools

Read tools, always on: `overview`, `search`, `get_item`, `related`, `connections`, `current_context`, `recent_activity`, `list_spaces`, `list_notes`, `read_note`.

Maintenance tools, only when "Let AI clients edit notes" is on: `create_note`, `append_to_note`, `add_link`.

Resources: `browser://overview`, `browser://context/current`, `browser://spaces`, `browser://item/{id}` and `browser://note/{+path}`. Prompts: `what_do_i_know`, `catch_me_up` and `tidy_my_notes`.
