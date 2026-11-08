import AppKit
import CoreServices
import WebKit

/// The security quick wins from notes/research/2026-11-08-security-privacy.md.
enum SecurityTests {
    static func check(_ ok: Bool, _ label: String, _ detail: String = "") { SelfTest.check(ok, label, detail) }

    static func run(dir: URL) {
        configDefaults()
        externalApps()
    }

    static func configDefaults() {
        let c = MainActor.assumeIsolated { BrowserModel.makeConfig(store: .nonPersistent()) }
        let prefs: WKWebpagePreferences = c.defaultWebpagePreferences
        check(prefs.preferredHTTPSNavigationPolicy == .automaticFallbackToHTTP,
              "pages try HTTPS first and fall back to HTTP", "\(prefs.preferredHTTPSNavigationPolicy.rawValue)")
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        if major >= 27 {
            check(WebSecurity.supportsGlobalPrivacyControl && WebSecurity.globalPrivacyControl(prefs) == true,
                  "Global Privacy Control is on (macOS 27 and later)")
        } else {
            check(WebSecurity.globalPrivacyControl(prefs) == nil, "Global Privacy Control is skipped where WebKit lacks it")
        }
        check(c.preferences.isFraudulentWebsiteWarningEnabled, "Safari's fraudulent website warning stays on")
    }

    static func externalApps() {
        MainActor.assumeIsolated {
            let saved = ExternalApps.remembered
            defer { ExternalApps.remembered = saved }
            ExternalApps.remembered = [:]
            @MainActor func v(_ source: String?, app: Bool = true, window: Bool = true, asking: Bool = false, page: String = "zoom.us") -> ExternalApps.Verdict {
                ExternalApps.verdict(scheme: "zoommtg", pageSite: page, sourceSite: source, hasApp: app, inWindow: window, alreadyAsking: asking)
            }
            check(v(nil) == .ask, "a page asks before opening another app")
            check(v("zoom.us") == .ask, "a frame from the same site asks too")
            check(v("ads.example") == .block, "a frame from another site can't open apps at all")
            check(v("") == .block, "a frame with no origin can't open apps")
            check(v(nil, asking: true) == .block, "one question at a time per tab, so a page can't stack them up")
            check(v(nil, window: false) == .block, "a tab that isn't on screen can't ask")
            check(v(nil, app: false) == .block, "nothing happens when no app handles the link")
            ExternalApps.remembered[ExternalApps.key(site: "zoom.us", scheme: "zoommtg")] = true
            ExternalApps.remembered[ExternalApps.key(site: "spam.example", scheme: "zoommtg")] = false
            check(v(nil) == .open && v(nil, page: "spam.example") == .block && v(nil, page: "other.example") == .ask,
                  "Don't ask again holds per site and kind of link")
            check(v("ads.example") == .block, "a remembered yes doesn't let another site's frame through")
            check(LinkRouting.site(host: "a.b.example.co.uk") == "example.co.uk" && LinkRouting.site(host: "www.zoom.us") == "zoom.us"
                  && LinkRouting.sameSite(URL(string: "https://x.zoom.us/a")!, URL(string: "https://zoom.us/b")!),
                  "sites still group subdomains the same way")
        }
    }
}

/// The security checks that need a real web view, in `--smoketest`.
@MainActor
enum SecuritySmoke {
    static func check(_ ok: Bool, _ label: String, _ detail: String = "") { SelfTest.check(ok, label, detail) }

    static func run() {
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400),
                           configuration: BrowserModel.makeConfig(store: .nonPersistent()))
        wv.loadHTMLString("<!doctype html><title>GPC</title><p>hello</p>", baseURL: URL(string: "https://gpc.example.test/")!)
        _ = SmokeTest.wait(10) { !wv.isLoading }
        let gpc = PasswordSmoke.js(wv, "return navigator.globalPrivacyControl === true")
        if WebSecurity.supportsGlobalPrivacyControl {
            check((gpc as? Bool) == true, "pages see Global Privacy Control turned on", "\(String(describing: gpc))")
        } else {
            print("      Global Privacy Control: not in this WebKit")
        }
    }
}
