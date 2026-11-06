import AppKit
import WebKit

/// The tab bar with a real page: the page's web view moves into the tab bar layout and back, the
/// address field sits in the toolbar for the command bar to grow from, and spaces still switch.
@MainActor
enum TabBarSmoke {
    static func run(model: BrowserModel, window: NSWindow, snaps: URL) {
        func check(_ ok: Bool, _ label: String, _ detail: String = "") { SelfTest.check(ok, label, detail) }
        let before = BrowserPrefs.shared.value.tabLayout
        let tab = model.newTab(url: nil, select: true)
        tab.ensureWebView().loadHTMLString("<title>Tab bar page</title><h1>Tab bar page</h1>", baseURL: URL(string: "https://tabbar.test/page"))
        _ = SmokeTest.wait(5) { !tab.isLoading && tab.title == "Tab bar page" }

        /// How far the page's top sits below the window's top.
        func pageTop() -> CGFloat {
            guard let wv = tab.webView, wv.window === window, let v = window.contentView else { return -1 }
            return v.bounds.height - wv.convert(wv.bounds, to: nil).maxY
        }
        let bar = Theme.Space.titleBarHeight + TabBarMetrics.stripHeight
        TabLayoutSwitch.set(.horizontal)
        let moved = SmokeTest.wait(5) { pageTop() >= bar - 1 && (tab.webView?.bounds.width ?? 0) > 200 }
        check(moved, "a page moves into the tab bar layout, below the toolbar and the row of tabs",
              "page top at \(pageTop()), \(tab.webView?.bounds.size ?? .zero)")
        let inToolbar = SmokeTest.wait(2) {
            let f = CommandBarAnchor.shared.addressFrame
            return f.minY < Theme.Space.titleBarHeight && f.width > 200
        }
        check(inToolbar, "the address field sits in the toolbar for the command bar", "\(CommandBarAnchor.shared.addressFrame)")
        SmokeTest.snapshot(window.contentView!, snaps.appendingPathComponent("12b-tab-bar.png"))

        // Spaces switch from the bar, and the bar shows the other space's tabs.
        let home = model.currentSpaceID
        let other = model.spaces.first { $0.id != home } ?? model.createSpace(name: "Tab bar")
        model.switchSpace(to: other.id)
        _ = SmokeTest.wait(1) { false }
        check(model.currentSpaceID == other.id && TabBarState.shared.spaceMenuOpen == false, "spaces switch in the tab bar layout")
        model.switchSpace(to: home)
        model.select(tab)

        TabLayoutSwitch.set(.sidebar)
        let back = SmokeTest.wait(5) { pageTop() >= 0 && pageTop() < bar - 1 && (tab.webView?.bounds.width ?? 0) > 200 }
        check(back, "the page moves back when the sidebar returns", "page top at \(pageTop()), \(tab.webView?.bounds.size ?? .zero)")
        SmokeTest.snapshot(window.contentView!, snaps.appendingPathComponent("12c-sidebar-again.png"))
        if before != .sidebar { TabLayoutSwitch.set(before) }
        model.close(tab)
    }
}
