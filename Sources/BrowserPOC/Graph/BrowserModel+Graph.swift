import Foundation

/// Opening the graph as an item, and opening items from the graph.
extension BrowserModel {
    /// The space's Graph item, made if it isn't there yet. With `focusID`, the graph focuses on that node.
    @discardableResult
    func openGraph(focusID: String? = nil) -> Tab {
        GraphController.global.model = self
        if let focusID { GraphController.global.focusID = focusID }
        if let t = spaceTabs.first(where: { $0.kind == .graph }) {
            select(t)
            return t
        }
        let t = Tab(kind: .graph, url: nil, title: "Graph")
        t.model = self
        tabs.append(t)
        select(t)
        scheduleSave()
        return t
    }

    /// Opens a node's item: an open tab with the same address if there is one, else a new one.
    func openFromGraph(_ n: LayoutNode, mode: GraphOpenMode) {
        guard let u = URL(string: n.url) else { return }
        let tab: Tab
        if n.kind == .note || u.isFileURL {
            tab = openNote(u, select: mode == .normal)
        } else if let t = spaceTabs.first(where: { $0.kind == .web && $0.url.map(URLKey.key(for:)) == n.key }) {
            tab = t
            if mode == .normal { select(t) }
        } else {
            tab = Tab(url: u, title: n.title)
            tab.model = self
            tabs.append(tab)
            if mode == .normal { select(tab) }
        }
        if mode == .split { openInSplit(tab, side: .right) }
        if !n.key.isEmpty { IndexStore.shared?.touchOpened(key: n.key) }
        scheduleSave()
    }
}
