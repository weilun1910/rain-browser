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

    enum ReadError: Error, CustomStringConvertible {
        case notFound
        /// macOS App Data protection: Chrome's folder needs Felix's OK for this app.
        case needsPermission
        case failed(String)

        var description: String {
            switch self {
            case .notFound: return "Chrome history wasn't found. This reads Chrome's Default profile."
            case .needsPermission: return ChromeHistory.permissionHelp
            case .failed(let why): return why
            }
        }
    }

    static let permissionHelp = "macOS needs your OK before Rain can read Chrome's history. If a prompt came up, click Allow, then try again. If you clicked Don't Allow or no prompt came up, open System Settings, go to Privacy & Security, then Files & Folders, find Rain and turn on Google Chrome."

    static let settingsURLs = [
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_FilesAndFolders",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders",
    ]

    struct Snapshot {
        var rows: [ChromeRow] = []
        var searches: [(term: String, at: Double)] = []
    }

    /// Copies Chrome's History file into our own tmp folder and reads the copy read-only.
    /// The original is opened once, read-only, only to copy its bytes. The copy is deleted after.
    static func read(from src: URL = historyURL) throws -> Snapshot {
        guard FileManager.default.fileExists(atPath: src.path) else { throw ReadError.notFound }
        Paths.ensure(Paths.tmpDir)
        let copy = Paths.tmpDir.appendingPathComponent("chrome-history-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: copy)
            for suffix in ["-journal", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: copy.path + suffix))
            }
        }
        try copyReadOnly(src, to: copy)
        var comps = URLComponents()
        comps.scheme = "file"
        comps.path = copy.path
        comps.queryItems = [URLQueryItem(name: "mode", value: "ro"), URLQueryItem(name: "immutable", value: "1")]
        let uri = comps.string ?? ("file:" + copy.path + "?mode=ro&immutable=1")
        let db = try SQLiteDB(path: uri, readOnly: true, uri: true)
        // Chrome stores time as microseconds since 1601-01-01 UTC.
        let epochOffset: Double = 11_644_473_600
        let since = (Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970 + epochOffset) * 1_000_000
        var snap = Snapshot()
        snap.rows = try db.query("""
            SELECT url, title, visit_count, last_visit_time FROM urls
            WHERE last_visit_time > ? AND hidden = 0
            ORDER BY last_visit_time DESC LIMIT 6000
            """, [since]) { s -> ChromeRow? in
            guard let u = URL(string: s.text(0)) else { return nil }
            let t = s.double(3) / 1_000_000 - epochOffset
            return ChromeRow(url: u, title: s.text(1), visitCount: Int(s.int(2)), lastVisit: Date(timeIntervalSince1970: t))
        }.compactMap { $0 }
        // Past searches. Older History files may not have this table.
        if let terms = try? db.query("""
            SELECT k.term, max(u.last_visit_time) FROM keyword_search_terms k JOIN urls u ON u.id = k.url_id
            WHERE u.last_visit_time > ? GROUP BY k.normalized_term ORDER BY 2 DESC LIMIT 2000
            """, [since], { ($0.text(0), $0.double(1) / 1_000_000 - epochOffset) }) {
            snap.searches = terms.filter { !$0.0.trimmingCharacters(in: .whitespaces).isEmpty }.map { (term: $0.0, at: $0.1) }
        }
        return snap
    }

    /// Opens the source with O_RDONLY and streams it into our copy. No locks, no writes to the source.
    static func copyReadOnly(_ src: URL, to dst: URL) throws {
        let fd = open(src.path, O_RDONLY)
        if fd < 0 {
            let e = errno
            if e == EPERM || e == EACCES { throw ReadError.needsPermission }
            throw ReadError.failed("Couldn't open Chrome history: \(String(cString: strerror(e)))")
        }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard FileManager.default.createFile(atPath: dst.path, contents: nil) else {
            throw ReadError.failed("Couldn't write a temporary copy in \(dst.deletingLastPathComponent().path)")
        }
        let output = try FileHandle(forWritingTo: dst)
        defer { try? output.close(); try? input.close() }
        while true {
            guard let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
        }
    }

    static func readRows() throws -> [ChromeRow] { try read().rows }

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
        let snap: Snapshot
        do { snap = try read() } catch {
            print("Could not read Chrome history: \(error)")
            return 1
        }
        let rows = snap.rows
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
        print("  past search terms: \(snap.searches.count)")
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
        case needsPermission
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
                let snap = try ChromeHistory.read()
                let plan = ChromeHistory.plan(snap.rows, settings: settings)
                IndexStore.shared.importSearches(snap.searches.map { ($0.term, $0.at) }, source: "chrome")
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
            } catch ChromeHistory.ReadError.needsPermission {
                await MainActor.run { self.phase = .needsPermission }
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
