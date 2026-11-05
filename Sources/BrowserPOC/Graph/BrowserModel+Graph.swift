import Foundation

/// Opening the graph, and opening items from the graph.
extension BrowserModel {
    /// The space's Graph item (an app page), made if it isn't there yet. With `focusID`, the graph
    /// focuses on that node.
    @discardableResult
    func openGraph(focusID: String? = nil) -> Tab {
        GraphController.global.model = self
        if let focusID { GraphController.global.focusID = focusID }
        return openAppPage(GraphTab.host)
    }

    /// Opens a node's item: an open tab with the same address if there is one, else a new one.
    func openFromGraph(_ n: LayoutNode, mode: GraphOpenMode) {
        guard let u = URL(string: n.url) else { return }
        let tab: Tab
        if n.kind == .note || u.isFileURL {
            tab = openNote(u, select: mode == .normal)
        } else if let t = (spaceTabs + essentials).first(where: { $0.kind == .web && $0.url.map(URLKey.key(for:)) == n.key }) {
            tab = t
            if mode == .normal { select(t) }
        } else {
            tab = newTab(url: u, select: mode == .normal)
        }
        if mode == .split { _ = openInSplit(tab, side: .right) }
        if !n.key.isEmpty { IndexStore.shared?.touchOpened(key: n.key) }
        scheduleSave()
    }
}
