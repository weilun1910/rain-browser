import Foundation

struct ChromeRow {
    let url: URL
    let title: String
    let visitCount: Int
    let lastVisit: Date
}

struct ChromePlan {
    var imports: [ChromeRow] = []
    var fetch: [ChromeRow] = []
    var notImported: [(ChromeRow, String)] = []
    var titleOnly: [(ChromeRow, String)] = []
    var totalRows = 0
}

enum ChromeHistory {
    static var historyURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/Default/History")
    }

    static let maxImport = 2000
    static let maxFetch = 300
    static let days = 90

    /// Copies Chrome's History file into our own tmp folder, reads the copy read-only,
    /// then deletes the copy. The original is only ever read by the file copy.
    static func readRows() throws -> [ChromeRow] {
        let src = historyURL
        guard FileManager.default.fileExists(atPath: src.path) else {
            throw SQLiteError(message: "Chrome history not found at the Default profile")
        }
        Paths.ensure(Paths.tmpDir)
        let copy = Paths.tmpDir.appendingPathComponent("chrome-history-\(UUID().uuidString).sqlite")
        try FileManager.default.copyItem(at: src, to: copy)
        defer {
            try? FileManager.default.removeItem(at: copy)
            for suffix in ["-journal", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: copy.path + suffix))
            }
        }
        var comps = URLComponents()
        comps.scheme = "file"
        comps.path = copy.path
        comps.queryItems = [URLQueryItem(name: "mode", value: "ro"), URLQueryItem(name: "immutable", value: "1")]
        let uri = comps.string ?? ("file:" + copy.path + "?mode=ro&immutable=1")
        let db = try SQLiteDB(path: uri, readOnly: true, uri: true)
        // Chrome stores time as microseconds since 1601-01-01 UTC.
        let epochOffset: Double = 11_644_473_600
        let since = (Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970 + epochOffset) * 1_000_000
        let rows = try db.query("""
            SELECT url, title, visit_count, last_visit_time FROM urls
            WHERE last_visit_time > ? AND hidden = 0
            ORDER BY last_visit_time DESC LIMIT 6000
            """, [since]) { s -> ChromeRow? in
            guard let u = URL(string: s.text(0)) else { return nil }
            let t = s.double(3) / 1_000_000 - epochOffset
            return ChromeRow(url: u, title: s.text(1), visitCount: Int(s.int(2)), lastVisit: Date(timeIntervalSince1970: t))
        }
        return rows.compactMap { $0 }
    }

    static func plan(_ rows: [ChromeRow], settings: AppSettings) -> ChromePlan {
        var p = ChromePlan()
        p.totalRows = rows.count
        var seen = Set<String>()
        for r in rows {
            switch URLFilter.importDecision(r.url, settings: settings) {
            case .skip(let why):
                p.notImported.append((r, why))
            case .importIt:
                let key = URLKey.key(for: r.url)
                if seen.contains(key) { continue }
                if p.imports.count >= maxImport {
                    p.notImported.append((r, "over the 2,000 cap"))
                    continue
                }
                seen.insert(key)
                p.imports.append(r)
            }
        }
        let byVisits = p.imports.sorted { $0.visitCount > $1.visitCount }
        for r in byVisits {
            switch URLFilter.fetchDecision(r.url, visitCount: r.visitCount) {
            case .skip(let why):
                p.titleOnly.append((r, why))
            case .fetch:
                if p.fetch.count < maxFetch { p.fetch.append(r) } else { p.titleOnly.append((r, "outside the top 300")) }
            }
        }
        return p
    }

    /// Prints what an import would do. Fetches nothing and writes nothing to the index.
    static func dryRun() -> Int32 {
        let rows: [ChromeRow]
        do { rows = try readRows() } catch {
            print("Could not read Chrome history: \(error)")
            return 1
        }
        let p = plan(rows, settings: Settings.shared.value)
        print("Would fetch text for these \(p.fetch.count) pages:")
        for r in p.fetch { print("  FETCH  \(r.visitCount)x  \(r.url.absoluteString)") }
        print("")
        print("Imported as title and URL only:")
        for (r, why) in p.titleOnly { print("  TITLE  [\(why)]  \(r.url.absoluteString)") }
        print("")
        print("Not imported:")
        for (r, why) in p.notImported { print("  SKIP   [\(why)]  \(r.url.absoluteString)") }
        print("")
        print("Summary")
        print("  history rows in the last \(days) days: \(p.totalRows)")
        print("  would import: \(p.imports.count)")
        print("  would fetch text: \(p.fetch.count)")
        print("  title only: \(p.titleOnly.count)")
        for (why, n) in tally(p.titleOnly.map { $0.1 }) { print("    \(why): \(n)") }
        print("  not imported: \(p.notImported.count)")
        for (why, n) in tally(p.notImported.map { $0.1 }) { print("    \(why): \(n)") }
        return 0
    }

    static func tally(_ reasons: [String]) -> [(String, Int)] {
        var c: [String: Int] = [:]
        for r in reasons { c[r, default: 0] += 1 }
        return c.sorted { $0.value > $1.value }
    }
}

/// Runs the import inside the app, with progress for Settings.
@MainActor
final class ChromeImporter: ObservableObject {
    static let shared = ChromeImporter()

    enum Phase: Equatable {
        case idle
        case reading
        case fetching(done: Int, total: Int)
        case finished(String)
        case failed(String)
    }

    @Published var phase: Phase = .idle
    private var task: Task<Void, Never>?

    var isRunning: Bool {
        switch phase {
        case .reading, .fetching: return true
        default: return false
        }
    }

    func start() {
        guard !isRunning else { return }
        phase = .reading
        let settings = Settings.shared.value
        task = Task.detached(priority: .utility) {
            do {
                let rows = try ChromeHistory.readRows()
                let plan = ChromeHistory.plan(rows, settings: settings)
                var docs: [(DocUpsert, Analysis)] = []
                for r in plan.imports {
                    let key = URLKey.key(for: r.url)
                    let title = r.title.isEmpty ? (r.url.host ?? key) : r.title
                    let d = DocUpsert(key: key, source: .chrome, url: r.url.absoluteString, title: title,
                                      firstSeen: r.lastVisit.timeIntervalSince1970,
                                      lastSeen: r.lastVisit.timeIntervalSince1970, visitCount: r.visitCount)
                    // Title-only entries get one passage made from the title.
                    let a = TextAnalysis.analyze(title: title, description: "", text: "")
                    docs.append((d, a))
                }
                let inserted = IndexStore.shared.importChrome(docs)
                let pending = IndexStore.shared.chromeDocsWithoutText()
                let toFetch = plan.fetch.filter { pending.contains(URLKey.key(for: $0.url)) }
                await MainActor.run { self.phase = .fetching(done: 0, total: toFetch.count) }
                let fetched = await ChromeFetcher.fetchAll(toFetch) { done in
                    Task { @MainActor in self.phase = .fetching(done: done, total: toFetch.count) }
                }
                let summary = "Imported \(plan.imports.count) pages (\(inserted) new). Read text for \(fetched) of \(toFetch.count)."
                Settings.shared.update { $0.chromeImportedAt = Date(); $0.chromeSummary = summary }
                await MainActor.run {
                    self.phase = .finished(summary)
                    NotificationCenter.default.post(name: .indexChanged, object: nil)
                }
            } catch {
                await MainActor.run { self.phase = .failed(String(describing: error)) }
            }
        }
    }

    func cancel() {
        task?.cancel()
        phase = .idle
    }
}

/// Cookie-free GETs, 4 at a time, 10 second timeout. Redirects are checked against the same rules.
final class ChromeFetcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static func makeSession(delegate: URLSessionTaskDelegate) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        cfg.urlCredentialStorage = nil
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 15
        cfg.httpMaximumConnectionsPerHost = 2
        cfg.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
            "Accept": "text/html,application/xhtml+xml",
        ]
        return URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let u = request.url, case .fetch = URLFilter.fetchDecision(u, visitCount: 99),
              !Settings.shared.value.isExcluded(host: u.host) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    static func fetchAll(_ rows: [ChromeRow], progress: @escaping @Sendable (Int) -> Void) async -> Int {
        let delegate = ChromeFetcher()
        let session = makeSession(delegate: delegate)
        defer { session.invalidateAndCancel() }
        var done = 0, ok = 0
        await withTaskGroup(of: Bool.self) { group in
            var iterator = rows.makeIterator()
            func addNext() -> Bool {
                guard let r = iterator.next() else { return false }
                group.addTask { await fetchOne(r, session: session) }
                return true
            }
            for _ in 0..<4 { if !addNext() { break } }
            while let success = await group.next() {
                done += 1
                if success { ok += 1 }
                progress(done)
                if Task.isCancelled { group.cancelAll(); break }
                _ = addNext()
            }
        }
        return ok
    }

    static func fetchOne(_ r: ChromeRow, session: URLSession) async -> Bool {
        var req = URLRequest(url: r.url)
        req.httpMethod = "GET"
        req.httpShouldHandleCookies = false
        req.timeoutInterval = 10
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return false }
            let mime = http.mimeType?.lowercased() ?? ""
            guard mime.contains("html"), data.count < 4_000_000 else { return false }
            let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
            let e = HTMLText.extract(html)
            if HTMLText.isLoginWall(e) { return false }
            let key = URLKey.key(for: r.url)
            let title = e.title.isEmpty ? r.title : e.title
            let a = TextAnalysis.analyze(title: title, description: e.description, text: e.text)
            IndexStore.shared.setChromeText(key: key, title: title, description: e.description, body: e.text, analysis: a)
            return true
        } catch {
            return false
        }
    }
}

extension Notification.Name {
    static let indexChanged = Notification.Name("local.browserpoc.indexChanged")
}
