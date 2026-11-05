import AppKit
import Foundation

/// The Arc and Zen behaviour: split trees, pins and Essentials, ordering, the archive, the
/// command bar's actions and autocomplete, history, profiles and app pages.
enum ArcZenTests {
    static func check(_ ok: Bool, _ label: String, _ detail: String = "") { SelfTest.check(ok, label, detail) }

    static func run(dir: URL) {
        MainActor.assumeIsolated {
            BrowserModel.useEphemeralStore = true
            BrowserPrefs.shared.reload()
            splitTree()
            dropMath()
            linkRouting()
            cleanURL()
            history(dir: dir)
            splitModel()
            pinsAndEssentials()
            ordering()
            closedAndArchive()
            commandBar()
            fuzzyAndLearner()
            profilesAndPages()
            switcherAndRows()
            peekAndLittleArc()
            downloadsAndSessions(dir: dir)
            favicons()
            foldersAndKeyboard()
            try? FileManager.default.removeItem(at: Paths.stateFile)
        }
    }

    @MainActor static func freshModel() -> BrowserModel {
        try? FileManager.default.removeItem(at: Paths.stateFile)
        try? FileManager.default.removeItem(at: ClosedStore.file)
        return BrowserModel()
    }

    @MainActor static func page(_ m: BrowserModel, _ url: String, _ title: String = "", select: Bool = false) -> Tab {
        let t = Tab(url: URL(string: url)!, title: title.isEmpty ? url : title)
        t.model = m
        t.order = m.topOrder(today: m.currentSpaceID)
        m.tabs.append(t)
        if select { m.select(t) }
        return t
    }

    // MARK: Split tree

    @MainActor static func splitTree() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let two = SplitNode.leaf(a).inserting(b, at: .right, of: a)
        check(two == .branch(.row, [.leaf(a), .leaf(b)], [0.5, 0.5]), "a pane dropped on the right edge makes a side by side pair")
        let three = two.inserting(c, at: .right, of: b)
        check(three.leaves == [a, b, c] && three == .branch(.row, [.leaf(a), .leaf(b), .leaf(c)], [0.5, 0.25, 0.25]),
              "a pane added beside one in a row becomes a sibling and shares its space")
        let four = three.inserting(d, at: .bottom, of: a)
        if case .branch(.row, let kids, _) = four, case .branch(.column, let col, _) = kids[0] {
            check(col == [.leaf(a), .leaf(d)] && four.leaves == [a, d, b, c], "dropping on a pane's bottom edge stacks the new pane under it")
        } else {
            check(false, "dropping on a pane's bottom edge stacks the new pane under it", "\(four)")
        }
        let back = four.removing(d)
        check(back?.leaves == [a, b, c] && back.map { if case .branch(.row, let k, let s) = $0 { return k.count == 3 && abs(s.reduce(0, +) - 1) < 1e-9 }; return false } == true,
              "removing a pane folds its column away and keeps shares adding up")
        check(SplitNode.leaf(a).inserting(b, at: .right, of: a).removing(a) == .leaf(b), "a split left with one pane is just that pane")
        let grid3 = SplitNode.layout([a, b, c], .grid)
        let grid4 = SplitNode.layout([a, b, c, d], .grid)
        check(grid3 == .branch(.row, [.branch(.column, [.leaf(a), .leaf(b)], [0.5, 0.5]), .leaf(c)], [0.5, 0.5])
              && grid4.leaves == [a, b, c, d] && grid4.layoutKind == .grid && SplitNode.layout([a, b], .grid).layoutKind == .sideBySide,
              "grid stacks pairs in columns with an odd one at full height, like Zen")
        check(SplitNode.layout([a, b, c], .stacked).layoutKind == .stacked && three.layoutKind == .sideBySide && four.layoutKind == nil,
              "layouts are recognised from the tree")
        check(four.swapping(a, c).leaves == [c, d, b, a], "swap trades two panes")
        // Old two-pane files.
        let old = """
        {"id":"\(UUID().uuidString)","left":"\(a.uuidString)","right":"\(b.uuidString)","ratio":0.62,"focusRight":true,"createdAt":"2026-11-03T10:00:00Z"}
        """
        let r = try? JSONDecoder.iso.decode(SplitRecord.self, from: Data(old.utf8))
        check(r?.items == [a, b] && r?.focused == b && r.map { abs($0.ratio - 0.62) < 1e-9 } == true && r?.focusRight == true,
              "a split saved by the first version loads as a two-pane row")
        var rec = SplitRecord(root: four, focused: d)
        rec.isPinned = true
        rec.order = 3
        let data = try? JSONEncoder.pretty.encode(rec)
        let again = data.flatMap { try? JSONDecoder.iso.decode(SplitRecord.self, from: $0) }
        check(again?.root == rec.root && again?.focused == d && again?.isPinned == true && again?.order == 3 && again?.id == rec.id,
              "a split tree survives saving and loading")
    }

    @MainActor static func dropMath() {
        let r = CGRect(x: 0, y: 0, width: 800, height: 600)
        check(DropMath.edge(at: CGPoint(x: 20, y: 300), in: r) == .left && DropMath.edge(at: CGPoint(x: 790, y: 300), in: r) == .right
              && DropMath.edge(at: CGPoint(x: 400, y: 580), in: r) == .bottom && DropMath.edge(at: CGPoint(x: 400, y: 10), in: r) == .top
              && DropMath.edge(at: CGPoint(x: 400, y: 300), in: r) == nil,
              "drops pick the nearest edge within a quarter of the pane, and the middle picks none")
        check(DropMath.preview(.right, in: r) == CGRect(x: 400, y: 0, width: 400, height: 600), "the drop preview covers the half the new pane takes")
    }

    @MainActor static func linkRouting() {
        let m = freshModel()
        let pinned = page(m, "https://mail.example.com/inbox", "Mail")
        m.togglePin(pinned)
        let plain = page(m, "https://news.example.org/a")
        let cross = URL(string: "https://other.site/page")!
        let same = URL(string: "https://www.example.com/settings")!
        check(LinkRouting.route(for: cross, flags: [], from: pinned, peekForPins: true) == .peek
              && LinkRouting.route(for: same, flags: [], from: pinned, peekForPins: true) == nil
              && LinkRouting.route(for: cross, flags: [], from: plain, peekForPins: true) == nil
              && LinkRouting.route(for: cross, flags: [], from: pinned, peekForPins: false) == nil,
              "links to other sites from a pinned tab open in Peek, links within the site stay")
        check(LinkRouting.route(for: cross, flags: .option, from: plain, peekForPins: true) == .split
              && LinkRouting.route(for: cross, flags: .shift, from: plain, peekForPins: true) == .peek
              && LinkRouting.route(for: cross, flags: .command, from: plain, peekForPins: true) == .backgroundTab
              && LinkRouting.route(for: cross, flags: [.command, .shift], from: plain, peekForPins: true) == .foregroundTab,
              "Option-click splits, Shift-click peeks, Cmd-click opens a background tab")
        check(LinkRouting.sameSite(URL(string: "https://a.bbc.co.uk")!, URL(string: "https://www.bbc.co.uk/news")!)
              && !LinkRouting.sameSite(URL(string: "https://bbc.co.uk")!, URL(string: "https://itv.co.uk")!),
              "same site looks at the registrable domain, including country domains")
        m.prepareForQuit()
    }

    @MainActor static func cleanURL() {
        let u = URL(string: "https://example.com/a?id=4&utm_source=x&utm_campaign=y&fbclid=z&si=abc&q=swift")!
        check(CleanURL.strip(u).absoluteString == "https://example.com/a?id=4&q=swift", "Copy link drops tracking parameters", CleanURL.strip(u).absoluteString)
        check(CleanURL.strip(URL(string: "https://example.com/?utm_source=a")!).absoluteString == "https://example.com/", "and the question mark when nothing is left")
    }

    @MainActor static func history(dir: URL) {
        let h = HistoryStore(path: dir.appendingPathComponent("history-test.sqlite").path)
        let t0 = Date().addingTimeInterval(-3 * 3600)
        h.record(url: URL(string: "https://github.com/zen-browser/desktop")!, title: "Zen desktop", spaceID: nil, at: t0)
        h.record(url: URL(string: "https://github.com/zen-browser/desktop")!, title: "", spaceID: nil, at: t0.addingTimeInterval(60))
        h.record(url: URL(string: "https://www.github.com/nook-browser/Nook")!, title: "Nook", spaceID: nil, at: t0.addingTimeInterval(120))
        h.record(url: URL(string: "https://gitlab.com/x")!, title: "GitLab", spaceID: nil, at: t0.addingTimeInterval(180))
        h.record(url: URL(string: "https://github.com/zen-browser/desktop")!, title: "Zen again", spaceID: nil, at: t0.addingTimeInterval(3600))
        h.record(url: URL(string: "about:blank")!, title: "blank", spaceID: nil)
        check(h.count == 4, "visits to the same page within ten minutes merge, other pages and later visits add rows", "\(h.count)")
        h.updateTitle(url: URL(string: "https://gitlab.com/x")!, title: "GitLab home")
        let all = h.visits()
        check(all.first?.title == "Zen again" && all.contains { $0.title == "GitLab home" }, "newest visits come first and late titles land")
        check(h.visits(matching: "zen desktop").count == 2 && h.visits(matching: "nook").count == 1, "history search needs every word")
        check(h.hosts(prefix: "git").first?.host == "github.com" && h.hosts(prefix: "git").first?.visits == 3, "hosts for autocomplete rank by visits and drop www")
        if let g = all.first(where: { $0.host == "gitlab.com" }) { h.delete(g.id) }
        h.clear(since: t0.addingTimeInterval(3000))
        check(h.count == 2, "deleting a visit and clearing the last hour work", "\(h.count)")
    }

    // MARK: Split view in the model

    @MainActor static func splitModel() {
        let m = freshModel()
        let a = page(m, "about:blank#a", "A", select: true)
        let b = page(m, "about:blank#b", "B")
        let c = page(m, "about:blank#c", "C")
        let d = page(m, "about:blank#d", "D")
        let e = page(m, "about:blank#e", "E")
        m.openInSplit(b)
        m.openInSplit(c)
        m.openInSplit(d)
        let ok5 = m.openInSplit(e)
        let sp = m.currentSplit
        check(sp?.count == 4 && !ok5 && m.toastState?.message.contains("four") == true && m.splits.count == 1,
              "a split takes up to four panes and says so on the fifth", "\(sp?.count ?? 0)")
        check(sp?.focused == d.id && m.currentTab?.id == d.id, "the newest pane has focus")
        m.setLayout(.grid)
        check(m.currentSplit?.root.layoutKind == .grid, "the layout switches to a grid")
        m.focusPane(index: 0)
        check(m.currentTab?.id == m.currentSplit?.items[0], "Ctrl-Shift-1 focuses the first pane")
        m.focusNextPane(-1)
        check(m.currentTab?.id == m.currentSplit?.items.last, "the previous pane wraps around")
        m.saveNow()
        let re = BrowserModel()
        check(re.currentSplit?.root == m.currentSplit?.root && re.currentSplit?.focused == m.currentSplit?.focused,
              "four panes, their layout and focus survive a relaunch")
        // Unsplit a pane and stay in the split, like Shift-click in Zen.
        m.popOut(b.id, stay: true)
        check(m.currentSplit?.count == 3 && !m.currentSplit!.contains(b.id) && m.looseTabs.contains { $0.id == b.id },
              "Unsplit with Shift takes one pane out and keeps you in the split")
        m.focusPane(item: c.id)
        m.closeCurrent()
        check(m.currentSplit?.count == 2 && m.tab(c.id) == nil, "closing a pane in a three-pane split leaves two")
        m.closeCurrent()
        check(m.currentSplit == nil && m.splits.isEmpty && m.currentTab != nil, "closing one of the last two leaves a normal tab")
        m.prepareForQuit()
        dropsAndPins()
    }

    @MainActor static func dropsAndPins() {
        let m = freshModel()
        // A drop on the bottom edge of a pane stacks it there.
        let a = page(m, "about:blank#p", "P", select: true)
        let b = page(m, "about:blank#q", "Q")
        let e = page(m, "about:blank#r", "R")
        m.drop(tabID: b.id, side: .right, onPane: a.id)
        m.drop(tabID: e.id, side: .bottom, onPane: b.id)
        if let s = m.currentSplit, case .branch(.row, let kids, _) = s.root, kids.count == 2, case .branch(.column, let col, _) = kids[1] {
            check(col.map { $0.leaves }.flatMap { $0 } == [b.id, e.id], "a drop near a pane's bottom edge stacks it under that pane")
        } else {
            check(false, "a drop near a pane's bottom edge stacks it under that pane", "\(String(describing: m.currentSplit?.root))")
        }
        // Moving a pane inside its own split.
        m.drop(tabID: a.id, side: .bottom, onPane: e.id)
        check(m.currentSplit?.items == [b.id, e.id, a.id] && m.splits.count == 1, "dragging a pane's handle to another pane moves it")
        if let s = m.currentSplit { m.separate(s) }
        // Drag one tab onto another in the sidebar and hold.
        let ex = page(m, "about:blank#x", "X")
        m.dropForSplit(ex.id, onto: a.id)
        check(m.currentSplit?.items == [a.id, ex.id] && m.currentTab?.id == ex.id, "holding a tab over another makes a split with the target first")
        if let s = m.currentSplit { m.separate(s) }
        // Multi-select into a split.
        let sp4 = m.split(items: [a.id, b.id, e.id, ex.id])
        check(sp4?.root.layoutKind == .grid && sp4?.count == 4, "four picked tabs open as a grid")
        if let s = m.currentSplit { m.separate(s) }
        check(m.splits.isEmpty && [a, b, e, ex].allSatisfy { t in m.looseTabs.contains { $0.id == t.id } }, "separate puts every pane back in Tabs")
        // A split made from a pinned tab stays pinned.
        m.togglePin(a)
        m.select(a)
        m.openInSplit(b)
        check(m.currentSplit?.isPinned == true && m.refs(in: .pinned).contains(.split(m.currentSplit!.id)), "a split made from a pinned tab sits in Pinned")
        m.prepareForQuit()
    }

    // MARK: Pins and Essentials

    @MainActor static func pinsAndEssentials() {
        let m = freshModel()
        let mail = page(m, "https://mail.example.com/inbox", "Mail", select: true)
        m.togglePin(mail)
        check(mail.isPinned && mail.pinnedURL?.absoluteString == "https://mail.example.com/inbox", "pinning remembers the address")
        mail.url = URL(string: "https://mail.example.com/inbox#thread-4")
        check(!mail.isAwayFromPin, "a fragment change isn't wandering off")
        mail.url = URL(string: "https://mail.example.com/settings")
        check(mail.isAwayFromPin, "another page in the pinned tab shows it has wandered")
        m.separateFromPin(mail)
        check(m.currentTab?.url?.absoluteString == "https://mail.example.com/settings" && mail.pinnedURL == mail.url && !mail.isAwayFromPin,
              "Cmd-click keeps the page in a new tab and puts the pin back")
        mail.url = URL(string: "https://mail.example.com/labels")
        m.replacePinnedURL(mail)
        check(mail.pinnedURL?.absoluteString == "https://mail.example.com/labels" && !mail.isAwayFromPin, "replace pinned address takes the current page")
        mail.url = URL(string: "https://mail.example.com/elsewhere")
        m.select(mail)
        m.closeCurrent()
        check(mail.isPinned && !mail.isLoaded && mail.url == mail.pinnedURL && m.tab(mail.id) != nil && m.currentTab?.id != mail.id,
              "Cmd-W on a pinned tab goes back to its address, unloads and moves on, like Zen")
        // Essentials.
        let cal = page(m, "https://calendar.example.com/", "Calendar")
        m.addToEssentials(cal)
        let home = m.currentSpaceID
        let work = m.createSpace(name: "Work")
        m.switchSpace(to: work.id)
        check(m.essentials.map { $0.id } == [cal.id] && !m.spaceTabs.contains { $0.id == cal.id } && cal.pinnedURL != nil,
              "Essentials show in every space and keep their address")
        m.select(cal)
        check(m.currentSpaceID == work.id && m.currentTab?.id == cal.id, "picking an Essential doesn't change space")
        m.switchSpace(to: home)
        m.switchSpace(to: work.id)
        check(m.currentTab?.id == cal.id, "a space comes back to the Essential it showed")
        for i in 0..<12 { m.addToEssentials(page(m, "https://e\(i).example.com/", "E\(i)")) }
        check(m.essentials.count == BrowserModel.essentialsLimit && m.toastState?.message.contains("12") == true, "Essentials stop at twelve")
        m.removeFromEssentials(cal)
        check(!cal.isEssential && m.looseTabs.first?.id == cal.id && cal.pinnedURL == nil, "removing an Essential puts it at the top of Tabs")
        m.prepareForQuit()
    }

    // MARK: Ordering

    @MainActor static func ordering() {
        let m = freshModel()
        let a = page(m, "https://a.example/", "A")
        let b = page(m, "https://b.example/", "B")
        let c = m.newTab(url: URL(string: "https://c.example/")!, select: false)
        check(m.looseTabs.map { $0.id } == [c.id, b.id, a.id], "new tabs go at the top of Tabs")
        m.place([.tab(a.id)], next: .tab(c.id), after: false)
        check(m.looseTabs.map { $0.id } == [a.id, c.id, b.id], "dragging a row above another puts it there")
        m.place([.tab(a.id)], next: .tab(b.id), after: true)
        check(m.looseTabs.map { $0.id } == [c.id, b.id, a.id], "and below another")
        m.place([.tab(b.id)], in: .pinned, at: 0)
        check(b.isPinned && b.pinnedURL?.absoluteString == "https://b.example/" && m.pinnedTabs.map { $0.id } == [b.id], "dragging into Pinned pins the tab")
        let f = m.createFolder(named: "Reading")
        let g = m.createFolder(named: "Later")
        m.place([.tab(c.id), .tab(a.id)], in: .folder(f.id), at: 0)
        check(m.tabs(in: f).map { $0.id } == [c.id, a.id] && m.looseTabs.isEmpty, "dragging into a folder files the tabs in order")
        m.place([.tab(b.id)], next: .tab(a.id), after: true)
        check(!b.isPinned && b.folderID == f.id && b.pinnedURL == nil && m.tabs(in: f).map { $0.id } == [c.id, a.id, b.id], "a pinned tab dragged into a folder stops being pinned")
        check(m.spaceFolders.map { $0.id } == [g.id, f.id], "new folders go on top")
        m.placeFolder(g.id, next: f.id, after: true)
        check(m.spaceFolders.map { $0.id } == [f.id, g.id], "folders reorder")
        m.rename(a, to: "  My name  ")
        check(a.displayTitle == "My name", "a renamed tab shows its own name")
        m.saveNow()
        let re = BrowserModel()
        check(re.tabs(in: re.folders.first { $0.id == f.id }!).map { $0.id } == [c.id, a.id, b.id] && re.spaceFolders.map { $0.id } == [f.id, g.id]
              && re.tab(a.id)?.customTitle == "My name", "order and names survive a relaunch")
        m.rename(a, to: "")
        check(a.customTitle == nil && a.displayTitle == "A", "an empty name goes back to the page title")
        // A version 2 file has no order: Today was newest first.
        let s = m.currentSpaceID
        let older = """
        {"version":2,"spaces":[{"id":"\(s.uuidString)","name":"Home","icon":"house","color":"#7A8CA8"}],"currentSpace":"\(s.uuidString)","folders":[],
         "tabs":[{"id":"\(a.id.uuidString)","kind":"web","url":"https://a.example/","title":"A","isPinned":false,"createdAt":"2026-11-01T10:00:00Z","spaceID":"\(s.uuidString)"},
                 {"id":"\(b.id.uuidString)","kind":"web","url":"https://b.example/","title":"B","isPinned":false,"createdAt":"2026-11-02T10:00:00Z","spaceID":"\(s.uuidString)"}]}
        """
        try? Data(older.utf8).write(to: Paths.stateFile)
        let v2 = BrowserModel()
        check(v2.looseTabs.map { $0.id } == [b.id, a.id], "an older state file keeps Tabs newest first")
        m.prepareForQuit()
        try? FileManager.default.removeItem(at: Paths.stateFile)
        // Multi-select.
        let n = freshModel()
        let x = page(n, "https://x.example/", "X")
        let y = page(n, "https://y.example/", "Y")
        let z = page(n, "https://z.example/", "Z", select: true)
        n.multiSelectClick(.tab(x.id), shift: false)
        check(n.multiSelection == [z.id, x.id], "Cmd-click picks the clicked tab along with the current one")
        n.multiSelectClick(.tab(y.id), shift: true)
        check(n.multiSelection == [z.id, x.id, y.id] && n.multiSelectedTabs.map { $0.id } == [z.id, y.id, x.id], "Shift-click picks the range, in sidebar order")
        n.multiSelectClick(.tab(y.id), shift: false)
        check(!n.multiSelection.contains(y.id), "Cmd-click again takes one out")
        n.prepareForQuit()
    }

    // MARK: Recently closed, archive and Clear Today

    @MainActor static func closedAndArchive() {
        let m = freshModel()
        let work = m.createSpace(name: "Work")
        m.switchSpace(to: work.id)
        let a = page(m, "https://a.example/", "A", select: true)
        m.close(a)
        check(m.tab(a.id) == nil && m.closed.recent.first?.id == a.id && m.canReopenClosed, "a closed tab goes to Recently Closed")
        let home = m.spaces[0].id
        m.switchSpace(to: home)
        m.reopenClosed()
        check(m.tab(a.id) != nil && m.tab(a.id)?.spaceID == work.id && m.currentSpaceID == work.id && m.currentTab?.id == a.id,
              "Cmd-Shift-T brings it back with the same identity, in the space it came from")
        // Auto-archive.
        BrowserPrefs.shared.update { $0.archiveAfterHours = 12 }
        let old = Date().addingTimeInterval(-13 * 3600)
        let idle = page(m, "https://idle.example/", "Idle")
        let pinned = page(m, "https://pinned.example/", "Pinned")
        m.togglePin(pinned)
        let filed = page(m, "https://filed.example/", "Filed")
        m.move(filed, to: m.createFolder(named: "Keep").id)
        let playing = page(m, "https://music.example/", "Music")
        playing.mediaPlaying = true
        let fresh = page(m, "https://fresh.example/", "Fresh")
        let s1 = page(m, "https://s1.example/", "S1")
        let s2 = page(m, "https://s2.example/", "S2")
        m.select(s1)
        m.openInSplit(s2)
        let splitID = m.currentSplit!.id
        m.select(a)
        for t in [idle, pinned, filed, playing, s1, s2] { t.lastActiveAt = old }
        a.lastActiveAt = old
        fresh.lastActiveAt = Date()
        let n = m.archiveIdleTabs()
        check(m.tab(idle.id) == nil && m.split(splitID) == nil && m.tab(s1.id) == nil && n == 3,
              "tabs idle for longer than the setting move to the archive, a split as a whole", "\(n)")
        check(m.tab(pinned.id) != nil && m.tab(filed.id) != nil && m.tab(playing.id) != nil && m.tab(fresh.id) != nil && m.tab(a.id) != nil,
              "pinned, filed, playing, recent and on-screen tabs stay")
        let archived = m.closed.archive
        check(archived.contains { $0.id == idle.id && $0.reason == .archived }, "the archive lists them")
        if let g = archived.first(where: { $0.id == s1.id })?.group {
            m.restoreClosed(Set(m.closed.members(of: g).map { $0.id }))
            check(m.currentSplit?.items == [s1.id, s2.id], "restoring an archived split brings back the split")
        } else {
            check(false, "restoring an archived split brings back the split")
        }
        BrowserPrefs.shared.update { $0.archiveAfterHours = 0 }
        fresh.lastActiveAt = .distantPast
        check(m.archiveIdleTabs() == 0, "Never turns auto-archive off")
        BrowserPrefs.shared.update { $0.archiveAfterHours = 12 }
        // Clear Today with Undo.
        let today = m.refs(in: .today)
        let cleared = m.clearToday()
        check(cleared > 0 && m.refs(in: .today).isEmpty && m.toastState?.actionTitle == "Undo" && m.tab(pinned.id) != nil,
              "Clear Today archives every Tabs row and offers Undo", "\(cleared)")
        m.runToastAction()
        check(m.refs(in: .today).count == today.count, "Undo brings them all back", "\(m.refs(in: .today).count) of \(today.count)")
        m.prepareForQuit()
        let re = BrowserModel()
        check(re.closed.items.count == m.closed.items.count, "Recently Closed and the archive survive a relaunch")
        m.closed.clearArchive()
        check(m.closed.archive.isEmpty, "Clear archive empties it")
    }

    // MARK: Command bar

    @MainActor static func commandBar() {
        let m = freshModel()
        let bar = m.bar
        // Actions only show when they apply.
        bar.open(.newTab)
        bar.setActionsOnly(true)
        let ids = Set(bar.results.compactMap { if case .action(let id) = $0.kind { return id }; return nil })
        check(bar.results.allSatisfy { $0.group == .commands } && ids.contains("space.new") && !ids.contains("split.unsplit") && !ids.contains("tab.reopen"),
              "Tab on an empty bar lists the actions that apply, and only those")
        check(bar.results.first { if case .action("space.new") = $0.kind { return true }; return false }?.shortcut == nil
              && bar.results.first { if case .action("today.clear") = $0.kind { return true }; return false } == nil,
              "Clear Today waits until there's something to clear")
        bar.query = "new sp"
        check(bar.results.first.map { if case .action("space.new") = $0.kind { return true }; return false } == true, "typing in actions mode narrows them")
        bar.close()
        bar.open(.newTab, text: "/ split")
        check(bar.actionsOnly && bar.query == "split", "a slash and a space switch to actions, like Arc")
        bar.close()
        // Contextual: split actions appear in a split.
        let a = page(m, "https://alpha.example/", "Alpha", select: true)
        let b = page(m, "https://beta.example/", "Beta")
        m.openInSplit(b)
        bar.open(.newTab)
        bar.setActionsOnly(true)
        let inSplit = Set(bar.results.compactMap { if case .action(let id) = $0.kind { return id }; return nil })
        check(inSplit.contains("split.unsplit") && inSplit.contains("split.stacked") && inSplit.contains("tab.copyURL"), "split and tab actions appear when they apply")
        if let s = m.currentSplit { m.separate(s) }
        bar.close()
        // Mixed results.
        bar.open(.newTab, text: "new space")
        check(bar.results.contains { if case .action("space.new") = $0.kind { return $0.group == .commands }; return false }, "a typed command shows among the results")
        bar.query = "example.org"
        check(!bar.results.contains { $0.group == .commands }, "addresses don't bring up commands")
        bar.close()
        // Shortcuts on rows.
        bar.open(.newTab, text: "copy link")
        check(bar.results.contains { $0.shortcut == "⇧⌘C" }, "actions show their shortcut")
        bar.close()
        // Other spaces and folders.
        let work = m.createSpace(name: "Work")
        m.switchSpace(to: work.id)
        let f = m.createFolder(named: "Quarterly planning")
        let filed = page(m, "https://docs.example/plan", "Planning doc")
        m.move(filed, to: f.id)
        m.switchSpace(to: m.spaces[0].id)
        bar.open(.newTab, text: "planning")
        let row = bar.results.first { $0.kind == .tab(filed.id) }
        check(row?.subtitle.contains("in Work") == true, "tabs in other spaces show with their space", row?.subtitle ?? "nil")
        check(bar.results.contains { $0.kind == .folder(f.id) }, "folders are results")
        if let row { bar.pick(row) }
        check(m.currentSpaceID == work.id && m.currentTab?.id == filed.id, "switching to a tab in another space goes there")
        bar.open(.newTab, text: "quarterly")
        if let fr = bar.results.first(where: { $0.kind == .folder(f.id) }) { bar.pick(fr) }
        check(m.currentTab?.id == filed.id && m.folders.first { $0.id == f.id }?.isExpanded == true, "opening a folder shows its first item")
        // Cmd-T twice closes, Cmd-L twice closes.
        m.newTabCommand()
        m.newTabCommand()
        check(!bar.isOpen, "a second Cmd-T closes the bar")
        // Typed text comes back.
        bar.open(.newTab, text: "half typed thought")
        bar.close()
        bar.open(.newTab)
        check(bar.query == "half typed thought", "text typed before Esc comes back on the next Cmd-T")
        bar.close()
        // Autocomplete.
        let now = Date()
        for i in 0..<3 { HistoryStore.shared.record(url: URL(string: "https://github.com/repo\(i)")!, title: "Repo \(i)", spaceID: nil, at: now.addingTimeInterval(Double(i) * 700)) }
        HistoryStore.shared.record(url: URL(string: "https://gitlab.com/x")!, title: "GitLab", spaceID: nil)
        bar.open(.newTab)
        bar.lastEditWasInsertion = true
        bar.query = "gi"
        check(bar.completion == "github.com" && bar.completionSuffix == "thub.com", "typing the start of a domain fills in the most visited one",
              "\(bar.completion ?? "nil")")
        check(bar.results.first.map { if case .openURL(let u) = $0.kind { return u.host == "github.com" }; return false } == true, "the filled-in domain is the top hit")
        bar.dismissCompletion()
        check(bar.completion == nil && bar.query == "gi", "Backspace drops the fill and keeps what was typed")
        bar.lastEditWasInsertion = true
        bar.query = "git"
        bar.acceptCompletion()
        check(bar.query == "github.com" && bar.completion == nil, "Tab or the right arrow accepts the fill")
        bar.close()
        let gh = page(m, "https://github.com/me", "My GitHub")
        m.togglePin(gh)
        bar.open(.newTab)
        bar.lastEditWasInsertion = true
        bar.query = "githu"
        check(bar.results.first?.kind == .tab(gh.id), "a domain you have pinned switches to that tab instead, like Arc")
        bar.close()
        // Modifiers.
        check(CommandBar.route([.option]) == .split && CommandBar.route([.shift]) == .peek && CommandBar.route([.command]) == .backgroundTab && CommandBar.route([]) == nil,
              "Option-Enter splits, Shift-Enter peeks, Cmd-Enter opens behind")
        m.select(a)
        let before = m.tabs.count
        bar.open(.newTab, text: "https://split.example/")
        bar.submit(flags: .option)
        check(m.currentSplit?.count == 2 && m.tabs.count == before + 1 && m.currentTab?.url?.host == "split.example", "Option-Enter opens the pick in split view")
        if let s = m.currentSplit { m.separate(s) }
        let sel = m.currentTab?.id
        bar.open(.newTab, text: "https://behind.example/")
        bar.submit(flags: .command)
        check(m.currentTab?.id == sel && m.tabs.contains { $0.url?.host == "behind.example" }, "Cmd-Enter opens a background tab")
        bar.open(.newTab, text: "https://peek.example/")
        bar.submit(flags: .shift)
        check(m.peek?.tab.url?.host == "peek.example" && !m.tabs.contains { $0.url?.host == "peek.example" }, "Shift-Enter opens Peek")
        m.closePeek()
        // Cmd-L then Enter on the same address stays in the tab.
        if let t = m.currentWebTab {
            let n = m.tabs.count
            m.focusAddress()
            bar.submit()
            check(m.tabs.count == n && m.currentTab?.id == t.id && !bar.isOpen, "Cmd-L then Enter on the same address reloads in place")
        }
        m.prepareForQuit()
    }

    @MainActor static func fuzzyAndLearner() {
        check(Fuzzy.score("New space", "new space") == Fuzzy.exact && Fuzzy.score("New space", "new") > Fuzzy.prefix
              && Fuzzy.score("New space", "nsp") > Fuzzy.actionsMinimum && Fuzzy.score("New space", "xyz") == 0,
              "action scoring puts exact matches first, then prefixes, then fuzzy matches")
        check(Fuzzy.score("Close tab", "close tab") > Fuzzy.score("Reopen closed tab", "close tab"), "the action that is exactly the query wins, like Zen's fix")
        let L = CommandLearner()
        BrowserPrefs.shared.update { $0.actionScores = [:] }
        for _ in 0..<7 { L.record("tab.duplicate", seen: ["tab.duplicate", "tab.rename"]) }
        check(L.score("tab.duplicate") == 5 && L.score("tab.rename") == -5, "picking an action counts up to 5, skipping one counts down to -5")
        L.record("tab.rename", seen: [])
        L.record(nil, seen: ["tab.duplicate"])
        check(L.score("tab.rename") == -4 && L.score("tab.duplicate") == 4, "and the counts move back")
        let m = freshModel()
        _ = page(m, "https://x.example/", "Some page", select: true)
        m.bar.open(.newTab, text: "dupl")
        check(m.bar.results.first.map { if case .action("tab.duplicate") = $0.kind { return $0.group == .top }; return false } == true,
              "an action you use a lot becomes the top hit")
        m.bar.close()
        BrowserPrefs.shared.update { $0.actionScores = [:] }
        m.prepareForQuit()
    }

    // MARK: Profiles and app pages

    @MainActor static func profilesAndPages() {
        check(BrowserModel.profileStoreID("Work") == BrowserModel.profileStoreID("work") && BrowserModel.profileStoreID("Work") != BrowserModel.profileStoreID("Home"),
              "each profile gets a stable store of its own")
        let m = freshModel()
        let work = m.createSpace(name: "Work")
        m.updateSpace(work.id) { $0.profile = "Work" }
        let t = page(m, "about:blank", "Home page")
        let w = Tab(url: URL(string: "about:blank")!, title: "Work page")
        w.model = m
        w.spaceID = work.id
        m.tabs.append(w)
        check(m.configuration(for: t) === m.webConfig && m.configuration(for: w) !== m.webConfig
              && m.configuration(for: w) === m.configuration(forProfile: "Work")
              && m.configuration(for: w).websiteDataStore !== m.webConfig.websiteDataStore,
              "a space on another profile uses its own WebKit store")
        _ = w.ensureWebView()
        m.updateSpace(work.id) { $0.profile = nil }
        check(!w.isLoaded, "changing a space's profile reloads its pages in the new store")
        check(m.profiles.isEmpty, "profiles are listed from the spaces that use them")
        // App pages.
        let h = m.openAppPage("history")
        check(h.isApp && h.url?.absoluteString == "browser://history" && h.displayTitle == "History" && m.currentTab?.id == h.id, "History opens as an item")
        check(m.openAppPage("history").id == h.id, "opening it again reuses the item")
        AppPages.register(AppPage(host: "test-page", title: "Test page", icon: "star") { _ in AnyView(EmptyView()) })
        let tp = m.openAppPage("test-page")
        check(tp.displayTitle == "Test page" && AppPages.page(for: tp.url)?.icon == "star" && BarActions.all(m).contains { $0.id == "page.test-page" },
              "a registered page opens as an item and gets a command")
        m.togglePin(tp)
        m.saveNow()
        let re = BrowserModel()
        check(re.tab(tp.id)?.isApp == true && re.tab(tp.id)?.isPinned == true, "app page items can be pinned and come back after a relaunch")
        m.prepareForQuit()
    }

    // MARK: Ctrl-Tab and Cmd-1 to 9

    @MainActor static func switcherAndRows() {
        let m = freshModel()
        let a = page(m, "about:blank#1", "One", select: true)
        let b = page(m, "about:blank#2", "Two", select: true)
        let c = page(m, "about:blank#3", "Three", select: true)
        check(m.recentSelections == [.tab(c.id), .tab(b.id), .tab(a.id)], "Ctrl-Tab lists recent tabs, newest first")
        m.beginSwitcher()
        check(m.switcher?.index == 1, "the first Ctrl-Tab highlights the previous tab")
        m.advanceSwitcher(1)
        m.commitSwitcher()
        check(m.currentTab?.id == a.id && m.switcher == nil, "releasing Ctrl goes to the highlighted tab")
        let e = page(m, "https://essential.example/", "Ess")
        m.addToEssentials(e)
        m.selectRow(number: 1)
        check(m.currentTab?.id == e.id, "Cmd-1 counts Essentials first")
        m.selectRow(number: 9)
        check(m.currentTab?.id == m.visibleRowOrder.last?.id, "Cmd-9 picks the last row")
        m.selectAdjacentRow(1)
        check(m.currentTab?.id == e.id, "Cmd-Opt-Down wraps to the top")
        m.prepareForQuit()
    }

    // MARK: Peek and Little Arc

    @MainActor static func peekAndLittleArc() {
        let m = freshModel()
        let src = page(m, "about:blank#src", "Source", select: true)
        m.openPeek(URL(string: "about:blank#peek")!, from: src)
        let wv = m.peek?.tab.webView
        check(m.peek?.parentID == src.id && wv != nil && !m.tabs.contains { $0 === m.peek?.tab }, "Peek opens a page over the current one, outside the sidebar")
        m.expandPeek()
        check(m.peek == nil && m.currentTab?.webView === wv && wv != nil && m.looseTabs.first?.webView === wv, "Cmd-O makes it a tab with the same web view, so nothing reloads")
        m.select(src)
        m.openPeek(URL(string: "about:blank#second")!, from: src)
        m.splitPeek()
        check(m.currentSplit?.items.count == 2 && m.currentSplit?.items.first == src.id, "Split puts the Peek next to the page it came from")
        if let s = m.currentSplit { m.separate(s) }
        m.openPeek(URL(string: "about:blank#third")!, from: src)
        let pid = m.peek!.tab.id
        m.closeCurrent()
        check(m.peek == nil && m.closed.recent.first?.id == pid && m.tab(src.id) != nil, "Cmd-W closes Peek first and Cmd-Shift-T can bring it back")
        m.openPeek(URL(string: "about:blank#fourth")!, from: src)
        let other = page(m, "about:blank#other", "Other")
        m.select(other)
        check(m.peek == nil, "switching tabs closes Peek")
        // Little Arc.
        let t = LittleArc.shared.open(URL(string: "about:blank#little")!, model: m, show: false)
        let lwv = t.webView
        check(!m.tabs.contains { $0 === t } && LittleArc.shared.tabs.contains { $0 === t } && lwv != nil, "a link from another app opens in a small window")
        LittleArc.shared.moveToMain(t, model: m)
        check(m.currentTab === t && t.webView === lwv && !LittleArc.shared.tabs.contains { $0 === t }, "Cmd-O moves it into the main window without reloading")
        m.prepareForQuit()
    }

    // MARK: Favicons

    @MainActor static func png(_ px: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    @MainActor static func favicons() {
        let page = URL(string: "https://www.example.com/a/b")!
        func link(_ href: String, _ rel: String, _ sizes: String = "", _ type: String = "") -> Favicons.Candidate? {
            Favicons.candidate(["href": href, "rel": rel, "sizes": sizes, "type": type])
        }
        let ranked = Favicons.rank([
            link("https://www.example.com/logo.svg", "icon", "any", "image/svg+xml"),
            link("https://www.example.com/16.png", "icon", "16x16"),
            link("https://www.example.com/180.png", "apple-touch-icon", "180x180"),
            link("https://www.example.com/32.png", "icon", "32x32"),
            link("https://www.example.com/96.png", "icon", "96x96"),
            link("https://www.example.com/mask.svg", "mask-icon"),
        ], page: page).map { $0.url.lastPathComponent }
        check(ranked.first == "32.png" && ranked.firstIndex(of: "96.png")! < ranked.firstIndex(of: "16.png")!
              && ranked.firstIndex(of: "180.png")! < ranked.firstIndex(of: "logo.svg")! && ranked.last == "favicon.ico" && ranked.dropLast().last == "mask.svg",
              "icons rank by a crisp 32 px first, touch icons before SVG, and /favicon.ico last", ranked.joined(separator: " "))
        check(Favicons.candidate(["href": "https://x.example/i.png", "rel": "icon", "sizes": "16x16 48x48"])?.px == 48, "an icon listing several sizes counts its largest")
        let small = Favicons.normalized(png(16)).flatMap { NSBitmapImageRep(data: $0) }
        let big = Favicons.normalized(png(400)).flatMap { NSBitmapImageRep(data: $0) }
        check(small?.pixelsWide == 32 && big?.pixelsWide == 128, "icons are stored at their own size, from 32 to 128 px", "\(small?.pixelsWide ?? 0), \(big?.pixelsWide ?? 0)")
        check(Favicons.monogram(URL(string: "https://docs.google.com/document/d/1")) == "G" && Favicons.monogram(URL(string: "https://www.bbc.co.uk/news")) == "B"
              && Favicons.monogram(URL(string: "https://localhost:3000/")) == "L" && Favicons.monogram(nil) == "",
              "sites without an icon get a monogram from their name")
        // Icons on disk show at once after a relaunch.
        Paths.ensure(Favicons.dir)
        try? Favicons.normalized(png(64))?.write(to: Favicons.file("cached.example"))
        check(Favicons.shared.hasIcon(for: URL(string: "https://www.cached.example/page")), "a cached icon is there straight away, by host")
    }

    // MARK: Folders and the keyboard

    @MainActor static func foldersAndKeyboard() {
        let m = freshModel()
        let pin = page(m, "https://pin.example/", "Pin")
        m.togglePin(pin)
        let f = m.createFolder(named: "Reading")
        let inFolder = page(m, "https://read.example/1", "Read 1")
        let inFolder2 = page(m, "https://read.example/2", "Read 2")
        m.move(inFolder, to: f.id)
        m.move(inFolder2, to: f.id)
        let loose = page(m, "https://loose.example/", "Loose", select: true)
        check(m.sidebarStops == [.row(.tab(pin.id)), .folder(f.id), .row(.tab(inFolder.id)), .row(.tab(inFolder2.id)), .row(.tab(loose.id))],
              "the keyboard walks the sidebar top to bottom, folders included")
        m.setFolder(f.id, open: false)
        check(!m.isFolderOpen(f.id) && m.sidebarStops == [.row(.tab(pin.id)), .folder(f.id), .row(.tab(loose.id))], "a closed folder hides its items")
        m.saveNow()
        check(BrowserModel().folders.first { $0.id == f.id }?.isExpanded == false, "each folder keeps its open state after a relaunch")
        m.select(inFolder)
        check(m.shownInClosedFolder(f) == [.tab(inFolder.id)] && m.sidebarStops.contains(.row(.tab(inFolder.id))) && !m.sidebarStops.contains(.row(.tab(inFolder2.id))),
              "a closed folder still shows the tab on screen")
        m.select(loose)
        m.toggleSidebarKeyboard()
        check(m.sidebarCursor == .row(.tab(loose.id)), "Cmd-. starts the keyboard on the row on screen")
        m.moveSidebarCursor(-1)
        check(m.sidebarCursor == .folder(f.id), "Up moves to the folder above")
        m.sidebarCursorRight()
        check(m.isFolderOpen(f.id) && m.sidebarCursor == .folder(f.id), "Right opens the folder")
        m.sidebarCursorRight()
        check(m.sidebarCursor == .row(.tab(inFolder.id)), "Right again goes into it")
        m.sidebarCursorLeft()
        check(m.sidebarCursor == .folder(f.id), "Left from an item goes up to its folder")
        m.sidebarCursorLeft()
        check(!m.isFolderOpen(f.id), "Left on the folder closes it")
        m.activateSidebarCursor()
        check(m.isFolderOpen(f.id) && m.sidebarCursor == .folder(f.id), "Return toggles a folder")
        m.moveSidebarCursor(1)
        m.activateSidebarCursor()
        check(m.currentTab?.id == inFolder.id && m.sidebarCursor == nil, "Return on a tab opens it and gives the keys back")
        m.toggleSidebarKeyboard()
        m.toggleSidebarKeyboard()
        check(m.sidebarCursor == nil, "Cmd-. again leaves the sidebar")
        m.prepareForQuit()
    }

    // MARK: Downloads and session files

    @MainActor static func downloadsAndSessions(dir: URL) {
        let d = dir.appendingPathComponent("dl", isDirectory: true)
        Paths.ensure(d)
        try? Data().write(to: d.appendingPathComponent("report.pdf"))
        try? Data().write(to: d.appendingPathComponent("report 2.pdf"))
        check(Downloads.uniqueDestination(in: d, name: "report.pdf").lastPathComponent == "report 3.pdf"
              && Downloads.uniqueDestination(in: d, name: "a/b:c").lastPathComponent == "a-b-c", "downloads never overwrite a file and clean odd names")
        let id = UUID(), other = UUID()
        SessionFiles.write(Data("state".utf8), for: id)
        SessionFiles.copy(id, to: other)
        check(SessionFiles.read(other) == Data("state".utf8), "session files copy for duplicates and restores")
        SessionFiles.prune(keeping: [id])
        check(SessionFiles.read(id) != nil && SessionFiles.read(other) == nil, "session files nothing points at are pruned")
        // Duplicate copies the session and sits right below.
        let m = freshModel()
        let a = page(m, "about:blank#dup-a", "A", select: true)
        let b = page(m, "about:blank#dup-b", "B")
        let dup = m.duplicate(a)
        let order = m.looseTabs.map { $0.id }
        let ia = order.firstIndex(of: a.id), id2 = dup.flatMap { order.firstIndex(of: $0.id) }
        check(dup.map { SessionFiles.read($0.id) == SessionFiles.read(a.id) } == true && m.currentTab?.id == dup?.id
              && ia != nil && id2 == ia! + 1 && order.contains(b.id),
              "Duplicate copies the back and forward history and opens right below the original")
        m.prepareForQuit()
    }
}

import SwiftUI
