import CryptoKit
import Foundation

/// Self test checks for round 3's engine: models, retrieval, sources and the read API.
/// Runs on the self test's throwaway index and fixture files. No network, no real app data.
enum EngineTests {
    static func check(_ ok: Bool, _ label: String, _ detail: String = "") { SelfTest.check(ok, label, detail) }

    static func run(dir: URL) {
        print("")
        print("Engine")
        modelStoreTests(dir: dir)
        embedderTests()
        retrievalTests()
        apiTests()
        reasonTests()
        reembedTests(dir: dir)
        notionTests(dir: dir)
        googleDocsTests()
        granolaTests()
        shutdownTests()
        quitTests()
    }

    /// Shutdown waits for a job holding a model and refuses new ones.
    static func shutdownTests() {
        let started = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            started.signal()
            _ = Intelligence.shared.embedQueries(["a"], using: .sentence)
        }
        started.wait()
        let t = Date()
        let ok = Intelligence.shared.shutdown(timeout: 5)
        let refused = Intelligence.shared.rerank(query: "x", documents: ["y"]) == nil && Intelligence.shared.isShuttingDown
        Intelligence.shared.reopenAfterShutdownForTests()
        check(ok && refused && Date().timeIntervalSince(t) < 5 && !Intelligence.shared.hasLoadedModels,
              "shutdown drains model work within its time limit and refuses new work")
    }

    /// Quits a child process mid-re-embed with both models loaded, the app's way and with a bare
    /// exit, and checks it ends cleanly. Needs the models: set BROWSERPOC_QUIT_CHECK_MODELS.
    static func quitTests() {
        guard let dirPath = ProcessInfo.processInfo.environment["BROWSERPOC_QUIT_CHECK_MODELS"], !dirPath.isEmpty,
              ModelCatalog.all.allSatisfy({ FileManager.default.fileExists(atPath: URL(fileURLWithPath: dirPath).appendingPathComponent($0.file + ".verified").path) }) else {
            print("      quit check skipped: set BROWSERPOC_QUIT_CHECK_MODELS to a folder with both models")
            return
        }
        guard let exe = Bundle.main.executablePath else { return }
        for mode in ["app", "exit"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = ["--quit-check", mode, "--models-dir", dirPath]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do { try p.run() } catch { check(false, "quit check starts", "\(error)"); continue }
            // Read as it runs, so a full pipe can't stall the child.
            var data = Data()
            let reader = DispatchQueue(label: "quit-check-read")
            let done = DispatchSemaphore(value: 0)
            reader.async { data = pipe.fileHandleForReading.readDataToEndOfFile(); done.signal() }
            let deadline = Date().addingTimeInterval(180)
            while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            if p.isRunning { p.terminate() }
            _ = done.wait(timeout: .now() + 5)
            let out = String(decoding: data, as: UTF8.self)
            let crashed = out.contains("GGML_ASSERT") || out.contains("Segmentation") || p.terminationReason == .uncaughtSignal
            let line = out.split(separator: "\n").first(where: { $0.contains("quit-check") }).map(String.init) ?? "status \(p.terminationStatus)"
            check(out.contains(EngineQuitCheck.marker) && !crashed && p.terminationStatus == 0,
                  "quitting mid-re-embed with the models loaded exits cleanly (\(mode))",
                  crashed ? String(out.suffix(300)) : line)
        }
    }

    static func modelStoreTests(dir: URL) {
        let mdir = dir.appendingPathComponent("models-fixture", isDirectory: true)
        try? FileManager.default.removeItem(at: mdir)
        Paths.ensure(mdir)
        let saved = ModelFiles.overrideDir
        ModelFiles.overrideDir = mdir
        defer { ModelFiles.overrideDir = saved; ModelFiles.clearReadyCache() }
        let payload = Data((0..<5000).map { UInt8($0 % 251) })
        let sum = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let spec = ModelSpec(id: "fixture", name: "Fixture", role: .embedding, file: "fixture.gguf",
                             url: URL(string: "https://example.invalid/fixture.gguf")!, bytes: Int64(payload.count),
                             sha256: sum, licence: "test", summary: "test")
        // Half a file: not finished, and the partial file stays for a resume.
        try? payload.prefix(2000).write(to: ModelFiles.partial(spec))
        var sizeError = false
        do { try ModelDownloader.finish(spec) } catch ModelDownloader.Failure.size { sizeError = true } catch {}
        check(sizeError && FileManager.default.fileExists(atPath: ModelFiles.partial(spec).path) && !ModelFiles.isReady(spec),
              "a half-downloaded model is kept for resume and not used")
        // Full size, wrong bytes: rejected and deleted.
        var bad = payload; bad[10] ^= 0xFF
        try? bad.write(to: ModelFiles.partial(spec))
        var checksumError = false
        do { try ModelDownloader.finish(spec) } catch ModelDownloader.Failure.checksum { checksumError = true } catch {}
        check(checksumError && !FileManager.default.fileExists(atPath: ModelFiles.partial(spec).path), "a model with the wrong checksum is deleted")
        try? payload.write(to: ModelFiles.partial(spec))
        var ok = true
        do { try ModelDownloader.finish(spec) } catch { ok = false }
        check(ok && ModelFiles.isReady(spec) && FileManager.default.fileExists(atPath: ModelFiles.marker(spec).path),
              "a verified model moves into place under the profile's Models folder")
        check(ModelFiles.dir.path.hasPrefix(dir.path), "models live inside the support folder, so --data-dir keeps them apart")
    }

    static func embedderTests() {
        check(Intelligence.shared.documentEmbedder == .sentence, "without downloaded models, passages use Apple's built-in embedding",
              Intelligence.shared.documentEmbedder.rawValue)
        check(!Intelligence.shared.hasReranker, "without downloaded models there's no reranker, and nothing tries to load one")
        if let v = ContextualEmbedder.shared.vector("WKWebExtension loads Chrome extensions in a WebKit browser.") {
            let n = v.reduce(0) { $0 + $1 * $1 }
            check(v.count == 512 && abs(n - 1) < 0.01, "Apple's contextual embedding gives unit vectors", "\(v.count) dims")
        } else {
            print("      contextual embedding assets not on this Mac, skipped")
        }
        let p = Intelligence.documentPrompt(title: "", text: "abc")
        check(p == "title: none | text: abc" && Intelligence.queryPrompt("x") == "task: search result | query: x", "EmbeddingGemma prompts follow the model card")
    }

    static func retrievalTests() {
        let store = IndexStore.shared!
        Intelligence.shared.rerankerDisabled = true
        defer { Intelligence.shared.rerankerDisabled = false }
        let params = RankParams.fromSettings(AppSettings())
        // A fresh key: the round 2 checks dismissed a card for the original WebKit context.
        let ctx = ContextInput(key: "https://example.com/engine-webkit", title: SelfTest.contextWebKit.title, text: SelfTest.contextWebKit.text, kind: .page)
        let q = Pipeline.makeQuery(ctx, work: nil, store: store)
        let cands = store.hybridCandidates(q, params)
        let found = Set(cands.all.prefix(6).map { $0.doc.key })
        check(found.contains(SelfTest.fixtures[0].key) && found.contains(SelfTest.fixtures[1].key),
              "hybrid retrieval finds the WebKit pages", cands.all.prefix(4).map { $0.doc.title.prefix(20) }.joined(separator: ", "))
        check(cands.all.first.map { Set($0.foundBy).count >= 2 } ?? false, "the top candidate was found by more than one retriever",
              cands.all.first?.foundBy.joined(separator: ",") ?? "none")
        let r = Pipeline.rank(q, params, store: store)
        let keys = Set(r.matches.map { $0.doc.key })
        let webkit: Set<String> = [SelfTest.fixtures[0].key, SelfTest.fixtures[1].key, SelfTest.fixtures[2].key, SelfTest.fixtures[7].key]
        check(!keys.isEmpty && keys.isSubset(of: webkit), "round 3 ranking shows only WebKit items for a WebKit page", r.matches.map { $0.doc.title }.joined(separator: " | "))
        let tax = ContextInput(key: "https://example.com/tax2", title: "Filing quarterly estimated taxes",
                               text: "Freelancers pay estimated taxes four times a year. Use form 1040-ES to work out the amount and avoid a penalty.", kind: .page)
        let rt = Pipeline.rank(Pipeline.makeQuery(tax, work: nil, store: store), params, store: store)
        check(rt.matches.isEmpty, "round 3 ranking stays quiet for an unrelated page", rt.matches.map { $0.doc.title }.joined(separator: " | "))
        let selfQ = Pipeline.makeQuery(ContextInput(key: SelfTest.fixtures[0].key, title: SelfTest.fixtures[0].title, text: SelfTest.fixtures[0].text, kind: .page), work: nil, store: store)
        check(!store.hybridCandidates(selfQ, params).all.contains { $0.doc.key == SelfTest.fixtures[0].key }, "the current item never comes back as its own candidate")

        // The judgment: strong cards always stay; borderline ones go on a fairly sure no.
        let g = Pipeline.Gate(bar: 0.15, strong: 0.85, usesReranker: true)
        var m = Pipeline.match(cands.all[0], score: 0.5, rerank: 0.5, norm: 1)
        check(!Pipeline.accept(m, judgment: Judgment(helpful: false, confidence: 0.7, reason: ""), gate: g), "a borderline card goes when the model is sure it doesn't help")
        check(Pipeline.accept(m, judgment: Judgment(helpful: false, confidence: 0.2, reason: ""), gate: g), "a borderline card stays when the model is unsure")
        m.score = 0.95
        check(Pipeline.accept(m, judgment: Judgment(helpful: false, confidence: 0.9, reason: ""), gate: g), "a strong reranker score can't be vetoed")

        check(CanonicalID.of(url: "https://www.notion.so/team/Plan-3f2a9c1b8d7e4f60a1b2c3d4e5f60718") == CanonicalID.of(url: "https://www.notion.so/3f2a9c1b8d7e4f60a1b2c3d4e5f60718")
              && CanonicalID.of(url: "https://docs.google.com/document/d/1AbCdEfGhIjKlMnOp/edit") == "gdoc:1AbCdEfGhIjKlMnOp",
              "a Notion page or Google Doc has one identity however it was opened")
    }

    static func apiTests() {
        let store = IndexStore.shared!
        guard let wk = store.doc(key: SelfTest.fixtures[0].key) else { check(false, "API test fixture missing"); return }
        let n = store.semanticNeighbours(itemID: wk.id, k: 3)
        check(!n.isEmpty && !n.contains { $0.doc.id == wk.id } && n.first.map { $0.similarity > 0 } == true,
              "semanticNeighbours returns other items by similarity", n.map { "\($0.doc.title.prefix(18)) \(String(format: "%.2f", $0.similarity))" }.joined(separator: ", "))
        let topics = store.topics(itemID: wk.id)
        check(!topics.isEmpty, "topics falls back to the item's distinctive words", topics.joined(separator: ", "))
        let anyEntities = SelfTest.fixtures.compactMap { store.doc(key: $0.key) }.contains { !store.entities(itemID: $0.id).isEmpty }
        check(anyEntities, "entities are stored per item")
        Intelligence.shared.rerankerDisabled = true
        let hits = store.search("sourdough starter feeding")
        check(hits.first?.doc.key == SelfTest.fixtures[3].key, "search ranks the starter guide first for a starter query", hits.prefix(3).map { $0.doc.title }.joined(separator: " | "))
        let notesOnly = store.search("starter", filters: SearchFilters(sources: [.note]))
        check(!notesOnly.isEmpty && notesOnly.allSatisfy { $0.doc.source == .note }, "search filters by source")
        Intelligence.shared.rerankerDisabled = false
    }

    static func reasonTests() {
        let now = Date().timeIntervalSince1970
        let doc = DocMeta(id: 1, key: "k", source: .web, url: "https://example.com/a", title: "A", description: "", project: nil, root: nil,
                          firstSeen: now - 86400 * 20, lastSeen: now - 86400 * 20, visitCount: 3, dwell: 0, lastOpened: 0, hasText: true, mtime: 0)
        let h = Reasons.history(doc, visits: [Visit(at: now - 86400 * 20, kind: "read", during: "writing Thesis outline")])
        check(h.hasPrefix("You read this on ") && h.hasSuffix(" while writing Thesis outline."), "the reason says when and in what context it was read", h)
        let plain = Reasons.history(doc)
        check(plain.contains("3 visits"), "without a recorded context it says how often", plain)
        let gd = DocMeta(id: 2, key: "k2", source: .gdocs, url: "https://docs.google.com/spreadsheets/d/1AbCdEfGhIjKlMnOp", title: "B", description: "", project: nil, root: nil,
                         firstSeen: now, lastSeen: now - 86400 * 3, visitCount: 1, dwell: 0, lastOpened: 0, hasText: true, mtime: now)
        check(Reasons.history(gd).hasPrefix("Your Google Sheet, last opened"), "Google Sheets are named as sheets", Reasons.history(gd))
        ActivityTracker.shared.reset()
        ActivityTracker.shared.noteWriting(title: "Thesis outline", key: "file:///x.md")
        check(ActivityTracker.shared.current() == "writing Thesis outline" && ActivityTracker.shared.current(excluding: "file:///x.md") == nil,
              "captures record what Felix was writing, never the item itself")
        ActivityTracker.shared.reset()
        // Visits are recorded once per hour per kind, with the context kept.
        let store = IndexStore.shared!
        if let d = store.doc(key: SelfTest.fixtures[1].key) {
            store.recordVisit(docID: d.id, at: now, kind: "read", during: nil)
            store.recordVisit(docID: d.id, at: now + 60, kind: "read", during: "writing Plan")
            let v = store.visits(docID: d.id).filter { $0.at >= now - 1 }
            check(v.count == 1 && v.first?.during == "writing Plan", "repeat visits within an hour merge and keep their context", "\(v.count)")
        }
    }

    static func reembedTests(dir: URL) {
        guard ContextualEmbedder.shared.isAvailable else { print("      contextual embedding not available, re-embed test skipped"); return }
        let u = dir.appendingPathComponent("reembed.sqlite")
        try? FileManager.default.removeItem(at: u)
        guard let s = try? IndexStore(url: u) else { check(false, "re-embed store opens"); return }
        let a = TextAnalysis.analyze(title: "Old page", description: "", text: "Some text about WebKit extensions and the controller that loads them.")
        s.recordCapture(DocUpsert(key: "https://example.com/old", source: .web, url: "https://example.com/old", title: "Old page",
                                  body: "Some text", firstSeen: 1, lastSeen: 1), analysis: a)
        let saved = IndexStore.shared
        IndexStore.shared = s
        Intelligence.shared.forcedEmbedder = .contextual
        let n = Reembedder.shared.runBatch()
        let again = Reembedder.shared.runBatch()
        Intelligence.shared.forcedEmbedder = nil
        IndexStore.shared = saved
        let counts = s.vectorCounts()
        check(n > 0 && again == 0 && (counts[.contextual] ?? 0) > 0 && (counts[.sentence] ?? 0) == 0,
              "the background job re-embeds old passages with the new model, once", "\(counts.map { "\($0.key.rawValue)=\($0.value)" })")
    }

    /// A small database shaped like the Notion app's cache.
    static func notionTests(dir: URL) {
        let f = dir.appendingPathComponent("notion-fixture/notion.db")
        Paths.ensure(f.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: f)
        let page = "3f2a9c1b-8d7e-4f60-a1b2-c3d4e5f60718", child = "11111111-2222-3333-4444-555555555555"
        do {
            let db = try SQLiteDB(path: f.path)
            try db.exec("""
            CREATE TABLE block(id TEXT PRIMARY KEY, space_id TEXT, type TEXT, properties TEXT, content TEXT, collection_id TEXT,
              created_time REAL, last_edited_time REAL, parent_id TEXT, parent_table TEXT, alive INTEGER, is_template INTEGER,
              meta_last_access_timestamp REAL);
            CREATE TABLE collection(id TEXT, name TEXT);
            CREATE TABLE space(id TEXT, name TEXT);
            INSERT INTO space VALUES('s1', 'Felix''s Notion');
            """)
            let t = Date().timeIntervalSince1970 * 1000
            func ins(_ id: String, _ type: String, _ title: String, _ content: [String] = [], alive: Int = 1, template: Int = 0) throws {
                let props = try String(data: JSONSerialization.data(withJSONObject: ["title": [[title], ["", [["b"]]]]]), encoding: .utf8)!
                let c = try String(data: JSONSerialization.data(withJSONObject: content), encoding: .utf8)!
                try db.run("INSERT INTO block VALUES(?,?,?,?,?,NULL,?,?,NULL,'block',?,?,?)", [id, "s1", type, props, c, t - 86400000, t - 3600000, alive, template, t - 600000])
            }
            try ins(page, "page", "Midpoint plan", ["b1", "b2", "b3", child])
            try ins("b1", "sub_header", "Opportunities")
            try ins("b2", "bulleted_list", "Late night fresh food", ["b4"])
            try ins("b4", "text", "Group night outers after 11pm")
            try ins("b3", "text", "Concept tests next week")
            try ins(child, "page", "Interview notes", ["b5"])
            try ins("b5", "text", "Students compare prices")
            try ins("dead0000-0000-0000-0000-000000000000", "page", "Deleted page", ["b3"], alive: 0)
            try ins("tmpl0000-0000-0000-0000-000000000000", "page", "Template", ["b3"], template: 1)
        } catch {
            check(false, "could build a Notion fixture", "\(error)")
            return
        }
        let before = SelfTest.snapshotFiles(f.deletingLastPathComponent(), ["notion.db"])
        do {
            let (pages, stats) = try NotionSource.read(from: f)
            let plan = pages.first { $0.title == "Midpoint plan" }
            check(stats.livePages == 2 && pages.count == 2 && !pages.contains { $0.title == "Deleted page" || $0.title == "Template" },
                  "Notion pages are read, skipping deleted pages and templates", pages.map { $0.title }.joined(separator: ", "))
            check(plan?.text == "## Opportunities\n- Late night fresh food\nGroup night outers after 11pm\nConcept tests next week\nInterview notes",
                  "a Notion page's text is rebuilt from its blocks in order, with child pages as titles", plan?.text ?? "nil")
            check(plan?.space == "Felix's Notion" && plan?.url == "https://www.notion.so/3f2a9c1b8d7e4f60a1b2c3d4e5f60718", "Notion pages carry their workspace and link")
            let store = IndexStore.shared!
            let first = try NotionSource.sync(from: f, store: store)
            let second = try NotionSource.sync(from: f, store: store)
            let doc = store.doc(key: "notion:3f2a9c1b8d7e4f60a1b2c3d4e5f60718")
            check(doc?.source == .notion && first.contains("2 updated") && second.contains("0 updated"),
                  "Notion sync adds pages once and skips unchanged ones", "\(first) then \(second)")
            check(store.section(key: "notion:3f2a9c1b8d7e4f60a1b2c3d4e5f60718", writingSites: []) == .docs, "Notion pages go under Notes / Docs")
        } catch {
            check(false, "Notion fixture reads", "\(error)")
        }
        check(before == SelfTest.snapshotFiles(f.deletingLastPathComponent(), ["notion.db"]), "reading Notion's cache leaves the original untouched")
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: Paths.tmpDir.path)) ?? []).filter { $0.hasPrefix("notion-") }
        check(leftovers.isEmpty, "the Notion temp copy is deleted", leftovers.joined(separator: ", "))
        try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: f.path)
        var denied = false
        do { _ = try NotionSource.read(from: f) } catch ForeignDB.ReadError.needsPermission { denied = true } catch {}
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.path)
        check(denied, "a denied read of Notion's data shows the permission help")
    }

    static func googleDocsTests() {
        let signin = URL(string: "https://accounts.google.com/ServiceLogin?continue=x")!
        check(GoogleDocsSource.classify(status: 200, finalURL: signin, mime: "text/html", body: Data()) == .signedOut,
              "a redirect to Google's sign-in page counts as signed out")
        check(GoogleDocsSource.classify(status: 200, finalURL: URL(string: "https://doc-0s.docs.googleusercontent.com/export/x"), mime: "text/plain", body: Data("Hello".utf8)) == .text("Hello"),
              "a plain-text export is read as the document's text")
        check(GoogleDocsSource.cleanTitle("Thesis outline - Google Docs") == "Thesis outline", "Google's title suffix is dropped")
        // With no Google sign-in in the profile, a sync says so and sends nothing.
        let store = IndexStore.shared!
        let key = "https://docs.google.com/document/d/1ZyXwVuTsRqPoNmLkJiHgFe"
        store.recordCapture(DocUpsert(key: key, source: .web, url: key + "/edit", title: "Plan - Google Docs", firstSeen: 1, lastSeen: 1),
                            analysis: TextAnalysis.analyze(title: "Plan", description: "", text: ""))
        nonisolated(unsafe) var status: String?
        Task.detached { status = await GoogleDocsSource.sync(store: store) }
        _ = SelfTest.spin(10) { status != nil }
        check(status?.hasPrefix("Sign in to Google in this browser first") == true, "Google Docs sync without a Google sign-in asks for one and fetches nothing", status ?? "timed out")
        let cookie = HTTPCookie(properties: [.domain: ".google.com", .path: "/", .name: "SID", .value: "x"])!
        check(GoogleDocsSource.cookie(cookie, appliesTo: URL(string: "https://docs.google.com/document/d/1/export")!)
              && !GoogleDocsSource.cookie(cookie, appliesTo: URL(string: "https://doc-0s.docs.googleusercontent.com/x")!)
              && !GoogleDocsSource.cookie(cookie, appliesTo: URL(string: "https://evilgoogle.com/x")!),
              "Google cookies are only sent to Google's own hosts")
    }

    static func granolaTests() {
        let json = """
        {"meetings": [{"id": "0a1b2c3d-4e5f-6071-8293-a4b5c6d7e8f9", "title": "Coffee chat with Sam", "meeting_at": "2026-10-12T15:00:00Z",
          "summary": "Talked about EPM interviews.", "attendees": [{"name": "Sam"}]}]}
        """
        let m1 = GranolaSource.parseMeetings(json)
        check(m1.count == 1 && m1[0].title == "Coffee chat with Sam" && m1[0].date != nil && m1[0].text.contains("EPM interviews") && m1[0].text.contains("Sam"),
              "Granola meetings parse from JSON", "\(m1)")
        let xml = """
        <meetings><meeting id="0a1b2c3d-4e5f-6071-8293-a4b5c6d7e8f9" title="Team sync" date="2026-10-20">
        <summary>Decided to ship the reranker.</summary><private_notes>Ask about latency.</private_notes></meeting></meetings>
        """
        let m2 = GranolaSource.parseMeetings(xml)
        check(m2.count == 1 && m2[0].title == "Team sync" && m2[0].text.contains("ship the reranker") && m2[0].text.contains("latency"),
              "Granola meetings parse from XML-like text", "\(m2)")
        check(GranolaSource.parseMeetings("Found meetings 0a1b2c3d-4e5f-6071-8293-a4b5c6d7e8f9 and more").first?.id == "0a1b2c3d-4e5f-6071-8293-a4b5c6d7e8f9",
              "Granola meeting ids are found in plain text as a last resort")
        check(OAuthClient.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
              "PKCE challenges match RFC 7636")
        check(LoopbackListener.parseQuery("GET /callback?code=abc&state=xyz HTTP/1.1") == ["code": "abc", "state": "xyz"], "the sign-in redirect's code and state are read")
        let sse = Data("event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"ok\":true}}\n\n".utf8)
        check((MCPClient.parseResponse(sse, contentType: "text/event-stream", id: 7)?["result"] as? [String: Any])?["ok"] as? Bool == true,
              "MCP answers are read from an event stream")
        check(!GranolaSource.isConnected && GranolaSource.tokenFile.path.hasPrefix(Paths.root.path), "Granola's sign-in lives in the profile folder and starts disconnected")
    }
}
