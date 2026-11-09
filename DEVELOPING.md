# Building and running Rain

How to build the proof of concept, run its tests and open the demo profile. What it does is in the [README](README.md) and [docs/FEATURES.md](docs/FEATURES.md).

## Build and run

You need Xcode 26 (or its command line tools) on macOS 26 or later.

From the repo folder:

```
scripts/build.sh        # builds build.noindex/Rain.app (release)
scripts/run.sh          # builds, then opens it
scripts/install.sh      # builds, waits until Rain is closed, then swaps the copy in /Applications
scripts/forget-copies.sh  # takes every Rain but /Applications/Rain.app off macOS's list of apps
```

The app ends up at `build.noindex/Rain.app`. The folder ends in `.noindex` so Spotlight skips it, and the scripts take the build off macOS's list of apps, so only the copy in /Applications shows up there. Quit a running copy before rebuilding. `scripts/install.sh` keeps the copy it replaces in `build.noindex/previous/Rain.app`. It copies the old app there and deletes it rather than moving it, because macOS and the Dock follow a moved app and list it again. Then it runs `scripts/forget-copies.sh`, which takes every other Rain macOS has seen off the list, including copies in the Trash, worktree builds and test copies whose bundle IDs start with `local.browserpoc`. It only touches that list, never the files.

The build is signed ad hoc, so every build has a different signature. macOS ties some permissions to the signature, so after a rebuild it may ask again before the app can read Chrome's history. To keep that permission across builds, sign with a certificate from your keychain:

```
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" scripts/build.sh
```

To run the app on a separate profile, with its own support folder and its own cookies, pass `--data-dir`. Your normal profile isn't read or touched:

```
build.noindex/Rain.app/Contents/MacOS/BrowserPOC --data-dir ~/Desktop/test-profile
```

Tests and checks from the command line:

```
scripts/selftest.sh                                             # index, notes, sections, splits, spaces, sidebar, command bar, Related shelf, MCP and look checks
.build/debug/BrowserPOC --smoketest                             # drives the real browser headless, no window on screen
build.noindex/Rain.app/Contents/MacOS/BrowserPOC --chrome-dry-run # what a Chrome import would do, fetches nothing
.build/debug/BrowserPOC --extract-check <url>                   # what capture reads from one public page
.build/debug/BrowserPOC --eval --models-dir <folder>            # resurfacing quality, old pipeline against new
.build/debug/BrowserPOC --demo-diag <demo profile> [--reasons] # where each labelled demo item lands, and the reasons cards would show
.build/debug/BrowserPOC --quit-check app --models-dir <folder>  # quits mid-re-embed with the models loaded and must exit cleanly (the self test runs it when BROWSERPOC_QUIT_CHECK_MODELS is set)
.build/debug/BrowserPOC --notion-dry-run                        # counts and field names from Notion's cache, no content
.build/debug/BrowserPOC --granola-dry-run                       # which Granola files exist and Granola's public sign-in details
.build/debug/BrowserPOC --download-models --data-dir <profile>  # fetch the on-device models into a profile
.build/debug/BrowserPOC --render-review <dir>                   # light and dark snapshots of every main view, offscreen
.build/debug/BrowserPOC --tabbar-shots <dir> --profile <demo profile>  # the horizontal tab bar, its Essentials grid and space menu, offscreen
scripts/make-icon.sh                                            # redraws the app icon from code
.build/debug/BrowserPOC --shelf-demo --data-dir <folder>        # plays the Related shelf's motion in a window, on a throwaway profile
.build/debug/BrowserPOC --data-dir <folder> --motion-tour glass dark --reduce-transparency  # each glass layer over a bright, busy and dark page, in a window; light or dark, and the solid fallback with --reduce-transparency
.build/debug/BrowserPOC --data-dir <folder> --motion-tour spaces # plays one area's motion in a window for recording, then quits (also rows, peek, split, compact, toasts)
scripts/mcp-e2e.sh                                              # Claude Code and Codex against a made-up profile, temporary configs only
build.noindex/Rain.app/Contents/MacOS/BrowserPOC --graph-bench    # the graph's 5,000 node timings on a release build
.build/debug/BrowserPOC --thumbnail-check [tmp/thumbnail-test.html] # a local test page offscreen: the thumbnail is the top of the page, and nothing is taken after it scrolls
```

Both tests use throwaway folders and exit non-zero if a check fails. The self test checks delete with a stand-in Trash folder inside its throwaway folder, so your real Trash is never touched. The dry run prints full URLs from your Chrome history, so keep its output to yourself.

## Demo profile

To play with Related and the graph without my own data, `scripts/demo.sh` builds the app, makes a demo profile and opens a separate copy of the app on it. The profile belongs to Theo Park, a made-up Yale student. He's writing a seminar paper, building a textbook swap app with a friend, applying for PM internships and planning a trip to Japan. Everyone in it is made up. The web pages are real, so tabs open the actual page. What to try is in `Demo/SCENARIOS.md`.

```
scripts/demo.sh                     # seeds the profile the first time, then opens it
scripts/demo.sh --reset             # starts the profile over; changes made in it are lost
scripts/demo.sh --models <folder>   # copies verified model files in instead of downloading them
```

The profile lives in `demo-profile.nosync` in the project folder. The script only writes to an empty folder or to a demo profile it made before, and never to my real support folder. Seeding copies the notes in as real Markdown files, indexes the demo Google Docs, Notion pages and Granola meetings as those sources, records six weeks of visits and searches, reads each page's text without cookies, embeds and tags everything, builds the graph and lays out four spaces with Essentials, pins, folders, tabs and splits. Each space also gets its folder in `Space Folders/` inside the profile, with saved pages, a Reading folder with a folder inside it, a link to the space's notes and an empty Ideas folder in School. The sidebar's folders are moved onto disk and pinned the way a real profile's are, and Personal pins its linked notes. Seeded more than a week after the demo moment, times move forward by whole weeks. Outside sources stay off in the demo profile, and auto-archive is off so the layout stays put.

The demo docs and meetings open at `demo://` addresses as read-only pages drawn by the app, so nothing ever loads a real Google or Notion page.

```
BrowserPOC --seed-demo <empty folder> [--models-from <folder>] [--offline] [--no-topics]
BrowserPOC --demo-eval <demo profile>                          # scores Related against Demo/expected.json, on a copy
BrowserPOC --demo-snapshots <out folder> --profile <demo profile>  # the opening moment, each space and the graph, offscreen
BrowserPOC --sidebar-shots <out folder> --profile <demo profile>   # the sidebar at each width and icons only, offscreen, with drag, right-click menu and hover card checks
BrowserPOC --drag-shots <out folder> --profile <demo profile>      # folders inside folders, folder drop zones, a tab dragged over the page and the split divider, offscreen
BrowserPOC --folder-shots <out folder> --profile <demo profile>    # the folder popup in light and dark: a space's folder, a folder inside it, an empty one, a linked one, search, save mode and the tab bar, with click, key and save checks
build.noindex/Rain.app/Contents/MacOS/BrowserPOC --drag-probe --profile <demo profile>  # hands drops to the window as AppKit does in a real drag: a tab onto the page, onto a folder and into the folder popup, a page from the popup onto a pinned folder, and a folder from the popup into the Folders section. Run it from the built app, whose Info.plist declares the drag type
python3 -I Demo/tools/check_demo.py [--network]                 # checks the demo content itself
```

## Your data across updates

Tabs, spaces, history, notes and cookies live outside the app, so a new build never replaces them. Three things keep them safe as the app changes:

- The first time a new build opens a profile, it backs the profile up to `Backups/` inside it before reading anything. That covers spaces and tabs, settings, history, the index, Rain's own Notes folder, Rain's order for the space folders, and WebKit's cookies and site data for the profile and its named profiles. The models and caches, page thumbnails included, are left out. The space folders in `~/Documents/Rain` sit outside the profile and aren't copied. The last five backups are kept, and each has an "About this backup.txt" that says where every part goes back to.
- If the app can't read a file it saved (state.json, settings.json and the rest), it moves the file into `Recovered/` before starting that part over, and says so in a sheet. If only part of a file can't be read, say one tab, it loads the rest and keeps a copy of the whole file in `Recovered/`. A file it can't read or move is never written to.
- The self test loads frozen samples of every saved format (spaces and tabs, settings, preferences, recently closed, history and the index) and fails if anything goes missing.

So when a change touches how something is saved, the new code has to read the old format too, or move it over once. The space folders build moves the sidebar's folders onto disk this way (`Folders/SpaceFolderMigration.swift`): after the launch backup, it writes every folder, saved page and link first, only then changes state.json, records that it finished, and on a failure leaves the old folders working and tries again next launch. New fields in state.json are optional or have a default, and old samples in `Tests/DataSafetyTests.swift` stay as they are.

The bundle ID (`local.browserpoc`) and the profile folder name (`BrowserPOC`) stay fixed. WebKit files cookies and logins under the bundle ID, so changing either one opens an empty profile and signs you out of everything. A rename needs a step that moves the data first. `scripts/build.sh` refuses another bundle ID, and the self test checks both.

## Where things live

- App data: `~/Library/Application Support/BrowserPOC/` (state.json, settings.json, index.sqlite, and Notes/ when no notes folders are chosen). Round 3 adds Models/ (the downloaded models), sources.json (the source switches), related.json (Related as a shelf or a sidebar) and granola-auth.json (the Granola sign-in, readable only by my account). The AI client settings are in mcp.json, the served log in mcp-log.jsonl, and what's on screen in current-context.json.
- Browsing data sits next to it: browser.json (Browsing settings), history.sqlite (visits), closed.json (recently closed and the archive), sessions/ (back and forward for each tab), favicons/ and downloads.json.
- WebKit keeps site data under `~/Library/WebKit/local.browserpoc`, the default profile's cookies in `~/Library/HTTPStorages/local.browserpoc.binarycookies`, and caches under `~/Library/Caches/local.browserpoc`. Each named profile has its own WebKit store, cookies included, in `~/Library/WebKit/local.browserpoc/WebsiteDataStore/`.
- Backups/ (one per new build, the last five) and Recovered/ (files the app couldn't read) sit in the app data folder, and last-build.txt says which build opened it last.
- Space folders: one folder per space under `~/Documents/Rain/` for the default profile. A profile opened with `--data-dir`, the demo profile and every test profile keep theirs in `Space Folders/` inside the profile folder instead, so they never touch `~/Documents/Rain`. Settings, Browsing can move them. Rain's own order for each folder and when things were last opened from one are in space-folders.json in the app data folder, and page thumbnails are in Thumbnails/ there, named from a hash of the page's address, so the folders stay clean. Paths in state.json that point inside the space folders are kept relative to their root, so a copy of a profile finds its own files.
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
- Motion: the space strip and its swipe (`UI/SpacePager.swift`, the rules in `UI/SwipePhysics.swift`), Peek's choreography (`UI/PeekMotion.swift`), drag gaps (`UI/SidebarDrag.swift`), compact mode's reveal (`UI/CompactReveal.swift`) and the smaller pieces (`UI/MotionDetails.swift`).
- `Sources/BrowserPOC/UI/Theme`: the design system. Colours, spacing, radii, shadows, type and motion, plus the small components the views share and the window chrome.
- `Sources/BrowserPOC/Startup`: the mark, the launch animation and the icon art.
- `Sources/BrowserPOC/MCP`: the `--mcp` server, its tools, privacy rules and note writer, the current-context writer and the AI clients Settings pane.
- `Sources/BrowserPOC/Demo`: the demo profile's seeder, the `demo://` pages, the demo eval and snapshots. The content itself is in `Demo/`, with its formats in `Demo/SPEC.md`.
- `Sources/BrowserPOC/Tests`: `--selftest`, `--smoketest` and `--extract-check`.
- `integrations`: the Claude Code, Claude Desktop, Codex and ChatGPT packaging.
