<p align="center">
  <img src="docs/screenshots/icon.png" width="128" alt="Rain icon">
</p>

# Rain

Rain is a Mac browser I'm building, and this repo is its proof of concept.

Pages, notes, docs and meetings I've already seen come back on their own when what I'm working on makes them relevant. I don't have to file or pin anything first, and it all runs on my Mac.

![An article on two-sided marketplaces next to a paper draft, with a coffee chat note from another space resurfacing at the bottom](docs/screenshots/hero.jpg)

## Why I'm building it

- Useful pages I've read disappear from my head. My history still has them, but that only helps if I remember they exist.
- My notes, Notion plans, Google Docs and meeting notes all hold pieces of the same work, and I'm the one who has to connect them again. That gets worse across projects, because the right note is usually sitting in a project I don't have open.
- I want Arc's way of organising tabs and Obsidian's local Markdown notes in the same place, so reading and writing happen side by side.

## What it does

### Related, at the bottom of the page

Whatever I'm reading or writing, Rain looks across everything I've seen and floats the few things that actually relate along the bottom of the page as small cards. Hovering one shows the passage that matched and why it came back, like "Your note in Job hunt, last edited 14 Oct". It looks across every space, so a coffee chat from my job hunt can come back while I'm writing a paper. When nothing clears the bar, there's no row at all.

![The Related shelf with its hover card open](docs/screenshots/shelf.jpg)

Picking the cards runs on the Mac. EmbeddingGemma finds candidates by meaning alongside keyword and name search, a Qwen3 reranker reads each one against the part of the page it matched, and Apple's on-device model judges the close calls and writes the reasons. The first launch downloads the two models, about 700 MB together.

### A graph of everything

An Obsidian-style graph connects my notes, Google Docs, Notion pages, Granola meetings and the sites I've read. Lines come from links in my notes, pages that led to other pages, things I opened side by side, things I added to research, closeness in meaning and shared topics. Each space gets its own colour, so the things that bridge two projects sit between them. It runs at 120 Hz on ProMotion, and the button at the end of the Related row opens a small graph around whatever I'm on.

![The graph of a demo profile with four spaces in their own colours](docs/screenshots/graph.jpg)

### Arc and Zen, rebuilt natively

Spaces have their own pinned tabs, folders, tabs and splits, each with a colour that tints the sidebar, and a two-finger swipe slides between them under my fingers. Cmd-T opens one bar that switches tabs, runs about 40 commands, fills in addresses and searches my notes and history. Split view takes up to four pages or notes. There's also Essentials, Peek, compact mode, auto-archive and pinned tabs that remember their page. The floating controls sit on Liquid Glass.

![The Cmd-T bar open over a page](docs/screenshots/command-bar.jpg)

![Three panes in a split, with a note on the right](docs/screenshots/split.jpg)

### Notes that live in my own folders

I point Rain at folders of Markdown files, like my Obsidian vault, and every note opens as a tab I can pin, file or split next to a page. Rain never re-saves a note on open and never overwrites a file that changed on disk, because Claude and Codex edit the same files.

### My AI can read it too

Rain runs as an MCP server, so Claude Code, Claude Desktop and Codex can search what I've read and written, see how things connect and know what I have open right now. That makes it a body of personal context that keeps itself up to date. A switch per source decides what AI clients can see, and editing notes stays off until I turn it on. The plugins are in [integrations/](integrations/).

![The AI clients settings, with install steps and a switch for each source](docs/screenshots/ai-clients.jpg)

## About the screenshots

They come from a demo profile of a made-up student, Theo Park, who's writing a paper on campus marketplaces, building a textbook swap app, applying for PM internships and planning a trip to Japan. His notes, docs and meetings are made up, and the web pages are real.

The full feature list is in [docs/FEATURES.md](docs/FEATURES.md), and building it or opening the demo is in [DEVELOPING.md](DEVELOPING.md).

## Credits

A lot of how Rain handles tabs, spaces, split view and Cmd-T comes from [Arc](https://arc.net) and [Zen](https://github.com/zen-browser/desktop). Zen being open source meant I could read how those small behaviours actually work instead of guessing.
