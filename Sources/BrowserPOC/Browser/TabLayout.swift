import AppKit
import Foundation

/// Where tabs live: down the sidebar, like Arc and Zen, or in a bar along the top, like Safari.
/// Saved in `browser.json` as `tabLayout`. Files from before 6 Nov 2026 have none and keep the sidebar.
enum TabLayout: String, Codable, CaseIterable {
    case sidebar, horizontal

    var title: String { self == .sidebar ? "Sidebar" : "Tab bar" }
}

/// Switching between the two layouts, from Settings, the View menu and the command bar.
@MainActor
enum TabLayoutSwitch {
    static var current: TabLayout { BrowserPrefs.shared.value.tabLayout }
    static var isHorizontal: Bool { current == .horizontal }

    static func set(_ layout: TabLayout) {
        guard layout != current else { return }
        // Anything hanging off the old layout goes with it.
        TabBarState.shared.closeAll()
        if let m = AppDelegate.shared?.model { m.sidebarCursor = nil }
        BrowserPrefs.shared.update { $0.tabLayout = layout }
    }

    static func toggle() { set(isHorizontal ? .sidebar : .horizontal) }

    /// Command bar actions that only make sense in one layout. The sidebar's own actions (hide it,
    /// move it, icons only) don't apply to the tab bar.
    static func applies(_ actionID: String, in layout: TabLayout) -> Bool {
        if layout == .horizontal && actionID.hasPrefix("view.sidebar") { return false }
        if actionID == "view.tabBar" { return layout == .sidebar }
        if actionID == "view.tabSidebar" { return layout == .horizontal }
        return true
    }

    static func applies(_ actionID: String) -> Bool { applies(actionID, in: current) }
}

/// The three ways to show tabs, as the right-click menu on the sidebar, the icon column and the
/// tab bar offers them: the sidebar with titles, the sidebar as a column of icons, or the bar
/// along the top.
enum TabMode: CaseIterable {
    case sidebar, icons, bar

    var title: String {
        switch self {
        case .sidebar: return "Sidebar"
        case .icons: return "Sidebar Icons Only"
        case .bar: return "Tab Bar"
        }
    }

    /// Compact mode's floating sidebar always has titles, so it counts as the sidebar.
    static func of(_ p: BrowserPrefsValue) -> TabMode {
        if p.tabLayout == .horizontal { return .bar }
        return p.sidebarIconsOnly && !p.sidebarHidden ? .icons : .sidebar
    }

    @MainActor static var current: TabMode { of(BrowserPrefs.shared.value) }

    @MainActor static func set(_ mode: TabMode) {
        guard mode != current else { return }
        switch mode {
        case .bar:
            TabLayoutSwitch.set(.horizontal)
        case .sidebar, .icons:
            let icons = mode == .icons
            if TabLayoutSwitch.isHorizontal {
                // The layouts swap at once, so the sidebar arrives already in its new form.
                BrowserPrefs.shared.update { p in
                    p.sidebarIconsOnly = icons
                    if icons { p.sidebarHidden = false }
                }
                TabLayoutSwitch.set(.sidebar)
            } else if icons && BrowserPrefs.shared.value.sidebarHidden {
                // Picking icons in compact mode brings the sidebar back as the column, since the
                // floating sidebar only ever shows titles.
                Motion.run(Motion.sidebarToggle) { BrowserPrefs.shared.update { $0.sidebarHidden = false; $0.sidebarIconsOnly = true } }
            } else {
                SidebarResize.shared.setIconsOnly(icons)
            }
        }
    }
}

/// The tab bar's rules, as plain values and pure functions so the self test can check them. The
/// numbers come from notes/research/2026-11-06-horizontal-tabs.md.
enum TabBarRules {
    /// Essentials the closed box shows. The rest open below it on hover.
    static let essentialsShown = 3
    /// Columns in the open grid: the box's own width, so it grows straight down.
    static let essentialsColumns = 3

    /// A tab never gets narrower than this. Past it, the strip scrolls.
    static let tabMinWidth: CGFloat = 96
    /// Nor wider than this, so two tabs don't each take half a wide window.
    static let tabMaxWidth: CGFloat = 240
    /// A split takes this many tabs' width, one per pane up to this.
    static let splitUnits = 2.0
    /// A pinned tab: its icon on a tile, like Safari's pinned tabs and Firefox's 32 px squares.
    static let pinnedWidth: CGFloat = 32
    /// Space between items in the strip.
    static let gap: CGFloat = 2
    /// The line between pinned and other tabs, 1 pt wide with 6 pt either side.
    static let dividerRoom: CGFloat = 13
    /// A little more room between the last folder and the first loose tab.
    static let groupGap: CGFloat = 8
    /// Below this, a tab shows only its icon.
    static let titleNeeds: CGFloat = 64
    /// The Essentials box opens after the pointer rests on it this long, and closes this long
    /// after it leaves, so passing over it doesn't throw the grid over the page. The same as the
    /// sidebar's icon column and compact mode's reveal.
    static let essentialsOpenDelay: TimeInterval = Motion.Timing.revealDwell
    static let essentialsCloseDelay: TimeInterval = Motion.Timing.concealDelay
    /// After you close tabs, they keep their width until the pointer has been out of the strip this long, like Chrome.
    static let widthHold: TimeInterval = 0.3
    /// The soft edge where tabs run off the strip, and the strip of it a click pages from.
    static let edgeFade: CGFloat = 10
    static let edgeClick: CGFloat = 16
    /// A click on an edge pages by the visible width less this, so a tab stays in view, like Chrome.
    static let pageOverlap: CGFloat = 32
    /// How wide each tab is, given the room for the strip, the room fixed items take (pinned
    /// tabs, folder chips, the divider) and how many tab widths the rest needs.
    static func tabWidth(available: CGFloat, fixed: CGFloat, units: Double, gaps: Int) -> CGFloat {
        guard units > 0 else { return tabMaxWidth }
        let room = available - fixed - CGFloat(max(0, gaps)) * gap
        return min(tabMaxWidth, max(tabMinWidth, (room / CGFloat(units)).rounded(.down)))
    }

    /// Whether the strip is wider than its room, so it scrolls.
    static func overflows(available: CGFloat, fixed: CGFloat, units: Double, gaps: Int) -> Bool {
        fixed + CGFloat(units) * tabMinWidth + CGFloat(max(0, gaps)) * gap > available + 0.5
    }

    /// The Essentials the closed box shows: always the first three, so they stay where you left
    /// them. The sidebar's icon column does the same.
    static func essentialSlots(_ ids: [UUID]) -> [UUID] { Array(ids.prefix(essentialsShown)) }

    /// Whether the page you're on is an Essential the closed box doesn't show. Its count then
    /// looks selected, so you can still tell where you are.
    static func openIsHidden(_ ids: [UUID], open: Set<UUID>) -> Bool {
        ids.dropFirst(essentialsShown).contains { open.contains($0) }
    }

    /// Rows in the open Essentials grid.
    static func essentialRows(_ count: Int) -> Int { max(1, Int((Double(count) / Double(essentialsColumns)).rounded(.up))) }

    /// Tabs in the bar read oldest to newest, left to right, so a new tab opens at the right end
    /// next to the plus button, like Safari. The sidebar lists them newest first.
    static func barOrder(_ today: [SidebarRef]) -> [SidebarRef] { today.reversed() }

    /// A drop beside a tab in the bar, said in the model's order: left of a tab is below it in
    /// the sidebar, and right of it is above it.
    static func todayDrop(displayAfter: Bool) -> Bool { !displayAfter }
}

extension BrowserModel {
    /// Option-click on a tab's close button closes the space's other loose tabs, like Safari.
    /// Pinned tabs, folders, Essentials and splits stay. Each goes to Recently Closed.
    @discardableResult
    func closeOtherTabs(keeping keep: Tab) -> Int {
        let others = refs(in: .today).compactMap { r -> Tab? in
            if case .tab(let id) = r, id != keep.id { return tab(id) }
            return nil
        }
        select(keep)
        for t in others { t.kind == .web ? close(t) : remove(t) }
        if !others.isEmpty { toast(others.count == 1 ? "Closed 1 other tab" : "Closed \(others.count) other tabs") }
        return others.count
    }

    /// What the tab bar shows for a space, left to right: pinned tabs and splits, then folders,
    /// then other tabs and splits, oldest first.
    func barRows(space: UUID) -> (pinned: [SidebarRef], folders: [Folder], today: [SidebarRef]) {
        (refs(in: .pinned, space: space), folders(in: space), TabBarRules.barOrder(refs(in: .today, space: space)))
    }

    /// The rows of an open folder, or the one a closed folder keeps on screen, as the bar shows them.
    func barRows(folder f: Folder) -> [SidebarRef] {
        f.isExpanded ? refs(in: .folder(f.id)) : shownInClosedFolder(f)
    }
}
