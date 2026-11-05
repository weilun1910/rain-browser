import Foundation

extension IndexStore {
    /// The stored text of one item, for the demo eval's contexts.
    func storedBody(key: String) -> (title: String, body: String)? {
        queue.sync { (try? db.query("SELECT title, body FROM docs WHERE key = ?", [key]) { ($0.text(0), $0.text(1)) })?.first }
    }
}

/// `--demo-eval <profile>`: runs Related's pipelines over a copy of a seeded demo profile's
/// index and scores the labelled cases in `Demo/expected.json`. The profile itself isn't
/// opened for writing. Precision at 3 counts a card as right when the case lists it as a
/// must, a nice or an acceptable card, over up to three cards per section, the way the panel
/// shows them.
enum DemoEval {
    struct Score {
        var cards = 0, right = 0, strict = 0, mustShown = 0, mustTotal = 0, wrong = 0, doubles = 0
        var p3Sum = 0.0, p3Cases = 0, empty = 0, ms = 0.0, runs = 0
        var precision: Double { p3Cases == 0 ? 0 : p3Sum / Double(p3Cases) }
        var line: String {
            String(format: "precision@3 %.2f  must recall %d/%d  shouldn't-show hits %d  near-duplicate pairs %d  cards %d  no cards %d  avg %.0f ms",
                   precision, mustShown, mustTotal, wrong, doubles, cards, empty, runs == 0 ? 0 : ms / Double(runs))
        }
    }

    static func commandLine(_ args: [String]) -> Int32 {
        func arg(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        guard let p = arg("--demo-eval") else { print("Usage: --demo-eval <demo profile> [--demo-content <Demo folder>] [--verbose]"); return 2 }
        let profile = URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: profile.appendingPathComponent(DemoSeeder.marker).path) else {
            print("\(profile.path) isn't a demo profile. Make one with --seed-demo first.")
            return 1
        }
        guard let dir = DemoContent.locate(arg("--demo-content")), let c = try? DemoContent.load(dir), let expected = c.expected else {
            print("Couldn't load Demo/ and its expected.json. Pass --demo-content <path to Demo>.")
            return 1
        }
        return run(profile: profile, content: c, expected: expected, verbose: args.contains("--verbose"))
    }

    static func run(profile: URL, content c: DemoContent, expected: DemoContent.Expected, verbose: Bool) -> Int32 {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("BrowserPOC-demo-eval-\(UUID().uuidString)", isDirectory: true)
        Paths.ensure(tmp)
        defer { try? fm.removeItem(at: tmp) }
        for f in ["index.sqlite", "index.sqlite-wal", "index.sqlite-shm"] {
            try? fm.copyItem(at: profile.appendingPathComponent(f), to: tmp.appendingPathComponent(f))
        }
        Paths.overrideRoot = tmp
        ModelFiles.overrideDir = profile.appendingPathComponent("Models", isDirectory: true)
        ModelFiles.clearReadyCache()
        Intelligence.shared.modelsChanged()
        Reembedder.shared.enabled = false
        guard let store = try? IndexStore(url: tmp.appendingPathComponent("index.sqlite")) else { print("Couldn't open the index copy"); return 1 }
        IndexStore.shared = store

        // Content ids to index keys and back.
        let notesRoot = profile.appendingPathComponent("Notes", isDirectory: true)
        var noteURL: [String: URL] = [:]
        for n in c.notes { noteURL[n.id] = notesRoot.appendingPathComponent(n.folder).appendingPathComponent(n.title + ".md").standardizedFileURL }
        func key(_ ref: String) -> String? { DemoSeeder.indexKey(ref, c, noteURL) }
        var refOf: [String: String] = [:]
        for n in c.notes { if let k = key(n.id) { refOf[k] = n.id } }
        for i in c.items { refOf[i.demoURL] = i.id }
        for pg in c.pages { if let k = key(pg.id) { refOf[k] = pg.id } }
        func title(_ ref: String) -> String { c.note(ref)?.title ?? c.item(ref)?.title ?? c.page(ref)?.title ?? ref }

        let haveReranker = ModelFiles.isReady(ModelCatalog.reranker)
        let haveFM = ContextReader.isAvailable
        print("Demo eval on a copy of \(profile.lastPathComponent)")
        print("Vectors: \(store.vectorCounts().map { "\($0.key.rawValue) \($0.value)" }.joined(separator: ", "))  Reranker: \(haveReranker ? "ready" : "not found")  Foundation Models: \(haveFM ? "available" : "unavailable")")
        print("Cases: \(expected.cases.count)\n")

        var params = RankParams.fromSettings(AppSettings())
        params.now = Date()
        typealias Runner = (ContextInput) -> [[String]]
        var modes: [(String, Runner)] = []
        modes.append(("Hybrid retrieval, no reranker", { input in
            Intelligence.shared.rerankerDisabled = true
            let r = Pipeline.rank(Pipeline.makeQuery(input, work: nil, store: store), params, store: store)
            return [r.sites.prefix(params.limit).map { $0.doc.key }, r.docs.prefix(params.limit).map { $0.doc.key }]
        }))
        if haveReranker {
            modes.append(("Hybrid retrieval and reranker", { input in
                Intelligence.shared.rerankerDisabled = false
                let r = Pipeline.rank(Pipeline.makeQuery(input, work: nil, store: store), params, store: store)
                return [r.sites.prefix(params.limit).map { $0.doc.key }, r.docs.prefix(params.limit).map { $0.doc.key }]
            }))
        }
        if haveFM {
            modes.append(("Full, as the panel runs it (Foundation Models context and judgment)", { input in
                Intelligence.shared.rerankerDisabled = false
                let work = EngineEval.runAsync { await ContextReader.describe(input) } ?? nil
                let r = Pipeline.rank(Pipeline.makeQuery(input, work: work, store: store), params, store: store)
                var shown: [[String]] = []
                for list in [r.sites, r.docs] {
                    var keep: [String] = []
                    for m in list where keep.count < params.limit {
                        if m.score >= r.gate.strong { keep.append(m.doc.key); continue }
                        guard let cand = r.candidates[m.doc.id] else { continue }
                        let j = EngineEval.runAsync { await Judge.judge(work: work, input: input, item: cand, history: Reasons.history(m.doc)) } ?? nil
                        if Pipeline.accept(m, judgment: j, gate: r.gate) { keep.append(m.doc.key) }
                    }
                    shown.append(keep)
                }
                return shown
            }))
        }

        var results: [(String, Score)] = []
        for (name, runner) in modes {
            var s = Score()
            print(name)
            for cs in expected.cases {
                guard let ck = key(cs.context.ref) else { print("  \(cs.id): unknown context \(cs.context.ref)"); continue }
                let text: String, ctitle: String, kind: ContextKind
                if let u = noteURL[cs.context.ref] {
                    ctitle = c.note(cs.context.ref)?.title ?? ""
                    text = (try? String(contentsOf: u, encoding: .utf8)) ?? ""
                    kind = .note
                } else {
                    let b = store.storedBody(key: ck)
                    ctitle = b?.title ?? title(cs.context.ref)
                    text = b?.body ?? ""
                    kind = .page
                }
                // What's on screen beside the context was just opened, so the app hides it.
                let screen = cs.onScreen.compactMap(key)
                let before = screen.map { store.doc(key: $0)?.lastOpened ?? 0 }
                for k in screen { store.touchOpened(key: k, at: Date()) }
                let t = Date()
                let keys = runner(ContextInput(key: ck, title: ctitle, text: text, kind: kind))
                s.ms += Date().timeIntervalSince(t) * 1000
                s.runs += 1
                for (k, b) in zip(screen, before) { store.touchOpened(key: k, at: Date(timeIntervalSince1970: b)) }

                let shown = keys.flatMap { $0 }.map { refOf[$0] ?? $0 }
                let must = Set(cs.must.map(\.ref)), nice = Set(cs.nice.map(\.ref)), ok = Set(cs.acceptable)
                let bad = Set(cs.shouldNotSurface.map(\.ref))
                let right = shown.filter { must.contains($0) || nice.contains($0) || ok.contains($0) }.count
                s.cards += shown.count
                s.right += right
                s.strict += shown.filter { must.contains($0) || nice.contains($0) }.count
                s.mustTotal += must.count
                s.mustShown += must.intersection(shown).count
                s.wrong += shown.filter { bad.contains($0) }.count
                s.doubles += cs.atMostOneOf.filter { g in g.filter { shown.contains($0) }.count > 1 }.count
                if shown.isEmpty { s.empty += 1 } else { s.p3Sum += Double(right) / Double(shown.count); s.p3Cases += 1 }
                let tag: (String) -> String = { r in must.contains(r) ? "must" : nice.contains(r) ? "nice" : ok.contains(r) ? "ok" : bad.contains(r) ? "NOT" : "other" }
                let p = shown.isEmpty ? "-" : String(format: "%.2f", Double(right) / Double(shown.count))
                print("  \(cs.id.padding(toLength: 28, withPad: " ", startingAt: 0)) p@3 \(p)  must \(must.intersection(shown).count)/\(must.count)")
                if verbose || shown.contains(where: { bad.contains($0) }) {
                    for (sec, list) in zip(["sites", "docs "], keys) {
                        let row = list.map { refOf[$0] ?? $0 }.map { "\(tag($0)): \(String(title($0).prefix(34)))" }.joined(separator: " | ")
                        print("      \(sec) \(row.isEmpty ? "(none)" : row)")
                    }
                }
            }
            print("  " + s.line + "\n")
            results.append((name, s))
        }
        print("Results")
        for (name, s) in results { print("  \(name.padding(toLength: 70, withPad: " ", startingAt: 0)) \(s.line)") }
        Intelligence.shared.rerankerDisabled = false
        Intelligence.shared.shutdown()
        return 0
    }
}
