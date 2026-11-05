import Foundation

/// `--demo-diag <profile>`: for each labelled demo case, shows where every must item ends up in
/// retrieval, fusion and the reranker, so misses can be traced to a stage. Works on a copy of
/// the profile's index, like `--demo-eval`.
enum EngineDemoDiag {
    static func run(_ args: [String]) -> Int32 {
        func arg(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        guard let p = arg("--demo-diag"), let dir = DemoContent.locate(arg("--demo-content")), let c = try? DemoContent.load(dir),
              let expected = c.expected else { print("Usage: --demo-diag <demo profile>"); return 2 }
        let profile = URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("BrowserPOC-demo-diag-\(UUID().uuidString)", isDirectory: true)
        Paths.ensure(tmp)
        defer { try? fm.removeItem(at: tmp) }
        for f in ["index.sqlite", "index.sqlite-wal", "index.sqlite-shm"] {
            try? fm.copyItem(at: profile.appendingPathComponent(f), to: tmp.appendingPathComponent(f))
        }
        Paths.overrideRoot = tmp
        ModelFiles.overrideDir = profile.appendingPathComponent("Models", isDirectory: true)
        ModelFiles.clearReadyCache()
        Reembedder.shared.enabled = false
        guard let store = try? IndexStore(url: tmp.appendingPathComponent("index.sqlite")) else { return 1 }
        IndexStore.shared = store
        let notesRoot = profile.appendingPathComponent("Notes", isDirectory: true)
        var noteURL: [String: URL] = [:]
        for n in c.notes { noteURL[n.id] = notesRoot.appendingPathComponent(n.folder).appendingPathComponent(n.title + ".md").standardizedFileURL }
        func key(_ ref: String) -> String? { DemoSeeder.indexKey(ref, c, noteURL) }
        var params = RankParams.fromSettings(AppSettings())
        params.now = Date()
        let only = arg("--case")
        for cs in expected.cases where only == nil || cs.id == only {
            guard let ck = key(cs.context.ref) else { continue }
            let text: String, title: String, kind: ContextKind
            if let u = noteURL[cs.context.ref] {
                title = c.note(cs.context.ref)?.title ?? ""; text = (try? String(contentsOf: u, encoding: .utf8)) ?? ""; kind = .note
            } else {
                let b = store.storedBody(key: ck); title = b?.title ?? ""; text = b?.body ?? ""; kind = .page
            }
            for k in cs.onScreen.compactMap(key) { store.touchOpened(key: k, at: Date()) }
            let input = ContextInput(key: ck, title: title, text: text, kind: kind)
            let q = Pipeline.makeQuery(input, work: nil, store: store)
            let cands = store.hybridCandidates(q, params, perSection: 40)
            print("\n\(cs.id)  [\(title)]")
            print("  rerank query: \(q.rerankQuery.prefix(160).replacingOccurrences(of: "\n", with: " "))")
            for m in cs.must {
                guard let mk = key(m.ref) else { print("  must \(m.ref): no key"); continue }
                let list = (m.section ?? "docs") == "sites" ? cands.sites : cands.docs
                guard let i = list.firstIndex(where: { $0.doc.key == mk }) else {
                    let d = store.doc(key: mk)
                    print("  must \(m.ref) (\(m.section ?? "-")): NOT in the top 40 [in index: \(d != nil), section \(d.map { store.section(key: $0.key, writingSites: params.writingSites).rawValue } ?? "-")]")
                    continue
                }
                let cand = list[i]
                let rq = Pipeline.rerankQuery(for: cand, q)
                let rr = Intelligence.shared.rerank(query: rq, documents: ["Title: \(cand.doc.title)\n\(cand.rawPassage)"])?.first ?? -1
                print(String(format: "  must %@ (%@): fused rank %d, dense %.2f, meaning %.2f, rerank %.2f, by %@", m.ref, m.section ?? "-", i + 1, cand.dense, cand.meaning, rr, cand.foundBy.joined(separator: ",")))
                print("       passage: \(cand.rawPassage.prefix(120).replacingOccurrences(of: "\n", with: " "))")
                print("       query:   \(rq.prefix(140).replacingOccurrences(of: "\n", with: " "))")
            }
            if args.contains("--reasons") {
                let r = Pipeline.rank(q, params, store: store)
                for m in r.sites.prefix(params.limit) + r.docs.prefix(params.limit) {
                    print("  card: \(m.doc.title.prefix(44))")
                    print("        \(Reasons.template(m, visits: store.visits(docID: m.doc.id, limit: 10)))")
                    print("        passage: \(m.passage.prefix(90).replacingOccurrences(of: "\n", with: " "))")
                }
            }
            if Pipeline.debugRank {
                let cent = Pipeline.chunkCentrality(q)
                for (i, t) in q.queryTexts.enumerated() { print("  q\(i) c\(String(format: "%.2f", i < cent.count ? cent[i] : -1)): \(t.prefix(110).replacingOccurrences(of: "\n", with: " "))") }
                _ = Pipeline.rank(q, params, store: store)
                // Local (matched part) against global (whole context) reranker scores, with labels.
                var label: [String: String] = [:]
                for m in cs.must { if let k = key(m.ref) { label[k] = "MUST" } }
                for m in cs.nice { if let k = key(m.ref) { label[k] = "nice" } }
                for r in cs.acceptable { if let k = key(r) { label[k] = "ok" } }
                for (secName, sec) in [("sites", cands.sites), ("docs", cands.docs)] {
                    let pool = Array(sec.prefix(30))
                    let local = Intelligence.shared.rerank(queries: pool.map { Pipeline.rerankQuery(for: $0, q) }, documents: pool.map { "Title: \($0.doc.title)\n\($0.rawPassage)" }) ?? []
                    let global = Intelligence.shared.rerank(query: q.rerankQuery, documents: pool.map { "Title: \($0.doc.title)\n\($0.rawPassage)" }) ?? []
                    let cc = Pipeline.contextCentroid(q)
                    for (i, c) in pool.enumerated() where i < local.count {
                        print(String(format: "    FEAT %@ %@ %d q%d L%.3f G%.3f gs%.3f d%.3f m%.3f f%.4f %@", secName, (label[c.doc.key] ?? "other").padding(toLength: 5, withPad: " ", startingAt: 0), i + 1, c.queryIndex ?? -1, local[i], global[i], Pipeline.globalSimilarity(c, cc), c.dense, c.meaning, c.fused, String(c.doc.title.prefix(40))))
                    }
                }
            }
            for k in cs.onScreen.compactMap(key) { store.touchOpened(key: k, at: Date(timeIntervalSince1970: 0)) }
        }
        Intelligence.shared.shutdown()
        return 0
    }
}
