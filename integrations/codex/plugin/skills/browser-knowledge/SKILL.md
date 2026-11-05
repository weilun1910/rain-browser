---
name: browser-knowledge
description: Use the user's Rain knowledge base (their notes, pages they read, Google Docs, Notion pages, Granola meeting notes, how these connect, and what they have open right now) whenever a question touches their own work, projects, meetings, notes, past reading or research, or when they say "I read something about", "my notes", "what did we decide", "what do I know about", "this page" or "what I'm working on". Also use it to keep their notes well linked when they ask.
---

# Using the Browser knowledge base

The `browser` MCP server reads the knowledge base the user's Rain app keeps on their Mac. It covers Markdown notes in their notes folders, pages they read in the app, their Chrome history, Google Docs, Notion pages, Granola meeting notes, the spaces and folders in their sidebar, and what they have open right now. Search and Related use the browser's own on-device ranking. Everything stays on their Mac. Items they hid from AI clients never come back, so don't guess at them.

## When to reach for it

- Before answering anything about the user's own projects, plans, notes, decisions or earlier research. Their notes beat your general knowledge about their work.
- When they refer to something they read, saw or wrote before, even vaguely ("that article about starters", "the doc Meera sent").
- When you're helping them write or think about a topic they've researched. Bring back what they already have instead of starting from zero.
- When they say "this", "the page I have open" or "what I'm working on". Start with `current_context`.
- At the start of a longer task on one of their projects, `overview` and `list_spaces` show how their work is organised.

Don't use it for general questions that have nothing to do with the user.

## Which tool for what

| Need | Tool |
|---|---|
| Find items by words or a question | `search` (filter by `sources`, `kind`, `project`, `since`; `kind: "meeting"` for Granola) |
| Find items near a fuzzy topic or a paragraph | `related` with `text` |
| What relates to one item, the way the browser's Related panel sees it | `related` with `item` |
| How an item connects (links, research, similar, shared names) | `connections`, `depth` 2 for a wider view |
| Read one item | `get_item`, paged with `offset` and `max_chars` |
| A note's exact current Markdown | `read_note` |
| What's open now | `current_context` |
| What they did lately | `recent_activity` |
| Their spaces, pins and folders | `list_spaces` |
| Browse their notes | `list_notes` |

Good order for a topic: `search`, then `related` with the topic as text to catch items that use other words, then `get_item` on the two or three best, then `connections` on the most central one.

## Citing

- Every result has a `cite` field, a ready Markdown link. Use it whenever a point comes from an item.
- Say whether a point comes from the user's own note or doc, a meeting, or a page they read. Their notes are their thinking, meetings are what was agreed, and pages are sources.
- Each result's `history` says when and in what context they saw it, like "You read this on 12 Oct while writing Thesis outline". Use it to tell old reading from current work.
- For notes, the link is a file path on their Mac. That's expected.
- Quote sparingly. Summarise in your own words and link the item.
- If their notes disagree with a page or with what you know, say so plainly instead of picking one silently.

## Keeping their notes in good shape

The maintenance tools (`create_note`, `append_to_note`, `add_link`) only exist when the user turned on "Let AI clients edit notes" in the app's Settings. If they're missing, suggest the change in your answer and let the user make it.

When they are there:
- Ask before writing anything, and show what you'll add.
- Keep the user's own wording. Add, don't rewrite. There's no tool to delete or replace text, on purpose.
- Read the note with `read_note` first and pass its `version` as `expected_version`. If a write is refused because the note changed, read it again and rethink. Never retry blindly; the user or another app may be editing it.
- Use `add_link` to connect a note to pages and notes it relates to. It files links under "## Related", the same place the browser's Add to research button uses.
- Put new notes where the user keeps that kind of note. By default `create_note` uses the folder of the space they're in.
- Good maintenance work: notes that should link to each other, pages that belong in a note's Related list, near-duplicates to point out, open questions and TODOs worth surfacing.
