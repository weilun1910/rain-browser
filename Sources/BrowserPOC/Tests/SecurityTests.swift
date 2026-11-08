import AppKit
import CoreServices
import WebKit

/// The security quick wins from notes/research/2026-11-08-security-privacy.md.
enum SecurityTests {
    static func check(_ ok: Bool, _ label: String, _ detail: String = "") { SelfTest.check(ok, label, detail) }

    static func run(dir: URL) {
        externalApps()
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
