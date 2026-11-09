import AppKit
import SwiftUI
import WebKit

/// The horizontal tab bar: its saved setting, the switch both ways, tab widths, the Essentials
/// box, the order tabs show in and where drops land, and the bar drawing in a window.
enum TabBarTests {
    static func check(_ ok: Bool, _ label: String, _ detail: String = "") { SelfTest.check(ok, label, detail) }

    static func run(dir: URL) {
        MainActor.assumeIsolated {
            BrowserModel.useEphemeralStore = true
            BrowserPrefs.shared.reload()
            rules()
            savedSetting()
            switching()
            model()
            drawing()
            BrowserPrefs.shared.update { $0.tabLayout = .sidebar }
            try? FileManager.default.removeItem(at: Paths.stateFile)
        }
    }

    // MARK: Rules

    @MainActor static func rules() {
        let r = TabBarRules.self
        check(r.tabWidth(available: 1000, fixed: 100, units: 4, gaps: 3) == 223, "tabs share the strip's room evenly",
              "\(r.tabWidth(available: 1000, fixed: 100, units: 4, gaps: 3))")
        check(r.tabWidth(available: 1400, fixed: 0, units: 2, gaps: 1) == r.tabMaxWidth, "two tabs in a wide window stop at the widest a tab gets")
        check(r.tabWidth(available: 800, fixed: 0, units: 30, gaps: 29) == r.tabMinWidth, "many tabs stop at the narrowest a tab gets")
        check(!r.overflows(available: 800, fixed: 0, units: 5, gaps: 4) && r.overflows(available: 800, fixed: 0, units: 30, gaps: 29),
              "the strip scrolls only once tabs reach their narrowest")
        check(r.tabWidth(available: 800, fixed: 0, units: 0, gaps: 0) == r.tabMaxWidth, "an empty strip doesn't divide by zero")

        let ids = (0..<6).map { _ in UUID() }
        check(r.essentialSlots(ids) == Array(ids.prefix(3)), "the Essentials box shows the first three, always in their places")
        check(r.essentialSlots(Array(ids.prefix(2))) == Array(ids.prefix(2)), "with two Essentials the box shows two")
        check(r.essentialSlots([]).isEmpty, "with no Essentials the box shows none")
        check(r.openIsHidden(ids, open: [ids[4]]) && !r.openIsHidden(ids, open: [ids[1]]) && !r.openIsHidden(ids, open: []),
              "the count lights up only when the page you're on is a hidden Essential")
        check(EssentialsBoxGeometry.restWidth(6) == EssentialsBoxGeometry.width(3)
              && EssentialsBoxGeometry.restWidth(3) == EssentialsBoxGeometry.width(3) && EssentialsBoxGeometry.restWidth(2) == EssentialsBoxGeometry.width(2),
              "the box is three tiles wide at most")
        check(EssentialsBoxGeometry.slotWidth(6) == EssentialsBoxGeometry.width(3) + EssentialsBoxGeometry.gap + EssentialsBoxGeometry.countWidth
              && EssentialsBoxGeometry.slotWidth(3) == EssentialsBoxGeometry.width(3),
              "the count sits outside the box, and only when there are more")
        check(r.essentialsOpenDelay == Motion.Timing.revealDwell && r.essentialsCloseDelay == Motion.Timing.concealDelay,
              "the box opens and closes on the same timings as the sidebar's icon column")
        check([1, 3, 4, 7, 12].map(r.essentialRows) == [1, 1, 2, 3, 4], "the open grid has a row per three Essentials",
              "\([1, 3, 4, 7, 12].map(r.essentialRows))")
        check(EssentialsBoxGeometry.width(r.essentialsColumns) == EssentialsBoxGeometry.restWidth(12)
              && EssentialsBoxGeometry.openHeight(12) > EssentialsBoxGeometry.openHeight(4)
              && (0..<3).allSatisfy { EssentialsBoxGeometry.gridOrigin($0).y == EssentialsBoxGeometry.pad }
              && EssentialsBoxGeometry.gridOrigin(3).x == EssentialsBoxGeometry.gridOrigin(0).x && EssentialsBoxGeometry.gridOrigin(3).y > 0,
              "the grid opens straight down at the box's own width, with the first three where they were")

        let refs: [SidebarRef] = ids.prefix(3).map { .tab($0) }
        check(r.barOrder(refs) == refs.reversed(), "the bar lists tabs oldest first, newest at the right")
        check(r.todayDrop(displayAfter: false) == true && r.todayDrop(displayAfter: true) == false,
              "left of a tab in the bar is below it in the sidebar, and right is above")
    }

    // MARK: Saved setting

    @MainActor static func savedSetting() {
        let dec = JSONDecoder()
        let old = try? dec.decode(BrowserPrefsValue.self, from: Data("{\"archiveAfterHours\":24,\"sidebarHidden\":true}".utf8))
        check(old?.tabLayout == .sidebar && old?.archiveAfterHours == 24 && old?.sidebarHidden == true,
              "browser preferences from before the tab bar keep the sidebar and every other setting")
        let new = try? dec.decode(BrowserPrefsValue.self, from: Data("{\"tabLayout\":\"horizontal\"}".utf8))
        check(new?.tabLayout == .horizontal, "the tab bar layout reads back")
        let odd = try? dec.decode(BrowserPrefsValue.self, from: Data("{\"tabLayout\":\"diagonal\",\"littleArc\":false}".utf8))
        check(odd?.tabLayout == .sidebar && odd?.littleArc == false, "a layout this build doesn't know falls back to the sidebar and keeps the rest")
        var v = BrowserPrefsValue()
        v.tabLayout = .horizontal
        let back = (try? JSONEncoder().encode(v)).flatMap { try? dec.decode(BrowserPrefsValue.self, from: $0) }
        check(back == v, "the layout round trips through browser.json")
    }

    // MARK: Switching

    @MainActor static func switching() {
        BrowserPrefs.shared.update { $0.tabLayout = .sidebar }
        TabBarState.shared.essentialsOpen = true
        TabLayoutSwitch.set(.horizontal)
        check(BrowserPrefs.shared.value.tabLayout == .horizontal && !TabBarState.shared.essentialsOpen,
              "switching to the tab bar saves it and closes anything left open")
        BrowserPrefs.shared.reload()
        check(BrowserPrefs.shared.value.tabLayout == .horizontal, "the tab bar layout is still there after reading browser.json again")
        TabLayoutSwitch.toggle()
        check(BrowserPrefs.shared.value.tabLayout == .sidebar, "the switch goes back to the sidebar")

        let s = TabLayoutSwitch.self
        check(!s.applies("view.sidebar", in: .horizontal) && !s.applies("view.sidebarSide", in: .horizontal) && !s.applies("view.sidebarIcons", in: .horizontal),
              "the sidebar's own actions are left out of the command bar in the tab bar layout")
        check(s.applies("view.sidebar", in: .sidebar) && s.applies("tab.close", in: .horizontal) && s.applies("space.next", in: .horizontal),
              "other actions stay in both layouts")
        check(s.applies("view.tabBar", in: .sidebar) && !s.applies("view.tabBar", in: .horizontal)
              && s.applies("view.tabSidebar", in: .horizontal) && !s.applies("view.tabSidebar", in: .sidebar),
              "the command bar offers the layout you're not in")

        let m = ArcZenTests.freshModel()
        let sidebarIDs = Set(BarActions.available(m).map(\.id))
        TabLayoutSwitch.set(.horizontal)
        let barIDs = Set(BarActions.available(m).map(\.id))
        check(sidebarIDs.contains("view.tabBar") && !sidebarIDs.contains("view.tabSidebar") && barIDs.contains("view.tabSidebar")
              && !barIDs.contains("view.sidebar") && !barIDs.contains("view.tabBar"),
              "the command bar's list follows the layout")
        let item = NSMenuItem(title: "Tabs in a Bar Along the Top", action: #selector(AppDelegate.tabLayoutAction), keyEquivalent: "s")
        let sidebarItem = NSMenuItem(title: "Toggle Sidebar", action: NSSelectorFromString("toggleSidebarAction"), keyEquivalent: "s")
        let delegate = AppDelegate.shared ?? AppDelegate()
        let on = delegate.validateMenuItem(item) && item.state == .on
        let sidebarOff = !delegate.validateMenuItem(sidebarItem)
        TabLayoutSwitch.set(.sidebar)
        check(on && sidebarOff && delegate.validateMenuItem(item) && item.state == .off && delegate.validateMenuItem(sidebarItem),
              "the View menu checks the tab bar while it's on and turns the sidebar's items off")
    }

    // MARK: Model

    @MainActor static func model() {
        let m = ArcZenTests.freshModel()
        let space = m.currentSpaceID
        let a = ArcZenTests.page(m, "https://a.example.com", "A")
        let b = ArcZenTests.page(m, "https://b.example.com", "B")
        let c = ArcZenTests.page(m, "https://c.example.com", "C", select: true)
        check(m.refs(in: .today) == [.tab(c.id), .tab(b.id), .tab(a.id)], "the sidebar lists tabs newest first")
        check(m.barRows(space: space).today == [.tab(a.id), .tab(b.id), .tab(c.id)], "the bar lists the same tabs oldest first")

        // Cmd-1 to 9 count what's on screen.
        TabLayoutSwitch.set(.horizontal)
        check(m.visibleRowOrder == [.tab(a.id), .tab(b.id), .tab(c.id)], "Cmd-1 to 9 count the bar's tabs left to right")
        m.selectRow(number: 1)
        check(m.currentTab?.id == a.id, "Cmd-1 picks the leftmost tab in the bar")
        TabLayoutSwitch.set(.sidebar)
        check(m.visibleRowOrder == [.tab(c.id), .tab(b.id), .tab(a.id)], "and the sidebar's top row in the sidebar")

        // Drag C to the left of A in the bar.
        m.place([.tab(c.id)], next: .tab(a.id), after: TabBarRules.todayDrop(displayAfter: false))
        check(m.barRows(space: space).today == [.tab(c.id), .tab(a.id), .tab(b.id)], "a tab dropped left of another lands left of it in the bar",
              "\(m.barRows(space: space).today.compactMap { m.tab($0.id)?.title })")
        // And A to the right of B.
        m.place([.tab(a.id)], next: .tab(b.id), after: TabBarRules.todayDrop(displayAfter: true))
        check(m.barRows(space: space).today == [.tab(c.id), .tab(b.id), .tab(a.id)], "a tab dropped right of another lands right of it in the bar",
              "\(m.barRows(space: space).today.compactMap { m.tab($0.id)?.title })")
        // The empty end of the strip makes a tab the newest, at the right.
        m.place([.tab(c.id)], in: .today, at: 0)
        check(m.barRows(space: space).today.last == .tab(c.id), "a tab dropped on the strip's empty end goes to the right end")

        // The line pins.
        m.place([.tab(b.id)], in: .pinned, at: Int.max)
        let rows = m.barRows(space: space)
        check(rows.pinned == [.tab(b.id)] && b.isPinned && !rows.today.contains(.tab(b.id)), "a tab dropped on the line is pinned and moves before it")
        let layout = TabStripLayout.measure(m, space: space, available: 900, frozen: nil)
        check(abs(layout.pinnedRoom - (TabBarRules.pinnedWidth + TabBarRules.dividerRoom)) < 0.5 && !layout.overflows
              && layout.tabWidth == TabBarRules.tabMaxWidth,
              "a pinned tab and its line take fixed room, and two tabs get the widest width",
              "pinned \(layout.pinnedRoom), tab \(layout.tabWidth)")
        let frozen = TabStripLayout.measure(m, space: space, available: 900, frozen: 150)
        check(frozen.tabWidth == 150, "tabs keep their width while you close them one after another")

        // Many tabs reach their narrowest and scroll.
        for i in 0..<20 { _ = ArcZenTests.page(m, "https://many\(i).example.com", "Many \(i)") }
        let full = TabStripLayout.measure(m, space: space, available: 900, frozen: nil)
        check(full.overflows && full.tabWidth == TabBarRules.tabMinWidth, "past their narrowest the tabs scroll", "\(full.tabWidth)")

        // Option-click on a close button closes the other loose tabs and keeps pinned ones.
        let keepPinned = b
        let closedBefore = m.closed.recent.count
        let n = m.closeOtherTabs(keeping: a)
        check(n > 0 && m.refs(in: .today) == [.tab(a.id)] && m.tab(keepPinned.id) != nil && m.currentTab?.id == a.id
              && m.closed.recent.count >= closedBefore + n,
              "Option-click on a tab's close button closes the other tabs, keeps pinned ones, and they go to Recently Closed",
              "closed \(n), left \(m.refs(in: .today).count)")
        let state = TabBarState.shared
        state.holdWidths(140)
        state.pointerInStrip(true)
        check(state.frozenTabWidth == 140, "tabs hold their width while the pointer stays in the strip")
        state.pointerInStrip(false)
        check(state.frozenTabWidth == 140, "and for a moment after it leaves")
        _ = SmokeTest.wait(TabBarRules.widthHold + 0.4) { state.frozenTabWidth == nil }
        check(state.frozenTabWidth == nil, "then they ease to their new widths")
        let c2 = ArcZenTests.page(m, "https://c2.example.com", "C2", select: true)

        // Folders: a closed one keeps only what's on screen.
        let f = m.createFolder(named: "Reading")
        let d = ArcZenTests.page(m, "https://d.example.com", "D")
        let e = ArcZenTests.page(m, "https://e.example.com", "E")
        m.move(d, to: f.id)
        m.move(e, to: f.id)
        guard let folder = m.folders.first(where: { $0.id == f.id }) else { check(false, "the folder was made"); return }
        check(m.barRows(folder: folder).count == 2, "an open folder shows its tabs after its chip")
        m.select(d)
        m.setFolder(f.id, open: false)
        let closed = m.folders.first { $0.id == f.id }!
        check(m.barRows(folder: closed) == [.tab(d.id)], "a closed folder keeps the tab on screen beside its chip")
        check(BarFolderChip.width(closed, count: 2) > BarFolderChip.width(folder, count: 2), "a closed folder's chip makes room for its count")

        // Splits show as one item, two tabs wide.
        m.select(a)
        m.openInSplit(c2)
        if let sp = m.currentSplit {
            check(m.barRows(space: space).today.contains(.split(sp.id)) && !m.barRows(space: space).today.contains(.tab(a.id)),
                  "a split shows as one item in the bar")
            check(TabStripLayout.splitWidth(150) == 300 + TabBarRules.gap, "a split is two tabs wide")
        } else {
            check(false, "Option-click style split opens", "no split")
        }
    }

    // MARK: Drawing

    /// The bar in a window: it lays out, its strip has the Essentials box, and switching back puts
    /// the sidebar's web view host in the window again.
    @MainActor static func drawing() {
        let m = ArcZenTests.freshModel()
        for i in 0..<5 { m.addToEssentials(ArcZenTests.page(m, "https://e\(i).example.com", "E\(i)")) }
        let page = ArcZenTests.page(m, "https://x.example.com", "X", select: true)
        page.ensureWebView().loadHTMLString("<h1>Under the grid</h1>", baseURL: URL(string: "https://x.example.com"))
        MotionSuppression.set(.launch, true)
        // The first run panel would cover the page that the click checks below need.
        let firstRun = Settings.shared.value.firstRunDone
        Settings.shared.update { $0.firstRunDone = true }
        defer {
            MotionSuppression.set(.launch, false)
            Settings.shared.update { $0.firstRunDone = firstRun }
        }
        TabLayoutSwitch.set(.horizontal)
        let host = MainView.host(m)
        let w = SmokeTest.offscreenWindow(host, size: NSSize(width: 1200, height: 800))
        WindowChrome.configure(w)
        _ = SmokeTest.wait(0.6) { false }
        host.layoutSubtreeIfNeeded()
        check(host.fittingSize.width <= 1200 && host.bounds.width == 1200, "the tab bar layout fits the window")
        TabBarState.shared.essentialsOpen = true
        _ = SmokeTest.wait(0.3) { false }
        let png = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        if let png { host.cacheDisplay(in: host.bounds, to: png) }
        check(png != nil, "the tab bar draws with the Essentials grid open")
        // A click on the open grid where it hangs over the page reaches the grid, not the page.
        // Drawn inside its container, the sidebar's icon-column grid went under the web view.
        // Just under the row of tabs, over the page's top left. `hitTest` takes the point in the
        // superview's coordinates.
        let below = Theme.Space.titleBarHeight + TabBarMetrics.stripHeight + 6
        let inHost = NSPoint(x: Theme.Space.windowMargin + EssentialsBoxGeometry.tileWidth / 2, y: host.isFlipped ? below : host.bounds.height - below)
        let point = host.superview.map { host.convert(inHost, to: $0) } ?? inHost
        let hit = host.hitTest(point)
        var inPage = false
        var v: NSView? = hit
        while let x = v { if x is WebHostView || x is WKWebView { inPage = true }; v = x.superview }
        check(hit != nil && !inPage && EssentialsBoxGeometry.openHeight(5) > TabBarMetrics.itemHeight + 6,
              "a click on the open Essentials grid over the page reaches the grid", hit.map { String(describing: type(of: $0)) } ?? "nothing")
        TabBarState.shared.closeAll()
        _ = SmokeTest.wait(0.2) { false }
        var closedHit: NSView? = host.hitTest(point)
        var reachesPage = false
        while let x = closedHit { if x is WebHostView || x is WKWebView { reachesPage = true }; closedHit = x.superview }
        let wv = page.webView
        let wvFrame = wv.map { $0.window == nil ? "not in a window" : "\($0.convert($0.bounds, to: nil))" } ?? "none"
        check(reachesPage, "with the grid closed, a click there reaches the page",
              "hit \(host.hitTest(point).map { String(describing: type(of: $0)) } ?? "nothing") at \(point), page \(wvFrame), window \(w.frame.size)")
        TabLayoutSwitch.set(.sidebar)
        _ = SmokeTest.wait(0.4) { false }
        check(BrowserPrefs.shared.value.tabLayout == .sidebar && w.contentView === host, "switching back keeps the same window")
        w.close()
    }
}
