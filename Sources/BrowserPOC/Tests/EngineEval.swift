import Foundation

/// `--eval [--models-dir <dir>] [--workdir <dir>]`: seeds throwaway indexes from the labelled
/// fixture and compares the round 2 pipeline with the new one. Prints precision at 3 for each.
enum EngineEval {
    struct Tally {
        var shown = 0
        var relevantShown = 0
        var p3Sum = 0.0
        var p3Contexts = 0
        var recallHits = 0
        var recallPossible = 0
        var quietOK = 0
        var quietTotal = 0
        var ms = 0.0
        var runs = 0

        var precision: Double { p3Contexts == 0 ? 0 : p3Sum / Double(p3Contexts) }
        var recall: Double { recallPossible == 0 ? 0 : Double(recallHits) / Double(recallPossible) }

        mutating func add(shown keys: [[String]], relevant: Set<String>, ms elapsed: Double) {
            runs += 1
            ms += elapsed
            // Up to three cards per section, as the panel shows them.
            let top = keys.flatMap { $0.prefix(3) }
            if relevant.isEmpty {
                quietTotal += 1
                if top.isEmpty { quietOK += 1 }
                shown += top.count
                return
            }
            let hits = top.filter { relevant.contains($0) }.count
            shown += top.count
            relevantShown += hits
            if !top.isEmpty {
                p3Sum += Double(hits) / Double(top.count)
                p3Contexts += 1
            }
            recallHits += Set(top).intersection(relevant).count
            recallPossible += min(relevant.count, 3)
        }

        var line: String {
            String(format: "precision@3 %.2f  recall@3 %.2f  quiet %d/%d  cards %d  avg %.0f ms",
                   precision, recall, quietOK, quietTotal, shown, runs == 0 ? 0 : ms / Double(runs))
        }
    }

    static func arg(_ name: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    static func seed(_ store: IndexStore, now: Date) {
        for f in EvalFixture.items {
            let t = now.timeIntervalSince1970 - f.daysAgo * 86400
            let a = TextAnalysis.analyze(title: f.title, description: "", text: f.text)
            var d = DocUpsert(key: f.key, source: f.source, url: f.key, title: f.title, body: f.text,
                              firstSeen: t, lastSeen: t, visitCount: f.visits, mtime: t)
            switch f.source {
            case .web:
                store.recordCapture(d, analysis: a)
            case .chrome:
                d.body = ""
                _ = store.importChrome([(d, a)])
            case .note, .markdown:
                d.project = "Notes"
                d.root = "/eval/notes"
                store.upsertFile(d, analysis: a)
            case .notion, .gdocs, .granola:
                store.upsertSourceDoc(d, analysis: a, visitKind: "opened")
            }
        }
    }

    static func makeStore(_ dir: URL, embedder: EmbedderID) -> IndexStore? {
        Intelligence.shared.forcedEmbedder = embedder
        let u = dir.appendingPathComponent("index-\(embedder.rawValue).sqlite")
        try? FileManager.default.removeItem(at: u)
        guard let s = try? IndexStore(url: u) else { return nil }
        seed(s, now: Date())
        return s
    }

    static func titles(_ keys: [String]) -> String {
        keys.map { k in
            let t = EvalFixture.items.first { $0.key == k }?.title ?? k
            return String(t.prefix(34))
        }.joined(separator: " | ")
    }

    static func run(workdir: URL?) -> Int32 {
        let dir = workdir ?? FileManager.default.temporaryDirectory.appendingPathComponent("BrowserPOC-eval-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: dir)
        Paths.ensure(dir)
        Paths.overrideRoot = dir
        defer { if workdir == nil { try? FileManager.default.removeItem(at: dir) } }
        Reembedder.shared.enabled = false
        if let m = arg("--models-dir") { ModelFiles.overrideDir = URL(fileURLWithPath: (m as NSString).expandingTildeInPath, isDirectory: true) }
        ModelFiles.clearReadyCache()
        let haveEmbedder = ModelFiles.isReady(ModelCatalog.embedder)
        let haveReranker = ModelFiles.isReady(ModelCatalog.reranker)
        let haveFM = ContextReader.isAvailable
        let verbose = CommandLine.arguments.contains("--verbose")
        print("Eval in \(dir.path)")
        print("Items \(EvalFixture.items.count), contexts \(EvalFixture.contexts.count) (\(EvalFixture.contexts.filter { $0.relevant.isEmpty }.count) should stay quiet)")
        print("EmbeddingGemma 2: \(haveEmbedder ? "ready" : "not found")  Reranker: \(haveReranker ? "ready" : "not found")  Foundation Models: \(haveFM ? "available" : "unavailable")")
        if !haveEmbedder || !haveReranker { print("Pass --models-dir <folder with the GGUF files> to include the model pipelines.") }
        print("")

        var params = RankParams.fromSettings(AppSettings())
        params.now = Date()
        if let n = arg("--scale").flatMap(Int.init) { scaleCheck(passages: n, dir: dir, params: params); return 0 }
        var results: [(String, Tally)] = []

        // Round 2: sentence vectors, TF-IDF keywords, weighted score, fixed threshold.
        guard let sentenceStore = makeStore(dir, embedder: .sentence) else { print("could not open index"); return 1 }
        var old = Tally()
        for c in EvalFixture.contexts {
            let t = Date()
            let r = sentenceStore.retrieve(ContextAnalysis.make(c.input), params)
            let keys = [r.sites.map { $0.doc.key }, r.docs.map { $0.doc.key }]
            old.add(shown: keys, relevant: c.relevant, ms: Date().timeIntervalSince(t) * 1000)
            if verbose { print("  old   \(c.name): \(titles(keys.flatMap { $0 }))") }
        }
        results.append(("Round 2 pipeline", old))

        // Round 3 without downloaded models: hybrid retrieval and rank fusion, Apple's embedding.
        Intelligence.shared.rerankerDisabled = true
        var fallback = Tally()
        for c in EvalFixture.contexts {
            let t = Date()
            let q = Pipeline.makeQuery(c.input, work: nil, store: sentenceStore)
            let r = Pipeline.rank(q, params, store: sentenceStore)
            let keys = [r.sites.prefix(params.limit).map { $0.doc.key }, r.docs.prefix(params.limit).map { $0.doc.key }]
            fallback.add(shown: keys, relevant: c.relevant, ms: Date().timeIntervalSince(t) * 1000)
            if verbose { print("  fall  \(c.name): \(titles(keys.flatMap { $0 }))  [" + r.scored.prefix(4).map { String(format: "%@ %.2f", String($0.title.prefix(20)), $0.score) }.joined(separator: ", ") + "]") }
        }
        results.append(("Round 3, built-in embedding, no reranker", fallback))
        if haveFM {
            var fallbackFull = Tally()
            for c in EvalFixture.contexts {
                let t = Date()
                let shown = fullRun(c, store: sentenceStore, params: params, verbose: verbose)
                fallbackFull.add(shown: shown, relevant: c.relevant, ms: Date().timeIntervalSince(t) * 1000)
            }
            results.append(("Round 3, built-in embedding and Foundation Models", fallbackFull))
        }

        if haveEmbedder, let gemmaStore = makeStore(dir, embedder: .gemma) {
            Intelligence.shared.rerankerDisabled = true
            var dense = Tally()
            for c in EvalFixture.contexts {
                let t = Date()
                let r = Pipeline.rank(Pipeline.makeQuery(c.input, work: nil, store: gemmaStore), params, store: gemmaStore)
                let keys = [r.sites.prefix(params.limit).map { $0.doc.key }, r.docs.prefix(params.limit).map { $0.doc.key }]
                dense.add(shown: keys, relevant: c.relevant, ms: Date().timeIntervalSince(t) * 1000)
                if verbose { print("  gemma \(c.name): \(titles(keys.flatMap { $0 }))") }
            }
            results.append(("Round 3, EmbeddingGemma 2, no reranker", dense))

            if haveReranker {
                Intelligence.shared.rerankerDisabled = false
                var reranked = Tally()
                var full = Tally()
                for c in EvalFixture.contexts {
                    var t = Date()
                    let r = Pipeline.rank(Pipeline.makeQuery(c.input, work: nil, store: gemmaStore), params, store: gemmaStore)
                    let keys = [r.sites.prefix(params.limit).map { $0.doc.key }, r.docs.prefix(params.limit).map { $0.doc.key }]
                    reranked.add(shown: keys, relevant: c.relevant, ms: Date().timeIntervalSince(t) * 1000)
                    if verbose {
                        let scored = r.scored.prefix(5).map { String(format: "%@ %.2f", String($0.title.prefix(26)), $0.score) }
                        print("  rr    \(c.name): \(scored.joined(separator: " | "))")
                    }
                    guard haveFM else { continue }
                    let tf = Date()
                    full.add(shown: fullRun(c, store: gemmaStore, params: params, verbose: verbose), relevant: c.relevant, ms: Date().timeIntervalSince(tf) * 1000)
                }
                results.append(("Round 3, EmbeddingGemma 2 and reranker", reranked))
                if haveFM { results.append(("Round 3, full (adds Foundation Models context and judgment)", full)) }
            }
        }

        print("Results")
        for (name, t) in results {
            print("  \(name.padding(toLength: 60, withPad: " ", startingAt: 0))  \(t.line)")
        }
        Intelligence.shared.forcedEmbedder = nil
        Intelligence.shared.rerankerDisabled = false
        Intelligence.shared.shutdown()
        return 0
    }

    /// The whole pipeline as the panel runs it: the model's description, retrieval with its
    /// queries, then the judgment on borderline cards.
    static func fullRun(_ c: EvalFixture.Context, store: IndexStore, params: RankParams, verbose: Bool) -> [[String]] {
        let work = runAsync { await ContextReader.describe(c.input) } ?? nil
        let r = Pipeline.rank(Pipeline.makeQuery(c.input, work: work, store: store), params, store: store)
        var shown: [[String]] = []
        for list in [r.sites, r.docs] {
            var keep: [String] = []
            for m in list where keep.count < params.limit {
                if m.score >= r.gate.strong { keep.append(m.doc.key); continue }
                let cand = r.candidates[m.doc.id]!
                let j = runAsync { await Judge.judge(work: work, input: c.input, item: cand, history: Reasons.history(m.doc)) } ?? nil
                if Pipeline.accept(m, judgment: j, gate: r.gate) { keep.append(m.doc.key) }
                if verbose, let j { print(String(format: "        judge %@ helpful=%@ conf=%.2f  %@", String(m.doc.title.prefix(30)), j.helpful ? "yes" : "no", j.confidence, j.reason)) }
            }
            shown.append(keep)
        }
        if verbose { print("  full  \(c.name) [\(work?.topic ?? "-")]: \(titles(shown.flatMap { $0 }))") }
        return shown
    }

    /// `--scale N`: times hybrid retrieval over N synthetic passages with 768-dimension vectors,
    /// to see whether a flat scan is still fast enough.
    static func scaleCheck(passages n: Int, dir: URL, params: RankParams) {
        Intelligence.shared.forcedEmbedder = .sentence
        let u = dir.appendingPathComponent("scale.sqlite")
        try? FileManager.default.removeItem(at: u)
        guard let s = try? IndexStore(url: u) else { return }
        let words = ["browser", "webkit", "extension", "starter", "sourdough", "marathon", "thesis", "memory", "convenience", "interview",
                     "swift", "actor", "notion", "granola", "meeting", "budget", "travel", "kyoto", "camera", "design", "graph", "model"]
        var rng = SystemRandomNumberGenerator()
        let perDoc = 6
        let t0 = Date()
        var docs: [(DocUpsert, Analysis)] = []
        for i in 0..<(n / perDoc) {
            let text = (0..<perDoc).map { _ in (0..<40).map { _ in words.randomElement(using: &rng)! }.joined(separator: " ") }
            let d = DocUpsert(key: "https://scale.test/\(i)", source: .chrome, url: "https://scale.test/\(i)", title: "Page \(i)",
                              firstSeen: 1, lastSeen: 1, visitCount: 1)
            docs.append((d, Analysis(passages: text, vectors: Array(repeating: nil, count: perDoc), entities: [])))
        }
        _ = s.importChrome(docs)
        let pending = s.passagesNeedingVectors(model: .gemma, limit: n + 10)
        let vecs = pending.map { p -> (pid: Int64, did: Int64, vec: [Float]) in
            (p.pid, p.did, VectorMath.normalized((0..<768).map { _ in Float.random(in: -1...1, using: &rng) })!)
        }
        s.setVectors(vecs, model: .gemma)
        print("Seeded \(pending.count) passages in \(Int(Date().timeIntervalSince(t0))) s")
        var q = Pipeline.makeQuery(ContextInput(key: "x", title: "WebKit browser extension thesis", text: "A browser on webkit with extension support and a thesis on memory.", kind: .page), work: nil, store: s)
        q.queryVectors = [.gemma: (0..<6).map { _ in VectorMath.normalized((0..<768).map { _ in Float.random(in: -1...1, using: &rng) })! }]
        var times: [Double] = []
        for _ in 0..<5 {
            let t = Date()
            _ = s.hybridCandidates(q, params)
            times.append(Date().timeIntervalSince(t) * 1000)
        }
        print(String(format: "Hybrid retrieval over %d passages, 6 query vectors: median %.0f ms (runs %@)", pending.count, times.sorted()[2],
                     times.map { String(format: "%.0f", $0) }.joined(separator: ", ")))
        Intelligence.shared.forcedEmbedder = nil
    }

    /// Runs async work from the synchronous eval and waits for it.
    static func runAsync<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T? {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var out: T?
        Task.detached {
            out = await body()
            sem.signal()
        }
        sem.wait()
        return out
    }
}
