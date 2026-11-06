import AppKit
import Foundation

/// A section of the sidebar that items can be dragged into.
enum SidebarSection: Equatable, Hashable {
    case essentials, pinned, today
    case folder(UUID)
}

/// One row in the sidebar.
enum SidebarRef: Equatable, Hashable {
    case tab(UUID), split(UUID)
    var id: UUID { switch self { case .tab(let i), .split(let i): return i } }
}

struct ToastState: Equatable {
    let id = UUID()
    let message: String
    var actionTitle: String?
    static func == (a: ToastState, b: ToastState) -> Bool { a.id == b.id }
}

struct SwitcherState: Equatable {
    var items: [Selection]
    var index: Int
}

/// Sidebar organisation: ordering, Essentials, pinned addresses, renaming, duplicating,
/// multi-select, recently closed, the archive, Clear Today, copying links and tab navigation.
extension BrowserModel {
    static let essentialsLimit = 12

    // MARK: Ordering

    /// Rows in a section, in order.
    func refs(in section: SidebarSection, space: UUID? = nil) -> [SidebarRef] {
        let sp = space ?? currentSpaceID
        let inSplit = splitTabIDs
        switch section {
        case .essentials:
            return essentials.map { .tab($0.id) }
        case .pinned:
            let t = tabs.filter { $0.spaceID == sp && $0.isPinned && !$0.isEssential && !inSplit.contains($0.id) }.map { ($0.order, SidebarRef.tab($0.id)) }
            let s = splits.filter { $0.spaceID == sp && $0.isPinned }.map { ($0.order, SidebarRef.split($0.id)) }
            return (t + s).sorted { $0.0 < $1.0 }.map { $0.1 }
        case .today:
            let t = tabs.filter { $0.spaceID == sp && !$0.isPinned && !$0.isEssential && $0.folderID == nil && !inSplit.contains($0.id) }
                .map { ($0.order, SidebarRef.tab($0.id)) }
            let s = splits.filter { $0.spaceID == sp && !$0.isPinned }.map { ($0.order, SidebarRef.split($0.id)) }
            return (t + s).sorted { $0.0 < $1.0 }.map { $0.1 }
        case .folder(let fid):
            return tabs.filter { $0.folderID == fid && !$0.isPinned && !$0.isEssential && !inSplit.contains($0.id) }.sorted { $0.order < $1.order }.map { .tab($0.id) }
        }
    }

    func order(of ref: SidebarRef) -> Double {
        switch ref {
        case .tab(let id): return tab(id)?.order ?? 0
        case .split(let id): return split(id)?.order ?? 0
        }
    }

    /// An order that sorts above everything in Today.
    func topOrder(today space: UUID) -> Double {
        (refs(in: .today, space: space).map { order(of: $0) }.min() ?? 1) - 1
    }

    func topOrder(pinned space: UUID) -> Double {
        (refs(in: .pinned, space: space).map { order(of: $0) }.min() ?? 1) - 1
    }

    func endOrder(_ section: SidebarSection) -> Double {
        (refs(in: section).map { order(of: $0) }.max() ?? -1) + 1
    }

    private func setOrder(_ ref: SidebarRef, _ value: Double) {
        switch ref {
        case .tab(let id): tab(id)?.order = value
        case .split(let id): if let i = splits.firstIndex(where: { $0.id == id }) { splits[i].order = value }
        }
    }

    func section(of ref: SidebarRef) -> SidebarSection? {
        switch ref {
        case .tab(let id):
            guard let t = tab(id) else { return nil }
            if t.isEssential { return .essentials }
            if t.isPinned { return .pinned }
            if let f = t.folderID { return .folder(f) }
            return .today
        case .split(let id):
            guard let s = split(id) else { return nil }
            return s.isPinned ? .pinned : .today
        }
    }

    /// Moves rows into a section at a position, changing what they are on the way: pinned,
    /// filed, an Essential, or a plain tab. Splits only go to Pinned or Today. Returns false if
    /// nothing moved.
    @discardableResult
    func place(_ moving: [SidebarRef], in section: SidebarSection, at index: Int) -> Bool {
        var moved: [SidebarRef] = []
        for ref in moving where !moved.contains(ref) {
            switch ref {
            case .tab(let id):
                guard let t = tab(id) else { continue }
                if section == .essentials && !t.isEssential && essentials.count >= Self.essentialsLimit {
                    toast("Essentials hold up to \(Self.essentialsLimit)")
                    continue
                }
                if let sp = split(containing: id) {
                    // Dragging a member out of a split.
                    removeFromSplit(id, sp)
                }
                convert(t, to: section)
                moved.append(ref)
            case .split(let id):
                guard let i = splits.firstIndex(where: { $0.id == id }) else { continue }
                switch section {
                case .pinned: splits[i].isPinned = true
                case .today: splits[i].isPinned = false
                default: continue
                }
                splits[i].spaceID = currentSpaceID
                moved.append(ref)
            }
        }
        guard !moved.isEmpty else { return false }
        var list = refs(in: section).filter { !moved.contains($0) }
        let at = max(0, min(index, list.count))
        list.insert(contentsOf: moved, at: at)
        for (n, r) in list.enumerated() { setOrder(r, Double(n)) }
        objectWillChange.send()
        scheduleSave()
        return true
    }

    /// Places rows just before or after another row, in that row's section.
    @discardableResult
    func place(_ moving: [SidebarRef], next target: SidebarRef, after: Bool) -> Bool {
        guard let sec = section(of: target), !moving.contains(target) else { return false }
        let list = refs(in: sec).filter { !moving.contains($0) }
        guard let i = list.firstIndex(of: target) else { return false }
        return place(moving, in: sec, at: after ? i + 1 : i)
    }

    /// Changes what a tab is to suit the section it lands in.
    private func convert(_ t: Tab, to section: SidebarSection) {
        switch section {
        case .essentials:
            t.isEssential = true; t.isPinned = false; t.folderID = nil
            if t.isWeb && t.pinnedURL == nil { t.pinnedURL = t.url }
        case .pinned:
            t.isEssential = false; t.isPinned = true; t.folderID = nil; t.spaceID = currentSpaceID
            if t.isWeb && t.pinnedURL == nil { t.pinnedURL = t.url }
        case .today:
            t.isEssential = false; t.isPinned = false; t.folderID = nil; t.pinnedURL = nil; t.spaceID = currentSpaceID
        case .folder(let f):
            t.isEssential = false; t.isPinned = false; t.folderID = f; t.pinnedURL = nil
            if let fs = folders.first(where: { $0.id == f })?.spaceID { t.spaceID = fs }
            if let i = folders.firstIndex(where: { $0.id == f }) { folders[i].isExpanded = true }
        }
    }

    /// Folders reorder among themselves.
    func placeFolder(_ id: UUID, next target: UUID, after: Bool) {
        guard id != target else { return }
        var list = spaceFolders.map { $0.id }.filter { $0 != id }
        guard let i = list.firstIndex(of: target) else { return }
        list.insert(id, at: after ? i + 1 : i)
        for (n, fid) in list.enumerated() { if let j = folders.firstIndex(where: { $0.id == fid }) { folders[j].order = Double(n) } }
        scheduleSave()
    }

    // MARK: Pinning and Essentials

    func togglePin(_ tab: Tab) {
        if tab.isPinned {
            tab.isPinned = false
            tab.pinnedURL = nil
            tab.order = topOrder(today: tab.spaceID ?? currentSpaceID)
        } else {
            tab.isEssential = false
            tab.isPinned = true
            tab.folderID = nil
            if tab.isWeb { tab.pinnedURL = tab.url }
            tab.order = endOrder(.pinned)
        }
        if let sp = split(containing: tab.id), let i = splits.firstIndex(where: { $0.id == sp.id }), sp.items.first == tab.id {
            splits[i].isPinned = tab.isPinned
        }
        objectWillChange.send()
        scheduleSave()
    }

    func move(_ tab: Tab, to folderID: UUID?) {
        if let folderID {
            place([.tab(tab.id)], in: .folder(folderID), at: Int.max)
        } else {
            place([.tab(tab.id)], in: .today, at: 0)
        }
    }

    func moveTabs(ids: [String], to folderID: UUID?, pin: Bool = false) -> Bool {
        let refs = ids.compactMap { UUID(uuidString: $0) }.filter { tab($0) != nil }.map { SidebarRef.tab($0) }
        guard !refs.isEmpty else { return false }
        if pin { return place(refs, in: .pinned, at: Int.max) }
        if let folderID { return place(refs, in: .folder(folderID), at: Int.max) }
        return place(refs, in: .today, at: 0)
    }

    func addToEssentials(_ tab: Tab) {
        guard !tab.isEssential else { return }
        place([.tab(tab.id)], in: .essentials, at: Int.max)
    }

    func removeFromEssentials(_ tab: Tab) {
        guard tab.isEssential else { return }
        place([.tab(tab.id)], in: .today, at: 0)
    }

    /// Back to the pinned address. Closing does this too, and also unloads the page.
    func resetPinned(_ tab: Tab, load: Bool = true) {
        guard tab.keepsPinnedURL, let p = tab.pinnedURL else { if !load { tab.unload() }; return }
        if load {
            tab.load(p)
        } else {
            tab.unload(keepSession: false)
            tab.url = p
            tab.title = ""
        }
        objectWillChange.send()
        scheduleSave()
    }

    /// Cmd-click on a wandered pin: the page you're on moves to a new tab and the pin goes back.
    func separateFromPin(_ tab: Tab) {
        guard tab.isAwayFromPin, let u = tab.url else { return }
        tab.saveSession()
        let t = Tab(url: u)
        t.model = self
        t.order = topOrder(today: currentSpaceID)
        SessionFiles.copy(tab.id, to: t.id)
        tabs.append(t)
        resetPinned(tab)
        select(t)
    }

    func replacePinnedURL(_ tab: Tab) {
        guard tab.keepsPinnedURL, let u = tab.url else { return }
        tab.pinnedURL = u
        toast("Pinned address is now this page")
        scheduleSave()
    }

    func promptEditPinnedURL(_ tab: Tab) {
        guard tab.keepsPinnedURL, let s = Prompt.text(title: "Pinned address", message: "This tab goes back here when you reset or close it.",
                                                      defaultValue: tab.pinnedURL?.absoluteString ?? ""),
              let u = AddressParser.url(for: s) else { return }
        tab.pinnedURL = u
        toast("Pinned address updated")
        scheduleSave()
    }

    // MARK: Renaming and duplicating

    func rename(_ tab: Tab, to name: String?) {
        let n = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        tab.customTitle = (n?.isEmpty ?? true) ? nil : n
        scheduleSave()
    }

    /// Notes rename their file. Pages and app pages get a name of their own.
    func promptRenameTab(_ tab: Tab) {
        if tab.isNote { promptRenameNote(tab); return }
        if let name = Prompt.text(title: "Rename tab", message: "Leave it empty to use the page title.", defaultValue: tab.customTitle ?? tab.displayTitle) {
            rename(tab, to: name)
        }
    }

    /// A copy right below, with the same back and forward history.
    @discardableResult
    func duplicate(_ tab: Tab) -> Tab? {
        guard tab.isWeb || tab.isApp, let u = tab.url ?? tab.webView?.url else { return nil }
        tab.saveSession()
        let t = Tab(kind: tab.kind, url: u, title: tab.title)
        t.model = self
        t.customTitle = tab.customTitle
        SessionFiles.copy(tab.id, to: t.id)
        let anchor = section(of: .tab(tab.id))
        if anchor == .today, split(containing: tab.id) == nil {
            t.order = tab.order + 0.0001
        } else {
            t.order = topOrder(today: currentSpaceID)
        }
        tabs.append(t)
        select(t)
        return t
    }

    // MARK: Multi-select

    /// Rows top to bottom as they show, for Shift-click ranges and Cmd-1 to 9.
    var visibleRowOrder: [SidebarRef] {
        var out = refs(in: .essentials) + refs(in: .pinned)
        for f in spaceFolders where f.isExpanded { out += refs(in: .folder(f.id)) }
        // The tab bar lists other tabs oldest first, so Cmd-1 to 9 count them as they're shown.
        return out + (BrowserPrefs.shared.value.tabLayout == .horizontal ? TabBarRules.barOrder(refs(in: .today)) : refs(in: .today))
    }

    /// Cmd-click adds or removes a row. Shift-click picks a range from the last one picked.
    func multiSelectClick(_ ref: SidebarRef, shift: Bool) {
        let ids: (SidebarRef) -> [UUID] = { r in
            switch r {
            case .tab(let id): return [id]
            case .split(let sid): return self.split(sid)?.items ?? []
            }
        }
        if multiSelection.isEmpty, let cur = currentTab, cur.id != ref.id {
            multiSelection.insert(cur.id)
            multiAnchor = cur.id
        }
        if shift, let anchor = multiAnchor {
            let rows = visibleRowOrder
            let a = rows.firstIndex { ids($0).contains(anchor) }
            let b = rows.firstIndex(of: ref)
            if let a, let b {
                for r in rows[min(a, b)...max(a, b)] { multiSelection.formUnion(ids(r)) }
                return
            }
        }
        let these = Set(ids(ref))
        if these.isSubset(of: multiSelection) { multiSelection.subtract(these) } else { multiSelection.formUnion(these) }
        multiAnchor = ref.id
    }

    /// Selected rows that are tabs, in sidebar order.
    var multiSelectedTabs: [Tab] {
        let order = visibleRowOrder.flatMap { r -> [UUID] in
            if case .split(let sid) = r { return split(sid)?.items ?? [] }
            return [r.id]
        }
        return order.filter { multiSelection.contains($0) }.compactMap { tab($0) }
    }

    func closeMultiSelected() {
        for t in multiSelectedTabs { close(t) }
        multiSelection = []
    }

    func copyMultiSelectedLinks() {
        let links = multiSelectedTabs.compactMap { $0.url.map { CleanURL.strip($0).absoluteString } }
        guard !links.isEmpty else { return }
        Self.copyText(links.joined(separator: "\n"))
        toast(links.count == 1 ? "Copied link" : "Copied \(links.count) links")
    }

    // MARK: Recently closed and the archive

    func recordClosed(_ list: [Tab], reason: ClosedItem.Reason, group: UUID? = nil, splitRoot: SplitNode? = nil) {
        let now = Date()
        var items: [ClosedItem] = []
        for t in list where !t.isBlank {
            if t.isLoaded { t.saveSession() }
            items.append(ClosedItem(id: t.id, kind: t.kind, url: t.url?.absoluteString, title: t.title, customTitle: t.customTitle,
                                    spaceID: t.spaceID, closedAt: now, reason: reason, group: group, splitRoot: splitRoot))
        }
        closed.add(items)
    }

    var canReopenClosed: Bool { !closed.recent.isEmpty }

    /// Cmd-Shift-T: the last closed tab, or the last closed split, with its history.
    func reopenClosed() {
        guard let last = closed.recent.first else { return }
        let ids = last.group.map { g in Set(closed.members(of: g).map { $0.id }) } ?? [last.id]
        restoreClosed(ids)
    }

    /// Brings items back to the space they came from, at the top of Today. Items that left as a
    /// split come back as that split.
    @discardableResult
    func restoreClosed(_ ids: Set<UUID>) -> [Tab] {
        let items = closed.take(ids)
        guard !items.isEmpty else { return [] }
        var restored: [UUID: Tab] = [:]
        let space = items.first?.spaceID.flatMap { id in spaces.contains { $0.id == id } ? id : nil } ?? currentSpaceID
        for (n, it) in items.sorted(by: { $0.closedAt < $1.closedAt }).enumerated() {
            let id = tabs.contains(where: { $0.id == it.id }) ? UUID() : it.id
            if id != it.id { SessionFiles.copy(it.id, to: id) }
            let t = Tab(id: id, kind: it.kind, url: it.url.flatMap(URL.init(string:)), title: it.title)
            t.model = self
            t.customTitle = it.customTitle
            t.spaceID = it.spaceID.flatMap { sid in spaces.contains { $0.id == sid } ? sid : nil } ?? space
            t.order = topOrder(today: t.spaceID ?? space) - Double(n) * 0.001
            t.lastActiveAt = Date()
            tabs.append(t)
            restored[it.id] = t
        }
        // Splits come back whole.
        var shownSplit: SplitRecord?
        for root in Set(items.compactMap { $0.group }).compactMap({ g in items.first { $0.group == g }?.splitRoot }) {
            var r = root
            for old in root.leaves {
                if let t = restored[old] { r = r.replacing(old, with: t.id) } else if let n = r.removing(old) { r = n }
            }
            guard r.leaves.count >= 2 else { continue }
            var sp = SplitRecord(root: r, focused: r.leaves[0], spaceID: restored[root.leaves[0]]?.spaceID ?? space)
            sp.order = topOrder(today: sp.spaceID ?? space)
            splits.append(sp)
            shownSplit = sp
        }
        if let sp = shownSplit { selectSplit(sp) } else if let first = items.last.flatMap({ restored[$0.id] }) { select(first) }
        scheduleSave()
        return Array(restored.values)
    }

    /// Idle Today tabs move to the archive, like Arc. Pinned tabs, Essentials, filed items, what's
    /// on screen and anything playing stay. A loose split goes only when every pane is idle.
    @discardableResult
    func archiveIdleTabs(now: Date = Date()) -> Int {
        let hours = BrowserPrefs.shared.value.archiveAfterHours
        guard hours > 0 else { return 0 }
        let cutoff = now.addingTimeInterval(-hours * 3600)
        let onScreen = Set(visibleTabs.map { $0.id }).union(peek.map { [$0.tab.id] } ?? [])
        func idle(_ t: Tab) -> Bool {
            !t.isPinned && !t.isEssential && t.folderID == nil && !onScreen.contains(t.id) && !t.mediaPlaying && t.lastActiveAt < cutoff && !t.isBlank
        }
        var count = 0
        for sp in splits where !sp.isPinned {
            let members = sp.items.compactMap { tab($0) }
            guard members.count == sp.items.count, members.allSatisfy(idle) else { continue }
            recordClosed(members, reason: .archived, group: UUID(), splitRoot: sp.root)
            splits.removeAll { $0.id == sp.id }
            for t in members { t.unload(); tabs.removeAll { $0.id == t.id } }
            count += members.count
        }
        let inSplit = splitTabIDs
        let loose = tabs.filter { idle($0) && !inSplit.contains($0.id) }
        if !loose.isEmpty {
            recordClosed(loose, reason: .archived)
            for t in loose { t.unload(); tabs.removeAll { $0.id == t.id } }
            count += loose.count
        }
        if count > 0 {
            selectionHistory.removeAll { s in
                if case .tab(let id) = s { return tab(id) == nil }
                if case .split(let id) = s { return split(id) == nil }
                return false
            }
            objectWillChange.send()
            scheduleSave()
        }
        return count
    }

    /// "Archive tab" from the bar or the menu.
    func archive(_ tab: Tab) {
        let wasSelected = isSelected(tab)
        if let sp = split(containing: tab.id) { removeFromSplit(tab.id, sp) }
        recordClosed([tab], reason: .archived)
        tab.unload()
        tabs.removeAll { $0.id == tab.id }
        if wasSelected { selectPrevious(excluding: .tab(tab.id)) }
        scheduleSave()
    }

    /// Cmd-Shift-K: every Today tab and split in this space goes to the archive, with Undo.
    @discardableResult
    func clearToday() -> Int {
        let rows = refs(in: .today)
        guard !rows.isEmpty else { return 0 }
        var ids: Set<UUID> = []
        let batch = UUID()
        for r in rows {
            switch r {
            case .tab(let id):
                guard let t = tab(id) else { continue }
                if t.isBlank { tabs.removeAll { $0.id == id }; continue }
                recordClosed([t], reason: .cleared, group: batch)
                t.unload()
                tabs.removeAll { $0.id == id }
                ids.insert(id)
            case .split(let sid):
                guard let sp = split(sid) else { continue }
                let members = sp.items.compactMap { tab($0) }
                recordClosed(members, reason: .cleared, group: UUID(), splitRoot: sp.root)
                splits.removeAll { $0.id == sid }
                for t in members { t.unload(); tabs.removeAll { $0.id == t.id }; ids.insert(t.id) }
            }
        }
        let current = selection
        let stillThere: Bool = {
            switch current {
            case .tab(let id): return tab(id) != nil
            case .split(let id): return split(id) != nil
            case nil: return true
            }
        }()
        if !stillThere {
            selection = nil
            selectPrevious(excluding: current!)
        }
        toast(ids.count == 1 ? "Cleared 1 tab" : "Cleared \(ids.count) tabs", action: "Undo") { [weak self] in
            // The rows come back the way they left, top to bottom.
            TodaySweep.shared.run { self?.restoreClosed(ids) }
        }
        objectWillChange.send()
        scheduleSave()
        return ids.count
    }

    // MARK: Links and toasts

    /// Cmd-Shift-C, or Cmd-Opt-Shift-C for a Markdown link. Tracking parameters come off.
    func copyCurrentURL(markdown: Bool = false) {
        guard let t = currentTab, let u = t.webView?.url ?? t.url else { return }
        let clean = CleanURL.strip(u)
        let s = markdown ? "[\(t.displayTitle.replacingOccurrences(of: "]", with: ")"))](\(clean.absoluteString))" : clean.absoluteString
        Self.copyText(s)
        toast(markdown ? "Copied as Markdown" : "Copied link")
    }

    /// The pasteboard copies go to. Tests use a private one, so they never touch the real clipboard.
    static var pasteboard: NSPasteboard = .general

    static func copyText(_ s: String) {
        pasteboard.clearContents()
        pasteboard.setString(s, forType: .string)
    }

    func toast(_ message: String, action: String? = nil, perform: (() -> Void)? = nil) {
        toastState = ToastState(message: message, actionTitle: action)
        toastAction = perform
        toastWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.toastState = nil; self?.toastAction = nil } }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (action == nil ? 2.5 : 6), execute: w)
    }

    /// Hovering a toast keeps it on screen. Leaving gives it another moment and a half.
    func holdToast(_ held: Bool) {
        guard toastState != nil else { return }
        toastWork?.cancel()
        guard !held else { return }
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.toastState = nil; self?.toastAction = nil } }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    func runToastAction() {
        let a = toastAction
        toastState = nil
        toastAction = nil
        a?()
    }

    // MARK: Moving between tabs

    func select(_ ref: SidebarRef) {
        switch ref {
        case .tab(let id): if let t = tab(id) { select(t) }
        case .split(let id): if let s = split(id) { selectSplit(s) }
        }
    }

    /// Cmd-1 to 8 pick that row, counting Essentials and pins first. Cmd-9 picks the last.
    func selectRow(number n: Int) {
        let rows = visibleRowOrder
        guard !rows.isEmpty else { return }
        let i = n >= 9 ? rows.count - 1 : n - 1
        guard rows.indices.contains(i) else { return }
        select(rows[i])
    }

    /// Cmd-Opt-Down and Up: the next or previous row in the sidebar.
    func selectAdjacentRow(_ step: Int) {
        let rows = visibleRowOrder
        guard !rows.isEmpty else { return }
        let cur: Int? = {
            switch selection {
            case .tab(let id): return rows.firstIndex(of: .tab(id))
            case .split(let id): return rows.firstIndex(of: .split(id))
            case nil: return nil
            }
        }()
        let next = cur.map { ($0 + step + rows.count) % rows.count } ?? (step > 0 ? 0 : rows.count - 1)
        select(rows[next])
    }

    /// Opens a page the app draws, reusing one that's already in this space.
    @discardableResult
    func openAppPage(_ host: String, in split: Bool = false) -> Tab {
        let u = AppPages.url(host)
        if let t = (spaceTabs + essentials).first(where: { $0.isApp && $0.url == u }) {
            if split { openInSplit(t) } else { select(t) }
            return t
        }
        let t = Tab(kind: .app, url: u, title: AppPages.page(for: u)?.title ?? host.capitalized)
        t.model = self
        t.order = topOrder(today: currentSpaceID)
        tabs.append(t)
        if split, currentTab != nil { openInSplit(t) } else { select(t) }
        scheduleSave()
        return t
    }

    // MARK: Ctrl-Tab

    /// Recent items, newest first, for the switcher.
    var recentSelections: [Selection] {
        var out: [Selection] = []
        if let s = selection { out.append(s) }
        for s in selectionHistory.reversed() where !out.contains(s) {
            switch s {
            case .tab(let id): if let t = tab(id), t.spaceID == currentSpaceID || t.isEssential { out.append(s) }
            case .split(let id): if let sp = split(id), sp.spaceID == currentSpaceID { out.append(s) }
            }
        }
        return Array(out.prefix(9))
    }

    func beginSwitcher(backwards: Bool = false) {
        let items = recentSelections
        guard items.count > 1 else { return }
        switcher = SwitcherState(items: items, index: backwards ? items.count - 1 : 1)
    }

    func advanceSwitcher(_ step: Int) {
        guard var s = switcher else { beginSwitcher(backwards: step < 0); return }
        s.index = (s.index + step + s.items.count) % s.items.count
        switcher = s
    }

    func commitSwitcher() {
        guard let s = switcher else { return }
        switcher = nil
        switch s.items[s.index] {
        case .tab(let id): if let t = tab(id) { select(t) }
        case .split(let id): if let sp = split(id) { selectSplit(sp) }
        }
    }

    func title(for s: Selection) -> String {
        switch s {
        case .tab(let id): return tab(id)?.displayTitle ?? ""
        case .split(let id): return split(id).map { $0.items.compactMap { tab($0)?.displayTitle }.joined(separator: " | ") } ?? ""
        }
    }
}

/// Copy URL drops tracking parameters, the way Arc and Zen do.
enum CleanURL {
    static let extra: Set<String> = ["si", "spm", "_hsenc", "_hsmi", "mkt_tok", "oly_anon_id", "oly_enc_id", "vero_id", "yclid", "twclid", "li_fat_id"]

    static func strip(_ url: URL) -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false), let items = c.queryItems, !items.isEmpty else { return url }
        let kept = items.filter { q in
            let n = q.name.lowercased()
            return !URLKey.trackingParams.contains(n) && !extra.contains(n) && !n.hasPrefix("utm_")
        }
        c.queryItems = kept.isEmpty ? nil : kept
        return c.url ?? url
    }
}
