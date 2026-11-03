# Browser POC

A rough Mac browser on WebKit, built to test one idea: pages and notes you've already seen should come back on their own when what you're working on makes them relevant. You don't file or pin anything. Everything stays on this Mac.

It's a proof of concept. It works, but it isn't polished.

## Build and run

You need Xcode 26 (or its command line tools) on macOS 26 or later.

```
cd "app.nosync"
scripts/build.sh        # builds build/BrowserPOC.app (release, signed ad hoc)
scripts/run.sh          # builds, then opens the app
```

The app ends up at `build/BrowserPOC.app`. You can also open it from Finder.

Tests and the Chrome check run from the command line:

```
scripts/selftest.sh                                             # index and ranking checks on fixture docs
.build/debug/BrowserPOC --smoketest                             # drives the real browser headless, no window on screen
build/BrowserPOC.app/Contents/MacOS/BrowserPOC --chrome-dry-run # what a Chrome import would do, fetches nothing
```

Both tests use a throwaway folder and exit non-zero if a check fails. The dry run prints full URLs from your Chrome history, so keep its output to yourself.

## What's in it

**Browser.** One window. The left sidebar has the address field (Google for searches), back, forward and reload, then Pinned, Folders, Notes and Tabs. Tabs are newest first. Right-click a tab to pin it or move it into a folder, or drag it onto a folder. Folders can be created, renamed and deleted (their tabs go back to Tabs). Closing a pinned or filed tab only unloads it. Pins, folders and open tabs come back after a restart. Element full screen works, and pages can be inspected from Safari's Develop menu.

Shortcuts: Cmd-T new tab, Cmd-L address field, Cmd-W close, Cmd-R reload, Cmd-[ and Cmd-] back and forward, Cmd-Shift-N new note, Cmd-Shift-R show or hide the right panel, Cmd-Shift-P note preview, Cmd-plus and Cmd-minus zoom.

**Notes.** Plain `.md` files in `~/Library/Application Support/BrowserPOC/Notes/` (you can pick another folder in Settings). They save as you type. There's a preview toggle. Markdown files from folders you add open read-only, with a Reveal in Finder button.

**Index.** When a page stays open about five seconds, its title, description and main text go into a local SQLite index with full-text search. It also stores Apple NaturalLanguage sentence vectors for each passage and the people, organisations and places in it. It skips anything that isn't http or https, and sites on the exclude list (banks and mail.google.com to start; edit it in Settings). Notes get indexed every time they save.

**Related cards.** The right panel shows up to five things you've seen before that relate to the page or note in front of you. A card needs to clear a fairly high bar, so often you'll see nothing, which is on purpose. The current item and anything you opened in the last 10 minutes never show. Cards stay put while you read or type and only reset when you move to something quite different. Each card has a source icon, title, site or project, the matching passage and a short reason. The reason starts from your real history ("You read this on 28 Oct, 3 visits. Both cover WKWebExtension and Nook."). When Apple's on-device model is available, it writes a short reason in its place.

- Open: pages open in a new tab, notes and Markdown files open in the editor.
- Add to research: in a note, adds a link under `## Related` at the end. On a page, adds the item to the tab's folder, or to a Research folder it creates.
- Dismiss: hides the card for this page or note, and scores it lower in similar contexts later.

**Seed sources.** On first launch a panel offers both. Nothing runs until you click.

- Import Chrome history copies Chrome's Default profile History file into the app's folder, reads the copy, then deletes it. The original is never opened as a database or written to. It imports the last 90 days, up to 2,000 pages, as title and URL. It then fetches text for up to 300 of the most visited pages without cookies, 4 at a time, 10 second timeout. It only fetches pages you opened at least twice. It skips anything that looks like a sign-in, unsubscribe, confirm, token or OAuth link, local addresses, search pages and logged-in apps like Gmail, Docs, Notion and LinkedIn. Redirects get the same checks. Pages that come back as a login wall stay title only.
- Add Markdown folders indexes every `.md` file under the folders you pick, skipping `.git`, `node_modules`, `.build` and any `.nosync` folder. The project label is the first folder under the one you picked. These files are only read. Files that iCloud hasn't downloaded are skipped so reading them doesn't trigger a download. Folders rescan on launch and from the Rescan button.

**Settings.** General (notes folder, exclude list, model status), Sources (Chrome import with progress, Markdown folders, counts per source, Clear index) and Tuning (relevance threshold, weights for keywords, meaning and names, and Show scores on cards).

## Not in this version

- No extensions, passkeys, password autofill, find in page, history view, favicons or profiles.
- Downloads go straight to Downloads with no download list.
- Back and forward history isn't kept across restarts, only the tab's page.
- Tabs can't be reordered by hand.
- Semantic matching uses `NLEmbedding.sentenceEmbedding`. `NLContextualEmbedding` isn't used.
- Chrome import reads the Default profile only, and uses the last visit date (not the first).

## Where things live

- App data: `~/Library/Application Support/BrowserPOC/` (state.json, settings.json, index.sqlite, Notes/).
- WebKit keeps cookies and caches under `~/Library/WebKit/local.browserpoc` and `~/Library/Caches/local.browserpoc`. The window position is saved in `~/Library/Preferences/local.browserpoc.plist`.
- Clearing the index in Settings removes indexed entries only. Notes and Markdown files aren't touched.

## Code map

- `Sources/BrowserPOC/Browser`: tabs, WebKit delegates, the browser model.
- `Sources/BrowserPOC/Notes`: notes, Markdown preview and the Related link helper.
- `Sources/BrowserPOC/Index`: SQLite wrapper, text analysis, the index and ranking.
- `Sources/BrowserPOC/Resurfacing`: the right panel's card logic and reasons.
- `Sources/BrowserPOC/Sources`: Chrome import, URL safety rules, HTML text, Markdown folders.
- `Sources/BrowserPOC/UI`: SwiftUI views.
- `Sources/BrowserPOC/Tests`: `--selftest` and `--smoketest`.
