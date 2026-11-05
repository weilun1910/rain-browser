## Browser knowledge base

The `browser` MCP server reads the knowledge base my Rain app keeps on this Mac: my Markdown notes, pages I read, Chrome history, Google Docs and Notion pages, how they connect, and what I have open right now.

- Search it before answering anything about my own projects, notes, plans or past reading. My notes beat general knowledge about my work.
- Start with `search`. Use `related` with a paragraph of text for fuzzy topics, `get_item` to read, and `connections` to see what links to what.
- When I say "this" or "what I'm working on", call `current_context` first.
- Cite every item you use with its `cite` link, and say whether it came from my notes or from a page I read.
- Only write to notes if I ask. Read the note with `read_note` first and pass its `version` to `append_to_note` or `add_link`. If a write is refused because the note changed, read it again before doing anything else.
