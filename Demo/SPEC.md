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
- Essentials are shared by every space, like Zen's Essentials. Until the app has them, the seeder can pin them in every space.
- Each content id is placed at most once in the whole layout.
- An item inside a split isn't also in a folder, because the sidebar shows a split as one joined row.

## Opening demo docs and meetings

These aren't real documents. They must never load a real Google or Notion URL.

- Each one has `demo_url`, for example `demo://google-docs/gdoc-paper-draft`. The seeder indexes it under that URL with the matching source type.
- `origin_url` is a realistic-looking URL for display only. It's never loaded.
- The app registers a `WKURLSchemeHandler` for `demo` on its web view configuration. It returns the item rendered with the app's Markdown renderer as a read-only page, with a quiet header showing the source, the title, the edited date and "Demo copy, read-only".
- Tabs, splits, back and forward, pins and folders then work with no special cases. `demo://` isn't http, so page capture never indexes it as a web page.
- Card section: docs and meetings go in Notes / Docs, the same as real Google Docs, Notion pages and Granola notes.

## Seeding

1. Build a fresh profile in a folder given with `--data-dir`. Refuse to seed a folder that already holds a profile. Never touch the default support folder.
2. Copy `notes/` to `<data-dir>/Notes/`, keeping the space folders. Set each file's modification date from `updated`. Point `settings.json` at that folder and mark first run done.
3. Index notes with the normal indexer. Index docs and meetings through the source adapters, using their own dates.
4. Index history pages with visit count, first and last seen and dwell. Fetch full text cookie-free at seed time with the existing fetcher, and fall back to `excerpt` if the fetch fails. Load `searches` into past searches.
5. Build `state.json` from `spaces.json`.
6. Shift every timestamp by now minus `anchor`, so "three weeks ago" stays true whenever the demo runs. Dates written inside note text don't move.
7. Set `last_opened` from the content's own dates, never to now. Otherwise everything open would be hidden from Related as recently opened.
