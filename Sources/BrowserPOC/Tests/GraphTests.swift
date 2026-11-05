import Foundation

/// The graph: edges of every type from a fixture index, the MCP read calls, the builder,
/// the simulation and the renderer, plus a performance check at 5,000 nodes.
enum GraphTests {
    static func check(_ ok: Bool, _ label: String, _ detail: String = "") { SelfTest.check(ok, label, detail) }

    struct Fix {
        let name: String
        let source: SourceType
        let url: String
        let title: String
        let text: String
    }

    static let notesDir = "/graphfix/notes/"
    static func noteURL(_ file: String) -> String { URL(fileURLWithPath: notesDir + file).standardizedFileURL.absoluteString }
    static func key(_ f: Fix) -> String {
        f.source == .note ? URLKey.fileKey(URL(string: f.url)!) : URLKey.key(for: URL(string: f.url)!)
    }

    static let plan = Fix(name: "plan", source: .note, url: noteURL("Browser plan.md"), title: "Browser plan", text: """
        # Browser plan

        Start from [[Engine notes]] and the [[Extension research|extension notes]]. Read [the WebKit post](https://webkit.org/blog/extensions) \
        and https://developer.apple.com/documentation/webkit/wkwebextension before deciding. Later: [[Missing idea]].
        Unrelated aside about bread is in [my bread log](Bread%20log.md).
        """)
    static let engine = Fix(name: "engine", source: .note, url: noteURL("Engine notes.md"), title: "Engine notes", text: """
        # Engine notes

        WebKit ships with macOS, so there's no engine upkeep. Back to [[Browser plan]]. Self link [[Engine notes]] is ignored.
        """)
    static let bread = Fix(name: "bread", source: .note, url: noteURL("Bread log.md"), title: "Bread log", text: """
        # Bread log

        Saturday loaf at 75 percent hydration with a levain built the night before. The sourdough starter was sluggish, \
        so next time feed the starter with rye flour twice a day and keep it warm before the bake. Bulk fermentation took five hours.
        """)
    static let extNote = Fix(name: "ext", source: .note, url: noteURL("Extension research.md"), title: "Extension research", text: """
        # Extension research

        WKWebExtensionController loads Chrome and Safari extensions in a WebKit browser.
        """)
    static let webkitBlog = Fix(name: "blog", source: .web, url: "https://webkit.org/blog/extensions", title: "Web extensions in WebKit apps", text: """
        WebKit apps can now load web extensions with WKWebExtension and WKWebExtensionController. The browser reports tab \
        and window events to the controller so extensions see the same tabs as the user. Manifest version 3 is supported.
        """)
    static let appleDoc = Fix(name: "apple", source: .web, url: "https://developer.apple.com/documentation/webkit/wkwebextension", title: "WKWebExtension", text: """
        WKWebExtension is an object that encapsulates a web extension's resources. Create it from a folder or a ZIP archive \
        that contains a manifest.json file, then load it into a WKWebExtensionController through a WKWebExtensionContext.
        """)
    static let hn = Fix(name: "hn", source: .web, url: "https://news.ycombinator.com/item?id=4242", title: "Show HN: a browser on WebKit", text: """
        Show HN thread about a Mac browser written in Swift on WKWebView, with people asking about extensions, password managers and tabs.
        """)
    static let starter = Fix(name: "starter", source: .web, url: "https://www.kingarthurbaking.com/sourdough-starter-guide", title: "How to feed a sourdough starter", text: """
        A healthy sourdough starter rises predictably after each feeding. Feed it equal weights of flour and water and keep it warm. \
        A sluggish starter that smells of acetone is hungry, so feed it twice a day with some whole rye flour until the levain doubles \
        and smells pleasantly sour. Then it's ready to mix into bread dough for a long bulk fermentation.
        """)
    static let starter2 = Fix(name: "starter2", source: .web, url: "https://www.seriouseats.com/sourdough-starter-feeding", title: "Feeding your sourdough starter", text: """
        To keep a sourdough starter lively, feed it flour and water every day and keep it somewhere warm. If the starter is sluggish \
        or smells like acetone, it is hungry: feed it twice a day, add a little rye flour, and wait for the levain to double and smell \
        sour before you mix your bread dough and start bulk fermentation.
        """)
    static let gh = (1...3).map { i in
        Fix(name: "gh\(i)", source: .chrome, url: "https://github.com/someone/repo\(i)", title: "someone/repo\(i)", text: "")
    }

    static func seed(_ store: IndexStore, _ fixes: [Fix], at: Double) {
        for f in fixes {
            let a = TextAnalysis.analyze(title: f.title, description: "", text: f.text)
            var d = DocUpsert(key: key(f), source: f.source, url: f.url, title: f.title, body: f.text, firstSeen: at, lastSeen: at, visitCount: 2, mtime: at)
            switch f.source {
            case .web: store.recordCapture(d, analysis: a)
            case .chrome: d.body = ""; _ = store.importChrome([(d, a)])
            case .note, .markdown: d.project = "Notes"; d.root = notesDir; store.upsertFile(d, analysis: a)
            }
        }
    }

    static func run(dir: URL) {
        let gdir = dir.appendingPathComponent("graph", isDirectory: true)
        try? FileManager.default.removeItem(at: gdir)
        Paths.ensure(gdir)
        let indexURL = gdir.appendingPathComponent("index.sqlite")
        guard let index = try? IndexStore(url: indexURL) else { check(false, "graph fixture index opens"); return }
        let store = GraphStore.reset(indexURL: indexURL)
        let now = Date().timeIntervalSince1970
        let first: [Fix] = [plan, engine, bread, webkitBlog, appleDoc, hn, starter, starter2] + gh
        seed(index, first, at: now - 86400 * 3)
        let n = store.sync()
        check(n == first.count, "graph sync reads every new item", "\(n) of \(first.count)")

        var s = store.snapshot()
        func idx(_ f: Fix) -> Int? { s.indexByKey[key(f)] }
        func has(_ a: Fix, _ b: Fix, _ t: GraphEdgeType) -> Bool {
            guard let ai = idx(a), let bi = idx(b) else { return false }
            return s.links.contains { $0.type == t && (($0.a == ai && $0.b == bi) || (!t.directed && $0.a == bi && $0.b == ai)) }
        }
        func unresolved(_ name: String) -> Bool { s.nodes.contains { $0.kind == .unresolved && $0.title == name } }

        check(has(plan, engine, .link) && has(engine, plan, .link), "wikilinks connect notes both ways")
        check(has(plan, webkitBlog, .link), "a Markdown link to an indexed page is an edge")
        check(has(plan, appleDoc, .link), "a bare URL in a note that matches an indexed page is an edge")
        check(has(plan, bread, .link), "a relative Markdown link to another note is an edge")
        check(unresolved("Extension research") && unresolved("Missing idea"), "wikilinks to notes that don't exist yet show as not created")
        check(!s.links.contains { l in l.type == .link && l.a == l.b }, "a note's link to itself is ignored")

        // The target note gets indexed later and the link resolves on its own.
        seed(index, [extNote], at: now - 86400)
        store.sync()
        s = store.snapshot()
        check(has(plan, extNote, .link) && !unresolved("Extension research") && unresolved("Missing idea"),
              "a wikilink resolves when its note is indexed later")

        // Browser-only connections.
        GraphRecorder.linkFollowed(from: URL(string: hn.url), to: URL(string: webkitBlog.url + "#comments"))
        store.recordResearch(contextKey: key(bread), addedKey: key(starter))
        store.recordTogether(key(webkitBlog), key(appleDoc), detail: "split")
        store.recordTogether(key(engine), key(hn), detail: "session")
        s = store.snapshot()
        check(has(hn, webkitBlog, .navigation) && !has(webkitBlog, hn, .navigation), "a link click becomes a directed navigation edge")
        check(has(bread, starter, .research), "Add to research becomes a research edge from the note")
        check(has(webkitBlog, appleDoc, .together), "a split becomes a together edge")
        check(!has(engine, hn, .together), "one session together isn't enough to show")
        store.recordTogether(key(hn), key(engine), detail: "session")
        s = store.snapshot()
        check(has(engine, hn, .together), "two sessions together show")

        // Similar meaning from today's vectors.
        if Embedder.shared.isAvailable {
            let src = IndexVectorNeighbours(reader: IndexReader(db: try! SQLiteDB(path: indexURL.path, readOnly: true)))
            src.refresh(nil)
            if let sid = index.doc(key: key(starter))?.id {
                let ns = src.neighbours(of: sid, k: 5)
                src.minScore = 0
                let all = src.neighbours(of: sid, k: 12)
                let titles = Dictionary(uniqueKeysWithValues: s.nodes.compactMap { n in n.docID.map { ($0, n.title) } })
                print("      similarity to the starter guide: " + all.map { String(format: "%@ %.2f", (titles[$0.docID] ?? "?").prefix(22) as CVarArg, $0.score) }.joined(separator: ", "))
                check(ns.contains { titles[$0.docID] == starter2.title }, "two pages about feeding a starter are similar in meaning")
                check(!ns.contains { titles[$0.docID] == webkitBlog.title || titles[$0.docID] == hn.title }, "a starter guide isn't similar to WebKit pages")
            }
            check(has(starter, starter2, .similar), "similarity edges are stored by the sync")
        } else {
            print("      Sentence embedding not available, so similarity edges are skipped.")
        }

        // The read calls the MCP server uses.
        if let pid = store.itemID(forKey: key(plan)), let hid = store.itemID(forKey: key(hn)), let bid = store.itemID(forKey: key(bread)) {
            let d1 = store.neighbours(itemID: pid, depth: 1)
            let t1 = Set(d1.map { $0.item.title })
            check(t1.isSuperset(of: [engine.title, webkitBlog.title, appleDoc.title, bread.title, extNote.title]) && d1.allSatisfy { $0.depth == 1 },
                  "neighbours at depth 1", t1.sorted().joined(separator: ", "))
            let d2 = store.neighbours(itemID: pid, depth: 2)
            let deep = Set(d2.filter { $0.depth == 2 }.map { $0.item.title })
            check(deep.contains(starter.title), "neighbours at depth 2 reach connections of connections", deep.sorted().joined(separator: ", "))
            let onlyLinks = store.neighbours(itemID: pid, depth: 1, types: [.navigation])
            check(onlyLinks.isEmpty, "neighbours can be limited to edge types")
            let es = store.edges(itemID: hid)
            let whys = es.map { $0.why }
            check(es.contains { $0.type == .navigation && $0.directed } && whys.allSatisfy { !$0.isEmpty && Fmt.clean($0) == $0 },
                  "edges come with plain reasons", whys.joined(separator: " | "))
            if let p = store.path(from: hid, to: bid) {
                let starts = p.first.map { $0.from == hid || $0.to == hid } ?? false
                let ends = p.last.map { $0.from == bid || $0.to == bid } ?? false
                check(p.count >= 2 && starts && ends,
                      "a path connects two items", p.map { $0.why }.joined(separator: " > "))
            } else {
                check(false, "a path connects two items")
            }
            let st = store.stats()
            check(st.items == first.count + 1 && (st.edges["link"] ?? 0) >= 6, "graph stats", "\(st.items) items, \(st.edges)")
        } else {
            check(false, "fixture items have graph IDs")
        }

        // Items that leave the index take their edges with them.
        index.deleteDocs(keys: [key(engine)])
        store.sync()
        s = store.snapshot()
        check(idx(engine) == nil && !has(plan, engine, .link), "deleted items drop out of the graph")
        let leftover = (try? SQLiteDB(path: indexURL.path).scalarInt("SELECT count(*) FROM g_edges WHERE type = 'link' AND a = ?", [key(engine)])) ?? -1
        check(leftover == 0, "links from a deleted note are pruned from the table", "\(leftover)")

        recorderTests(dir: gdir, store: store)
        GraphLayoutTests.builderTests(store)
        GraphMotionTests.run(store: store)
        GraphLayoutTests.simulationTests()
        GraphLayoutTests.performanceTests()
    }

    /// Splits and sessions recorded from a real model, on a fake clock.
    static func recorderTests(dir: URL, store: GraphStore) {
        let a = dir.appendingPathComponent("session-a.md"), b = dir.appendingPathComponent("session-b.md"), c = dir.appendingPathComponent("session-c.md")
        for u in [a, b, c] { SelfTest.write("# \(u.lastPathComponent)\n", to: u) }
        MainActor.assumeIsolated {
            BrowserModel.useEphemeralStore = true
            let model = BrowserModel()
            let rec = GraphRecorder.shared
            var clock = Date()
            rec.now = { clock }
            rec.attach(model)
            let ta = model.openNote(a), tb = model.openNote(b, select: false), tc = model.openNote(c, select: false)
            rec.focusChanged()
            clock += 30
            model.select(tb); rec.focusChanged()
            clock += 30
            model.select(tc); rec.focusChanged()
            clock += 5
            model.select(ta); rec.focusChanged()
            rec.endFocus()
            let ka = URLKey.fileKey(a), kb = URLKey.fileKey(b), kc = URLKey.fileKey(c)
            /// The together edge between two keys, after queued writes land.
            func together(_ x: String, _ y: String) -> String? {
                _ = SelfTest.spin(0.3) { false } // the model's publishers deliver on the main queue
                _ = store.snapshot()
                let rows = (try? SQLiteDB(path: store.url.path).query("SELECT a, b, detail FROM g_edges WHERE type = 'together'") {
                    ($0.text(0), $0.text(1), $0.text(2))
                }) ?? []
                return rows.first { ($0.0 == x && $0.1 == y) || ($0.0 == y && $0.1 == x) }?.2
            }
            check(together(ka, kb) == "session", "two items focused for a while in a row are used together")
            check(together(kb, kc) == nil, "an item focused for five seconds doesn't count")
            model.openInSplit(tb, side: .right)
            let split = together(ka, kb)
            check(split == "split", "opening two items in a split records them as a split", split ?? "none")
            rec.now = { Date() }
            _ = tc
            model.prepareForQuit()
        }
    }
}
