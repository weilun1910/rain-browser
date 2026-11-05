# Rain (proof of concept)

Rain is a Mac browser I'm building, and this repo is its proof of concept.

It's a browser on WebKit where pages and notes you've already seen come back on their own when what you're working on makes them relevant. You don't have to file or pin anything, and everything stays on your Mac.

## Build and run

You need Xcode 26 (or its command line tools) on macOS 26 or later.

From the repo folder:

```
scripts/build.sh        # builds build/BrowserPOC.app (release)
scripts/run.sh          # builds, then opens it
```

The app ends up at `build/BrowserPOC.app`. Quit a running copy before rebuilding.

The build is signed ad hoc, so every build has a different signature. macOS ties some permissions to the signature, so after a rebuild it may ask again before the app can read Chrome's history. To keep that permission across builds, sign with a certificate from your keychain:

```
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" scripts/build.sh
```

To run the app on a separate profile, with its own support folder and its own cookies, pass `--data-dir`. Your normal profile isn't read or touched:

```
build/BrowserPOC.app/Contents/MacOS/BrowserPOC --data-dir ~/Desktop/test-profile
```

Tests and checks from the command line:

```
scripts/selftest.sh                                             # index, notes, sections, splits, spaces, sidebar, command bar and MCP checks
.build/debug/BrowserPOC --smoketest                             # drives the real browser headless, no window on screen
build/BrowserPOC.app/Contents/MacOS/BrowserPOC --chrome-dry-run # what a Chrome import would do, fetches nothing
.build/debug/BrowserPOC --extract-check <url>                   # what capture reads from one public page
.build/debug/BrowserPOC --eval --models-dir <folder>            # resurfacing quality, old pipeline against new
.build/debug/BrowserPOC --notion-dry-run                        # counts and field names from Notion's cache, no content
.build/debug/BrowserPOC --granola-dry-run                       # which Granola files exist and Granola's public sign-in details
.build/debug/BrowserPOC --download-models --data-dir <profile>  # fetch the on-device models into a profile
scripts/mcp-e2e.sh                                              # Claude Code and Codex against a made-up profile, temporary configs only
```

Both tests use throwaway folders and exit non-zero if a check fails. The self test checks delete with a stand-in Trash folder inside its throwaway folder, so your real Trash is never touched. The dry run prints full URLs from your Chrome history, so keep its output to yourself.

## What's in it

The Arc and Zen parts below are built from how those browsers actually behave. The research, with every source and the files I read in Zen's code, is in `notes/research/2026-11-04-arc-zen-features.md` in the project folder.

**Spaces.** Each space has its own pinned items, folders, tabs and splits, a name, an icon or emoji and a colour that lightly tints the sidebar. Switch with the icons at the bottom of the sidebar, Ctrl-1 to Ctrl-9, Cmd-Opt-Left and Right, "Focus on" in the command bar, or a two-finger sideways swipe on the sidebar. Right-click a space icon to rename it, change its icon or colour, move it, set where its new notes go, pick its profile, or delete it. A profile keeps its own cookies and logins, like Arc's profiles, so a Work space can stay signed in to a different account. Deleting asks first and closes that space's tabs. Notes on disk are never touched. Older saved state moves into a space called Home.

**Command bar.** Cmd-T, the New tab button and Ctrl-Shift-= open a search bar in the middle of the window. Nothing is created until you pick something. Esc, a click outside, or a second Cmd-T closes it, and text you'd typed comes back if you press Cmd-T again within 45 seconds. It does four jobs in one field:
- Switch to anything open, in this space or another, including pinned tabs, Essentials and splits. Rows say which space and whether it's in a split.
- Run a command. About 40 actions mix into the results when you type their name, like "new space", "copy link" or "grid". Press Tab on an empty bar, or type "/ ", to list only the actions. They only show when they apply, they show their shortcut, and the ones you pick often rise to the top.
- Open a page. Domains fill in as you type, from your tabs and visits, with the filled part selected. Tab or the right arrow accepts it and Backspace drops it. If a pinned tab is already on that domain, the top hit switches to it.
- Search your notes, folders, past searches and history, here and from Chrome, then Google or a new note.

Enter opens. Option-Enter opens in split view, Shift-Enter in Peek and Cmd-Enter in a background tab. Cmd-L, or clicking the address in the sidebar, opens the bar with the current address, and Enter loads in place.

**Sidebar.** At the top sit Essentials, up to 12 icons shared by every space. Then come the space's pinned items, its folders and its tabs, newest at the top. Every page shows its site's icon, fetched without cookies and cached, with a quiet letter for sites that have none. Drag any row to reorder it or to move it between Pinned, a folder and Tabs. Drag a row onto the space's name to start Essentials. Cmd-click and Shift-click pick several rows, and right-click acts on all of them. Double-click a tab to rename it. Right-click for Duplicate, Mute, Copy link, Archive and more. Folders open and close in place and remember it. A closed folder still shows the tab you're on. Cmd-. moves the keys into the sidebar: arrows move, Return opens, Left and Right close and open folders, Esc leaves.

**Pinned tabs and Essentials.** They remember the page you pinned. If you wander off inside one, a slash shows after its name. Click its icon to go back, or Cmd-click the icon to keep the page you're on in a new tab. Right-click to make the current page the pinned one. Links to other sites open in Peek, so the pinned page stays put. Cmd-W on one goes back to its pinned page, unloads it and moves on, like Zen.

**Tabs and notes.** Notes are items just like tabs. They show in Tabs when open, and you can pin them, put them in sidebar folders next to pages, split them, or move them to another space. Closing a note only takes it out of the sidebar; the file stays and the command bar finds it again. Right-click a note to rename it, reveal it in Finder, or delete it, which asks first and moves the file to the Trash. If a note's file is moved or deleted outside the app, its item shows as missing with Locate and Close. Pages the app draws itself, like History, are items too.

**Split view.** Up to four items share the screen, side by side, stacked or as a grid. Ways in:
- Drag an item from the sidebar near any pane's edge. A preview shows where it lands.
- Drag a tab onto another tab in the sidebar and hold for half a second.
- Option-click a tab in the sidebar, or Option-click a link.
- Pick two to four tabs with Cmd-click and choose Open in split view.
- Ctrl-Shift-=, or Option-Enter in the command bar.

Hover a pane for its controls: a handle to drag it to another pane's edge, Unsplit (Shift-click to stay in the split) and Close. Ctrl-Shift-1 to 4 focus a pane, Ctrl-Shift-[ and ] step through them, and Ctrl-Shift-- unsplits. Every divider drags, and double-clicking one evens it out. A split shows as one joined row in the sidebar, and right-click has Separate, Swap or Rotate, Layout, Pin and Move to space. A split made from a pinned tab stays pinned. The address, back and forward, find, Cmd-L, Cmd-W and the Related panel follow the focused pane. Splits come back after a restart.

**Peek.** Shift-click a link, Shift-Enter in the bar, or click a link to another site from a pinned tab, and the page floats over the one you're on. Cmd-O or the expand button makes it a tab without reloading. The split button puts it next to the page. Esc, a click outside or Cmd-W closes it, and Cmd-Shift-T brings it back.

**Archive and history.** Tabs you haven't looked at for 12 hours move to the Archive, like Arc. Pinned tabs, Essentials, filed tabs, anything on screen and anything playing stay. The Browsing settings change the timing or turn it off. Cmd-Shift-K or Clear archives everything in Tabs at once, with Undo. Cmd-Shift-T reopens the last closed tab with its back and forward history, and History > Recently Closed lists more. Cmd-Y shows every visit by day, with search, delete and clear. Back and forward also come back after a restart.

**Everyday.** Cmd-Shift-C copies the link without tracking parameters, and Cmd-Opt-Shift-C copies it as Markdown. Cmd-F finds in the page with a match count. Cmd-1 to 8 pick a row, counting Essentials and pins first, and Cmd-9 picks the last. Cmd-Opt-Up and Down step through the sidebar. Ctrl-Tab shows recent tabs while you hold Ctrl. Cmd-S hides the sidebar, and it slides back when the pointer reaches the edge. View can put the sidebar on the right. A tab playing sound off screen gets play and mute controls at the bottom of the sidebar, and leaving a playing video asks for picture in picture. Downloads show progress next to Settings and list on their own page.

**Little Arc.** Links you open from other apps get a small window with no sidebar. Cmd-O moves the page into the main window as a tab, without reloading. Cmd-Opt-N opens an empty one to search from.

**Notes folders.** You pick the folders that hold your Markdown notes. Every `.md` file in them is a note you can open and edit here, with autosave and a preview. Hidden folders, `node_modules`, `.build` and `.nosync` folders are left out. New notes go in the space's chosen folder, or the first notes folder. If you haven't picked any, notes live in the app's own folder.

These files may also be edited by other apps while this one is open, so the app is careful:
- Opening, previewing or indexing a note never changes its bytes.
- It writes only after you actually change the text, and only to a `.md` file inside a notes folder.
- Before every save it checks the file on disk. If something else changed it, it doesn't save, and a bar offers Load disk version or Keep mine. If you had no unsaved edits, it just reloads.
- It watches the folders, so new, renamed and changed files show up and get indexed. Files still in iCloud are downloaded and retried.

**Related panel.** The right panel shows things you've seen before that relate to what's in front of you, in two sections. Sites holds pages you read, here or in Chrome. Notes / Docs holds things you write: your notes, Notion pages, Google Docs, Sheets and Slides, sites on the "Sites you write on" list in Settings, and any page where you've typed about 200 characters. Right-click a card to move it to the other section, and that choice is remembered. Each section shows up to 3 cards and has to clear the same fairly high bar, so a section is often empty. The current item and anything opened in the last 10 minutes never show, and Related always looks across every space. Each card has the matching passage and a short reason. The reason starts with when I saw it and what I was doing then, like "You read this on 12 Oct while writing Thesis outline", and then says what it covers. Open, Add to research and Dismiss work as before. With a note in a split, Add to research puts the link in that note.

**How Related picks cards.** Every page and note is cut into passages, and each passage gets a vector from EmbeddingGemma 2, a small embedding model that runs on this Mac. For whatever's in front of me, four searches run at once: keyword search (SQLite's BM25) on the page's own words, keyword search on search queries that Apple's on-device model writes after reading the page, a meaning search over the vectors, and a match on shared names. Reciprocal rank fusion merges them. The top 20 in each section go to Qwen3 Reranker, a cross-encoder that reads each passage next to what I have open and scores how well it fits. Cards that clear the bar easily show within a second or two. Borderline ones only show if Apple's on-device model, asked whether the item would help with what I'm doing right now, doesn't say no. Cards already on screen stay put while they still roughly qualify, and nothing reruns for small edits while I type.

**On-device models.** EmbeddingGemma 2 (310 MB) and Qwen3 Reranker 0.6B (396 MB) run through llama.cpp with Metal. Both are Apache 2.0. The first launch of a profile downloads them in the background, with a progress line in Related and details in Settings, under Models. Downloads resume after a quit and are checked against their published checksums. Until they're ready, Related uses Apple's built-in embedding and keyword scoring, and a background job re-embeds everything once the model arrives. Models are freed after five idle minutes.

**More sources.** Each one has a switch in Settings, under Sources, that says what it reads. All of them are read-only.
- Notion: reads a temp copy of the Notion app's local cache, which holds the pages I've opened in Notion on this Mac, and rebuilds each page's text from its blocks. macOS may ask once, the same way it does for Chrome.
- Google Docs, Sheets and Slides: takes the documents in my history here and in the Chrome import, and refreshes each one's text through its own plain-text export with this browser's Google sign-in. Up to 40 a run, each at most once a day.
- Granola: Granola encrypts its files on the Mac, so this uses Granola's official MCP connection. Connect opens Granola's sign-in in my default browser, with no key to paste, then brings in recent meetings' notes and summaries.

**Capture.** Pages that stay open about five seconds go into a local index with full-text search, sentence vectors and the names in them. Google Docs draw their text on a canvas, so for those the app asks Google for the doc's own text export, from inside your tab, once per load. The typing count only stores how many characters you typed in text areas and editable regions, never what you typed, and ignores search, address and password fields.

**AI clients.** Claude Code, Claude Desktop, Codex and ChatGPT for Mac can read what the browser knows, so they understand what I'm working on and can help keep my notes in shape. The app's binary runs as an MCP server with `--mcp` (add `--data-dir` for another profile). It reads the index without changing it, works while the app is open, and stops when the client closes. The tools:
- `search`, `get_item` and `read_note` find and read my notes, pages, Google Docs, Notion pages and Granola meetings. Search is the same hybrid search Related uses, with the reranker once it's downloaded, and each result says when and in what context I saw it. `get_item` adds the item's topics.
- `related` runs the Related panel's own first pass, for an item or a paragraph of text, against the panel's bar. It leaves out the Foundation Models steps, which take seconds.
- `connections` gives an item's neighbours with the type of each link and why it's there: links in notes, Related lists, closeness in meaning, and the same people or topics.
- `current_context` and `recent_activity` say what I have open now and what I did lately.
- `list_spaces`, `list_notes` and `overview` show how things are organised.

With "Let AI clients edit notes" on in Settings, three more tools can create a note, add to the end of one, and add a link under its Related heading. They follow the same disk rules as the app, and refuse to write if the note changed since the client read it. Settings, under AI clients, has the install steps for each client with copy buttons, a switch for each source (notes, pages, Chrome, Google Docs, Notion, Granola and past searches, which start off), a switch for what I'm working on now, and a log of everything that was served. The Google Docs and Notion switches cover those docs whether they came from their sync or from reading them in the browser. Sign-in links, links with tokens and sites on the never-index list never go out. The packaging is in `integrations/`: a Claude Code plugin with a skill, a Claude Desktop extension, a Codex plugin and config snippet, and the ChatGPT routes. ChatGPT on the web can only reach the Mac through OpenAI's Secure MCP Tunnel, so that route is written up but not set up.

**Chrome import.** It copies Chrome's History file, reads the copy and deletes it. The original is only opened read-only to copy it. It imports the last 90 days, up to 2,000 pages, plus your past searches, and fetches text without cookies for up to 300 of the pages you visited most, skipping anything that looks like a sign-in, token or unsubscribe link and logged-in apps. macOS asks once before this app can read Chrome's data. If the import says it needs your OK, click Allow in the macOS prompt, or open System Settings, go to Privacy & Security, then Files & Folders, find Browser POC and turn on Google Chrome. The import screen has a button for that.

## Not in this version

- No extensions, passkeys or password autofill.
- Folders on disk can't be renamed from the app, and sidebar folders don't nest.
- No live folders, Boosts, link routing between spaces, or sharing a space as a link.
- Picture in picture when you leave a video may need a click in the page first, because WebKit wants a user gesture for it.
- The Granola sync is built against Granola's documented MCP tools but hasn't run against a real account yet.
- The Notion sync reads only what the Notion app keeps on this Mac. Notion's hosted MCP would cover the rest.

## Where things live

- App data: `~/Library/Application Support/BrowserPOC/` (state.json, settings.json, index.sqlite, and Notes/ when no notes folders are chosen). Round 3 adds Models/ (the downloaded models), sources.json (the source switches) and granola-auth.json (the Granola sign-in, readable only by my account). The AI client settings are in mcp.json, the served log in mcp-log.jsonl, and what's on screen in current-context.json.
- Browsing data sits next to it: browser.json (Browsing settings), history.sqlite (visits), closed.json (recently closed and the archive), sessions/ (back and forward for each tab), favicons/ and downloads.json.
- WebKit keeps cookies and caches under `~/Library/WebKit/local.browserpoc` and `~/Library/Caches/local.browserpoc`. Each named profile has its own WebKit store there too.
- Clearing the index removes indexed entries only. Notes stay exactly as they are.

## Code map

- `Sources/BrowserPOC/Browser`: tabs, notes as items, split trees, spaces, WebKit delegates, writing signals, and the Arc and Zen model: sidebar ordering and Essentials (`BrowserModel+Items`), splits (`BrowserModel+Split`), Peek and find (`BrowserModel+Peek`), command bar actions (`BarActions`), history, the archive, favicons, media, downloads, and app pages (`AppPages`, where other parts of the app register a page of their own).
- `Sources/BrowserPOC/Notes`: notes folders, the note document with its disk checks, Markdown preview.
- `Sources/BrowserPOC/Index`: SQLite wrapper, text analysis, the index, hybrid retrieval (`Retrieval.swift`), and the read API for the graph and MCP (`IndexStore+API.swift`: `semanticNeighbours`, `entities`, `topics`, `search`).
- `Sources/BrowserPOC/Intelligence`: llama.cpp wrapper, model downloads, embeddings, the working-context description and judgment with Foundation Models, background re-embedding and topic tagging, and an MCP client with OAuth.
- `Sources/BrowserPOC/Resurfacing`: the Related panel's cards and reasons.
- `Sources/BrowserPOC/Sources`: Chrome import, Notion, Google Docs and Granola sources, URL safety rules, HTML text, the notes indexer and folder watcher.
- `Sources/BrowserPOC/UI`: SwiftUI views, including the command bar, split view and spaces.
- `Sources/BrowserPOC/MCP`: the `--mcp` server, its tools, privacy rules and note writer, the current-context writer and the AI clients Settings pane.
- `Sources/BrowserPOC/Tests`: `--selftest`, `--smoketest` and `--extract-check`.
- `integrations`: the Claude Code, Claude Desktop, Codex and ChatGPT packaging.
