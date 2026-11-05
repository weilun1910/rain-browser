# Browser POC

This is a proof of concept I'm using to test an idea. It isn't the product. I haven't designed anything yet, so the whole UI is placeholder, and the real browser will look and work very differently.

The idea I'm testing is a Mac browser on WebKit where pages and notes you've already seen come back on their own when what you're working on makes them relevant. You don't have to file or pin anything, and everything stays on your Mac.

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
scripts/selftest.sh                                             # index, notes, sections, split, spaces and command bar checks
.build/debug/BrowserPOC --smoketest                             # drives the real browser headless, no window on screen
build/BrowserPOC.app/Contents/MacOS/BrowserPOC --chrome-dry-run # what a Chrome import would do, fetches nothing
.build/debug/BrowserPOC --extract-check <url>                   # what capture reads from one public page
.build/debug/BrowserPOC --eval --models-dir <folder>            # resurfacing quality, old pipeline against new
.build/debug/BrowserPOC --notion-dry-run                        # counts and field names from Notion's cache, no content
.build/debug/BrowserPOC --granola-dry-run                       # which Granola files exist and Granola's public sign-in details
.build/debug/BrowserPOC --download-models --data-dir <profile>  # fetch the on-device models into a profile
```

Both tests use throwaway folders and exit non-zero if a check fails. The self test checks delete with a stand-in Trash folder inside its throwaway folder, so your real Trash is never touched. The dry run prints full URLs from your Chrome history, so keep its output to yourself.

## What's in it

**Spaces.** Each space has its own pinned items, folders, tabs and splits, a name, an icon or emoji and a colour that lightly tints the sidebar. Switch with the icons at the bottom of the sidebar, Ctrl-1 to Ctrl-9, or a two-finger sideways swipe on the sidebar. Right-click a space icon to rename it, change its icon or colour, move it, set where its new notes go, or delete it. Deleting asks first and closes that space's tabs. Notes on disk are never touched. Older saved state moves into a space called Home.

**Command bar.** Cmd-T, the New tab button and Ctrl-Shift-= open a search bar in the middle of the window. Nothing is created until you pick something, and Esc closes it. Suggestions come from what's open in this space, your notes in every space, your past searches, and pages you've visited here or in Chrome, then Search Google and New note. Arrow keys and Enter pick. A typed address shows as Open. Cmd-L, or clicking the address in the sidebar, opens the bar with the current address selected, and Enter loads in place. Searches you run from the bar are remembered, and the Chrome import brings in your Chrome searches too. Settings can clear them.

**Tabs and notes.** Notes are items just like tabs. They show in Tabs when open, and you can pin them, put them in sidebar folders next to pages, split them, or move them to another space. Closing a note only takes it out of the sidebar; the file stays and the command bar finds it again. Right-click a note to rename it, reveal it in Finder, or delete it, which asks first and moves the file to the Trash. If a note's file is moved or deleted outside the app, its item shows as missing with Locate and Close.

**Split view.** Any two items can sit side by side: right-click and pick Open in split view, drag an item onto either half of the page, or press Ctrl-Shift-=. A split shows as one joined row in the sidebar, with Separate and Swap sides on right-click. Click a pane to focus it. The address, back and forward, reload, Cmd-L, Cmd-W and the Related panel all follow the focused pane. Drag the gap to resize and double-click it for half and half. Splits come back after a restart.

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

**Chrome import.** It copies Chrome's History file, reads the copy and deletes it. The original is only opened read-only to copy it. It imports the last 90 days, up to 2,000 pages, plus your past searches, and fetches text without cookies for up to 300 of the pages you visited most, skipping anything that looks like a sign-in, token or unsubscribe link and logged-in apps. macOS asks once before this app can read Chrome's data. If the import says it needs your OK, click Allow in the macOS prompt, or open System Settings, go to Privacy & Security, then Files & Folders, find Browser POC and turn on Google Chrome. The import screen has a button for that.

## Not in this version

- No extensions, passkeys, password autofill, find in page, history view, favicons or profiles.
- Tabs can't be reordered by hand, and folders on disk can't be renamed from the app.
- Back and forward history isn't kept across restarts.
- The Granola sync is built against Granola's documented MCP tools but hasn't run against a real account yet.
- The Notion sync reads only what the Notion app keeps on this Mac. Notion's hosted MCP would cover the rest.

## Where things live

- App data: `~/Library/Application Support/BrowserPOC/` (state.json, settings.json, index.sqlite, and Notes/ when no notes folders are chosen). Round 3 adds Models/ (the downloaded models), sources.json (the source switches) and granola-auth.json (the Granola sign-in, readable only by my account).
- WebKit keeps cookies and caches under `~/Library/WebKit/local.browserpoc` and `~/Library/Caches/local.browserpoc`.
- Clearing the index removes indexed entries only. Notes stay exactly as they are.

## Code map

- `Sources/BrowserPOC/Browser`: tabs, notes as items, splits, spaces, WebKit delegates, writing signals.
- `Sources/BrowserPOC/Notes`: notes folders, the note document with its disk checks, Markdown preview.
- `Sources/BrowserPOC/Index`: SQLite wrapper, text analysis, the index, hybrid retrieval (`Retrieval.swift`), and the read API for the graph and MCP (`IndexStore+API.swift`: `semanticNeighbours`, `entities`, `topics`, `search`).
- `Sources/BrowserPOC/Intelligence`: llama.cpp wrapper, model downloads, embeddings, the working-context description and judgment with Foundation Models, background re-embedding and topic tagging, and an MCP client with OAuth.
- `Sources/BrowserPOC/Resurfacing`: the Related panel's cards and reasons.
- `Sources/BrowserPOC/Sources`: Chrome import, Notion, Google Docs and Granola sources, URL safety rules, HTML text, the notes indexer and folder watcher.
- `Sources/BrowserPOC/UI`: SwiftUI views, including the command bar, split view and spaces.
- `Sources/BrowserPOC/Tests`: `--selftest`, `--smoketest` and `--extract-check`.
