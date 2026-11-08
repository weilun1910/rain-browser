import AppKit
import CoreServices
import WebKit

/// Security defaults for web pages: HTTPS first, Global Privacy Control, the "Not secure" check
/// and quarantining downloads. Research behind each one is in
/// notes/research/2026-11-08-security-privacy.md.
enum WebSecurity {
    /// Sets the defaults on a web view configuration.
    ///
    /// Loads try HTTPS first and quietly fall back to HTTP when a site has no HTTPS, like Safari
    /// since 18.2 and Firefox's HTTPS-First. Global Privacy Control tells sites the user doesn't
    /// want their data sold or shared. Its switch is public API from macOS 27, which the pinned
    /// 26.2 SDK doesn't declare yet, so it's set by name when the system has it.
    static func applyDefaults(to c: WKWebViewConfiguration) {
        let prefs: WKWebpagePreferences = c.defaultWebpagePreferences
        prefs.preferredHTTPSNavigationPolicy = .automaticFallbackToHTTP
        if prefs.responds(to: gpcSetter) { prefs.setValue(true, forKey: gpcKey) }
        c.defaultWebpagePreferences = prefs
    }

    static let gpcKey = "globalPrivacyControlEnabled"
    static let gpcSetter = NSSelectorFromString("setGlobalPrivacyControlEnabled:")

    /// Whether this Mac's WebKit has the Global Privacy Control switch (macOS 27 and later).
    static var supportsGlobalPrivacyControl: Bool { WKWebpagePreferences().responds(to: gpcSetter) }

    /// Global Privacy Control on these preferences, or nil when WebKit doesn't have the switch.
    static func globalPrivacyControl(_ prefs: WKWebpagePreferences) -> Bool? {
        guard prefs.responds(to: NSSelectorFromString(gpcKey)) else { return nil }
        return (prefs.value(forKey: gpcKey) as? Bool) ?? false
    }

    // MARK: Not secure

    /// A page the address field labels "Not secure": plain HTTP to anywhere but this Mac.
    static func isNotSecure(_ address: String) -> Bool {
        guard let u = URL(string: address.trimmingCharacters(in: .whitespaces)) else { return false }
        return isNotSecure(u)
    }

    static func isNotSecure(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http", let host = url.host?.lowercased(), !host.isEmpty else { return false }
        return !isThisMac(host)
    }

    /// Local addresses count as secure, the way Chrome and Safari treat them.
    static func isThisMac(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return h == "localhost" || h.hasSuffix(".localhost") || h == "::1" || h.hasPrefix("127.")
    }

    // MARK: Downloads

    /// Marks a finished download as coming from the internet, like Safari does, so Gatekeeper
    /// checks an app or script before it first opens. A file WebKit already marked is left alone.
    @discardableResult
    static func quarantine(_ file: URL, source: String?) -> Bool {
        if isQuarantined(file) { return true }
        var props: [String: Any] = [
            kLSQuarantineAgentNameKey as String: "Rain",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
        ]
        if let s = source, let u = URL(string: s), ["http", "https"].contains(u.scheme?.lowercased() ?? "") {
            props[kLSQuarantineDataURLKey as String] = u
        }
        var values = URLResourceValues()
        values.quarantineProperties = props
        var url = file
        do { try url.setResourceValues(values); return true } catch { return false }
    }

    static func isQuarantined(_ file: URL) -> Bool {
        var url = file
        url.removeAllCachedResourceValues()
        return (try? url.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties) != nil
    }
}

/// Asks before a page opens another app through a link like zoommtg: or mailto:, the way Safari
/// and Chrome do. A frame from another site can't ask at all, a background tab can't ask, one tab
/// shows one question at a time so a page can't stack them up, and "Don't ask again" holds for
/// that site and kind of link until Rain quits.
@MainActor
enum ExternalApps {
    enum Verdict: Equatable { case ask, open, block }

    /// Choices made with "Don't ask again" ticked, keyed by site and scheme. Not saved to disk.
    static var remembered: [String: Bool] = [:]
    private static var asking = Set<ObjectIdentifier>()

    static func key(site: String, scheme: String) -> String { "\(site.lowercased()) \(scheme.lowercased())" }

    /// The rules apart from the question itself, so the self test can check them.
    /// `sourceSite` is nil when the main frame asked, and "" for a frame with no origin.
    static func verdict(scheme: String, pageSite: String, sourceSite: String?, hasApp: Bool,
                        inWindow: Bool, alreadyAsking: Bool) -> Verdict {
        guard hasApp, inWindow else { return .block }
        if let s = sourceSite, s.isEmpty || s != pageSite { return .block }
        if !pageSite.isEmpty, let r = remembered[key(site: pageSite, scheme: scheme)] { return r ? .open : .block }
        return alreadyAsking ? .block : .ask
    }

    static func appName(for app: URL) -> String {
        let name = FileManager.default.displayName(atPath: app.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// Called for a navigation to a scheme WebKit doesn't load. The navigation itself is
    /// already cancelled; this decides whether the link goes to its app.
    static func request(_ url: URL, action: WKNavigationAction, webView: WKWebView, model: BrowserModel?) {
        let scheme = url.scheme?.lowercased() ?? ""
        let pageHost = webView.url?.host ?? ""
        let pageSite = pageHost.isEmpty ? "" : LinkRouting.site(host: pageHost)
        // Swift says sourceFrame is never nil, but it is for loads the app starts itself.
        let source = action.value(forKey: "sourceFrame") as? WKFrameInfo
        var sourceSite: String?
        if let source, !source.isMainFrame {
            let h = source.securityOrigin.host
            sourceSite = h.isEmpty ? "" : LinkRouting.site(host: h)
        }
        let app = NSWorkspace.shared.urlForApplication(toOpen: url)
        let id = ObjectIdentifier(webView)
        let v = verdict(scheme: scheme, pageSite: pageSite, sourceSite: sourceSite, hasApp: app != nil,
                        inWindow: webView.window != nil, alreadyAsking: asking.contains(id))
        switch v {
        case .block:
            if app == nil, action.navigationType == .linkActivated { model?.toast("No app on this Mac opens \(scheme): links") }
            return
        case .open:
            NSWorkspace.shared.open(url)
            return
        case .ask:
            break
        }
        guard let app, let window = webView.window else { return }
        let name = appName(for: app)
        let alert = NSAlert()
        alert.messageText = "Open \(name)?"
        alert.informativeText = pageSite.isEmpty ? "This page wants to open a link in \(name)." : "\(pageSite) wants to open a link in \(name)."
        alert.addButton(withTitle: "Open \(name)")
        alert.addButton(withTitle: "Cancel")
        if !pageSite.isEmpty {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't ask again for \(pageSite) until Rain quits"
        }
        asking.insert(id)
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                asking.remove(id)
                let open = response == .alertFirstButtonReturn
                if alert.suppressionButton?.state == .on, !pageSite.isEmpty { remembered[key(site: pageSite, scheme: scheme)] = open }
                if open { NSWorkspace.shared.open(url) }
            }
        }
    }
}
