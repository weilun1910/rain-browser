import Foundation

/// The command bar: ranking, URL versus search, Esc, Cmd-L in place, past searches and speed.
enum CommandBarTests {
    static func check(_ ok: Bool, _ label: String, _ detail: String = "") { SelfTest.check(ok, label, detail) }

    static func run(dir: URL) {
        let root = dir.appendingPathComponent("notes-root", isDirectory: true)
        let nookNote = root.appendingPathComponent("Nook ideas.md")
        SelfTest.write("# Nook ideas\n\nWhat Nook does with native messaging is worth copying for Bitwarden.\n", to: nookNote)
        let sem = DispatchSemaphore(value: 0)
        NotesIndexer.shared.sync(roots: [NotesScan.scan(root)]) { sem.signal() }
        sem.wait()
        IndexStore.shared.addSearch("nook browser extensions", at: Date().addingTimeInterval(-3600))
        IndexStore.shared.addSearch("nook vs arc", at: Date().addingTimeInterval(-60))

        MainActor.assumeIsolated {
            BrowserModel.useEphemeralStore = true
            try? FileManager.default.removeItem(at: Paths.stateFile)
            let model = BrowserModel()
            let tab = Tab(url: URL(string: "about:blank")!, title: "Nook on GitHub")
            tab.model = model
            model.tabs.append(tab)

            // Ranking for a typed query.
            model.bar.open(.newTab, text: "nook")
            let rows = model.bar.results
            let groups = rows.map { $0.group }
            let order: [Suggestion.Group] = [.tabs, .notes, .searches, .history, .actions]
            let firstIndex = order.map { g in groups.firstIndex(of: g) ?? -1 }
            check(!firstIndex.contains(-1) && firstIndex == firstIndex.sorted(), "suggestions come in the order Tabs, Notes, Searches, History, then actions",
                  rows.map { "\($0.group.rawValue): \($0.title.prefix(30))" }.joined(separator: " | "))
            check(rows.first { $0.group == .notes }?.subtitle.contains("native messaging") == true, "notes show the matching line")
            check(rows.filter { $0.group == .searches }.map { $0.title } == ["nook vs arc", "nook browser extensions"], "recent past searches rank higher")
            check(rows.contains { $0.title == "New note: nook" } && rows.contains { $0.title == "Search Google for nook" }, "Search Google and New note rows are there")

            // URL detection versus search.
            model.bar.query = "github.com/nook-browser"
            let urlFirst = model.bar.results.first
            model.bar.query = "how do swift actors work"
            let searchRows = model.bar.results
            check(urlFirst.map { if case .openURL(let u) = $0.kind { return u.absoluteString == "https://github.com/nook-browser" }; return false } == true
                  && !searchRows.contains { if case .openURL = $0.kind { return true }; return false },
                  "a typed address shows Open, a phrase doesn't", urlFirst?.title ?? "nil")

            // Esc creates nothing.
            let before = model.tabs.map { $0.id }
            let sel = model.currentTab?.id
            model.bar.open(.newTab, text: "something")
            model.bar.close()
            check(model.tabs.map { $0.id } == before && model.currentTab?.id == sel && !model.bar.isOpen, "Esc closes the bar with nothing created")

            // Cmd-L navigates the focused pane in place.
            model.select(tab)
            model.focusAddress()
            let modeOK = model.bar.mode == .navigate(tab.id) && model.bar.query == "about:blank"
            model.bar.query = "about:blank#in-place"
            model.bar.submit()
            check(modeOK && tab.url?.absoluteString == "about:blank#in-place" && model.tabs.count == before.count && model.currentTab?.id == tab.id,
                  "Cmd-L opens the bar with the address and Enter loads in the same tab", tab.url?.absoluteString ?? "nil")

            // A Google search from the bar is remembered.
            model.bar.open(.navigate(tab.id), text: "swift actors explained")
            if let g = model.bar.results.first(where: { if case .google = $0.kind { return true }; return false }) { model.bar.pick(g) }
            model.bar.open(.newTab, text: "swift act")
            check(model.bar.results.contains { $0.group == .searches && $0.title == "swift actors explained" }, "searches run from the bar are stored and suggested")
            model.bar.close()

            // Notes are found from every space.
            let other = model.createSpace(name: "Elsewhere")
            model.switchSpace(to: other.id)
            model.bar.open(.newTab, text: "nook ideas")
            check(model.bar.results.contains { if case .note(let u) = $0.kind { return u.lastPathComponent == "Nook ideas.md" }; return false },
                  "notes show up in the bar in every space")
            model.bar.close()
            model.prepareForQuit()
            try? FileManager.default.removeItem(at: Paths.stateFile)
        }
        speed(dir: dir)
    }

    /// Suggestions stay well under 100 ms on an index the size of Felix's.
    static func speed(dir: URL) {
        guard let store = try? IndexStore(url: dir.appendingPathComponent("speed.sqlite")) else { return }
        let words = ["swift", "actors", "browser", "webkit", "notion", "bread", "marathon", "design", "figma", "research", "interview",
                     "convenience", "store", "extension", "chrome", "plan", "budget", "travel", "camera", "music"]
        var docs: [(DocUpsert, Analysis)] = []
        for i in 0..<3000 {
            let title = (0..<4).map { words[(i * 7 + $0 * 3) % words.count] }.joined(separator: " ") + " \(i)"
            let key = "https://site\(i % 300).example/page/\(i)"
            let t = Date().timeIntervalSince1970 - Double(i) * 1000
            docs.append((DocUpsert(key: key, source: .chrome, url: key, title: title, firstSeen: t, lastSeen: t, visitCount: i % 9),
                         Analysis(passages: [title], vectors: [nil], entities: [])))
        }
        _ = store.importChrome(docs)
        for i in 0..<150 {
            let d = DocUpsert(key: "file:///speed/\(i).md", source: .note, url: "file:///speed/\(i).md", title: "Note \(i)",
                              body: "Thinking about \(words[i % words.count]) and \(words[(i + 5) % words.count]) for the plan.", firstSeen: 0, lastSeen: 0)
            store.upsertFile(d, analysis: Analysis(passages: [d.body], vectors: [nil], entities: []))
        }
        for i in 0..<400 { store.addSearch("\(words[i % words.count]) \(words[(i * 3) % words.count]) \(i)") }
        var worst = 0.0
        for q in ["s", "sw", "swift ac", "browser webkit", "notion plan", "github.com", "zzz"] {
            let start = Date()
            _ = Suggest.build(q, tabs: [], store: store)
            worst = max(worst, Date().timeIntervalSince(start) * 1000)
        }
        check(worst < 100, "suggestions take under 100 ms on 3,000 pages, 150 notes and 400 searches", String(format: "slowest %.1f ms", worst))
    }
}
