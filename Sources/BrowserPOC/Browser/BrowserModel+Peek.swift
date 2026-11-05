import AppKit
import WebKit

/// A page floating over the current one, like Arc's Peek and Zen's Glance.
struct PeekState {
    let tab: Tab
    /// The item it was opened from. Its sidebar row shows a marker while Peek is open.
    let parentID: UUID?
}

/// Find in page for the focused pane.
struct FindState: Equatable {
    var visible = false
    var query = ""
    /// Matches on the page. Nil while counting or with nothing typed.
    var matches: Int?
    var index = 0
    /// Bumped to ask the field to take focus and select its text.
    var focusToken = 0
}

extension BrowserModel {
    // MARK: Links

    /// What a link click asked for. See LinkRouting for which keys mean what.
    func routeLink(_ url: URL, _ route: LinkRouting.Route, from source: Tab) {
        switch route {
        case .backgroundTab:
            newTab(url: url, select: false)
            if BrowserPrefs.shared.value.sidebarHidden { toast("Opened in a new tab") }
        case .foregroundTab:
            newTab(url: url, select: true)
        case .peek:
            openPeek(url, from: source)
        case .split:
            if peek?.tab === source { return }
            let t = Tab(url: url)
            t.model = self
            t.order = topOrder(today: currentSpaceID)
            tabs.append(t)
            if !isVisible(source) { select(source) }
            openInSplit(t, side: .right, of: source.id)
            _ = t.ensureWebView()
        }
    }

    // MARK: Peek

    func openPeek(_ url: URL, from parent: Tab?) {
        // A Peek still on its way out finishes first, and an open one gives way at once.
        PeekMotion.shared.flush()
        if peek != nil { closePeekNow() }
        let t = Tab(url: url)
        t.model = self
        t.spaceID = parent.map { $0.isEssential ? currentSpaceID : ($0.spaceID ?? currentSpaceID) } ?? currentSpaceID
        _ = t.ensureWebView()
        peek = PeekState(tab: t, parentID: parent?.id)
        focusWeb(t)
    }

    /// Esc, a click outside, Cmd-W or the close button. It goes to Recently Closed, so
    /// Cmd-Shift-T brings it back as a tab. In the app it shrinks back toward its link first.
    func closePeek() {
        guard let p = peek else { return }
        if PeekMotion.shared.play(.closing, tab: p.tab.id, duration: PeekMotion.closeDuration, finish: { [weak self] in
            if self?.peek?.tab.id == p.tab.id { self?.closePeekNow() }
        }) { return }
        closePeekNow()
    }

    private func closePeekNow() {
        guard let p = peek else { return }
        peek = nil
        recordClosed([p.tab], reason: .closed)
        p.tab.unload()
    }

    /// Cmd-O: the page becomes a normal tab. The same web view moves, so nothing reloads. In the
    /// app the Peek fills the pane first, so the page doesn't jump.
    func expandPeek() {
        guard let p = peek else { return }
        if PeekMotion.shared.play(.expanding, tab: p.tab.id, duration: PeekMotion.expandDuration, finish: { [weak self] in
            if self?.peek?.tab.id == p.tab.id { self?.expandPeekNow() }
        }) { return }
        expandPeekNow()
    }

    private func expandPeekNow() {
        guard let p = peek else { return }
        peek = nil
        let t = p.tab
        t.spaceID = currentSpaceID
        t.order = topOrder(today: currentSpaceID)
        tabs.append(t)
        select(t)
        focusWeb(t)
    }

    /// The page joins what's on screen as a split. In the app the Peek moves to the right half first.
    func splitPeek() {
        guard let p = peek else { return }
        if PeekMotion.shared.play(.splitting, tab: p.tab.id, duration: PeekMotion.expandDuration, finish: { [weak self] in
            if self?.peek?.tab.id == p.tab.id { self?.splitPeekNow() }
        }) { return }
        splitPeekNow()
    }

    private func splitPeekNow() {
        guard let p = peek else { return }
        peek = nil
        let t = p.tab
        t.spaceID = currentSpaceID
        t.order = topOrder(today: currentSpaceID)
        tabs.append(t)
        if let parent = p.parentID.flatMap({ tab($0) }), !isVisible(parent) { select(parent) }
        if currentTab == nil { select(t) } else { openInSplit(t, side: .right, of: p.parentID) }
    }

    // MARK: Find in page

    /// Cmd-F. Notes use the text view's own find bar.
    func openFind() {
        guard let t = currentTab else { return }
        if t.isNote {
            NotificationCenter.default.post(name: .focusEditor, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                let item = NSMenuItem()
                item.tag = NSTextFinder.Action.showFindInterface.rawValue
                NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: item)
            }
            return
        }
        guard t.isWeb, t.webView != nil else { return }
        find.visible = true
        find.focusToken += 1
        if !find.query.isEmpty { runFind(fresh: true) }
    }

    func closeFind() {
        find.visible = false
        find.matches = nil
        find.index = 0
        currentWebTab?.webView?.evaluateJavaScript("window.getSelection && window.getSelection().removeAllRanges()", in: nil, in: .defaultClient) { _ in }
    }

    func setFindQuery(_ q: String) {
        guard q != find.query else { return }
        find.query = q
        runFind(fresh: true)
    }

    /// Cmd-G and Cmd-Shift-G, or Enter and Shift-Enter in the field.
    func findNext(backwards: Bool = false) {
        guard let t = currentTab else { return }
        if t.isNote {
            let item = NSMenuItem()
            item.tag = (backwards ? NSTextFinder.Action.previousMatch : NSTextFinder.Action.nextMatch).rawValue
            NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: item)
            return
        }
        if !find.visible { openFind(); return }
        runFind(fresh: false, backwards: backwards)
    }

    private func runFind(fresh: Bool, backwards: Bool = false) {
        guard let wv = currentWebTab?.webView else { return }
        let q = find.query
        guard !q.isEmpty else {
            find.matches = nil
            find.index = 0
            wv.evaluateJavaScript("window.getSelection && window.getSelection().removeAllRanges()", in: nil, in: .defaultClient) { _ in }
            return
        }
        let cfg = WKFindConfiguration()
        cfg.backwards = backwards
        cfg.wraps = true
        cfg.caseSensitive = false
        if fresh {
            wv.callAsyncJavaScript(FindJS.count, arguments: ["q": q], in: nil, in: .defaultClient) { [weak self] r in
                MainActor.assumeIsolated {
                    guard let self, self.find.query == q else { return }
                    let n = (try? r.get()).flatMap { ($0 as? NSNumber)?.intValue } ?? 0
                    self.find.matches = n
                    self.find.index = n > 0 ? 1 : 0
                    wv.evaluateJavaScript("window.getSelection && window.getSelection().removeAllRanges()", in: nil, in: .defaultClient) { _ in
                        MainActor.assumeIsolated { wv.find(q, configuration: cfg) { _ in } }
                    }
                }
            }
            return
        }
        wv.find(q, configuration: cfg) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, result.matchFound, let n = self.find.matches, n > 0 else { return }
                self.find.index = backwards ? (self.find.index <= 1 ? n : self.find.index - 1) : (self.find.index >= n ? 1 : self.find.index + 1)
            }
        }
    }
}

enum FindJS {
    /// Counts case-insensitive matches in the page's visible text. Runs in an isolated world.
    static let count = """
    const needle = String(q || '').toLowerCase();
    if (!needle) return 0;
    const text = ((document.body && document.body.innerText) || '').toLowerCase();
    let n = 0, i = 0;
    while ((i = text.indexOf(needle, i)) !== -1) { n += 1; i += needle.length; if (n > 9999) break; }
    return n;
    """
}
