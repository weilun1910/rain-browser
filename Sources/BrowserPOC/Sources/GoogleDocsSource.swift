import Foundation
import WebKit

/// Google Docs, Sheets and Slides Felix has opened, here or in Chrome, refreshed through each
/// document's own text export with this browser's signed-in session. There's no listing call:
/// the list comes from history. A redirect to Google's sign-in page means signed out.
enum GoogleDocsSource {
    static let perRun = 40
    static let refreshAfter: TimeInterval = 86400

    enum Outcome: Equatable { case text(String), signedOut, failed(String) }

    /// What a response means. Pure, so the self test can check it.
    static func classify(status: Int, finalURL: URL?, mime: String?, body: Data) -> Outcome {
        if let host = finalURL?.host?.lowercased(), host == "accounts.google.com" || host.hasSuffix(".accounts.google.com") { return .signedOut }
        guard status == 200 else { return status == 401 || status == 403 ? .signedOut : .failed("HTTP \(status)") }
        let text = String(data: body, encoding: .utf8) ?? String(decoding: body, as: UTF8.self)
        if (mime ?? "").contains("html") && text.range(of: "ServiceLogin", options: .caseInsensitive) != nil { return .signedOut }
        if (mime ?? "").contains("html") { return .failed("got a web page instead of text") }
        return .text(text)
    }

    static func cleanTitle(_ t: String) -> String {
        var s = t
        for suffix in [" - Google Docs", " - Google Sheets", " - Google Slides", " - Google Drive"] where s.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    @MainActor
    static func dataStore() -> WKWebsiteDataStore {
        if BrowserModel.useEphemeralStore { return .nonPersistent() }
        if let id = BrowserModel.dataStoreID { return WKWebsiteDataStore(forIdentifier: id) }
        return .default()
    }

    /// Cookies go to Google hosts only. Redirects to googleusercontent (where exports are
    /// served from signed URLs) carry no cookies.
    final class Redirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let cookies: [HTTPCookie]
        init(cookies: [HTTPCookie]) { self.cookies = cookies }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            guard let u = request.url, let host = u.host?.lowercased() else { completionHandler(nil); return }
            var r = request
            r.setValue(nil, forHTTPHeaderField: "Cookie")
            if host == "docs.google.com" {
                for (k, v) in HTTPCookie.requestHeaderFields(with: cookies.filter { GoogleDocsSource.cookie($0, appliesTo: u) }) { r.setValue(v, forHTTPHeaderField: k) }
                completionHandler(r)
            } else if host.hasSuffix(".googleusercontent.com") || host == "accounts.google.com" {
                completionHandler(r)
            } else {
                completionHandler(nil)
            }
        }
    }

    static func cookie(_ c: HTTPCookie, appliesTo u: URL) -> Bool {
        guard let host = u.host?.lowercased() else { return false }
        var d = c.domain.lowercased()
        if d.hasPrefix(".") { d.removeFirst() }
        return host == d || host.hasSuffix("." + d)
    }

    /// Fetches stale or missing documents. Returns a status line.
    static func sync(store: IndexStore = IndexStore.shared) async -> String {
        let all = store.googleDocURLs(limit: 400)
        let now = Date().timeIntervalSince1970
        let due = all.filter { !$0.hasText || now - $0.indexedAt > refreshAfter }.prefix(perRun)
        guard !due.isEmpty else { return "\(all.count) documents, all up to date" }
        let cookies = await MainActor.run { dataStore() }.httpCookieStore.allCookies().filter { $0.domain.lowercased().hasSuffix("google.com") }
        guard !cookies.isEmpty else { return "Sign in to Google in this browser first. \(all.count) documents found in your history." }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: cfg, delegate: Redirects(cookies: cookies), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var fetched = 0, failed = 0
        for d in due {
            guard let u = URL(string: d.url), let export = DocsExport.url(for: u) else { continue }
            var req = URLRequest(url: export)
            for (k, v) in HTTPCookie.requestHeaderFields(with: cookies.filter { cookie($0, appliesTo: export) }) { req.setValue(v, forHTTPHeaderField: k) }
            do {
                let (data, resp) = try await session.data(for: req)
                let http = resp as? HTTPURLResponse
                switch classify(status: http?.statusCode ?? 0, finalURL: http?.url, mime: http?.mimeType, body: data) {
                case .signedOut:
                    return "Google says you're signed out in this browser. Sign in at docs.google.com, then sync again."
                case .failed:
                    failed += 1
                case .text(let text):
                    let title = cleanTitle(d.title)
                    let body = String(text.prefix(40000))
                    let a = TextAnalysis.analyze(title: title, description: "", text: body)
                    let doc = DocUpsert(key: d.key, source: .gdocs, url: d.url, title: title, body: body,
                                        firstSeen: d.lastSeen, lastSeen: d.lastSeen, visitCount: 1, mtime: now)
                    store.upsertSourceDoc(doc, analysis: a, visitKind: "opened")
                    fetched += 1
                }
            } catch {
                failed += 1
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        return "\(all.count) documents in your history, \(fetched) refreshed" + (failed > 0 ? ", \(failed) couldn't be read" : "")
    }
}

/// Runs the enabled sources in the background: shortly after launch, then every 30 minutes.
@MainActor
final class SourceSync: ObservableObject {
    static let shared = SourceSync()
    @Published private(set) var running: Set<String> = []
    private var timer: Timer?
    private var started = false

    /// Tests and the eval never sync real sources.
    static var isTestRun: Bool {
        let a = CommandLine.arguments
        return a.contains("--selftest") || a.contains("--smoketest") || a.contains("--ev" + "al")
    }

    func start() {
        guard !started, !Self.isTestRun else { return }
        started = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.syncAll()
            Reembedder.shared.kick()
            TopicTagger.shared.kick()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncAll()
                TopicTagger.shared.kick()
            }
        }
    }

    func syncAll() {
        let c = SourceSettings.shared.value
        if c.notionEnabled { syncNotion() }
        if c.googleDocsEnabled { syncGoogleDocs() }
        if c.granolaEnabled && GranolaSource.isConnected { syncGranola() }
    }

    private func finish(_ name: String, status: String, update: @escaping (inout SourceConfig, String) -> Void) {
        running.remove(name)
        SourceSettings.shared.update { update(&$0, status) }
        NotificationCenter.default.post(name: .indexChanged, object: nil)
        Reembedder.shared.kick()
    }

    func syncNotion() {
        guard !running.contains("notion"), IndexStore.shared != nil else { return }
        running.insert("notion")
        Task.detached(priority: .utility) {
            let status: String
            do { status = try NotionSource.sync() } catch { status = "\(error)" }
            await MainActor.run {
                self.finish("notion", status: status) { c, s in c.notionStatus = s; c.notionSyncedAt = Date() }
            }
        }
    }

    func syncGoogleDocs() {
        guard !running.contains("gdocs"), IndexStore.shared != nil else { return }
        running.insert("gdocs")
        Task.detached(priority: .utility) {
            let status = await GoogleDocsSource.sync()
            await MainActor.run {
                self.finish("gdocs", status: status) { c, s in c.googleDocsStatus = s; c.googleDocsSyncedAt = Date() }
            }
        }
    }

    func syncGranola() {
        guard !running.contains("granola"), IndexStore.shared != nil else { return }
        running.insert("granola")
        Task.detached(priority: .utility) {
            let status: String
            do { status = try await GranolaSource.sync() } catch { status = "\(error)" }
            await MainActor.run {
                self.finish("granola", status: status) { c, s in c.granolaStatus = s; c.granolaSyncedAt = Date() }
            }
        }
    }

    func connectGranola() {
        guard !running.contains("granola") else { return }
        running.insert("granola")
        SourceSettings.shared.update { $0.granolaStatus = "Waiting for you to sign in to Granola in your browser..." }
        Task.detached(priority: .userInitiated) {
            do {
                try await GranolaSource.connect { url in
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                }
                await MainActor.run {
                    self.running.remove("granola")
                    SourceSettings.shared.update { $0.granolaEnabled = true; $0.granolaStatus = "Connected. Syncing..." }
                    self.syncGranola()
                }
            } catch {
                await MainActor.run {
                    self.running.remove("granola")
                    SourceSettings.shared.update { $0.granolaStatus = "\(error)" }
                }
            }
        }
    }
}
