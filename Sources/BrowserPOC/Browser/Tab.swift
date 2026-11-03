import AppKit
import WebKit

enum TabKind: String, Codable {
    case web, note, file
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

    var displayTitle: String {
        if !title.isEmpty { return title }
        if kind != .web, let url { return url.deletingPathExtension().lastPathComponent }
        if kind != .web { return "Note" }
        if let host = url?.host { return host }
        return "New tab"
    }

    var isBlank: Bool { kind == .web && url == nil && webView?.url == nil }
    var isLoaded: Bool { webView != nil }

    func ensureWebView(configuration: WKWebViewConfiguration? = nil) -> WKWebView {
        if let webView { return webView }
        guard let model else { fatalError("tab without model") }
        let wv = WKWebView(frame: .zero, configuration: configuration ?? model.webConfig)
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
                Task { @MainActor in if !t.isEmpty { self?.title = t; self?.model?.scheduleSave() } }
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
        if kind == .web, let url, configuration == nil {
            wv.load(URLRequest(url: url))
        }
        return wv
    }

    private func webURLChanged(_ u: URL?) {
        guard let u else { return }
        let old = url
        url = u
        model?.tabURLChanged(self, from: old)
    }

    func unload() {
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
    }

    func load(_ u: URL) {
        loadError = nil
        kind = .web
        url = u
        if let webView {
            webView.load(URLRequest(url: u))
        } else {
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
        guard let wv = webView, let u = wv.url, URLKey.isIndexableWeb(u) else { done(nil); return }
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
        if !["http", "https", "about", "data", "blob", "file", "javascript"].contains(scheme) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command) {
            model?.newTab(url: url, select: navigationAction.modifierFlags.contains(.shift))
            decisionHandler(.cancel)
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
        if let tab { model?.close(tab) }
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
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var dest = dir.appendingPathComponent(suggestedFilename)
        var n = 2
        let base = dest.deletingPathExtension().lastPathComponent
        let ext = dest.pathExtension
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        model?.flash("Download finished")
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        model?.flash("Download failed")
    }
}
