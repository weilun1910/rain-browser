import AppKit
import SwiftUI

// The row of tabs in the tab bar layout. Left to right: Essentials in their box, then a strip
// that scrolls sideways with pinned tabs as icon tiles, folders as chips with their tabs after
// them, a line, and the other tabs, oldest first. A plus button for a new tab sits at the end.
// Tabs share the room evenly between a minimum and a maximum width, and past the minimum the
// strip scrolls. Splits show as one joined tab, the way the sidebar shows them as one row.

enum TabBarDropIndicator: Equatable { case before, after, split }

/// Where an item sits in the strip, which decides how it looks and how drops beside it land.
enum TabBarPlace { case pinned, folder, today }

/// A click on a tab in the bar does what a click on its sidebar row does. Cmd-click and
/// Shift-click pick several. Option-click opens it in split view with what's on screen, and on
/// the current tab, a copy of it.
@MainActor
enum TabClick {
    static func perform(_ tab: Tab, model: BrowserModel) {
        let mods = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) { model.multiSelectClick(.tab(tab.id), shift: false); return }
        if mods.contains(.shift) { model.multiSelectClick(.tab(tab.id), shift: true); return }
        if mods.contains(.option) {
            if model.isSelected(tab) {
                if let copy = model.duplicate(tab) { model.select(tab); model.openInSplit(copy) }
            } else if model.currentTab != nil {
                model.openInSplit(tab)
            } else {
                model.select(tab)
            }
            return
        }
        model.multiSelection = []
        model.select(tab)
    }
}

/// How the strip lays out for a space: the pinned tabs' room, which stays put, and the width of
/// each tab in the part that scrolls.
struct TabStripLayout: Equatable {
    /// The pinned tabs and the line after them. Zero with nothing pinned.
    var pinnedRoom: CGFloat
    var tabWidth: CGFloat
    var overflows: Bool

    /// Pinned tabs never take more than this share of the strip. Past it, they scroll on their own.
    static let pinnedShare: CGFloat = 0.45

    @MainActor
    static func measure(_ model: BrowserModel, space: UUID, available: CGFloat, frozen: CGFloat?) -> TabStripLayout {
        let rows = model.barRows(space: space)
        let pins = rows.pinned.reduce(CGFloat(0)) { $0 + pinnedWidth($1, model) } + CGFloat(max(0, rows.pinned.count - 1)) * TabBarRules.gap
        let pinnedRoom = rows.pinned.isEmpty ? 0 : min(pins, available * pinnedShare) + TabBarRules.dividerRoom
        var fixed: CGFloat = 0
        var units = 0.0
        var items = 0
        for f in rows.folders {
            fixed += BarFolderChip.width(f, count: model.tabs(in: f).count)
            items += 1
            for r in model.barRows(folder: f) { units += unitCount(r, model); items += 1 }
        }
        if !rows.folders.isEmpty && !rows.today.isEmpty { fixed += TabBarRules.groupGap }
        for r in rows.today { units += unitCount(r, model); items += 1 }
        let gaps = max(0, items - 1)
        let room = available - pinnedRoom
        let w = frozen ?? TabBarRules.tabWidth(available: room, fixed: fixed, units: units, gaps: gaps)
        return TabStripLayout(pinnedRoom: pinnedRoom, tabWidth: w,
                              overflows: TabBarRules.overflows(available: room, fixed: fixed, units: units, gaps: gaps))
    }

    @MainActor
    static func unitCount(_ r: SidebarRef, _ model: BrowserModel) -> Double {
        if case .split = r { return TabBarRules.splitUnits }
        return 1
    }

    @MainActor
    static func pinnedWidth(_ r: SidebarRef, _ model: BrowserModel) -> CGFloat {
        if case .split(let id) = r { return TabBarRules.pinnedWidth * CGFloat(model.split(id)?.count ?? 2) }
        return TabBarRules.pinnedWidth
    }

    /// A split's width: two tabs' worth and the gap between them.
    static func splitWidth(_ tabWidth: CGFloat) -> CGFloat { tabWidth * CGFloat(TabBarRules.splitUnits) + TabBarRules.gap }
}

struct TabStrip: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var state = TabBarState.shared

    var body: some View {
        HStack(spacing: 0) {
            EssentialsBoxSlot()
            TabStripPager(strip: SpaceStrip.of(model))
            NewTabButton()
                .padding(.leading, Theme.Space.xs)
        }
        .padding(.horizontal, Theme.Space.windowMargin)
        // Tabs keep their width while you close them one after another, until the pointer leaves.
        .onHover { state.pointerInStrip($0) }
        .motion(Motion.insert, value: model.essentials.isEmpty)
    }
}

/// One page of tabs per space, side by side. When the space changes, the old tabs slide a little
/// and fade while the new ones come in, following the fingers during a swipe over the toolbar.
struct TabStripPager: View {
    @ObservedObject var strip: SpaceStrip
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .topLeading) {
                ForEach(strip.visibleSlots, id: \.id) { item in
                    let d = CGFloat(item.slot) - CGFloat(strip.position)
                    TabStripPage(spaceID: item.id, available: w)
                        .frame(width: w, height: g.size.height)
                        .offset(x: d * min(w, 360) * 0.5)
                        .opacity(max(0, 1 - abs(Double(d)) * 1.5))
                        .allowsHitTesting(item.id == model.currentSpaceID && abs(d) < 0.5)
                }
            }
            .frame(width: w, height: g.size.height, alignment: .topLeading)
            .clipped()
        }
        .opacity(strip.listOpacity)
    }
}

/// Whether there's more of the strip off either edge, for the fades, and how far it can scroll.
private struct ScrollEdges: Equatable {
    var leading = false
    var trailing = false
    var offset: CGFloat = 0
    var maxOffset: CGFloat = 0
    var width: CGFloat = 0
}

/// Turns a vertical scroll over the row of tabs into a sideways one, so a mouse wheel scrolls the
/// tabs, as in Chrome and Firefox. A sideways trackpad scroll is left to the scroll view itself.
struct StripWheel: NSViewRepresentable {
    /// Takes the vertical travel in points and whether it came from a wheel. Returns true if it scrolled.
    let onScroll: @MainActor (CGFloat, Bool) -> Bool

    final class WheelView: NSView {
        var onScroll: (@MainActor (CGFloat, Bool) -> Bool)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
                MainActor.assumeIsolated {
                    guard let self, let w = self.window, e.window === w, !self.isHiddenOrHasHiddenAncestor,
                          self.bounds.contains(self.convert(e.locationInWindow, from: nil)),
                          abs(e.scrollingDeltaY) > abs(e.scrollingDeltaX) * 1.2, e.scrollingDeltaY != 0, e.momentumPhase.isEmpty || e.hasPreciseScrollingDeltas
                    else { return e }
                    let wheel = !e.hasPreciseScrollingDeltas
                    let dy = wheel ? e.scrollingDeltaY * 14 : e.scrollingDeltaY
                    return (self.onScroll?(dy, wheel) ?? false) ? nil : e
                }
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }

    func makeNSView(context: Context) -> WheelView {
        let v = WheelView()
        v.onScroll = onScroll
        return v
    }
    func updateNSView(_ v: WheelView, context: Context) { v.onScroll = onScroll }
}

/// One space's tabs.
struct TabStripPage: View {
    let spaceID: UUID
    let available: CGFloat
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var state = TabBarState.shared
    @ObservedObject private var drag = SidebarDrag.shared
    @State private var edges = ScrollEdges()
    @State private var endTargeted = false
    @State private var position = ScrollPosition(edge: .leading)

    var isCurrent: Bool { model.currentSpaceID == spaceID }

    /// The item on screen: a split, or a tab.
    var selectedRef: SidebarRef? {
        guard isCurrent else { return model.rememberedSelection(of: spaceID) }
        if let s = model.currentSplit { return .split(s.id) }
        return model.currentTab.map { .tab($0.id) }
    }

    var body: some View {
        let rows = model.barRows(space: spaceID)
        let layout = TabStripLayout.measure(model, space: spaceID, available: available, frozen: isCurrent ? state.frozenTabWidth : nil)
        let sel = selectedRef
        let dragging = !drag.dragging.isEmpty && isCurrent
        HStack(spacing: 0) {
            // Pinned tabs stay put at the start, like Safari's, and only the rest scrolls.
            if !rows.pinned.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: TabBarRules.gap) {
                        ForEach(rows.pinned, id: \.self) { r in
                            TabBarItem(ref: r, place: .pinned, tabWidth: layout.tabWidth)
                        }
                    }
                    .padding(.vertical, (TabBarMetrics.stripHeight - TabBarMetrics.itemHeight) / 2)
                }
                .scrollIndicators(.never)
                .scrollDisabled(layout.pinnedRoom < available * TabStripLayout.pinnedShare + TabBarRules.dividerRoom - 0.5)
                .frame(width: layout.pinnedRoom - TabBarRules.dividerRoom)
                .motion(Motion.insert, value: rows.pinned)
            } else if dragging {
                PinDropWell().transition(.opacity)
            }
            if !rows.pinned.isEmpty || dragging {
                TabBarDivider()
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: TabBarRules.gap) {
                        ForEach(rows.folders) { f in
                            TabBarFolderGroup(folder: f, tabWidth: layout.tabWidth)
                        }
                        if !rows.folders.isEmpty && !rows.today.isEmpty {
                            Color.clear.frame(width: TabBarRules.groupGap - TabBarRules.gap, height: 1)
                        }
                        ForEach(Array(rows.today.enumerated()), id: \.element) { i, r in
                            TabBarItem(ref: r, place: .today, tabWidth: layout.tabWidth,
                                       separator: i > 0 && r != sel && rows.today[i - 1] != sel)
                        }
                    }
                    .padding(.vertical, (TabBarMetrics.stripHeight - TabBarMetrics.itemHeight) / 2)
                    .frame(minWidth: max(0, available - layout.pinnedRoom - (dragging && rows.pinned.isEmpty ? TabBarRules.pinnedWidth + TabBarRules.dividerRoom : 0)),
                           alignment: .leading)
                    .background(endZone)
                    .motion(Motion.insert, value: rows.today)
                    .motion(Motion.expand, value: rows.folders.map(\.isExpanded))
                    .motion(Motion.insert, value: layout.tabWidth)
                }
                .scrollIndicators(.never)
                .scrollPosition($position)
                .onScrollGeometryChange(for: ScrollEdges.self) { g in
                    ScrollEdges(leading: g.contentOffset.x > 1,
                                trailing: g.contentOffset.x + g.containerSize.width < g.contentSize.width - 1,
                                offset: g.contentOffset.x, maxOffset: max(0, g.contentSize.width - g.containerSize.width),
                                width: g.containerSize.width)
                } action: { _, new in edges = new }
                .background(StripWheel { dy, wheel in
                    guard isCurrent, edges.maxOffset > 0 else { return false }
                    let x = min(edges.maxOffset, max(0, edges.offset - dy))
                    if wheel { Motion.run(Motion.hover) { position.scrollTo(x: x) } } else { position.scrollTo(x: x) }
                    return true
                })
                .mask(edgeFade)
                .overlay { edgeClicks }
                .onAppear { if let sel { proxy.scrollTo(sel) } }
                // Keep the tab you're on in view when it changes, and when the room changes.
                .onChange(of: sel) { _, new in
                    guard let new, isCurrent else { return }
                    Motion.run(Motion.insert) { proxy.scrollTo(new) }
                }
                .onChange(of: available) { _, _ in if let sel, isCurrent { proxy.scrollTo(sel) } }
                .onChange(of: rows.folders.map(\.isExpanded)) { _, _ in
                    guard let sel, isCurrent else { return }
                    DispatchQueue.main.async { Motion.run(Motion.insert) { proxy.scrollTo(sel) } }
                }
            }
        }
        .environment(\.pageSelection, isCurrent ? nil : model.rememberedSelection(of: spaceID))
    }

    /// Soft edges where tabs run off the strip.
    private var edgeFade: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0), .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: edges.leading ? TabBarRules.edgeFade : 0)
            Color.black
            LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .leading, endPoint: .trailing)
                .frame(width: edges.trailing ? TabBarRules.edgeFade : 0)
        }
        .motion(Motion.hover, value: [edges.leading, edges.trailing], fadeOnly: true)
    }

    /// A click at an edge with more tabs past it pages the strip by a view's width, keeping one
    /// tab in sight, like Safari and Chrome.
    private var edgeClicks: some View {
        HStack(spacing: 0) {
            if edges.leading { pageZone(-1) }
            Spacer(minLength: 0)
            if edges.trailing { pageZone(1) }
        }
    }

    private func pageZone(_ step: CGFloat) -> some View {
        Color.clear
            .frame(width: TabBarRules.edgeClick)
            .contentShape(Rectangle())
            .onTapGesture {
                let x = min(edges.maxOffset, max(0, edges.offset + step * max(40, edges.width - TabBarRules.pageOverlap)))
                Motion.run(.easeOut(duration: 0.3)) { position.scrollTo(x: x) }
            }
            .help(step < 0 ? "Earlier tabs" : "Later tabs")
    }

    /// The strip's empty space: double-click for a new tab, as in Safari, drag to move the
    /// window, and drop a tab here to make it the newest.
    private var endZone: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.newTabCommand() }
            .gesture(WindowDragGesture())
            .onDrop(of: [ItemDrag.type], isTargeted: $endTargeted) { providers in
                ItemDrag.loadItems(providers) { items in
                    let refs = items.compactMap(\.sidebarRef)
                    SidebarDrag.shared.land(refs.first) { model.place(refs, in: .today, at: 0) }
                }
            }
            .contextMenu { NewTabMenu() }
    }
}

/// The line between pinned tabs and folders, and the other tabs. Drop a tab on it to pin it.
struct TabBarDivider: View {
    @EnvironmentObject var model: BrowserModel
    @State private var targeted = false

    var body: some View {
        Capsule()
            .fill(targeted ? Color.accentColor : Color.primary.opacity(0.18))
            .frame(width: targeted ? 2 : 1, height: 16)
            .frame(width: TabBarRules.dividerRoom, height: TabBarMetrics.itemHeight)
            .contentShape(Rectangle())
            .onDrop(of: [ItemDrag.type], isTargeted: $targeted) { providers in
                ItemDrag.loadItems(providers) { items in
                    let refs = items.compactMap(\.sidebarRef)
                    SidebarDrag.shared.land(refs.first) { model.place(refs, in: .pinned, at: Int.max) }
                }
            }
            .motion(Motion.hover, value: targeted)
            .help("Drop a tab on the line to pin it")
            .accessibilityHidden(true)
    }
}

/// With nothing pinned in this space, a drag shows where a pinned tab would go.
struct PinDropWell: View {
    @EnvironmentObject var model: BrowserModel
    @State private var targeted = false

    var body: some View {
        Image(systemName: "pin")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(targeted ? .primary : .secondary)
            .frame(width: TabBarRules.pinnedWidth, height: TabBarMetrics.itemHeight)
            .background(Theme.Radius.shape(Theme.Radius.row)
                .strokeBorder(Theme.Palette.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .background(Theme.Radius.shape(Theme.Radius.row).fill(targeted ? Theme.Palette.rowHover : .clear)))
            .onDrop(of: [ItemDrag.type], isTargeted: $targeted) { providers in
                ItemDrag.loadItems(providers) { items in
                    let refs = items.compactMap(\.sidebarRef)
                    SidebarDrag.shared.land(refs.first) { model.place(refs, in: .pinned, at: Int.max) }
                }
            }
            .help("Drop here to pin")
    }
}

/// The plus at the end of the row: a new tab, or from its menu a note or a folder.
struct NewTabButton: View {
    @EnvironmentObject var model: BrowserModel
    var body: some View {
        IconButton(symbol: "plus", help: "New tab (Cmd-T)", width: 30, height: TabBarMetrics.itemHeight, symbolSize: 13) {
            model.newTabCommand()
        }
        .contextMenu { NewTabMenu() }
    }
}

struct NewTabMenu: View {
    @EnvironmentObject var model: BrowserModel
    var body: some View {
        Button("New tab") { model.newTabCommand() }
        Button("New note") { model.newNote() }
        Button("New folder...") { model.promptNewFolder() }
        Divider()
        Button("Clear tabs") { TodaySweep.shared.run { _ = model.clearToday() } }
            .disabled(model.refs(in: .today).isEmpty)
        Divider()
        TabModeItems()
    }
}

/// The three ways to show tabs, with a check on the one showing. The right-click menu on the
/// sidebar, the icon column and the tab bar all end with these, so you can get from any of them
/// to any other.
struct TabModeItems: View {
    @ObservedObject private var prefs = BrowserPrefs.shared
    var body: some View {
        Section("Show Tabs") {
            ForEach(TabMode.allCases, id: \.self) { mode in
                Toggle(mode.title, isOn: Binding(get: { TabMode.of(prefs.value) == mode },
                                                 set: { if $0 { TabMode.set(mode) } }))
            }
        }
    }
}

// MARK: - Items

/// One item in the strip, with the drops that land beside it or, held over a tab's middle, split
/// with it.
struct TabBarItem: View {
    let ref: SidebarRef
    let place: TabBarPlace
    let tabWidth: CGFloat
    var separator = false
    @EnvironmentObject var model: BrowserModel
    @ObservedObject private var drag = SidebarDrag.shared
    @State private var indicator: TabBarDropIndicator?
    @State private var clock = HoverClock()

    var width: CGFloat {
        switch ref {
        case .tab: return place == .pinned ? TabBarRules.pinnedWidth : tabWidth
        case .split(let id):
            return place == .pinned ? TabBarRules.pinnedWidth * CGFloat(model.split(id)?.count ?? 2) : TabStripLayout.splitWidth(tabWidth)
        }
    }

    var body: some View {
        Group {
            switch ref {
            case .tab(let id):
                if let t = model.tab(id) {
                    if place == .pinned { BarPinnedTab(tab: t, splitting: indicator == .split) }
                    else { BarTab(tab: t, width: tabWidth, splitting: indicator == .split) }
                }
            case .split(let id):
                if let s = model.split(id) { BarSplit(split: s, width: width, compact: place == .pinned) }
            }
        }
        .overlay(alignment: .leading) {
            if separator && indicator == nil {
                Rectangle().fill(Theme.Palette.hairline).frame(width: 1, height: 14)
                    .offset(x: -(TabBarRules.gap / 2) - 0.5)
                    .allowsHitTesting(false)
            }
        }
        .sidebarCursor(model.sidebarCursor == .row(ref))
        .opacity(drag.dragging.contains(ref.id) ? SidebarDrag.dimmed : 1)
        // While a tab is dragged over this one, a gap opens where it would land.
        .padding(.leading, indicator == .before ? TabBarMetrics.dropGap : 0)
        .padding(.trailing, indicator == .after ? TabBarMetrics.dropGap : 0)
        .motion(Motion.insert, value: indicator)
        .onDrop(of: [ItemDrag.type], delegate: TabBarDropDelegate(ref: ref, width: width, canSplit: { if case .tab = ref { return true }; return false }(),
                                                                  reversed: place == .today, model: model, indicator: $indicator, clock: clock))
        .id(ref)
        .transition(TabBarTransitions.item)
    }
}

/// A middle click on a view, for closing a tab the way Chrome and Firefox do. SwiftUI has no
/// gesture for the middle button, so a quiet view watches for it over its own bounds.
struct MiddleClick: NSViewRepresentable {
    let action: @MainActor () -> Void

    final class ClickView: NSView {
        var action: (@MainActor () -> Void)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { [weak self] e in
                MainActor.assumeIsolated {
                    guard let self, e.buttonNumber == 2, let w = self.window, e.window === w, !self.isHiddenOrHasHiddenAncestor,
                          self.bounds.contains(self.convert(e.locationInWindow, from: nil)) else { return e }
                    self.action?()
                    return nil
                }
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }

    func makeNSView(context: Context) -> ClickView {
        let v = ClickView()
        v.action = action
        return v
    }
    func updateNSView(_ v: ClickView, context: Context) { v.action = action }
}

enum TabBarTransitions {
    /// A tab opening grows in from its leading edge, and closing shrinks it away.
    static var item: AnyTransition {
        if Motion.suppressed { return .identity }
        if Motion.reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.6, anchor: .leading)).animation(Motion.insert),
            removal: .opacity.combined(with: .scale(scale: 0.6, anchor: .leading)).animation(Motion.remove))
    }
}

/// Drops beside an item: its left half lands before it and its right half after it, and half a
/// second over a tab's middle makes a split with it, like the sidebar.
struct TabBarDropDelegate: DropDelegate {
    let ref: SidebarRef
    let width: CGFloat
    let canSplit: Bool
    /// Other tabs show newest last, the other way round from the sidebar, so before and after swap.
    let reversed: Bool
    let model: BrowserModel
    @Binding var indicator: TabBarDropIndicator?
    let clock: HoverClock

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [ItemDrag.type]) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // With a gap open before the item, the item itself starts after it.
        let x = info.location.x - (indicator == .before ? TabBarMetrics.dropGap : 0)
        let middle = canSplit && x > width * 0.3 && x < width * 0.7
        if middle {
            if clock.enteredMiddleAt == nil {
                let started = Date()
                clock.enteredMiddleAt = started
                let binding = $indicator
                let c = clock
                DispatchQueue.main.asyncAfter(deadline: .now() + RowDropDelegate.holdToSplit) {
                    if c.enteredMiddleAt == started { c.armed = true; binding.wrappedValue = .split }
                }
            }
            if !clock.armed { indicator = x < width / 2 ? .before : .after }
        } else {
            clock.reset()
            indicator = x < width / 2 ? .before : .after
        }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        clock.reset()
        indicator = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let split = clock.armed
        let after = indicator == .after
        clock.reset()
        indicator = nil
        let target = ref
        let flip = reversed
        return ItemDrag.loadItems(info.itemProviders(for: [ItemDrag.type])) { items in
            let refs = items.compactMap(\.sidebarRef)
            SidebarDrag.shared.land(refs.first) {
                if split, refs.count == 1, case .tab(let id) = refs[0] {
                    model.dropForSplit(id, onto: target.id)
                } else {
                    model.place(refs, next: target, after: flip ? TabBarRules.todayDrop(displayAfter: after) : after)
                }
            }
        }
    }
}

/// A tab: its icon, title, a sound button while it plays, and a close button on hover.
struct BarTab: View {
    @ObservedObject var tab: Tab
    let width: CGFloat
    var splitting = false
    @EnvironmentObject var model: BrowserModel
    @State private var hovering = false
    @Environment(\.spaceAccent) private var spaceAccent
    @Environment(\.pageSelection) private var pageSelection

    var body: some View {
        let selected = model.isSelected(tab) || splitting || pageSelection == .tab(tab.id)
        let roomy = width >= TabBarRules.titleNeeds
        HStack(spacing: Theme.Space.s + 1) {
            // On hover a close button opens its own slot at the leading edge, like Safari, and the
            // icon moves over for it rather than turning into it. Loading shows as a soft fade of
            // the icon, as in the sidebar.
            if hovering {
                IconButton(symbol: "xmark", help: tab.folderID != nil ? "Unload. Option-click to close the other tabs." : "Close (Cmd-W). Option-click to close the other tabs.",
                           width: 16, height: 16, symbolSize: 8) { closeTab() }
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
            ItemIcon(tab: tab, size: 16)
                .opacity(tab.isLoading ? 0.45 : 1)
                .motion(Motion.hover, value: tab.isLoading, fadeOnly: true)
                .frame(width: 16)
            if roomy {
                Text(tab.displayTitle)
                    .font(Theme.Font.secondary)
                    .lineLimit(1)
                    .strikethrough(tab.isMissing, color: .secondary)
                    .foregroundStyle(tab.isMissing ? AnyShapeStyle(.secondary)
                                     : (tab.isLoaded || tab.kind != .web || selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(0.72))))
            }
            if model.peek?.parentID == tab.id {
                Theme.Radius.shape(2).strokeBorder(Color.secondary, lineWidth: 1).frame(width: 8, height: 8).help("Peek is open from this tab")
            }
            if splitting {
                Text("Split").font(Theme.Font.action).foregroundStyle(spaceAccent)
            }
            Spacer(minLength: 0)
            if tab.mediaPlaying || tab.isMuted {
                IconButton(symbol: tab.isMuted ? "speaker.slash" : "speaker.wave.2", help: tab.isMuted ? "Unmute" : "Mute",
                           width: 18, height: 18, symbolSize: 9) { model.toggleMute(tab) }
            }
        }
        .padding(.leading, hovering ? Theme.Space.xs : Theme.Space.m)
        .padding(.trailing, Theme.Space.s)
        .frame(width: width, height: TabBarMetrics.itemHeight, alignment: .leading)
        .clipped()
        .motion(Motion.hover, value: hovering)
        .modifier(RowBackground(selected: selected, hovering: hovering, multi: model.multiSelection.contains(tab.id)))
        .background(MiddleClick { closeTab(others: false) })
        .contentShape(Rectangle())
        .onTapGesture { TabClick.perform(tab, model: model) }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if !NSEvent.modifierFlags.contains(.command) && !NSEvent.modifierFlags.contains(.shift) { model.promptRenameTab(tab) }
        })
        .onHover { hovering = $0 }
        .onDrag {
            let picked = model.multiSelection.contains(tab.id) && model.multiSelection.count > 1
            let ids = picked ? model.multiSelectedTabs.map { $0.id } : [tab.id]
            SidebarDrag.shared.begin(ids)
            return ItemDrag.provider(ids: ids)
        }
        .contextMenu { TabMenu(tab: tab) }
        .help(tab.isWeb ? "\(tab.displayTitle)\n\(tab.url.map { Snippet.prettyURL($0.absoluteString) } ?? "")" : tab.displayTitle)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.displayTitle)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// Closes the tab, or with Option held, the space's other loose tabs. The rest keep their
    /// width until the pointer leaves the strip.
    func closeTab(others: Bool? = nil) {
        if others ?? NSEvent.modifierFlags.contains(.option) {
            model.closeOtherTabs(keeping: tab)
            return
        }
        TabBarState.shared.holdWidths(width)
        tab.kind == .web ? model.close(tab) : model.remove(tab)
    }
}

/// A pinned tab: only its icon, on a tile, like Safari's pinned tabs. Its title is in the tooltip.
struct BarPinnedTab: View {
    @ObservedObject var tab: Tab
    var splitting = false
    @EnvironmentObject var model: BrowserModel
    @State private var hovering = false
    @Environment(\.pageSelection) private var pageSelection

    var body: some View {
        let selected = model.isSelected(tab) || splitting || pageSelection == .tab(tab.id)
        ZStack(alignment: .topTrailing) {
            ItemIcon(tab: tab, size: 16)
                .opacity(tab.isLoaded || tab.isNote || tab.isApp || selected ? 1 : 0.7)
                .opacity(tab.isLoading ? 0.45 : 1)
                .frame(width: TabBarRules.pinnedWidth, height: TabBarMetrics.itemHeight)
                .modifier(RowBackground(selected: selected, hovering: hovering, multi: model.multiSelection.contains(tab.id)))
            if tab.isAwayFromPin {
                Circle().fill(Color.secondary).frame(width: 4, height: 4).padding(4)
                    .help("Away from its pinned page. Double-click to go back.")
            }
            if tab.mediaPlaying || tab.isMuted {
                Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 7)).foregroundStyle(.secondary).padding(3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .frame(width: TabBarRules.pinnedWidth, height: TabBarMetrics.itemHeight)
        .background(MiddleClick { model.close(tab) })
        .contentShape(Rectangle())
        .onTapGesture { TabClick.perform(tab, model: model) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { if tab.isAwayFromPin { model.resetPinned(tab) } })
        .onHover { hovering = $0 }
        .onDrag {
            let picked = model.multiSelection.contains(tab.id) && model.multiSelection.count > 1
            let ids = picked ? model.multiSelectedTabs.map { $0.id } : [tab.id]
            SidebarDrag.shared.begin(ids)
            return ItemDrag.provider(ids: ids)
        }
        .contextMenu { TabMenu(tab: tab) }
        // Only its icon shows, so its name and site come up in a card under it.
        .hoverCard(tab)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A split: its panes side by side on one chip, joined by a hairline, the way the sidebar shows a
/// split as one row. Click a pane to focus it. Pinned, it shows only the panes' icons.
struct BarSplit: View {
    let split: SplitRecord
    let width: CGFloat
    var compact = false
    @EnvironmentObject var model: BrowserModel
    @State private var hovering = false
    @Environment(\.pageSelection) private var pageSelection

    var selected: Bool { model.currentSplit?.id == split.id || pageSelection == .split(split.id) }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(split.items.enumerated()), id: \.element) { i, id in
                if i > 0 { Rectangle().fill(Theme.Palette.hairline).frame(width: 1, height: 14) }
                Group {
                    if compact {
                        ItemIcon(tab: model.tab(id), size: 14).frame(maxWidth: .infinity)
                    } else {
                        SplitHalf(tab: model.tab(id), focused: selected && split.focused == id, compact: split.count > 2, showClose: hovering) {
                            if let t = model.tab(id) { model.selectSplit(split, focusItem: id); model.focusPane(item: t.id); model.closeCurrent() }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { model.selectSplit(split, focusItem: id) }
            }
        }
        .frame(width: width, height: TabBarMetrics.itemHeight)
        .modifier(RowBackground(selected: selected, hovering: hovering, multi: split.items.allSatisfy { model.multiSelection.contains($0) }))
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().modifiers(.option).onEnded { model.separate(split) })
        .onHover { hovering = $0 }
        .onDrag { SidebarDrag.shared.begin([split.id]); return ItemDrag.provider(split: split.id) }
        .contextMenu { SplitMenu(split: split) }
        .help(split.items.compactMap { model.tab($0)?.displayTitle }.joined(separator: " | "))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Split view")
    }
}

/// A folder: its chip, then its tabs while it's open, with a line in the space's colour under
/// them, like Chrome's tab groups. Closed, it keeps showing the tab that's on screen, like the
/// sidebar.
struct TabBarFolderGroup: View {
    let folder: Folder
    let tabWidth: CGFloat
    @EnvironmentObject var model: BrowserModel
    @Environment(\.spaceAccent) private var accent

    var body: some View {
        let rows = model.barRows(folder: folder)
        HStack(spacing: TabBarRules.gap) {
            BarFolderChip(folder: folder)
            ForEach(rows, id: \.self) { r in
                TabBarItem(ref: r, place: .folder, tabWidth: tabWidth)
            }
        }
        .background(alignment: .bottom) {
            if folder.isExpanded && !rows.isEmpty {
                Capsule().fill(accent.opacity(0.55)).frame(height: 2)
                    .padding(.horizontal, Theme.Space.s)
                    .offset(y: 3)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .motion(Motion.insert, value: rows)
    }
}

struct BarFolderChip: View {
    let folder: Folder
    @EnvironmentObject var model: BrowserModel
    @State private var hovering = false
    @State private var targeted = false

    static let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let maxName: CGFloat = 120

    /// The chip's width, so the strip can share out the rest of the room before drawing.
    static func width(_ f: Folder, count: Int) -> CGFloat {
        let name = min(maxName, ceil((f.name as NSString).size(withAttributes: [.font: font]).width))
        let badge = f.isExpanded ? 0 : ceil(("\(count)" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width) + Theme.Space.s
        return Theme.Space.m * 2 + 16 + Theme.Space.s + name + badge
    }

    var body: some View {
        let count = model.tabs(in: folder).count
        HStack(spacing: Theme.Space.s) {
            FolderGlyph(isOpen: folder.isExpanded, size: 16)
            Text(folder.name)
                .font(Theme.Font.secondary.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: Self.maxName, alignment: .leading)
            if !folder.isExpanded {
                Text("\(count)").font(Theme.Font.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(width: Self.width(folder, count: count), height: TabBarMetrics.itemHeight)
        .modifier(RowBackground(selected: targeted, hovering: hovering))
        .sidebarCursor(model.sidebarCursor == .folder(folder.id))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(FolderMotion.toggle) { model.toggleFolder(folder) } }
        .onHover { hovering = $0 }
        .onDrag { ItemDrag.provider(folder: folder.id) }
        .onDrop(of: [ItemDrag.type], isTargeted: $targeted) { providers in
            ItemDrag.loadItems(providers) { items in
                if case .folder(let fid)? = items.first {
                    model.placeFolder(fid, next: folder.id, after: false)
                } else {
                    let refs = items.compactMap(\.sidebarRef)
                    SidebarDrag.shared.land(refs.first) { model.place(refs, in: .folder(folder.id), at: Int.max) }
                }
            }
        }
        .contextMenu {
            Button(folder.isExpanded ? "Close folder" : "Open folder") { withAnimation(FolderMotion.toggle) { model.toggleFolder(folder) } }
            Button("Rename...") { model.promptRename(folder) }
            Button("Delete folder") { model.deleteFolder(folder) }
        }
        .help(folder.isExpanded ? folder.name : "\(folder.name), \(count) tabs. Click to open.")
        .accessibilityLabel("Folder \(folder.name)")
        .accessibilityAddTraits(.isButton)
    }
}
