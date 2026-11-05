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
scripts/selftest.sh                                             # index, notes, sections, splits, spaces, sidebar, command bar, Related shelf, MCP and look checks
.build/debug/BrowserPOC --smoketest                             # drives the real browser headless, no window on screen
build/BrowserPOC.app/Contents/MacOS/BrowserPOC --chrome-dry-run # what a Chrome import would do, fetches nothing
.build/debug/BrowserPOC --extract-check <url>                   # what capture reads from one public page
.build/debug/BrowserPOC --eval --models-dir <folder>            # resurfacing quality, old pipeline against new
.build/debug/BrowserPOC --notion-dry-run                        # counts and field names from Notion's cache, no content
.build/debug/BrowserPOC --granola-dry-run                       # which Granola files exist and Granola's public sign-in details
.build/debug/BrowserPOC --download-models --data-dir <profile>  # fetch the on-device models into a profile
.build/debug/BrowserPOC --render-review <dir>                   # light and dark snapshots of every main view, offscreen
scripts/make-icon.sh                                            # redraws the app icon from code
.build/debug/BrowserPOC --shelf-demo --data-dir <folder>        # plays the Related shelf's motion in a window, on a throwaway profile
scripts/mcp-e2e.sh                                              # Claude Code and Codex against a made-up profile, temporary configs only
build/BrowserPOC.app/Contents/MacOS/BrowserPOC --graph-bench    # the graph's 5,000 node timings on a release build
```

Both tests use throwaway folders and exit non-zero if a check fails. The self test checks delete with a stand-in Trash folder inside its throwaway folder, so your real Trash is never touched. The dry run prints full URLs from your Chrome history, so keep its output to yourself.

## Demo profile

To play with Related and the graph without my own data, `scripts/demo.sh` builds the app, makes a demo profile and opens a separate copy of the app on it. The profile belongs to Theo Park, a made-up Yale student. He's writing a seminar paper, building a textbook swap app with a friend, applying for PM internships and planning a trip to Japan. Everyone in it is made up. The web pages are real, so tabs open the actual page. What to try is in `Demo/SCENARIOS.md`.

```
scripts/demo.sh                     # seeds the profile the first time, then opens it
scripts/demo.sh --reset             # starts the profile over; changes made in it are lost
scripts/demo.sh --models <folder>   # copies verified model files in instead of downloading them
```

The profile lives in `demo-profile.nosync` in the project folder. The script only writes to an empty folder or to a demo profile it made before, and never to my real support folder. Seeding copies the notes in as real Markdown files, indexes the demo Google Docs, Notion pages and Granola meetings as those sources, records six weeks of visits and searches, reads each page's text without cookies, embeds and tags everything, builds the graph and lays out four spaces with Essentials, pins, folders, tabs and splits. Times move so the demo's "now" is the moment it was seeded. Outside sources stay off in the demo profile, and auto-archive is off so the layout stays put.

The demo docs and meetings open at `demo://` addresses as read-only pages drawn by the app, so nothing ever loads a real Google or Notion page.

```
BrowserPOC --seed-demo <empty folder> [--models-from <folder>] [--offline] [--no-topics]
BrowserPOC --demo-eval <demo profile>                          # scores Related against Demo/expected.json, on a copy
BrowserPOC --demo-snapshots <out folder> --profile <demo profile>  # the opening moment, each space and the graph, offscreen
python3 -I Demo/tools/check_demo.py [--network]                 # checks the demo content itself
```

## What's in it

**Look and feel.** It follows Zen's layout. The page sits in a rounded card 8 points in from the window, and the sidebar runs straight into the window around it with no title bar. The traffic lights rest as grey dots in the sidebar's top row and show their colour when you hover them. Backgrounds are neutral grey with a fine grain. The only colour in the chrome is the space's, which tints the sidebar and fades toward the right. Every space colour gets the same calm strength in light and dark mode, and it dims when the window isn't in front. The UI text is SF Pro, with New York for the few headings where the app talks to you. Animations are short and don't bounce: tabs fade in, folders open like a drawer, a new space's list slides in, Cmd-T rises in and Cmd-L grows out of the address field, the selection glides between results, splits slide open and Related cards arrive one after another. With Reduce Motion on, movement turns into short fades or nothing.

**Startup and icon.** The app is called Rain. Every launch draws its mark in the middle of the window for about a second while the window restores behind it: an open loop drawn like a brush stroke, a dot that lands last like a drop, then the name. It never blocks a click and it's skipped with Reduce Motion on. The loop comes back around to the dot, for things you've seen coming back. The mark and the app icon are drawn in code, so they're crisp at every size. The icon is an Icon Composer icon, so macOS shows its light, dark, clear and tinted looks. It's still placeholder art.

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

Hover a pane for its controls: a handle to drag it to another pane's edge, Unsplit (Shift-click to stay in the split) and Close. Ctrl-Shift-1 to 4 focus a pane, Ctrl-Shift-[ and ] step through them, and Ctrl-Shift-- unsplits. Every divider drags, and double-clicking one evens it out. A split shows as one joined row in the sidebar, and right-click has Separate, Swap or Rotate, Layout, Pin and Move to space. A split made from a pinned tab stays pinned. The address, back and forward, find, Cmd-L, Cmd-W and Related follow the focused pane. Splits come back after a restart.

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

**Related.** Things I've seen before that relate to what's in front of me float along the bottom of the page or note, as a row of small cards with the site's icon and the title. Hovering one, or reaching it with the keyboard, opens a card above it with the matching passage, a short reason, and Open, Add to research and Dismiss. Moving along the row keeps that card open and slides it across. Clicking a small card opens the item, and right-click has the rest. The row scrolls sideways when there are more, with a trackpad or a mouse wheel.

A soft fade sits behind the row so it reads over any page, toward black in dark mode and toward light grey in light mode. The page is told its bottom is covered, so cookie bars, chat boxes and other fixed footers sit above the row, and the end of the page scrolls clear of it. With nothing related there's no row at all. It sinks out of the way while I type in a note and comes back when I pause. In a split it sits under the pane I'm in. While the on-device models download, a small pill at the end of the row shows how far along they are. The button at the very end opens the local graph above the row. Cmd-Shift-R hides or shows Related. Related can also show as a panel on the right: pick Sidebar in Settings, under General, or press Ctrl-Cmd-R to switch.

Sites come first in the row, then a thin line, then Notes / Docs. Sites holds pages you read, here or in Chrome. Notes / Docs holds things you write: your notes, Notion pages, Google Docs, Sheets and Slides, sites on the "Sites you write on" list in Settings, and any page where you've typed about 200 characters. Right-click a card to move it to the other section, and that choice is remembered. Each section shows up to 3 cards and has to clear the same fairly high bar, so a section is often empty. The current item and anything opened in the last 10 minutes never show, and Related always looks across every space. The reason starts with when I saw it and what I was doing then, like "You read this on 12 Oct while writing Thesis outline", and then says what it covers. With a note in a split, Add to research puts the link in that note.

**How Related picks cards.** Every page and note is cut into passages, and each passage gets a vector from EmbeddingGemma 2, a small embedding model that runs on this Mac. For whatever's in front of me, four searches run at once: keyword search (SQLite's BM25) on the page's own words, keyword search on search queries that Apple's on-device model writes after reading the page, a meaning search over the vectors, and a match on shared names. Reciprocal rank fusion merges them. The top 20 in each section go to Qwen3 Reranker, a cross-encoder that reads each passage next to what I have open and scores how well it fits. Cards that clear the bar easily show within a second or two. Borderline ones only show if Apple's on-device model, asked whether the item would help with what I'm doing right now, doesn't say no. Cards already on screen stay put while they still roughly qualify, and nothing reruns for small edits while I type.

**On-device models.** EmbeddingGemma 2 (310 MB) and Qwen3 Reranker 0.6B (396 MB) run through llama.cpp with Metal. Both are Apache 2.0. The first launch of a profile downloads them in the background, with a progress line in Related and details in Settings, under Models. Downloads resume after a quit and are checked against their published checksums. Until they're ready, Related uses Apple's built-in embedding and keyword scoring, and a background job re-embeds everything once the model arrives. Models are freed after five idle minutes.

**More sources.** Each one has a switch in Settings, under Sources, that says what it reads. All of them are read-only.
- Notion: reads a temp copy of the Notion app's local cache, which holds the pages I've opened in Notion on this Mac, and rebuilds each page's text from its blocks. macOS may ask once, the same way it does for Chrome.
- Google Docs, Sheets and Slides: takes the documents in my history here and in the Chrome import, and refreshes each one's text through its own plain-text export with this browser's Google sign-in. Up to 40 a run, each at most once a day.
- Granola: Granola encrypts its files on the Mac, so this uses Granola's official MCP connection. Connect opens Granola's sign-in in my default browser, with no key to paste, then brings in recent meetings' notes and summaries.

**Graph.** An Obsidian-style graph of everything in the index: notes, Google Docs, Notion pages, Granola meetings and sites. Open it with the graph button at the bottom of the sidebar, View > Graph (Cmd-Option-G), Open Graph in the command bar, or its row in the sidebar. It's an app page like History, so it can be pinned, filed, put in a split next to a note and comes back after a relaunch. Lines come in six kinds, each with its own colour and filter:
- Links: `[[wikilinks]]`, Markdown links and URLs in a note or doc that match something indexed. A wikilink to a note that doesn't exist yet shows as a hollow node, and clicking it creates the note.
- Navigation: a link you clicked on one page that took you to another.
- Research: something you added to research from Related.
- Together: two items in a split, or two items you spent time on within ten minutes of each other in two separate sessions.
- Similar meaning: each item's closest neighbours by meaning from the best embedding model it has, kept only when the match goes both ways or is very close for that model.
- Shared topics: optional topic nodes for names, and topics the tagging model found, that several items share, like Obsidian's tag nodes.

Nodes take their space's colour. Things you write are bright and sites you read are toned back. An item belongs to a space when it's open, pinned or filed there, or when it's a note in that space's notes folder. Anything else takes the space most of its connections are in, and items with no clear space stay grey. Each space keeps loosely to its own region, so the things that bridge two spaces sit between them. Colour by kind and the space pull are in the settings panel.

Hover a node to light up its neighbours, dim the rest and see why it's connected in the corner. Click a node to light it up and glide to it, and click again or double-click to open it. Option-click opens it in a split, right-click gives more, and dragging moves it while its neighbours follow. Pinch, Cmd-scroll or the mouse wheel zooms around the pointer. A two-finger scroll or a background drag pans, and a flung drag coasts to a stop. `+`, `-`, `0`, Esc and the arrow keys work too. The search field takes plain words plus `type:note`, `site:github.com` and `project:Browser`. The settings panel has Obsidian's Filters, Groups, Display and Forces, plus a time range, a space and grouping pages by site (on its own above 1,500 items). Play runs a timelapse in the order things were first seen.

Changing a filter or a search fades and grows nodes in and out instead of redrawing everything, and fit and focus glide. The graph draws at the display's full rate, 120 Hz on ProMotion, while anything moves, and stops drawing when nothing does. It remembers where every node came to rest, so a relaunch starts from the same picture. Two graph panes each keep their own view.

The graph button at the end of the Related shelf opens a local graph for whatever's focused, 1 to 3 steps out, and from there the full graph focused on it. With Related as a sidebar, the local graph sits at the bottom of the right panel instead. When the item changes, the local graph shifts to it instead of starting over. With the graph focused in a split, the local graph follows the item next to it, and that item gets a ring in the big graph. The graph's own tables live in `index.sqlite` next to the index, and its settings in `graph.json`.

With `BROWSERPOC_GRAPH_SCRIPT=<seconds>` set, the graph drives itself through hover, pan, zoom, drag, focus, a search and fit after that delay. It prints frame pacing for each step and quits. Use it only with `--data-dir`.

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

- App data: `~/Library/Application Support/BrowserPOC/` (state.json, settings.json, index.sqlite, and Notes/ when no notes folders are chosen). Round 3 adds Models/ (the downloaded models), sources.json (the source switches), related.json (Related as a shelf or a sidebar) and granola-auth.json (the Granola sign-in, readable only by my account). The AI client settings are in mcp.json, the served log in mcp-log.jsonl, and what's on screen in current-context.json.
- Browsing data sits next to it: browser.json (Browsing settings), history.sqlite (visits), closed.json (recently closed and the archive), sessions/ (back and forward for each tab), favicons/ and downloads.json.
- WebKit keeps cookies and caches under `~/Library/WebKit/local.browserpoc` and `~/Library/Caches/local.browserpoc`. Each named profile has its own WebKit store there too.
- Clearing the index removes indexed entries only. Notes stay exactly as they are.

## Code map

- `Sources/BrowserPOC/Browser`: tabs, notes as items, split trees, spaces, WebKit delegates, writing signals, and the Arc and Zen model: sidebar ordering and Essentials (`BrowserModel+Items`), splits (`BrowserModel+Split`), Peek and find (`BrowserModel+Peek`), command bar actions (`BarActions`), history, the archive, favicons, media, downloads, and app pages (`AppPages`, where other parts of the app register a page of their own).
- `Sources/BrowserPOC/Notes`: notes folders, the note document with its disk checks, Markdown preview.
- `Sources/BrowserPOC/Index`: SQLite wrapper, text analysis, the index, hybrid retrieval (`Retrieval.swift`), and the read API for the graph and MCP (`IndexStore+API.swift`: `semanticNeighbours`, `entities`, `topics`, `search`).
- `Sources/BrowserPOC/Intelligence`: llama.cpp wrapper, model downloads, embeddings, the working-context description and judgment with Foundation Models, background re-embedding and topic tagging, and an MCP client with OAuth.
- `Sources/BrowserPOC/Resurfacing`: Related's cards and reasons.
- `Sources/BrowserPOC/Sources`: Chrome import, Notion, Google Docs and Granola sources, URL safety rules, HTML text, the notes indexer and folder watcher.
- `Sources/BrowserPOC/Graph`: the graph's edge store and sync, link extraction, similarity, the layout builder, the force simulation, the Metal renderer and its colour tokens (`GraphTheme.swift`).
- `Sources/BrowserPOC/UI`: SwiftUI views, including the command bar, split view, spaces, the graph panes and the Related shelf (`RelatedShelf`, its state and rules in `RelatedShelfState`, and every visual value in `ShelfStyle`).
- `Sources/BrowserPOC/UI/Theme`: the design system. Colours, spacing, radii, shadows, type and motion, plus the small components the views share and the window chrome.
- `Sources/BrowserPOC/Startup`: the mark, the launch animation and the icon art.
- `Sources/BrowserPOC/MCP`: the `--mcp` server, its tools, privacy rules and note writer, the current-context writer and the AI clients Settings pane.
- `Sources/BrowserPOC/Demo`: the demo profile's seeder, the `demo://` pages, the demo eval and snapshots. The content itself is in `Demo/`, with its formats in `Demo/SPEC.md`.
- `Sources/BrowserPOC/Tests`: `--selftest`, `--smoketest` and `--extract-check`.
- `integrations`: the Claude Code, Claude Desktop, Codex and ChatGPT packaging.
