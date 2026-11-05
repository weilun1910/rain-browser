# ChatGPT

ChatGPT can use the knowledge base in two ways. Which one works depends on where you use ChatGPT.

## ChatGPT for Mac (works today)

The Mac app runs Codex inside it and reads the same `~/.codex/config.toml` as the Codex CLI. So if you set up Codex, the Mac app has it too.

To add it in the app instead:
1. Open Settings, then MCP servers, then Add server.
2. Pick STDIO.
3. Command: the app's binary, for example `/Applications/BrowserPOC.app/Contents/MacOS/BrowserPOC`. Arguments: `--mcp`.
4. Save and restart ChatGPT.

The Browser POC's Settings, under AI clients, shows these values with your real path.

OpenAI documents local servers for Codex and Work threads that run on your Mac. In ordinary Chat threads the tools often don't show up yet (there's an open report at https://github.com/openai/codex/issues/38162). Use a Codex or Work thread.

You can also install the Codex plugin in `../codex`, which brings the skill along: `codex plugin marketplace add <this repo>/integrations/codex`, then install Browser knowledge from the Plugins Directory in the Mac app.

## ChatGPT on the web or your phone

ChatGPT on the web only connects to remote servers over HTTPS. It can't start a program on your Mac.

The safe way to reach the knowledge base from there is OpenAI's Secure MCP Tunnel (https://developers.openai.com/api/docs/guides/secure-mcp-tunnels). A small `tunnel-client` runs on your Mac, makes outbound calls to OpenAI, and hands each request to the same stdio command. Nothing listens on a port and nothing is public. It needs a tunnel id and an API key from your own OpenAI Platform account:

```
tunnel-client init --sample sample_mcp_stdio_local --profile browser --tunnel-id <your tunnel id> \
  --mcp-command "/Applications/BrowserPOC.app/Contents/MacOS/BrowserPOC --mcp"
tunnel-client run --profile browser
```

Then add it in ChatGPT at chatgpt.com/plugins as a custom MCP server using the tunnel.

Things to know before you do this:
- What ChatGPT reads goes through OpenAI's tunnel service. It goes to OpenAI anyway once the model reads it, but it's a step beyond the Mac-only routes.
- Which ChatGPT plans can add custom MCP servers on the web isn't settled in OpenAI's docs as of November 2026.
- Choose what AI clients can see in the Browser POC's Settings first. The served log there shows everything that went out.

Don't put the server behind a public tunnel like ngrok or cloudflared with no authentication. Anyone who learned the address could read your notes. This proof of concept doesn't open a local HTTP port for that reason.

This route wasn't tested for the proof of concept, because it needs your own OpenAI Platform setup.
