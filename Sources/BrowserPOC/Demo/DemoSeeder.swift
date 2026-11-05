import AppKit
import Foundation

/// `--seed-demo <dir>`: builds the demo profile from the repo's `Demo/` folder in an empty
/// folder, or rebuilds one this made before. Never the app's real support folder.
///
/// It writes the notes as real Markdown files in the profile's own notes folder, indexes the
/// demo Google Docs, Notion pages and Granola meetings as those sources, records the browsing
/// history with its visit times and searches, fetches page text cookie-free, embeds, tags
/// topics, builds the graph and lays out the spaces. Times move so the demo moment is now.
@MainActor
enum DemoSeeder {
    struct Options {
        var content: URL
        var target: URL
        var modelsFrom: URL?
        var fetchText = true
        var topics = true
        var favicons = true
        var shiftDates = true
        var now = Date()
        var log: (String) -> Void = { print($0) }
    }

    struct Summary {
        var notes = 0, items = 0, pages = 0, fetched = 0, visits = 0, searches = 0
        var embedder = "", vectors = 0, tagged = 0, edges = 0
        var seconds = 0.0
    }

    /// The file that marks a folder as a demo profile this made, so a reseed may clear it.
    nonisolated static let marker = ".rain-demo-profile"

    static var realSupportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BrowserPOC", isDirectory: true)
    }

    /// Nil when the folder is safe to seed, else why not: it must be missing, empty, or a
    /// demo profile with the marker, and never the app's real support folder.
    static func refusal(_ dir: URL) -> String? {
        let fm = FileManager.default
        let p = dir.standardizedFileURL.resolvingSymlinksInPath().path
        let real = realSupportRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath().path
        if p == "/" || p == home { return "won't seed the home folder or the disk root" }
        if p == real || p.hasPrefix(real + "/") { return "won't touch the app's real support folder" }
        if real.hasPrefix(p + "/") { return "\(p) holds the app's real support folder" }
        for lib in ["Library/Application Support", "Library/WebKit", "Library/Caches", "Library/Containers", "Library/Preferences"] {
            let l = home + "/" + lib
            if p == l || p.hasPrefix(l + "/") { return "won't seed inside ~/\(lib)" }
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: p, isDirectory: &isDir) else { return nil }
        guard isDir.boolValue else { return "\(p) is a file" }
        let entries = ((try? fm.contentsOfDirectory(atPath: p)) ?? []).filter { $0 != ".DS_Store" }
        if entries.isEmpty || entries.contains(marker) { return nil }
        return "\(p) isn't empty and isn't a demo profile made by --seed-demo. Pick an empty folder."
    }

    // MARK: Command line

    static func commandLine(_ args: [String]) -> Int32 {
        func arg(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let t = arg("--seed-demo") else { print("Usage: --seed-demo <empty folder> [--demo-content <Demo folder>] [--models-from <folder>] [--offline] [--no-topics]"); return 2 }
        let target = URL(fileURLWithPath: (t as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        if let why = refusal(target) { print("Not seeding: \(why)"); return 1 }
        guard let content = DemoContent.locate(arg("--demo-content")) else {
            print("Couldn't find the Demo folder. Pass --demo-content <path to Demo>.")
            return 1
        }
        var o = Options(content: content, target: target)
        o.modelsFrom = arg("--models-from").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        o.fetchText = !args.contains("--offline")
        o.favicons = !args.contains("--offline")
        o.topics = !args.contains("--no-topics")
        o.shiftDates = !args.contains("--keep-dates")
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        do {
            let s = try seed(o)
            print(String(format: "Demo profile ready in %.0f s: %@", s.seconds, target.path))
            print("  \(s.notes) notes, \(s.items) docs and meetings, \(s.pages) pages (text fetched for \(s.fetched)), \(s.visits) visits, \(s.searches) searches")
            print("  vectors \(s.vectors) from \(s.embedder), topics for \(s.tagged) items, \(s.edges) graph edges")
            print("Open it: build/Rain.app/Contents/MacOS/BrowserPOC --data-dir \"\(target.path)\"")
            return 0
        } catch {
            print("Seeding failed: \(error)")
            return 1
        }
    }

    // MARK: Seeding

    struct Failure: Error, CustomStringConvertible { let description: String }

    /// Points the app's support folder at the target for the rest of the process.
    @discardableResult
    static func seed(_ o: Options) throws -> Summary {
        let started = Date()
        let fm = FileManager.default
        if let why = refusal(o.target) { throw Failure(description: why) }
        let c = try DemoContent.load(o.content)
        var sum = Summary()
        // Times move forward in whole weeks, and only once a week has passed since the demo
        // moment. Weekdays then still match the notes, and dates written in the text only drift
        // when the demo is old enough that "three weeks ago" would otherwise go stale.
        let shift = o.shiftDates ? (o.now.timeIntervalSince(c.anchor) / (7 * 86400)).rounded(.down) * 7 * 86400 : 0
        func at(_ d: Date) -> Date { d.addingTimeInterval(shift) }
        func at(_ s: String) -> Date? { DemoContent.parseDate(s).map(at) }

        // A clean folder. A previous demo profile keeps only its downloaded models.
        let root = o.target
        Paths.ensure(root)
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where name != "Models" && name != marker {
            try fm.removeItem(at: root.appendingPathComponent(name))
        }
        try writeMarker(root, anchor: c.anchor, shift: shift, done: false)
        Paths.overrideRoot = root
        BrowserModel.dataStoreID = Paths.storeID(for: root)

        // Models, if there are verified copies to clone. Otherwise the app downloads them.
        let modelsDir = root.appendingPathComponent("Models", isDirectory: true)
        ModelFiles.overrideDir = nil
        if let from = o.modelsFrom {
            Paths.ensure(modelsDir)
            for spec in ModelCatalog.all {
                let src = from.appendingPathComponent(spec.file), mark = from.appendingPathComponent(spec.file + ".verified")
                let dst = modelsDir.appendingPathComponent(spec.file)
                guard fm.fileExists(atPath: src.path), fm.fileExists(atPath: mark.path) else { o.log("  no verified \(spec.file) in \(from.path)"); continue }
                if !fm.fileExists(atPath: dst.path) {
                    try fm.copyItem(at: src, to: dst)
                    try? fm.removeItem(at: modelsDir.appendingPathComponent(spec.file + ".verified"))
                    try fm.copyItem(at: mark, to: modelsDir.appendingPathComponent(spec.file + ".verified"))
                }
            }
        }
        ModelFiles.clearReadyCache()
        Intelligence.shared.modelsChanged()

        // Notes, as real files in the profile's notes folder, one folder per space.
        let notesRoot = root.appendingPathComponent("Notes", isDirectory: true)
        var noteURL: [String: URL] = [:]
        for n in c.notes {
            let folder = notesRoot.appendingPathComponent(n.folder, isDirectory: true)
            Paths.ensure(folder)
            let u = folder.appendingPathComponent(n.title + ".md")
            // The note starts with its heading, and its tags sit on the last line the way people
            // write inline tags. The front matter ids are demo bookkeeping and stay out.
            var text = n.body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            if !n.tags.isEmpty { text += "\n" + n.tags.map { "#" + $0 }.joined(separator: " ") + "\n" }
            try Data(text.utf8).write(to: u)
            try fm.setAttributes([.creationDate: at(n.created), .modificationDate: at(n.updated)], ofItemAtPath: u.path)
            noteURL[n.id] = u.standardizedFileURL
        }
        sum.notes = c.notes.count

        // The demo docs and meetings, read back by the demo:// pages.
        let itemsDir = root.appendingPathComponent("demo-items", isDirectory: true)
        Paths.ensure(itemsDir)
        for i in c.items { try Data(i.raw.utf8).write(to: itemsDir.appendingPathComponent(i.id + ".md")) }

        // Settings: the notes folder, first run done, every outside source off, no auto-archive.
        var settings = AppSettings()
        settings.notesFolders = [notesRoot.path]
        settings.firstRunDone = true
        try JSONEncoder.pretty.encode(settings).write(to: root.appendingPathComponent("settings.json"))
        try JSONEncoder.pretty.encode(SourceConfig()).write(to: root.appendingPathComponent("sources.json"))
        var prefs = BrowserPrefsValue()
        prefs.archiveAfterHours = 0
        try JSONEncoder.pretty.encode(prefs).write(to: root.appendingPathComponent("browser.json"))
        Settings.shared.reloadFromDisk()
        SourceSettings.shared.reload()

        // The index.
        let indexURL = root.appendingPathComponent("index.sqlite")
        let store = try IndexStore(url: indexURL)
        IndexStore.shared = store
        let spaceName = Dictionary(uniqueKeysWithValues: c.layout.spaces.map { ($0.id, $0.name) })
        func during(_ space: String) -> String? { spaceName[space].map { "in your \($0) space" } }
        o.log("Indexing \(c.notes.count) notes and \(c.items.count) docs and meetings (\(Intelligence.shared.documentEmbedder.rawValue) vectors)")
        for n in c.notes {
            guard let u = noteURL[n.id] else { continue }
            let text = (try? String(contentsOf: u, encoding: .utf8)) ?? n.body
            let (d, a) = Indexer.fileDoc(url: u, text: text, root: notesRoot, mtime: at(n.updated).timeIntervalSince1970)
            store.upsertFile(d, analysis: a)
            store.recordVisit(key: d.key, at: at(n.updated).timeIntervalSince1970, kind: "edited", during: during(n.space))
            store.touchOpened(key: d.key, at: at(n.updated))
        }
        for i in c.items {
            var text = i.body
            if i.isMeeting, !i.attendees.isEmpty {
                text = "Attendees: " + i.attendees.map { a in a.name + ([a.role, a.org].compactMap { $0 }.filter { !$0.isEmpty }.isEmpty ? "" : " (" + [a.role, a.org].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ") + ")") }.joined(separator: ", ") + "\n\n" + text
            }
            let a = TextAnalysis.analyze(title: i.title, description: "", text: text)
            let d = DocUpsert(key: i.demoURL, source: i.sourceType, url: i.demoURL, title: i.title, body: text,
                              firstSeen: at(i.created).timeIntervalSince1970, lastSeen: at(i.edited).timeIntervalSince1970,
                              visitCount: 1, mtime: at(i.edited).timeIntervalSince1970)
            let mine = i.owner == nil || i.owner == "Theo Park"
            store.upsertSourceDoc(d, analysis: a, visitKind: i.isMeeting ? "met" : (mine ? "edited" : "opened"))
            store.recordVisit(key: i.demoURL, at: at(i.edited).timeIntervalSince1970, kind: i.isMeeting ? "met" : (mine ? "edited" : "opened"), during: during(i.space))
            store.touchOpened(key: i.demoURL, at: at(i.edited))
        }
        sum.items = c.items.count

        // Browsing history: page text, every visit, and the browser's own history list.
        var texts: [String: DemoFetch.Page] = [:]
        if o.fetchText {
            o.log("Fetching text for \(c.pages.count) pages, cookie-free")
            texts = DemoFetch.fetchAll(c.pages.compactMap { URL(string: $0.url).map { ($0) } })
            o.log("  read \(texts.count) of \(c.pages.count). The rest use their stored excerpt.")
        }
        let history = HistoryStore(path: root.appendingPathComponent("history.sqlite").path)
        let spaceUUID = Dictionary(uniqueKeysWithValues: c.layout.spaces.map { ($0.id, DemoContent.uuid($0.id)) })
        for p in c.pages {
            guard let u = URL(string: p.url), let first = at(p.firstVisit), let last = at(p.lastVisit) else { continue }
            let fetched = texts[p.url]
            let body = fetched?.text.isEmpty == false ? fetched!.text : p.excerpt
            let desc = fetched?.description ?? ""
            let a = TextAnalysis.analyze(title: p.title, description: desc, text: body)
            let d = DocUpsert(key: URLKey.key(for: u), source: .web, url: p.url, title: p.title, description: desc, body: String(body.prefix(20000)),
                              firstSeen: first.timeIntervalSince1970, lastSeen: last.timeIntervalSince1970,
                              visitCount: p.visitCount, dwell: Double(p.dwellSeconds))
            store.recordCapture(d, analysis: a)
            for v in p.visits.compactMap(at) {
                store.recordVisit(key: d.key, at: v.timeIntervalSince1970, kind: "read", during: during(p.space))
                history.record(url: u, title: p.title, spaceID: spaceUUID[p.space], at: v)
                sum.visits += 1
            }
            store.touchOpened(key: d.key, at: last)
            if fetched != nil { sum.fetched += 1 }
        }
        sum.pages = c.pages.count
        let searches = c.history.searches.compactMap { s in at(s.at).map { (s.query, $0.timeIntervalSince1970) } }
        store.importSearches(searches, source: "bar")
        sum.searches = searches.count

        // Vectors from the best model that's ready, then topics.
        while Reembedder.shared.runBatch(size: 64) > 0 {}
        let counts = store.vectorCounts()
        sum.embedder = counts.max { $0.value < $1.value }?.key.rawValue ?? "none"
        sum.vectors = counts.values.reduce(0, +)
        if o.topics && TopicTagger.isAvailable {
            let todo = store.docsNeedingTopics(limit: 2000)
            o.log("Tagging topics for \(todo.count) items with Apple's on-device model")
            for (n, (id, title, text)) in todo.enumerated() {
                let topics = EngineEval.runAsync { await TopicTagger.tag(title: title, text: text) } ?? nil
                store.setTopics(docID: id, topics: topics ?? [], source: "model")
                if topics != nil { sum.tagged += 1 }
                if (n + 1) % 40 == 0 { o.log("  \(n + 1) of \(todo.count)") }
            }
        } else if o.topics {
            o.log("Apple's on-device model isn't available, so no topic tags. The graph still shows shared names.")
        }

        // The layout, then the graph, which reads it for splits.
        let state = buildState(c, noteURL: noteURL, notesRoot: notesRoot, now: o.now)
        try JSONEncoder.pretty.encode(state).write(to: root.appendingPathComponent("state.json"))
        let graph = GraphStore.reset(indexURL: indexURL, index: store)
        func key(_ it: DemoContent.Layout.Item) -> String? { indexKey(it.ref, c, noteURL) }
        for sp in c.layout.spaces {
            for split in sp.splits {
                if let a = key(split.left), let b = key(split.right) { graph.recordTogether(a, b, detail: "split", at: o.now) }
            }
        }
        graph.sync()
        sum.edges = graph.stats().edges.values.reduce(0, +)

        if o.favicons { cacheIcons(c) } else { writeDemoIcons() }
        try writeMarker(root, anchor: c.anchor, shift: shift, done: true)
        sum.seconds = Date().timeIntervalSince(started)
        return sum
    }

    static func writeMarker(_ root: URL, anchor: Date, shift: TimeInterval, done: Bool) throws {
        let info: [String: Any] = [
            "madeBy": "BrowserPOC --seed-demo",
            "note": "A demo profile with made-up content. Reseeding clears this folder, keeping Models.",
            "seededAt": ISO8601DateFormatter().string(from: Date()),
            "anchor": ISO8601DateFormatter().string(from: anchor),
            "shiftHours": (shift / 3600 * 10).rounded() / 10,
            "complete": done,
        ]
        try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent(marker))
    }

    /// The index key for a content id: a note's file, a demo item's address or a page's URL.
    nonisolated static func indexKey(_ ref: String, _ c: DemoContent, _ noteURL: [String: URL]) -> String? {
        if let u = noteURL[ref] { return URLKey.fileKey(u) }
        if let i = c.item(ref) { return i.demoURL }
        if let p = c.page(ref), let u = URL(string: p.url) { return URLKey.key(for: u) }
        return nil
    }

    // MARK: Layout

    static func buildState(_ c: DemoContent, noteURL: [String: URL], notesRoot: URL, now: Date) -> SavedState {
        let id = DemoContent.uuid
        var tabs: [TabRecord] = []
        var folders: [Folder] = []
        var splits: [SplitRecord] = []
        var spaces: [Space] = []

        func record(_ it: DemoContent.Layout.Item, space: UUID) -> TabRecord? {
            let kind: TabKind, url: String, title: String
            switch it.kind {
            case "note":
                guard let n = c.note(it.ref), let u = noteURL[it.ref] else { return nil }
                kind = .note; url = u.absoluteString; title = n.title
            case "doc", "meeting":
                guard let i = c.item(it.ref) else { return nil }
                kind = .web; url = i.demoURL; title = i.title
            default:
                guard let p = c.page(it.ref) else { return nil }
                kind = .web; url = p.url; title = p.title
            }
            var r = TabRecord(id: id(it.id), kind: kind, url: url, title: title, isPinned: false, folderID: nil, createdAt: now, spaceID: space)
            r.lastActiveAt = now
            return r
        }

        let first = c.layout.spaces.first.map { id($0.id) } ?? UUID()
        for (n, it) in c.layout.essentials.enumerated() {
            guard var r = record(it, space: first) else { continue }
            r.isEssential = true
            r.isPinned = true
            r.pinnedURL = r.url
            r.order = Double(n)
            tabs.append(r)
        }
        for s in c.layout.spaces {
            let sid = id(s.id)
            for (n, it) in s.pinned.enumerated() {
                guard var r = record(it, space: sid) else { continue }
                r.isPinned = true
                r.pinnedURL = r.url
                r.order = Double(n)
                tabs.append(r)
            }
            for (fn, f) in s.folders.enumerated() {
                let fid = id(f.id)
                folders.append(Folder(id: fid, spaceID: sid, name: f.name, isExpanded: f.expanded, createdAt: now, order: Double(fn)))
                for (n, it) in f.items.enumerated() {
                    guard var r = record(it, space: sid) else { continue }
                    r.folderID = fid
                    r.order = Double(n)
                    tabs.append(r)
                }
            }
            var order = 0.0
            for sp in s.splits {
                guard var l = record(sp.left, space: sid), var r = record(sp.right, space: sid) else { continue }
                l.order = order; r.order = order + 0.5
                order += 1
                tabs += [l, r]
                var rec = SplitRecord(id: id(sp.id), root: .branch(.row, [.leaf(l.id), .leaf(r.id)], [sp.ratio, 1 - sp.ratio]),
                                      focused: sp.focus == "left" ? l.id : r.id, createdAt: now, spaceID: sid)
                rec.order = Double(splits.count)
                splits.append(rec)
            }
            for it in s.tabs {
                guard var r = record(it, space: sid) else { continue }
                r.order = order
                order += 1
                tabs.append(r)
            }
            var space = Space(id: sid, name: s.name, icon: s.icon, color: s.color)
            space.newNotesFolder = notesRoot.appendingPathComponent(s.notesFolder, isDirectory: true).path
            space.selectedSplit = s.selected.split.map(id)
            space.selectedTab = s.selected.item.map(id)
            spaces.append(space)
        }
        var state = SavedState()
        state.spaces = spaces
        state.currentSpace = id(c.layout.currentSpace)
        state.tabs = tabs
        state.folders = folders
        state.splits = splits
        if let cur = spaces.first(where: { $0.id == state.currentSpace }) {
            state.selectedSplit = cur.selectedSplit
            state.selectedTab = cur.selectedTab
        }
        return state
    }

    // MARK: Icons

    /// The demo sources' icons, under the hosts their demo addresses use.
    static func writeDemoIcons() {
        Paths.ensure(Favicons.dir)
        for h in DemoIcons.hosts {
            if let png = DemoIcons.png(h) { try? png.write(to: Favicons.file(h)) }
        }
    }

    /// The demo icons, plus each site's own icon, fetched cookie-free the way the app does.
    static func cacheIcons(_ c: DemoContent) {
        writeDemoIcons()
        var seen = Set<String>()
        for p in c.pages {
            guard let u = URL(string: p.url), let k = Favicons.key(u), !seen.contains(k) else { continue }
            seen.insert(k)
            Favicons.shared.ensure(u)
        }
        // Wait until icons stop arriving, at most 30 seconds.
        var last = Favicons.shared.generation, quietSince = Date()
        let end = Date().addingTimeInterval(30)
        while Date() < end && Date().timeIntervalSince(quietSince) < 4 {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.2))
            if Favicons.shared.generation != last { last = Favicons.shared.generation; quietSince = Date() }
        }
    }
}

/// Page text for the demo history, with the app's cookie-free session and its redirect rules.
enum DemoFetch {
    struct Page: Sendable { let title: String; let description: String; let text: String }

    static func fetchAll(_ urls: [URL]) -> [String: Page] {
        EngineEval.runAsync { await fetch(urls) } ?? [:]
    }

    static func fetch(_ urls: [URL]) async -> [String: Page] {
        let delegate = ChromeFetcher()
        let session = ChromeFetcher.makeSession(delegate: delegate)
        defer { session.invalidateAndCancel() }
        var out: [String: Page] = [:]
        await withTaskGroup(of: (String, Page?).self) { group in
            var it = urls.makeIterator()
            func next() -> Bool {
                guard let u = it.next() else { return false }
                group.addTask { (u.absoluteString, await one(u, session)) }
                return true
            }
            for _ in 0..<6 { if !next() { break } }
            while let (k, p) = await group.next() {
                if let p { out[k] = p }
                _ = next()
            }
        }
        return out
    }

    static func one(_ u: URL, _ session: URLSession) async -> Page? {
        if let p = await appleDocs(u, session) { return p }
        var req = URLRequest(url: u)
        req.httpShouldHandleCookies = false
        req.timeoutInterval = 15
        guard let (data, resp) = try? await session.data(for: req), let http = resp as? HTTPURLResponse, http.statusCode == 200,
              (http.mimeType ?? "").lowercased().contains("html"), data.count < 6_000_000 else { return nil }
        let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let e = HTMLText.extract(html)
        if HTMLText.isLoginWall(e) || e.text.count < 200 { return nil }
        return Page(title: e.title, description: e.description, text: e.text)
    }

    /// Apple's documentation pages draw their text with JavaScript, so a plain fetch gets only the
    /// summary. The page itself loads the same content as public JSON, which this reads instead,
    /// so the index has what the browser would have captured from the rendered page.
    static func appleDocs(_ u: URL, _ session: URLSession) async -> Page? {
        guard u.host == "developer.apple.com", u.path.hasPrefix("/documentation/") || u.path.hasPrefix("/design/"),
              let json = URL(string: "https://developer.apple.com/tutorials/data" + u.path.replacingOccurrences(of: "/$", with: "", options: .regularExpression) + ".json")
        else { return nil }
        var req = URLRequest(url: json)
        req.httpShouldHandleCookies = false
        req.timeoutInterval = 15
        guard let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var lines: [String] = []
        var line = ""
        let blocks: Set<String> = ["paragraph", "heading", "aside", "unorderedList", "orderedList", "termList", "table"]
        func walk(_ v: Any) {
            if let d = v as? [String: Any] {
                let type = d["type"] as? String ?? ""
                if type == "codeListing" { return }
                if type == "heading", let t = d["text"] as? String { lines.append(t); return }
                if type == "text", let t = d["text"] as? String { line += t; return }
                if type == "codeVoice", let t = d["code"] as? String { line += t; return }
                for k in ["abstract", "content", "inlineContent", "items", "rows"] { if let x = d[k] { walk(x) } }
                if blocks.contains(type), !line.isEmpty { lines.append(line); line = "" }
            } else if let a = v as? [Any] {
                for x in a { walk(x) }
            }
        }
        walk(root["abstract"] ?? [])
        if !line.isEmpty { lines.append(line); line = "" }
        let summary = lines.joined(separator: " ")
        walk(root["primaryContentSections"] ?? [])
        if !line.isEmpty { lines.append(line) }
        let text = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
        guard text.count >= 200 else { return nil }
        let title = (root["metadata"] as? [String: Any])?["title"] as? String ?? ""
        return Page(title: title, description: summary, text: text)
    }
}
