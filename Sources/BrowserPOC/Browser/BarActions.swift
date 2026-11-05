import AppKit
import Foundation

/// A command the bar can run, like Zen's actions and Arc's Cmd-T actions. Each one says when it
/// applies, so the bar only lists what makes sense right now, and shows its shortcut.
struct BarAction {
    let id: String
    let title: String
    let icon: String
    var shortcut: String? = nil
    /// Extra words that find it, like "compact" for the sidebar toggle.
    var keywords: [String] = []
    var available: @MainActor (BrowserModel) -> Bool = { _ in true }
    let run: @MainActor (BrowserModel) -> Void
}

@MainActor
enum BarActions {
    static func all(_ m: BrowserModel) -> [BarAction] {
        var out = fixed
        // Focus on another space, like Zen's "Focus on" and Arc's "Focus On".
        for sp in m.spaces where sp.id != m.currentSpaceID {
            let id = sp.id
            out.append(BarAction(id: "space.focus.\(id.uuidString)", title: "Focus on \(sp.name)", icon: "square.stack", keywords: ["space", "switch"]) { $0.switchSpace(to: id) })
        }
        // Pages the app draws, including any another part of the app registered.
        for p in AppPages.all where p.inCommandBar {
            let host = p.host
            out.append(BarAction(id: "page.\(host)", title: "Open \(p.title)", icon: p.icon, shortcut: pageShortcuts[host], keywords: [host]) { $0.openAppPage(host) })
        }
        return out
    }

    static let pageShortcuts: [String: String] = ["history": "⌘Y", "downloads": "⌥⌘L"]

    static func available(_ m: BrowserModel) -> [BarAction] { all(m).filter { $0.available(m) } }

    static func run(_ id: String, model: BrowserModel) {
        all(model).first { $0.id == id }?.run(model)
    }

    private static func web(_ m: BrowserModel) -> Tab? { m.currentWebTab }

    static let fixed: [BarAction] = [
        BarAction(id: "tab.copyURL", title: "Copy link", icon: "link", shortcut: "⇧⌘C", keywords: ["url", "address", "copy url"],
                  available: { $0.currentTab?.url != nil && $0.currentTab?.isApp == false }) { $0.copyCurrentURL() },
        BarAction(id: "tab.copyMarkdown", title: "Copy link as Markdown", icon: "link", shortcut: "⌥⇧⌘C", keywords: ["url", "markdown"],
                  available: { $0.currentTab?.url != nil && $0.currentTab?.isApp == false }) { $0.copyCurrentURL(markdown: true) },
        BarAction(id: "tab.pin", title: "Pin tab", icon: "pin", shortcut: "⌘D",
                  available: { m in m.currentTab.map { !$0.isPinned && !$0.isEssential } ?? false }) { m in if let t = m.currentTab { m.togglePin(t) } },
        BarAction(id: "tab.unpin", title: "Unpin tab", icon: "pin.slash", shortcut: "⌘D",
                  available: { $0.currentTab?.isPinned == true }) { m in if let t = m.currentTab { m.togglePin(t) } },
        BarAction(id: "tab.addEssential", title: "Add to Essentials", icon: "square.grid.2x2", keywords: ["favorite", "favourite"],
                  available: { m in m.currentTab.map { !$0.isEssential } ?? false }) { m in if let t = m.currentTab { m.addToEssentials(t) } },
        BarAction(id: "tab.removeEssential", title: "Remove from Essentials", icon: "square.grid.2x2", keywords: ["favorite", "favourite"],
                  available: { $0.currentTab?.isEssential == true }) { m in if let t = m.currentTab { m.removeFromEssentials(t) } },
        BarAction(id: "tab.resetPin", title: "Back to pinned page", icon: "arrow.uturn.backward", keywords: ["reset"],
                  available: { $0.currentTab?.isAwayFromPin == true }) { m in if let t = m.currentTab { m.resetPinned(t) } },
        BarAction(id: "tab.replacePin", title: "Replace pinned address with this page", icon: "pin", keywords: ["reset", "pinned url"],
                  available: { $0.currentTab?.isAwayFromPin == true }) { m in if let t = m.currentTab { m.replacePinnedURL(t) } },
        BarAction(id: "tab.duplicate", title: "Duplicate tab", icon: "plus.square.on.square",
                  available: { m in m.currentTab.map { $0.isWeb || $0.isApp } ?? false }) { m in if let t = m.currentTab { m.duplicate(t) } },
        BarAction(id: "tab.rename", title: "Rename tab", icon: "pencil",
                  available: { $0.currentTab != nil }) { m in if let t = m.currentTab { m.promptRenameTab(t) } },
        BarAction(id: "tab.archive", title: "Archive tab", icon: "archivebox",
                  available: { m in m.currentTab.map { !$0.isPinned && !$0.isEssential && $0.folderID == nil } ?? false }) { m in if let t = m.currentTab { m.archive(t) } },
        BarAction(id: "tab.close", title: "Close tab", icon: "xmark", shortcut: "⌘W", available: { $0.currentTab != nil }) { $0.closeCurrent() },
        BarAction(id: "tab.reopen", title: "Reopen closed tab", icon: "arrow.uturn.backward", shortcut: "⇧⌘T", keywords: ["undo", "restore"],
                  available: { $0.canReopenClosed }) { $0.reopenClosed() },
        BarAction(id: "tab.reload", title: "Reload", icon: "arrow.clockwise", shortcut: "⌘R", keywords: ["refresh"],
                  available: { web($0) != nil }) { $0.reload() },
        BarAction(id: "tab.hardReload", title: "Reload without cache", icon: "arrow.clockwise", keywords: ["hard", "refresh"],
                  available: { web($0) != nil }) { $0.reloadFromOrigin() },
        BarAction(id: "tab.mute", title: "Mute tab", icon: "speaker.slash", keywords: ["sound", "audio"],
                  available: { m in web(m).map { !$0.isMuted } ?? false }) { m in if let t = web(m) { m.toggleMute(t) } },
        BarAction(id: "tab.unmute", title: "Unmute tab", icon: "speaker.wave.2", keywords: ["sound", "audio"],
                  available: { web($0)?.isMuted == true }) { m in if let t = web(m) { m.toggleMute(t) } },
        BarAction(id: "tab.find", title: "Find in page", icon: "text.magnifyingglass", shortcut: "⌘F", keywords: ["search page"],
                  available: { m in m.currentTab.map { $0.isWeb || $0.isNote } ?? false }) { m in DispatchQueue.main.async { m.openFind() } },
        BarAction(id: "today.clear", title: "Clear Today", icon: "sparkles", shortcut: "⇧⌘K", keywords: ["close all", "unpinned", "tidy"],
                  available: { !$0.refs(in: .today).isEmpty }) { _ = $0.clearToday() },
        BarAction(id: "peek.expand", title: "Open Peek as a tab", icon: "arrow.up.left.and.arrow.down.right", shortcut: "⌘O",
                  available: { $0.peek != nil }) { $0.expandPeek() },
        BarAction(id: "split.new", title: "New split view", icon: "rectangle.split.2x1", shortcut: "⌃⇧=", keywords: ["split", "side by side"],
                  available: { m in m.currentTab != nil && (m.currentSplit?.count ?? 1) < SplitNode.maxPanes }) { m in DispatchQueue.main.async { m.splitWithNewTab() } },
        BarAction(id: "split.unsplit", title: "Unsplit", icon: "rectangle", shortcut: "⌃⇧-", keywords: ["expand", "separate", "split"],
                  available: { $0.currentSplit != nil }) { $0.unsplitCurrent() },
        BarAction(id: "split.sideBySide", title: "Split layout: side by side", icon: "rectangle.split.3x1", keywords: ["vertical", "split"],
                  available: { m in m.currentSplit.map { $0.root.layoutKind != .sideBySide } ?? false }) { $0.setLayout(.sideBySide) },
        BarAction(id: "split.stacked", title: "Split layout: stacked", icon: "rectangle.split.1x2", keywords: ["horizontal", "split"],
                  available: { m in m.currentSplit.map { $0.root.layoutKind != .stacked } ?? false }) { $0.setLayout(.stacked) },
        BarAction(id: "split.grid", title: "Split layout: grid", icon: "rectangle.split.2x2", keywords: ["split"],
                  available: { m in m.currentSplit.map { $0.count > 2 && $0.root.layoutKind != .grid } ?? false }) { $0.setLayout(.grid) },
        BarAction(id: "split.swap", title: "Swap split panes", icon: "arrow.left.arrow.right", keywords: ["rotate", "split"],
                  available: { $0.currentSplit != nil }) { m in if let s = m.currentSplit { m.swap(s) } },
        BarAction(id: "split.even", title: "Even out split panes", icon: "equal.square", keywords: ["split", "resize"],
                  available: { $0.currentSplit != nil }) { $0.evenOut() },
        BarAction(id: "space.new", title: "New space", icon: "plus.square", keywords: ["workspace"]) { m in DispatchQueue.main.async { m.promptNewSpace() } },
        BarAction(id: "space.next", title: "Next space", icon: "chevron.right", shortcut: "⌥⌘→", keywords: ["workspace"],
                  available: { m in (m.spaces.firstIndex { $0.id == m.currentSpaceID } ?? 0) < m.spaces.count - 1 }) { $0.switchSpace(by: 1) },
        BarAction(id: "space.previous", title: "Previous space", icon: "chevron.left", shortcut: "⌥⌘←", keywords: ["workspace"],
                  available: { m in (m.spaces.firstIndex { $0.id == m.currentSpaceID } ?? 0) > 0 }) { $0.switchSpace(by: -1) },
        BarAction(id: "folder.new", title: "New folder", icon: "folder.badge.plus") { m in DispatchQueue.main.async { m.promptNewFolder() } },
        BarAction(id: "folder.collapseAll", title: "Collapse all folders", icon: "folder",
                  available: { $0.spaceFolders.contains { $0.isExpanded } }) { $0.setAllFolders(expanded: false) },
        BarAction(id: "folder.expandAll", title: "Expand all folders", icon: "folder",
                  available: { $0.spaceFolders.contains { !$0.isExpanded } }) { $0.setAllFolders(expanded: true) },
        BarAction(id: "view.sidebar", title: "Toggle sidebar", icon: "sidebar.left", shortcut: "⌘S", keywords: ["compact mode", "hide sidebar", "show sidebar"]) { _ in
            BrowserPrefs.shared.update { $0.sidebarHidden.toggle() }
        },
        BarAction(id: "view.sidebarSide", title: "Move sidebar to the other side", icon: "sidebar.right", keywords: ["tabs on the right", "left", "right"]) { _ in
            BrowserPrefs.shared.update { $0.sidebarOnRight.toggle() }
        },
        BarAction(id: "view.related", title: "Toggle Related panel", icon: "sidebar.right", shortcut: "⇧⌘R", keywords: ["cards", "resurfacing"]) { _ in
            Settings.shared.update { $0.rightPanelOpen.toggle() }
        },
        BarAction(id: "note.new", title: "New note", icon: "square.and.pencil", shortcut: "⇧⌘N") { $0.newNote() },
        BarAction(id: "littleArc.new", title: "New Little Arc window", icon: "macwindow", shortcut: "⌥⌘N", keywords: ["quick", "window"]) { m in
            DispatchQueue.main.async { LittleArc.shared.openBlank(model: m) }
        },
        BarAction(id: "app.settings", title: "Settings", icon: "gearshape", shortcut: "⌘,", keywords: ["preferences"]) { _ in
            DispatchQueue.main.async { AppDelegate.shared?.openSettings() }
        },
    ]
}

/// Ranks action titles the way Zen does: an exact match first, then a prefix match, then a
/// fuzzy match that rewards letters at word starts and runs of consecutive letters.
enum Fuzzy {
    static let exact = 1_000_000
    static let prefix = 100_000
    /// The bar mixes actions into normal results only above this score.
    static let mixedMinimum = 92
    /// In actions mode a looser score is fine.
    static let actionsMinimum = 30

    static func score(_ target: String, _ query: String) -> Int {
        let t = Array(target.lowercased()), q = Array(query.lowercased())
        guard !t.isEmpty, !q.isEmpty, q.count <= t.count else { return 0 }
        if t == q { return exact }
        if t.starts(with: q) { return prefix + q.count }
        var score = 0, qi = 0, last = -1, run = 0
        for (ti, ch) in t.enumerated() where qi < q.count && ch == q[qi] {
            var bonus = 10
            if ti == 0 || [" ", "-", "_", ":"].contains(t[ti - 1]) { bonus += 15 }
            if last == ti - 1 { run += 1; bonus += 20 * run } else { run = 0 }
            if last != -1 { bonus -= min(ti - last - 1, 10) }
            score += bonus
            last = ti
            qi += 1
        }
        return qi == q.count ? score : 0
    }

    /// The best score over the title and its keywords.
    static func best(_ a: BarAction, _ query: String) -> Int {
        ([a.title] + a.keywords).map { score($0, query) }.max() ?? 0
    }
}

/// Remembers which actions you pick, like Zen's results learner. Picking one adds a point, up
/// to 5. Each action that was shown but skipped loses one, down to -5. Positive ones rise to the top.
@MainActor
struct CommandLearner {
    static let cap = 5

    func score(_ id: String) -> Int { BrowserPrefs.shared.value.actionScores[id] ?? 0 }

    func record(_ picked: String?, seen: Set<String>) {
        BrowserPrefs.shared.update { p in
            if let picked { p.actionScores[picked] = min((p.actionScores[picked] ?? 0) + 1, Self.cap) }
            for id in seen where id != picked {
                let v = max((p.actionScores[id] ?? 0) - 1, -Self.cap)
                p.actionScores[id] = v == 0 ? nil : v
            }
        }
    }
}
