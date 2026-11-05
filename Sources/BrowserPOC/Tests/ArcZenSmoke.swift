import AppKit
import SwiftUI
import WebKit

/// The Arc and Zen part of `--smoketest`: real web views, headless, with offscreen snapshots.
@MainActor
enum ArcZenSmoke {
    static func check(_ ok: Bool, _ label: String, _ detail: String = "") { SelfTest.check(ok, label, detail) }
    static func wait(_ s: Double, _ done: () -> Bool) -> Bool { SmokeTest.wait(s, until: done) }

    static func html(_ title: String, _ body: String, head: String = "") -> String {
        "<!doctype html><html><head><title>\(title)</title>\(head)</head><body style=\"font: 15px -apple-system; padding: 24px\"><h1>\(title)</h1>\(body)</body></html>"
    }

    /// A tiny PNG as a data URL, so the favicon path runs without the network.
    static func iconDataURL(red: Bool = false) -> String {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        (red ? NSColor(calibratedRed: 0.85, green: 0.35, blue: 0.35, alpha: 1) : NSColor(calibratedRed: 0.3, green: 0.55, blue: 0.95, alpha: 1)).setFill()
        NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 28, height: 28), xRadius: 7, yRadius: 7).fill()
        NSGraphicsContext.restoreGraphicsState()
        return "data:image/png;base64," + (rep.representation(using: .png, properties: [:])?.base64EncodedString() ?? "")
    }

    static func load(_ t: Tab, _ html: String, _ url: String) {
        t.ensureWebView().loadHTMLString(html, baseURL: URL(string: url)!)
    }

    static func run(model: BrowserModel, window: NSWindow, snaps: URL) {
        let shot = { (name: String) in SmokeTest.snapshot(window.contentView!, snaps.appendingPathComponent(name)) }
        BrowserPrefs.shared.reload()
        Settings.shared.update { $0.rightPanelOpen = true }
        if let s = model.currentSplit { model.separate(s) }

        // 1. Back and forward come back after a relaunch, from WebKit's session state.
        // Two real navigations to local data pages, so nothing touches the network.
        func dataPage(_ t: String) -> URL { URL(string: "data:text/html;charset=utf-8," + html(t, "<p>\(t)</p>").addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)! }
        let one = dataPage("Page one"), two = dataPage("Page two")
        let hist = model.newTab(url: one, select: true)
        _ = wait(5) { hist.webView?.url == one && hist.webView?.isLoading == false }
        hist.load(two)
        _ = wait(5) { hist.webView?.url == two && hist.canGoBack && hist.webView?.isLoading == false }
        let backBefore = hist.webView?.backForwardList.backList.count ?? -1
        model.saveNow()
        check(SessionFiles.read(hist.id) != nil, "the back and forward list is saved for each tab",
              "\(backBefore) back, \(SessionFiles.read(hist.id)?.count ?? 0) bytes")
        let again = BrowserModel()
        MediaWatch.shared.model = model
        let restored = again.tab(hist.id)
        _ = restored?.ensureWebView()
        let back = wait(8) { restored?.webView?.backForwardList.backItem?.url == one }
        check(back && restored?.webView?.url == two, "back and forward survive a relaunch",
              "back \(restored?.webView?.backForwardList.backItem?.url.absoluteString ?? "nil"), at \(restored?.webView?.url?.absoluteString ?? "nil")")
        restored?.unload()

        // 2. Favicons come from the page's own icon link and are cached by host.
        let iconPage = model.newTab(url: nil, select: true)
        load(iconPage, html("Icon page", "<p>A page with its own icon.</p>", head: "<link rel=\"icon\" sizes=\"32x32\" href=\"\(iconDataURL())\">"), "https://icons.smoke.test/home")
        let gotIcon = wait(10) { Favicons.shared.hasIcon(for: URL(string: "https://icons.smoke.test/")) }
        check(gotIcon && FileManager.default.fileExists(atPath: Favicons.file("icons.smoke.test").path), "the site's icon is read from the page and cached")
        // A page that swaps its icon, like an unread count, gets the new one.
        let before = Favicons.shared.generation
        let newIcon = iconDataURL(red: true)
        iconPage.webView?.evaluateJavaScript("document.querySelector('link[rel=icon]').href = '\(newIcon)'") { _, _ in }
        check(wait(8) { Favicons.shared.generation > before }, "a page that changes its icon gets the new one")
        model.addToEssentials(iconPage)
        let pinPage = model.newTab(url: nil, select: true)
        load(pinPage, html("Pinned mail", "<p>Inbox</p>", head: "<link rel=\"icon\" href=\"\(iconDataURL())\">"), "https://mail.smoke.test/inbox")
        _ = wait(5) { pinPage.webView?.isLoading == false && pinPage.url?.host == "mail.smoke.test" }
        model.togglePin(pinPage)
        load(pinPage, html("Settings", "<p>Somewhere else in the pinned site.</p>"), "https://mail.smoke.test/settings")
        _ = wait(5) { pinPage.url?.path == "/settings" }
        check(pinPage.isAwayFromPin, "a pinned page that wanders shows it in the sidebar")

        // 3. Find in page counts matches.
        let findPage = model.newTab(url: nil, select: true)
        load(findPage, html("Sourdough notes", "<p>Sourdough starter. Feed the sourdough. More SOURDOUGH tomorrow.</p>"), "https://find.smoke.test/")
        _ = wait(5) { findPage.webView?.isLoading == false && findPage.webView?.url?.host == "find.smoke.test" }
        model.openFind()
        model.setFindQuery("sourdough")
        // The heading says it once and the text three times.
        let counted = wait(5) { model.find.matches == 4 }
        model.findNext()
        _ = wait(2) { model.find.index == 2 }
        check(counted && model.find.index == 2, "find in page counts every match and steps through them", "\(model.find.matches ?? -1), at \(model.find.index)")
        shot("9-find-in-page.png")
        model.closeFind()

        // 4. Three panes, then four as a grid.
        let p2 = model.newTab(url: nil, select: false)
        load(p2, html("Second pane", "<p>Two</p>"), "https://two.smoke.test/")
        let p3 = model.newTab(url: nil, select: false)
        load(p3, html("Third pane", "<p>Three</p>"), "https://three.smoke.test/")
        model.select(findPage)
        model.openInSplit(p2)
        model.openInSplit(p3, side: .bottom)
        check(model.currentSplit?.count == 3, "three items share the screen")
        shot("10-split-three.png")
        model.openInSplit(iconPage)
        model.setLayout(.grid)
        check(model.currentSplit?.count == 4 && model.currentSplit?.root.layoutKind == .grid, "four items as a grid")
        _ = wait(1) { false }
        shot("11-split-grid.png")
        func hosted() -> [CGFloat] { model.visibleTabs.compactMap { $0.webView?.window === window ? $0.webView?.frame.width : nil } }
        _ = wait(3) { hosted().count == 4 }
        let paneWidths = hosted()
        let missing = model.visibleTabs.filter { $0.webView?.window !== window }.map { "\($0.displayTitle) loaded \($0.isLoaded)" }
        check(paneWidths.count == 4 && paneWidths.allSatisfy { $0 > 150 }, "each pane hosts its own live web view",
              "\(paneWidths.map { Int($0) }) \(missing.joined(separator: ", "))")
        if let s = model.currentSplit { model.separate(s) }

        // 5. Peek opens over the page and becomes a tab without reloading.
        model.select(pinPage)
        model.openPeek(URL(string: "about:blank#peek")!, from: pinPage)
        if let p = model.peek { load(p.tab, html("A page in Peek", "<p>Opened from a pinned tab.</p>"), "https://peek.smoke.test/") }
        _ = wait(2) { false }
        shot("12-peek.png")
        let pwv = model.peek?.tab.webView
        model.expandPeek()
        check(model.currentTab?.webView === pwv && pwv != nil && model.peek == nil, "Peek becomes a tab with the same web view")

        // 6. Media reported from the page shows controls when you look away.
        let media = model.currentTab!
        media.webView?.evaluateJavaScript("window.webkit.messageHandlers.bpocMedia.postMessage({playing: true, video: false, audible: true})", in: nil, in: MediaWatch.world) { _ in }
        _ = wait(3) { media.mediaPlaying }
        model.select(findPage)
        check(media.mediaPlaying && model.playingElsewhere.contains { $0.id == media.id }, "a page playing audio shows controls in the sidebar while you're elsewhere")
        var hasCommand = false
        media.webView?.evaluateJavaScript("typeof window.__bpocMediaCmd", in: nil, in: MediaWatch.world) { r in
            if case .success(let v) = r { hasCommand = (v as? String) == "function" }
        }
        _ = wait(3) { hasCommand }
        check(hasCommand, "the media script runs in its own world")
        model.toggleMute(media)
        check(media.isMuted, "a tab can be muted")

        // 7. Archive and history pages.
        let stale = model.newTab(url: nil, select: false)
        load(stale, html("An old tab", "<p>Idle</p>"), "https://old.smoke.test/")
        _ = wait(4) { stale.webView?.isLoading == false && stale.url != nil }
        stale.lastActiveAt = Date().addingTimeInterval(-48 * 3600)
        _ = model.archiveIdleTabs()
        check(model.tab(stale.id) == nil && model.closed.archive.contains { $0.id == stale.id }, "an idle tab moves to the archive")
        // A private pasteboard, so the test never touches the real clipboard.
        BrowserModel.pasteboard = NSPasteboard(name: NSPasteboard.Name("local.browserpoc.smoketest"))
        model.copyCurrentURL()
        check(BrowserModel.pasteboard.string(forType: .string) == "https://find.smoke.test/" && model.toastState?.message == "Copied link",
              "Cmd-Shift-C copies the link and says so", BrowserModel.pasteboard.string(forType: .string) ?? "nil")
        BrowserModel.pasteboard.releaseGlobally()
        shot("13-sidebar-essentials-pins-media.png")
        model.openAppPage("history")
        _ = wait(1) { false }
        shot("14-history.png")
        model.openAppPage("archive")
        _ = wait(1) { false }
        shot("15-archive.png")

        // 8. The command bar: actions, then autocomplete.
        model.select(findPage)
        model.bar.open(.newTab)
        model.bar.query = ""
        model.bar.setActionsOnly(true)
        check(model.bar.results.count > 10, "Tab on an empty bar lists the actions", "\(model.bar.results.count)")
        _ = wait(0.5) { false }
        shot("16-command-actions.png")
        model.bar.close()
        model.bar.open(.newTab)
        model.bar.lastEditWasInsertion = true
        model.bar.query = "icons.sm"
        check(model.bar.completion == "icons.smoke.test", "the bar fills in a domain you've been to", model.bar.completion ?? "nil")
        _ = wait(0.5) { false }
        shot("17-command-autofill.png")
        model.bar.close()

        // 9. Ctrl-Tab, compact mode and the sidebar on the right.
        model.beginSwitcher()
        _ = wait(0.3) { false }
        shot("18-ctrl-tab.png")
        model.switcher = nil
        BrowserPrefs.shared.update { $0.sidebarHidden = true }
        _ = wait(0.5) { false }
        shot("19-compact-mode.png")
        BrowserPrefs.shared.update { $0.sidebarHidden = false; $0.sidebarOnRight = true }
        _ = wait(0.5) { false }
        shot("20-sidebar-right.png")
        BrowserPrefs.shared.update { $0.sidebarOnRight = false }
        let main = window.contentView!.frame.width
        check(main > 0, "compact mode and the right-side sidebar draw")
    }
}
