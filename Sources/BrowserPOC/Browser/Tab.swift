import AppKit
import WebKit

enum TabKind: String, Codable {
    /// `app` is a page the app draws itself, addressed as browser://<host>. See AppPages.
    case web, note, file, app
}

struct PageExtract {
    let url: URL
    let title: String
    let description: String
    let text: String
}

@MainActor
final class Tab: ObservableObject, Identifiable {
    let id: UUID
    let createdAt: Date
    @Published var kind: TabKind
    @Published var url: URL?
    @Published var title: String
    @Published var isPinned: Bool
    @Published var folderID: UUID?
    /// The space this item lives in. Essentials show in every space.
    var spaceID: UUID?
    /// In the Essentials grid at the top of the sidebar, shared by every space.
    @Published var isEssential = false
    /// The address a pinned tab or Essential goes back to.
    @Published var pinnedURL: URL?
    /// A name you gave it. Shown instead of the page title.
    @Published var customTitle: String?
    /// Sort key inside its sidebar section. Lower comes first.
    var order: Double = 0
    /// When it was last on screen, for auto-archive.
    var lastActiveAt = Date()
    @Published var isMuted = false
    /// Set from the page: something is playing, and whether a video is among it.
    @Published var mediaPlaying = false
    @Published var hasVideo = false
    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var loadError: String?
    /// A note whose file is gone from disk.
    @Published var isMissing = false

    private(set) var webView: WKWebView?
    private var observers: [NSKeyValueObservation] = []
    private var coordinator: WebCoordinator?
    weak var model: BrowserModel?

    var lastExtract: PageExtract?
    var docsExport: String?
    var docsExportStarted = false
    var captureWork: DispatchWorkItem?
    var contextWork: DispatchWorkItem?
    var activeSince: Date?
    var activeKey: String?
    /// The last session state written to disk, to skip rewriting the same bytes.
    var savedSessionHash: Int?

    init(id: UUID = UUID(), kind: TabKind = .web, url: URL?, title: String = "", isPinned: Bool = false,
         folderID: UUID? = nil, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.url = url
        self.title = title
        self.isPinned = isPinned
        self.folderID = folderID
        self.createdAt = createdAt
    }

    var isNote: Bool { kind == .note || kind == .file }
    var isWeb: Bool { kind == .web }
    var isApp: Bool { kind == .app }

    var displayTitle: String {
        if let c = customTitle, !c.isEmpty { return c }
        if isApp { return AppPages.page(for: url)?.title ?? (title.isEmpty ? "Page" : title) }
        if !title.isEmpty { return title }
        if kind != .web, let url { return url.deletingPathExtension().lastPathComponent }
        if kind != .web { return "Note" }
        if let host = url?.host { return host }
        return "New tab"
    }

    var isBlank: Bool { kind == .web && url == nil && webView?.url == nil }
    var isLoaded: Bool { webView != nil }

    /// Keeps a pinned address: pinned web tabs and Essentials.
    var keepsPinnedURL: Bool { kind == .web && (isPinned || isEssential) }

    /// A pinned tab or Essential that has wandered off the address it was pinned at.
    var isAwayFromPin: Bool {
        guard keepsPinnedURL, let p = pinnedURL, let u = url else { return false }
        return !Self.samePage(p, u)
    }

    /// Same page, ignoring the fragment and a trailing slash.
    static func samePage(_ a: URL, _ b: URL) -> Bool {
        func norm(_ u: URL) -> String {
            var s = u.absoluteString
            if let h = s.firstIndex(of: "#") { s = String(s[..<h]) }
            if s.hasSuffix("/") { s.removeLast() }
            return s.lowercased()
        }
        return norm(a) == norm(b)
    }

    func ensureWebView(configuration: WKWebViewConfiguration? = nil) -> WKWebView {
        if let webView { return webView }
        guard let model else { fatalError("tab without model") }
        let wv = WKWebView(frame: .zero, configuration: configuration ?? model.configuration(for: self))
        wv.isInspectable = true
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsMagnification = true
        let c = WebCoordinator(tab: self)
        wv.navigationDelegate = c
        wv.uiDelegate = c
        coordinator = c
        observers = [
            wv.observe(\.title, options: [.new]) { [weak self] wv, _ in
                let t = wv.title ?? ""
                Task { @MainActor in
                    guard let self, !t.isEmpty else { return }
                    self.title = t
                    if let u = wv.url { HistoryStore.shared.updateTitle(url: u, title: t) }
                    self.model?.scheduleSave()
                }
            },
            wv.observe(\.url, options: [.new]) { [weak self] wv, _ in
                let u = wv.url
                Task { @MainActor in self?.webURLChanged(u) }
            },
            wv.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
                let l = wv.isLoading
                Task { @MainActor in self?.isLoading = l }
            },
            wv.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                let p = wv.estimatedProgress
                Task { @MainActor in self?.progress = p }
            },
            wv.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in
                let b = wv.canGoBack
                Task { @MainActor in self?.canGoBack = b }
            },
            wv.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in
                let f = wv.canGoForward
                Task { @MainActor in self?.canGoForward = f }
            },
        ]
        webView = wv
        if kind == .web, configuration == nil {
            // Back and forward come back from the saved session, which also loads the page.
            if let data = SessionFiles.read(id) {
                wv.interactionState = data
                savedSessionHash = data.hashValue
                if wv.url == nil, let url { wv.load(URLRequest(url: url)) }
            } else if let url {
                wv.load(URLRequest(url: url))
            }
        }
        return wv
    }

    private func webURLChanged(_ u: URL?) {
        guard let u else { return }
        let old = url
        url = u
        model?.tabURLChanged(self, from: old)
    }

    /// Writes the back and forward list to disk when it changed.
    func saveSession() {
        guard kind == .web, let wv = webView, wv.url != nil, let data = wv.interactionState as? Data else { return }
        let h = data.hashValue
        guard h != savedSessionHash else { return }
        savedSessionHash = h
        SessionFiles.write(data, for: id)
    }

    /// Lets go of the web view. The session is saved first unless `keepSession` is false.
    func unload(keepSession: Bool = true) {
        if keepSession { saveSession() } else { SessionFiles.delete(id); savedSessionHash = nil }
        model?.endDwell(self)
        captureWork?.cancel()
        contextWork?.cancel()
        webView?.stopLoading()
        observers.forEach { $0.invalidate() }
        observers = []
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        coordinator = nil
        isLoading = false
        progress = 0
        mediaPlaying = false
        hasVideo = false
    }

    func load(_ u: URL) {
        loadError = nil
        kind = .web
        url = u
        if let webView {
            webView.load(URLRequest(url: u))
        } else {
            SessionFiles.delete(id)
            _ = ensureWebView() // loads `url` when it creates the view
        }
    }

    static let extractJS = """
    (() => {
      const pick = document.querySelector('article') || document.querySelector('main') || document.querySelector('[role="main"]');
      let text = pick ? pick.innerText : '';
      if (!text || text.length < 500) text = document.body ? document.body.innerText : '';
      const m = document.querySelector('meta[name="description"]') || document.querySelector('meta[property="og:description"]');
      return { title: document.title || '', description: m ? (m.getAttribute('content') || '') : '', text: (text || '').slice(0, 20000) };
    })()
    """

    /// Reads title, description and main text in an isolated script world, away from the page's own scripts.
    func extract(_ done: @escaping @MainActor (PageExtract?) -> Void) {
        // Demo pages give Related their text like any page. Capture stays http only.
        guard let wv = webView, let u = wv.url, URLKey.isIndexableWeb(u) || DemoScheme.handles(u) else { done(nil); return }
        wv.evaluateJavaScript(Self.extractJS, in: nil, in: .defaultClient) { result in
            MainActor.assumeIsolated {
                guard case .success(let value) = result, let dict = value as? [String: Any] else { done(nil); return }
                let e = PageExtract(url: u,
                                    title: (dict["title"] as? String) ?? "",
                                    description: (dict["description"] as? String) ?? "",
                                    text: (dict["text"] as? String) ?? "")
                done(e)
            }
        }
    }
}

@MainActor
final class WebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    weak var tab: Tab?

    init(tab: Tab) { self.tab = tab }

    private var model: BrowserModel? { tab?.model }

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
        let scheme = url.scheme?.lowercased() ?? ""
        if navigationAction.shouldPerformDownload { decisionHandler(.download); return }
        if !["http", "https", "about", "data", "blob", "file", "javascript", DemoScheme.scheme].contains(scheme) {
            // Links to other apps (zoommtg:, mailto:, itms-apps: and so on) ask first.
            decisionHandler(.cancel)
            ExternalApps.request(url, action: navigationAction, webView: webView, model: model)
            return
        }
        // The graph's navigation edges: page A led to page B, however the link opens.
        if navigationAction.navigationType == .linkActivated, navigationAction.targetFrame?.isMainFrame != false {
            GraphRecorder.linkFollowed(from: webView.url, to: url)
        }
        if navigationAction.navigationType == .linkActivated, navigationAction.targetFrame?.isMainFrame != false,
           let tab, let model, let route = LinkRouting.route(for: url, flags: navigationAction.modifierFlags, from: tab,
                                                             peekForPins: BrowserPrefs.shared.value.peekForPinnedLinks) {
            decisionHandler(.cancel)
            model.routeLink(url, route, from: tab)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        if !navigationResponse.canShowMIMEType && navigationResponse.isForMainFrame {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let tab else { return }
        tab.loadError = nil
        model?.pageWillNavigate(tab)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tab else { return }
        model?.pageDidFinish(tab)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    private func report(_ error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && (ns.code == 102 || ns.code == 204) { return }
        tab?.loadError = ns.localizedDescription
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // MARK: UI

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let model else { return nil }
        let t = model.newTab(url: nil, select: true, configuration: configuration)
        return t.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let tab, let model else { return }
        if model.peek?.tab === tab { model.closePeek(); return }
        model.close(tab)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        let a = NSAlert()
        a.messageText = frame.securityOrigin.host
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        let a = NSAlert()
        a.messageText = frame.securityOrigin.host
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        let a = NSAlert()
        a.messageText = frame.securityOrigin.host
        a.informativeText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        a.accessoryView = field
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        completionHandler(a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = parameters.allowsMultipleSelection
        p.canChooseDirectories = parameters.allowsDirectories
        p.canChooseFiles = true
        completionHandler(p.runModal() == .OK ? p.urls : nil)
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        decisionHandler(.prompt)
    }

    // MARK: Downloads

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor (URL?) -> Void) {
        completionHandler(Downloads.shared.destination(for: download, suggestedFilename: suggestedFilename, source: response.url))
    }

    func downloadDidFinish(_ download: WKDownload) {
        Downloads.shared.finished(download)
        model?.toast("Downloaded \(Downloads.shared.item(for: download)?.filename ?? "the file")")
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        Downloads.shared.failed(download, error: error)
        model?.toast("Download failed")
    }
}

/// What a link click does, from its modifier keys and the tab it was clicked in.
@MainActor
enum LinkRouting {
    enum Route: Equatable { case backgroundTab, foregroundTab, peek, split }

    /// Arc's meanings: Cmd-click opens a background tab (with Shift, in front), Shift-click opens
    /// Peek, Option-click opens split view. Links to another site from a pinned tab or Essential
    /// open in Peek, so the pinned page stays where it was. Nil lets the page navigate as usual.
    static func route(for url: URL, flags: NSEvent.ModifierFlags, from tab: Tab, peekForPins: Bool) -> Route? {
        let web = ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "")
        if flags.contains(.command) { return flags.contains(.shift) ? .foregroundTab : .backgroundTab }
        if flags.contains(.option) && web { return .split }
        if flags.contains(.shift) && web { return .peek }
        if peekForPins && web && tab.keepsPinnedURL, let from = tab.webView?.url ?? tab.url, URLKey.isIndexableWeb(from), !sameSite(from, url) {
            return .peek
        }
        return nil
    }

    /// Same site means the same registrable-looking domain: the last two labels, or three for
    /// country domains like co.uk.
    static func sameSite(_ a: URL, _ b: URL) -> Bool {
        site(host: a.host ?? "") == site(host: b.host ?? "")
    }

    static func site(host: String) -> String {
        let parts = host.lowercased().split(separator: ".").map(String.init)
        guard parts.count > 2, let last = parts.last else { return parts.joined(separator: ".") }
        let second = parts[parts.count - 2]
        let country = last.count == 2 && ["co", "com", "org", "net", "ac", "gov", "edu"].contains(second)
        return parts.suffix(country ? 3 : 2).joined(separator: ".")
    }
}
