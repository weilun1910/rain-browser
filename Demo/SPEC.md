# Demo content spec

The demo profile is a fictional student, Theo Park, Yale '28, with four spaces: School, Swapshelf, Job hunt and Personal. Every person and company in it is made up. The web pages are real public pages. This file says what each file holds and how the app should load it. `SCENARIOS.md` says what to try once it's loaded.

The demo moment is `anchor` in `spaces.json`: Wednesday 4 November 2026, 4:40pm New York time.

## Files

| Path | What it is |
|---|---|
| `notes/<Space folder>/*.md` | 39 Markdown notes, copied into the profile as real, editable notes |
| `docs/*.md` | 21 demo Google Docs, Sheets, Slides and Notion pages, shown read-only |
| `meetings/*.md` | 8 Granola-style meetings, shown read-only |
| `history.json` | 149 real pages with visits, dwell, searches and excerpts |
| `spaces.json` | Spaces, essentials, pins, folders, tabs, splits and the focused item |
| `expected.json` | Labelled resurfacing cases for the eval and for checking the demo |
| `tools/build_history.py` | Rebuilds `history.json` and checks every page loads |
| `tools/check_demo.py` | Checks references, dates and writing rules. `--network` also requests every page. |

## Ids

Every piece of content has one id, used everywhere else to point at it.

- Notes: `note-...`, in front matter
- Google Docs, Sheets and Slides: `gdoc-...`, `gsheet-...`, `gslides-...`
- Notion: `notion-...`
- Meetings: `granola-YYYY-MM-DD-...`
- Web pages: `web-...`, in `history.json`
- Layout items in `spaces.json`: `item-...`, plus `folder-...` and `split-...`

Derive UUIDs from these with UUID v5 so a reseed gives the same UUIDs.

## Front matter

Simple YAML: scalars, `[a, b]` lists, and for meetings a list of `{name, role, org}` maps. Times are ISO 8601 with an offset.

Notes:
```
id, title, space, created, updated, tags
```
The file name is the title, and the body starts with `# <title>`, so today's indexer already gets the title right. Links are Obsidian style, `[[File name]]`.

Docs:
```
id, title, source (google-docs | google-sheets | google-slides | notion), space,
created, edited, owner, shared_with, origin_url, demo_url
```
Sheets are Markdown tables. Slides have one `## Slide n - Title` section per slide.

Meetings:
```
id, title, source (granola), space, date, duration_min, attendees, demo_url
```
The body has `## Notes`, `## Action items` and `## Transcript excerpt`, the way Granola lays out a meeting.

## history.json

```
anchor, timezone, about,
pages: [{ id, url, title, site, space, query, visitCount, firstVisit, lastVisit,
          visits: [time], dwellSeconds, excerpt, excerptSource }],
searches: [{ query, at, led_to }]
```

- `title` and `excerpt` come from the live page with a cookie-free request. Wikipedia excerpts come from its summary API. Two pages render with JavaScript only, so their excerpt is written by hand and `excerptSource` is `written`.
- `query` is the search that led to the page, or null.
- `searches` seeds past searches for the command bar. `led_to` is a page id or null.

## spaces.json

```
version, anchor, currentSpace,
focus: { space, split, pane, item },
essentials: [item],
spaces: [{ id, name, icon, color, notesFolder,
           pinned: [item], folders: [{ id, name, expanded, items: [item] }],
           tabs: [item], splits: [{ id, left: item, right: item, ratio, focus }],
           selected: { split } or { item } }]
item: { id, kind (web | note | doc | meeting), ref }
```

- Icons are SF Symbol names from `Space.icons`. Colours are from `Space.palette`.
- `notesFolder` is the space's folder under the demo notes root. It becomes the space's `newNotesFolder`.
- Essentials are shared by every space, like Zen's Essentials.
- Each content id is placed at most once in the whole layout.
- An item inside a split isn't also in a folder, because the sidebar shows a split as one joined row.

## Opening demo docs and meetings

These aren't real documents. They must never load a real Google or Notion URL.

- Each one has `demo_url`, for example `demo://google-docs/gdoc-paper-draft`. The seeder indexes it under that URL with the matching source type.
- `origin_url` is a realistic-looking URL for display only. It's never loaded.
- `DemoScheme` (`Sources/BrowserPOC/Demo/DemoScheme.swift`) is a `WKURLSchemeHandler` registered in `BrowserModel.makeConfig`, so every web view and profile has it. It reads `demo-items/<id>.md` from the profile and draws a read-only page in the app's look: the card's neutral background, SF Pro text, a New York title, and a quiet header with the source, the edited date or meeting time, the owner or attendees and "Demo copy, read-only". Tables, task lists and Granola transcript lines are laid out properly. An unknown or odd address gets a not-found page, never the network.
- The tab lets `demo` through its scheme check, and page extraction reads demo pages so Related gets their text. Capture still only indexes http pages, so a demo page is never indexed twice.
- Each demo page links its source's icon as a data URL, and the seeder caches the same icons, so the sidebar shows them.
- Card section: docs and meetings go in Notes / Docs, the same as real Google Docs, Notion pages and Granola notes.

## Seeding

Built as `BrowserPOC --seed-demo <folder>` (`Sources/BrowserPOC/Demo/DemoSeeder.swift`), and run by `scripts/demo.sh`.

1. The folder must be missing, empty, or a demo profile with the `.rain-demo-profile` marker. It's never the app's real support folder, the home folder or anything under `~/Library/Application Support`, `WebKit`, `Caches`, `Containers` or `Preferences`. A reseed clears the folder but keeps `Models/`.
2. `--models-from <folder>` clones verified model files into `Models/`. Without them the app downloads them on first launch, and Related uses Apple's embedding until then.
3. Notes go to `Notes/<Space folder>/<title>.md` starting with their heading and with their tags as `#tags` on the last line, and their file dates set from `created` and `updated`. Docs and meetings go to `demo-items/<id>.md` for the `demo://` pages.
4. `settings.json` points at the notes folder and marks first run done. `sources.json` keeps Notion, Google Docs and Granola off, so Felix's real accounts are never read into the demo. `browser.json` turns auto-archive off, so the layout stays put.
5. Notes go through the normal indexer. Docs go in as `gdocs` or `notion` and meetings as `granola`, keyed by their `demo_url`. Pages go in as visited pages, with their text read cookie-free through the Chrome importer's session and redirect rules, falling back to `excerpt`. Every visit is recorded in the index's visits table and in the browser's own history, with "in your <space> space" as its context. Searches seed past searches.
6. Passages are embedded with the best ready model, then Apple's content tagging model tags topics (`--no-topics` skips it). The graph store records the splits as together edges and syncs links and similarity.
7. `state.json` comes from `spaces.json`, with UUIDs derived from the ids. The demo docs open as web tabs at their `demo_url`. Essentials are pinned and shared. Each space keeps its selection, and School opens on its split with the draft focused.
8. Seeded within a week of `anchor`, times stay as written. After that every timestamp moves forward by whole weeks, so weekdays still match the text and "three weeks ago" stays roughly true. Dates written inside the text never move. `last_opened` comes from each item's own last date, never from now.
9. Site icons are fetched cookie-free into `favicons/`, and the demo sources get drawn icons under their demo hosts.

`--offline` skips the page text and icon fetches, for tests and quick seeds.
