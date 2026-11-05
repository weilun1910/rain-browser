import Foundation

/// Split view: two to four items on screen together, as a tree of rows and columns.
extension BrowserModel {
    // MARK: Selecting and focusing

    func selectSplit(_ sp: SplitRecord, focusItem: UUID? = nil) {
        if let sid = sp.spaceID, sid != currentSpaceID { switchSpace(to: sid, restore: false) }
        if let focusItem, let i = splits.firstIndex(where: { $0.id == sp.id }), splits[i].contains(focusItem) {
            if splits[i].focused != focusItem, let t = tab(splits[i].focused) { endDwell(t) }
            splits[i].focused = focusItem
        }
        if selection == .split(sp.id) {
            refreshFocus()
            syncAddress()
        } else {
            setSelection(.split(sp.id))
        }
        for t in visibleTabs where t.kind == .web && t.url != nil { _ = t.ensureWebView() }
        contextForFocused()
        scheduleSave()
    }

    /// The first version's call: left is the first pane, right the second.
    func selectSplit(_ sp: SplitRecord, focus: PaneSide?) {
        let items = sp.items
        let id: UUID? = focus.map { ($0 == .left || $0 == .top) ? items.first : (items.count > 1 ? items[1] : items.first) } ?? nil
        selectSplit(sp, focusItem: id)
    }

    /// Focus a pane by item.
    func focusPane(item: UUID) {
        guard let sp = currentSplit, let i = splits.firstIndex(where: { $0.id == sp.id }), sp.contains(item), sp.focused != item else { return }
        if let t = tab(sp.focused) { endDwell(t) }
        splits[i].focused = item
        tab(item)?.lastActiveAt = Date()
        if find.visible { closeFind() }
        refreshFocus()
        syncAddress()
        contextForFocused()
        scheduleSave()
    }

    /// Ctrl-Shift-1 to 4: focus the nth pane in reading order.
    func focusPane(index: Int) {
        guard let sp = currentSplit, sp.items.indices.contains(index) else { return }
        focusPane(item: sp.items[index])
    }

    /// Left is the first pane and right the second, as in the first version.
    func focusPane(_ side: PaneSide) {
        guard let sp = currentSplit else { return }
        focusPane(index: (side == .left || side == .top) ? 0 : min(1, sp.items.count - 1))
    }

    /// Ctrl-Shift-] and Ctrl-Shift-[: the next or previous pane.
    func focusNextPane(_ step: Int) {
        guard let sp = currentSplit, let i = sp.items.firstIndex(of: sp.focused) else { return }
        let n = sp.items.count
        focusPane(index: ((i + step) % n + n) % n)
    }

    // MARK: Making splits

    /// Puts an item on screen next to what's there. In a split it becomes a new pane beside the
    /// focused one (or `target`), up to four. Returns false when the split is full.
    @discardableResult
    func openInSplit(_ tab: Tab, side: PaneSide = .right, of target: UUID? = nil) -> Bool {
        if let sp = currentSplit, let i = splits.firstIndex(where: { $0.id == sp.id }) {
            let anchor = target.flatMap { sp.contains($0) ? $0 : nil } ?? sp.focused
            if sp.contains(tab.id) {
                // Moving a pane within its own split.
                guard anchor != tab.id, let without = sp.root.removing(tab.id) else { return true }
                splits[i].root = without.inserting(tab.id, at: side, of: anchor)
                splits[i].focused = tab.id
                selectSplit(splits[i])
                return true
            }
            guard sp.count < SplitNode.maxPanes else {
                toast("Split view holds up to four panes")
                return false
            }
            if let old = split(containing: tab.id) { removeFromSplit(tab.id, old) }
            guard let j = splits.firstIndex(where: { $0.id == sp.id }) else { return false }
            splits[j].root = splits[j].root.inserting(tab.id, at: side, of: anchor)
            splits[j].focused = tab.id
            adoptIntoSpace(tab, splits[j].spaceID)
            selectSplit(splits[j])
            return true
        }
        guard let cur = currentTab, cur.id != tab.id else { select(tab); return true }
        if let old = split(containing: tab.id) { removeFromSplit(tab.id, old) }
        var sp = SplitRecord(root: SplitNode.leaf(cur.id).inserting(tab.id, at: side, of: cur.id), focused: tab.id, spaceID: currentSpaceID)
        // The split takes the place of the item it grew from.
        sp.isPinned = cur.isPinned && !cur.isEssential
        sp.order = cur.isEssential ? topOrder(today: currentSpaceID) : cur.order
        if cur.folderID != nil { sp.order = topOrder(today: currentSpaceID) }
        adoptIntoSpace(tab, currentSpaceID)
        splits.append(sp)
        selectSplit(sp)
        return true
    }

    /// An item from another space joins this one when it goes into a split here.
    private func adoptIntoSpace(_ tab: Tab, _ space: UUID?) {
        guard let space, tab.spaceID != space, !tab.isEssential else { return }
        tab.spaceID = space
        tab.folderID = nil
        tab.isPinned = false
    }

    /// Two to four items as a new split, from a multi-selection. Side by side up to three, grid for four.
    @discardableResult
    func split(items ids: [UUID]) -> SplitRecord? {
        var list: [UUID] = []
        for id in ids where !list.contains(id) && tab(id) != nil { list.append(id) }
        guard list.count >= 2 else { return nil }
        if list.count > SplitNode.maxPanes { toast("Split view holds up to four panes"); return nil }
        for id in list { if let old = split(containing: id) { removeFromSplit(id, old) } }
        let first = tab(list[0])
        var sp = SplitRecord(root: SplitNode.layout(list, list.count == 4 ? .grid : .sideBySide), focused: list[0], spaceID: currentSpaceID)
        sp.isPinned = first?.isPinned == true && first?.isEssential != true
        sp.order = first.map { $0.isEssential || $0.folderID != nil ? topOrder(today: currentSpaceID) : $0.order } ?? topOrder(today: currentSpaceID)
        for id in list { if let t = tab(id) { adoptIntoSpace(t, currentSpaceID) } }
        splits.append(sp)
        multiSelection = []
        selectSplit(sp)
        return sp
    }

    /// Ctrl-Shift-=: the bar, and whatever's picked opens as a new pane.
    func splitWithNewTab() {
        if bar.isOpen && bar.mode == .split { bar.close(); return }
        bar.open(currentTab == nil ? .newTab : .split)
    }

    /// A sidebar item dropped on the content area. `onPane` is the pane under the pointer.
    func drop(tabID: UUID, side: PaneSide, onPane: UUID? = nil) {
        guard let t = tab(tabID) else { return }
        if currentTab == nil { select(t); return }
        if currentSplit == nil, currentTab?.id == tabID { return }
        openInSplit(t, side: side, of: onPane)
    }

    /// A sidebar item held over another item in the sidebar, then dropped: the two become a
    /// split, or the dragged one joins the target's split.
    func dropForSplit(_ draggedID: UUID, onto targetID: UUID) {
        guard draggedID != targetID, let dragged = tab(draggedID), let target = tab(targetID) else { return }
        if let sp = split(containing: targetID) {
            selectSplit(sp, focusItem: targetID)
            openInSplit(dragged, side: .right, of: targetID)
            return
        }
        select(target)
        openInSplit(dragged, side: .right, of: targetID)
    }

    // MARK: Changing splits

    /// Both or all items go back to being normal items, where the split was.
    func separate(_ sp: SplitRecord) {
        let focused = tab(sp.focused)
        for (n, id) in sp.items.enumerated() {
            guard let t = tab(id), !t.isEssential, t.folderID == nil else { continue }
            t.order = sp.order + Double(n) * 0.001
        }
        splits.removeAll { $0.id == sp.id }
        if selection == .split(sp.id) {
            selection = nil
            if let focused { select(focused) }
        }
        objectWillChange.send()
        scheduleSave()
    }

    /// Ctrl-Shift--: the current split comes apart, keeping its tabs.
    func unsplitCurrent() {
        if let sp = currentSplit { separate(sp) }
    }

    /// Takes one pane out of its split and keeps it as a normal item. With `stay`, focus stays in
    /// the split (Shift-click on Unsplit, like Zen). Two panes left alone become normal items.
    func popOut(_ id: UUID, stay: Bool = false) {
        guard let sp = split(containing: id), let t = tab(id) else { return }
        if sp.count <= 2 {
            let other = sp.items.first { $0 != id }.flatMap { tab($0) }
            separate(sp)
            if stay, let other { select(other) } else { select(t) }
            return
        }
        removeFromSplit(id, sp)
        if t.folderID == nil && !t.isEssential { t.order = sp.order - 0.001 }
        if !stay { select(t) } else if let s2 = split(sp.id) { selectSplit(s2) }
        scheduleSave()
    }

    /// Removes an item from a split. A split left with one item goes away.
    func removeFromSplit(_ id: UUID, _ sp: SplitRecord) {
        guard let i = splits.firstIndex(where: { $0.id == sp.id }) else { return }
        guard let rest = splits[i].root.removing(id), rest.leaves.count >= 2 else {
            let wasSelected = selection == .split(sp.id)
            let keep = sp.items.first { $0 != id }
            splits.remove(at: i)
            if wasSelected, let keep, let t = tab(keep) { selection = nil; select(t) }
            return
        }
        splits[i].root = rest
        if splits[i].focused == id { splits[i].focused = rest.leaves.first ?? id }
        if selection == .split(sp.id) { refreshFocus(); syncAddress(); contextForFocused() }
    }

    /// The other panes stay. One left goes full width.
    func dissolveSplit(around removed: UUID) {
        guard let sp = split(containing: removed) else { return }
        removeFromSplit(removed, sp)
    }

    /// Two panes trade places. With more, they rotate one step.
    func swap(_ sp: SplitRecord) {
        guard let i = splits.firstIndex(where: { $0.id == sp.id }) else { return }
        let items = sp.items
        if items.count == 2 {
            splits[i].root = sp.root.swapping(items[0], items[1])
        } else {
            var root = sp.root
            let rotated = Array(items.dropFirst()) + [items[0]]
            // Rebuild leaf by leaf through a placeholder so swaps don't collide.
            var tmp: [UUID: UUID] = [:]
            for id in items { let p = UUID(); tmp[id] = p; root = root.replacing(id, with: p) }
            for (old, new) in zip(items, rotated) { root = root.replacing(tmp[old]!, with: new) }
            splits[i].root = root
        }
        scheduleSave()
    }

    func setLayout(_ layout: SplitLayout, for sp: SplitRecord? = nil) {
        guard let sp = sp ?? currentSplit, let i = splits.firstIndex(where: { $0.id == sp.id }) else { return }
        splits[i].root = SplitNode.layout(sp.items, layout)
        scheduleSave()
    }

    /// Evens out every divider.
    func evenOut(_ sp: SplitRecord? = nil) {
        guard let sp = sp ?? currentSplit, let i = splits.firstIndex(where: { $0.id == sp.id }) else { return }
        splits[i].root = sp.root.evened
        scheduleSave()
    }

    /// New shares for one branch of the current split, from dragging a divider.
    func setSplitSizes(_ sizes: [Double], at path: [Int], in splitID: UUID, save: Bool) {
        guard let i = splits.firstIndex(where: { $0.id == splitID }) else { return }
        splits[i].root = splits[i].root.settingSizes(sizes, at: path)
        if save { scheduleSave() }
    }

    /// The first version's divider: the first pane's share of a two-pane split.
    func setSplitRatio(_ r: Double, save: Bool) {
        guard let sp = currentSplit, case .branch(_, let kids, _) = sp.root, kids.count == 2 else { return }
        let v = min(0.8, max(0.2, r))
        setSplitSizes([v, 1 - v], at: [], in: sp.id, save: save)
    }

    func togglePin(split sp: SplitRecord) {
        guard let i = splits.firstIndex(where: { $0.id == sp.id }) else { return }
        splits[i].isPinned.toggle()
        splits[i].order = splits[i].isPinned ? topOrder(pinned: currentSpaceID) : topOrder(today: currentSpaceID)
        scheduleSave()
    }
}
