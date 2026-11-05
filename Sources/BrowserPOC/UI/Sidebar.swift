import AppKit
import SwiftUI

struct LeftSidebar: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var settings = Settings.shared

    @State private var addressHover = false

    var body: some View {
        let strip = SpaceStrip.of(model)
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            topBar
            addressField
            EssentialsGrid()
            // One page per space, side by side. A swipe drags them under the fingers, and clicks
            // and shortcuts slide them. Essentials, the address and the bottom bar stay still,
            // the way Arc keeps its Favorites still. Pages run to the sidebar's edges.
            SpacePager(strip: strip) { id in
                SpacePage(spaceID: id)
                    .padding(.horizontal, Theme.Space.sidebarInset)
            }
            .padding(.horizontal, -Theme.Space.sidebarInset)
            MediaBar()
            bottomBar
        }
        .padding(.horizontal, Theme.Space.sidebarInset)
        .background(SpaceSwipeTracker(model: model))
    }

    // MARK: Top

    private var topBar: some View {
        HStack(spacing: 2) {
            WindowDragArea()
            if let tab = model.currentTab, tab.kind == .web {
                NavControls(tab: tab)
            } else {
                NavButton(symbol: "chevron.left", help: "Back") {}.disabled(true)
                NavButton(symbol: "chevron.right", help: "Forward") {}.disabled(true)
                NavButton(symbol: "arrow.clockwise", help: "Reload") {}.disabled(true)
            }
            RelatedToggleButton()
        }
        // Matches the title bar, so these buttons share a row with the traffic lights.
        .frame(height: Theme.Space.titleBarHeight)
    }

    /// Shows the focused page's address. Clicking it opens the command bar, like Cmd-L.
    private var addressField: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(model.addressText.isEmpty ? "Search or enter address" : Snippet.prettyURL(model.addressText))
                .font(Theme.Font.row)
                .foregroundStyle(model.addressText.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if model.currentTab?.url != nil, model.currentTab?.isApp == false {
                IconButton(symbol: "link", help: "Copy link (Shift-Cmd-C)", width: 20, height: 20, symbolSize: 10) { model.copyCurrentURL() }
                    .opacity(addressHover ? 1 : 0)
                    .motion(Motion.hover, value: addressHover, fadeOnly: true)
            }
        }
        .padding(.leading, Theme.Space.l - 2)
        .padding(.trailing, Theme.Space.xs)
        .frame(height: 32)
        .background(Theme.Radius.shape(Theme.Radius.row).fill(addressHover ? Theme.Palette.fieldHover : Theme.Palette.field))
        // The command bar grows out of here for Cmd-L, so it needs to know where the field is.
        .background(AddressFieldFrame())
        .contentShape(Rectangle())
        .onTapGesture { model.focusAddress() }
        .onHover { addressHover = $0 }
        .motion(Motion.hover, value: addressHover, fadeOnly: true)
        .help(model.addressText)
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if let msg = model.flashMessage {
                Text(msg)
                    .font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.horizontal, Theme.Space.rowInset)
                    .transition(.opacity)
            }
            HStack(spacing: 2) {
                SmallIconButton(symbol: "gearshape", help: "Settings") { AppDelegate.shared?.openSettings() }
                SmallIconButton(symbol: "clock", help: "History (Cmd-Y)") { model.openAppPage("history") }
                SmallIconButton(symbol: GraphTab.icon, help: "Graph (Cmd-Option-G)") { model.openGraph() }
                DownloadsButton()
                Spacer(minLength: Theme.Space.m)
                SpaceBar()
            }
            .frame(height: 32)
        }
        .motion(Motion.hover, value: model.flashMessage, fadeOnly: true)
        .padding(.bottom, Theme.Space.m)
    }
}

/// One space's page in the sidebar's strip: its name, pins, folders and tabs. Only the current
/// space's page takes clicks and drops. The others show while the strip moves.
struct SpacePage: View {
    let spaceID: UUID
    @EnvironmentObject var model: BrowserModel
    /// Rows are matched by item across sections, so pinning, unpinning or moving a tab into a
    /// folder glides the row to its new place instead of cutting, and a closed folder's visible
    /// tab keeps its place while the rest of the folder slides away.
    @Namespace private var rowSpace

    var isCurrent: Bool { model.currentSpaceID == spaceID }

    @ObservedObject private var drag = SidebarDrag.shared
    @ObservedObject private var sweep = TodaySweep.shared

    private func row(_ ref: SidebarRef) -> some View {
        // A row you dropped lands in the gap it was dropped in, so it isn't matched to where it was.
        let id: AnyHashable = drag.landing == ref ? AnyHashable("landing") : AnyHashable(ref)
        return SidebarRow(ref: ref).matchedGeometryEffect(id: id, in: rowSpace)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SpaceHeader(spaceID: spaceID)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.sectionGap) {
                    pinnedSection
                    foldersSection
                    tabsSection
                }
                .padding(.bottom, Theme.Space.l)
                // A folder opening or closing moves everything below it on the same spring.
                .motion(Motion.expand, value: model.folders(in: spaceID).map { $0.isExpanded })
            }
            .scrollIndicators(.never)
        }
        .environment(\.pageSelection, isCurrent ? nil : model.rememberedSelection(of: spaceID))
        .allowsHitTesting(isCurrent)
    }

    // MARK: Sections

    private var pinnedSection: some View {
        let rows = model.refs(in: .pinned, space: spaceID)
        // Like Zen, pins sit under the space's name with no label, and a hairline closes them off.
        return SectionBox(title: rows.isEmpty ? "Pinned" : "", onDropItems: { items in model.place(items.compactMap(\.sidebarRef), in: .pinned, at: Int.max) }) {
            if rows.isEmpty {
                Text("Drag tabs here to pin them")
                    .font(Theme.Font.secondary).foregroundStyle(.secondary)
                    .padding(.leading, Theme.Space.rowInset).frame(height: 24)
            }
            ForEach(rows, id: \.self) { row($0).transition(Motion.Transitions.tabRow) }
            if !rows.isEmpty { SectionDivider() }
        }
        .motion(Motion.insert, value: rows)
    }

    private var foldersSection: some View {
        SectionBox(title: "Folders", trailing: AnyView(SmallIconButton(symbol: "plus", help: "New folder") { model.promptNewFolder() })) {
            ForEach(model.folders(in: spaceID)) { f in
                FolderRow(folder: f)
                FolderReveal(isOpen: f.isExpanded) {
                    VStack(spacing: Theme.Space.rowGap) {
                        let rows = model.refs(in: .folder(f.id))
                        ForEach(rows, id: \.self) { row($0).transition(Motion.Transitions.tabRow) }
                        if rows.isEmpty {
                            Text("Empty")
                                .font(Theme.Font.secondary).foregroundStyle(.secondary)
                                .padding(.leading, Theme.Space.rowInset).frame(height: 24)
                        }
                    }
                    .padding(.top, Theme.Space.rowGap)
                    // Child icons line up under the folder's name.
                    .padding(.leading, Theme.Space.folderIndent)
                }
                if !f.isExpanded {
                    // A closed folder still shows what's on screen, like Arc and Zen.
                    let shown = model.shownInClosedFolder(f)
                    if !shown.isEmpty {
                        VStack(spacing: Theme.Space.rowGap) { ForEach(shown, id: \.self) { row($0) } }
                            .padding(.leading, Theme.Space.folderIndent)
                            .transition(.opacity)
                    }
                }
            }
        }
        .motion(Motion.insert, value: model.folders(in: spaceID).map { model.refs(in: .folder($0.id)) })
    }

    private var tabsSection: some View {
        let rows = model.refs(in: .today, space: spaceID)
        let trailing = HStack(spacing: 2) {
            if !rows.isEmpty {
                Button("Clear") { TodaySweep.shared.run { _ = model.clearToday() } }
                    .buttonStyle(QuietActionStyle())
                    .help("Archive every tab here (Shift-Cmd-K)")
                    .padding(.trailing, Theme.Space.xs)
            }
            SmallIconButton(symbol: "square.and.pencil", help: "New note") { model.newNote() }
        }
        return SectionBox(title: "Tabs", trailing: AnyView(trailing), onDropItems: { items in model.place(items.compactMap(\.sidebarRef), in: .today, at: 0) }) {
            Button { model.newTabCommand() } label: {
                HStack(spacing: Theme.Space.rowIconGap) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: Theme.Space.rowIcon)
                    Text("New tab")
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(SidebarActionRowStyle(selected: isCurrent && model.bar.isOpen && model.bar.mode == .newTab))
            // Clear Today sweeps the rows out top to bottom, and Undo brings them back the same way.
            ForEach(Array(rows.enumerated()), id: \.element) { i, r in
                row(r).transition(Motion.Transitions.todayRow(index: i, sweeping: sweep.sweeping))
            }
        }
        .motion(Motion.insert, value: rows)
    }

}

extension DragItem {
    var sidebarRef: SidebarRef? {
        switch self {
        case .tab(let id): return .tab(id)
        case .split(let id): return .split(id)
        case .folder: return nil
        }
    }
}

/// The space's name above its pins. Dropping a tab here with no Essentials yet starts the grid.
struct SpaceHeader: View {
    var spaceID: UUID?
    @EnvironmentObject var model: BrowserModel
    @State private var targeted = false

    var body: some View {
        if let sp = spaceID.flatMap({ id in model.spaces.first { $0.id == id } }) ?? model.currentSpace {
            HStack(spacing: Theme.Space.s) {
                SpaceIcon(icon: sp.icon, size: 11).foregroundStyle(Theme.Palette.accent(sp.color))
                Text(targeted && model.essentials.isEmpty ? "Add to Essentials" : sp.name)
                    .font(Theme.Font.spaceTitle).foregroundStyle(.secondary)
                if let p = sp.profile {
                    Text(p).font(Theme.Font.caption).foregroundStyle(.secondary).opacity(0.8)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.rowInset)
            .padding(.top, Theme.Space.xxs)
            .frame(height: 22)
            .background(Theme.Radius.shape(Theme.Radius.button).fill(targeted && model.essentials.isEmpty ? Theme.Palette.rowHover : .clear))
            .onDrop(of: [ItemDrag.type], isTargeted: $targeted) { providers in
                guard model.essentials.isEmpty else { return false }
                return ItemDrag.load(providers) { ids in model.place(ids.map { .tab($0) }, in: .essentials, at: Int.max) }
            }
        }
    }
}

/// Essentials: a grid of icons shared by every space, like Zen's Essentials and Arc's Favorites.
struct EssentialsGrid: View {
    @EnvironmentObject var model: BrowserModel
    @State private var targeted = false

    var body: some View {
        let items = model.essentials
        if !items.isEmpty {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.s), count: min(4, max(3, items.count))),
                      spacing: Theme.Space.s) {
                ForEach(items) { EssentialTile(tab: $0).transition(Motion.Transitions.tabRow) }
            }
            .padding(.vertical, Theme.Space.xxs)
            .background(Theme.Radius.shape(Theme.Radius.card).fill(targeted ? Theme.Palette.rowHover : .clear))
            .motion(Motion.insert, value: items.map { $0.id })
            .onDrop(of: [ItemDrag.type], isTargeted: $targeted) { providers in
                ItemDrag.load(providers) { ids in model.place(ids.map { .tab($0) }, in: .essentials, at: Int.max) }
            }
        }
    }
}

struct EssentialTile: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var model: BrowserModel
    @State private var hovering = false

    var body: some View {
        let selected = model.isSelected(tab) || model.isVisible(tab)
        ZStack(alignment: .topTrailing) {
            ItemIcon(tab: tab, size: 18)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .opacity(tab.isLoaded || tab.isNote || tab.isApp || selected ? 1 : 0.7)
                .essentialTile(selected: selected, hovering: hovering)
            if tab.isAwayFromPin {
                Circle().fill(Color.secondary).frame(width: 5, height: 5).padding(5).help("Away from its pinned page. Double-click to go back.")
            }
            if tab.mediaPlaying || tab.isMuted {
                Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 8)).foregroundStyle(.secondary).padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .sidebarCursor(model.sidebarCursor == .row(.tab(tab.id)))
        .contentShape(Rectangle())
        .onTapGesture { model.select(tab) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { if tab.isAwayFromPin { model.resetPinned(tab) } })
        .onHover { hovering = $0 }
        .onDrag { ItemDrag.provider(tab.id) }
        .contextMenu { TabMenu(tab: tab) }
        .help(tab.displayTitle)
    }
}

struct SectionBox<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    var onDrop: (([String]) -> Bool)? = nil
    var onDropItems: (([DragItem]) -> Void)? = nil
    @ViewBuilder var content: () -> Content
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.rowGap) {
            if title.isEmpty {
                // No label: a thin drop strip above the rows.
                Theme.Radius.shape(Theme.Radius.xs)
                    .fill(targeted ? Theme.Palette.rowHover : .clear)
                    .frame(height: 4)
                    .modifier(DropModifier(onDrop: onDrop, onDropItems: onDropItems, targeted: $targeted))
            } else {
                SectionHeader(title: title, highlighted: targeted) { trailing ?? AnyView(EmptyView()) }
                    .modifier(DropModifier(onDrop: onDrop, onDropItems: onDropItems, targeted: $targeted))
            }
            content()
        }
    }
}

struct DropModifier: ViewModifier {
    let onDrop: (([String]) -> Bool)?
    var onDropItems: (([DragItem]) -> Void)? = nil
    @Binding var targeted: Bool
    func body(content: Content) -> some View {
        if let onDropItems {
            content.onDrop(of: [ItemDrag.type], isTargeted: $targeted) { providers in
                ItemDrag.loadItems(providers) { items in onDropItems(items) }
            }
        } else if let onDrop {
            content.onDrop(of: [ItemDrag.type], isTargeted: $targeted) { providers in
                ItemDrag.load(providers) { ids in _ = onDrop(ids.map { $0.uuidString }) }
            }
        } else {
            content
        }
    }
}

struct NavControls: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var model: BrowserModel
    var body: some View {
        NavButton(symbol: "chevron.left", help: "Back") { model.goBack() }.disabled(!tab.canGoBack)
        NavButton(symbol: "chevron.right", help: "Forward") { model.goForward() }.disabled(!tab.canGoForward)
        NavButton(symbol: tab.isLoading ? "xmark" : "arrow.clockwise", help: tab.isLoading ? "Stop" : "Reload") {
            if tab.isLoading { tab.webView?.stopLoading() } else { model.reload() }
        }
        .disabled(tab.url == nil)
    }
}

struct NavButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        IconButton(symbol: symbol, help: help, action: action)
    }
}

struct SmallIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        IconButton(symbol: symbol, help: help, width: 24, height: 22, symbolSize: 12, action: action)
    }
}

struct RowBackground: ViewModifier {
    let selected: Bool
    let hovering: Bool
    var multi: Bool = false
    func body(content: Content) -> some View {
        content.sidebarRow(selected: selected, hovering: hovering, multi: multi)
    }
}

/// Where a dragged row would land relative to the row under it.
enum RowDropIndicator { case above, below, split }

/// Times how long a drag hovers over the middle of a row, for hold-to-split.
final class HoverClock {
    var enteredMiddleAt: Date?
    var armed = false
    func reset() { enteredMiddleAt = nil; armed = false }
}

/// Drops on a row reorder, or after half a second over the middle of a tab, make a split with it,
/// like Zen and Arc.
struct RowDropDelegate: DropDelegate {
    let ref: SidebarRef
    let height: CGFloat
    let canSplit: Bool
    let model: BrowserModel
    @Binding var indicator: RowDropIndicator?
    let clock: HoverClock
    static let holdToSplit: TimeInterval = 0.5

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [ItemDrag.type]) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // With a gap open above the row, the row itself starts below it.
        let y = info.location.y - (indicator == .above ? SidebarDrag.gap : 0)
        let middle = canSplit && y > height * 0.25 && y < height * 0.75
        if middle {
            if clock.enteredMiddleAt == nil {
                let started = Date()
                clock.enteredMiddleAt = started
                let binding = $indicator
                let c = clock
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdToSplit) {
                    if c.enteredMiddleAt == started { c.armed = true; binding.wrappedValue = .split }
                }
            }
            if !clock.armed { indicator = y < height / 2 ? .above : .below }
        } else {
            clock.reset()
            indicator = y < height / 2 ? .above : .below
        }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        clock.reset()
        indicator = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let split = clock.armed
        let after = indicator == .below
        clock.reset()
        indicator = nil
        return ItemDrag.loadItems(info.itemProviders(for: [ItemDrag.type])) { items in
            let refs = items.compactMap(\.sidebarRef)
            SidebarDrag.shared.land(refs.first) {
                if split, refs.count == 1, case .tab(let id) = refs[0] {
                    model.dropForSplit(id, onto: ref.id)
                } else {
                    model.place(refs, next: ref, after: after)
                }
            }
        }
    }
}

/// A row in Pinned, Tabs or a folder: a tab or a split, with reorder and split drops.
struct SidebarRow: View {
    let ref: SidebarRef
    @EnvironmentObject var model: BrowserModel
    @State private var indicator: RowDropIndicator?
    @State private var clock = HoverClock()
    @ObservedObject private var drag = SidebarDrag.shared

    /// Where this row shows a gap: the drop hovering it, or the tour's stand-in for one.
    private var gap: RowDropIndicator? { drag.preview.map { $0.ref == ref ? $0.at : nil } ?? indicator }

    var body: some View {
        Group {
            switch ref {
            case .tab(let id): if let t = model.tab(id) { TabRow(tab: t, splitting: indicator == .split) }
            case .split(let id): if let s = model.split(id) { SplitRow(split: s) }
            }
        }
        .sidebarCursor(model.sidebarCursor == .row(ref))
        .opacity(drag.dragging.contains(ref.id) ? SidebarDrag.dimmed : 1)
        // While a row is dragged over this one, a gap opens where it would land and the rows
        // below move down to make room, like Zen and Arc.
        .padding(.top, gap == .above ? SidebarDrag.gap : 0)
        .padding(.bottom, gap == .below ? SidebarDrag.gap : 0)
        .motion(Motion.insert, value: gap)
        .onDrop(of: [ItemDrag.type], delegate: RowDropDelegate(ref: ref, height: Theme.Space.rowHeight, canSplit: { if case .tab = ref { return true }; return false }(),
                                                               model: model, indicator: $indicator, clock: clock))
    }
}

struct TabRow: View {
    @ObservedObject var tab: Tab
    var splitting = false
    @EnvironmentObject var model: BrowserModel
    @State private var hovering = false
    @Environment(\.spaceAccent) private var spaceAccent
    @Environment(\.pageSelection) private var pageSelection

    var body: some View {
        HStack(spacing: Theme.Space.rowIconGap) {
            // The site's icon. Loading shows as a soft fade of the icon rather than a spinner,
            // the way Zen hides the throbber.
            ItemIcon(tab: tab, size: Theme.Space.rowIcon)
                .opacity(tab.isLoading ? 0.45 : 1)
                .motion(Motion.hover, value: tab.isLoading, fadeOnly: true)
            .frame(width: Theme.Space.rowIcon)
            .contentShape(Rectangle())
            .onTapGesture {
                // Arc: the icon of a wandered pin goes back. Cmd-click keeps the page in a new tab.
                if tab.isAwayFromPin {
                    if NSEvent.modifierFlags.contains(.command) { model.separateFromPin(tab) } else { model.resetPinned(tab); model.select(tab) }
                } else {
                    click()
                }
            }
            .help(tab.isAwayFromPin ? "Back to pinned page. Cmd-click to keep this page in a new tab." : "")
            HStack(spacing: 3) {
                Text(tab.displayTitle)
                    .font(Theme.Font.row)
                    .lineLimit(1)
                    .strikethrough(tab.isMissing, color: .secondary)
                    // Pages that aren't loaded are only a little quieter, so a folder of sources
                    // doesn't look half disabled.
                    .foregroundStyle(tab.isMissing ? AnyShapeStyle(.secondary)
                                     : (tab.isLoaded || tab.kind != .web || model.isSelected(tab) ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(0.72))))
                if tab.isAwayFromPin {
                    Text("/").font(Theme.Font.row).foregroundStyle(.secondary).help("This pinned tab has moved away from its pinned page")
                }
            }
            if model.peek?.parentID == tab.id {
                Theme.Radius.shape(2).strokeBorder(Color.secondary, lineWidth: 1).frame(width: 9, height: 9).help("Peek is open from this tab")
            }
            if splitting {
                Text("Split").font(Theme.Font.action).foregroundStyle(spaceAccent)
            }
            if tab.isMissing && hovering {
                Button("Locate") { model.locateNote(tab) }
                    .buttonStyle(QuietActionStyle())
            }
            Spacer(minLength: 0)
            if tab.mediaPlaying || tab.isMuted {
                IconButton(symbol: tab.isMuted ? "speaker.slash" : "speaker.wave.2", help: tab.isMuted ? "Unmute" : "Mute",
                           width: 20, height: 20, symbolSize: 10) { model.toggleMute(tab) }
            }
            // Always laid out, so the title doesn't jump when the close button appears on hover.
            IconButton(symbol: "xmark", help: tab.keepsPinnedURL ? "Back to pinned page and unload" : (tab.folderID != nil ? "Unload" : "Close"),
                       width: 20, height: 20, symbolSize: 9) {
                tab.kind == .web ? model.close(tab) : model.remove(tab)
            }
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .motion(Motion.hover, value: hovering, fadeOnly: true)
        }
        .padding(.leading, Theme.Space.rowInset)
        .padding(.trailing, Theme.Space.xs)
        .frame(height: Theme.Space.rowHeight)
        .modifier(RowBackground(selected: model.isSelected(tab) || splitting || pageSelection == .tab(tab.id), hovering: hovering, multi: model.multiSelection.contains(tab.id)))
        .contentShape(Rectangle())
        .onTapGesture { click() }
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
    }

    /// Plain click selects. Cmd-click and Shift-click pick several. Option-click opens it in split
    /// view with what's on screen, and on the current tab, a copy of it.
    func click() {
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

struct TabMenu: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var model: BrowserModel

    var multi: [Tab] { model.multiSelection.contains(tab.id) && model.multiSelection.count > 1 ? model.multiSelectedTabs : [] }

    var body: some View {
        if multi.count > 1 { multiMenu } else if tab.isNote { noteMenu } else { webMenu }
    }

    @ViewBuilder var multiMenu: some View {
        let n = multi.count
        Button("Open \(n) in split view") { model.split(items: multi.map { $0.id }) }
            .disabled(n > SplitNode.maxPanes)
        Menu("Move \(n) to folder") {
            ForEach(model.spaceFolders) { f in Button(f.name) { model.place(multi.map { .tab($0.id) }, in: .folder(f.id), at: Int.max); model.multiSelection = [] } }
            if !model.spaceFolders.isEmpty { Divider() }
            Button("New folder...") { model.promptNewFolder(moving: tab) }
        }
        Button("Pin \(n)") { model.place(multi.map { .tab($0.id) }, in: .pinned, at: Int.max); model.multiSelection = [] }
        Button("Copy \(n) links") { model.copyMultiSelectedLinks() }
        Divider()
        Button("Close \(n)") { model.closeMultiSelected() }
    }

    @ViewBuilder var splitMenu: some View {
        Button("Open in split view") { model.openInSplit(tab, side: .right) }
            .disabled(model.currentTab?.id == tab.id && model.currentSplit == nil)
        if model.peek == nil, tab.isWeb, let u = tab.url, !model.isVisible(tab) {
            Button("Open in Peek") { model.openPeek(u, from: model.currentTab) }
        }
        MoveToSpaceMenu { id in model.move(tab, toSpace: id) }
    }

    @ViewBuilder var folderMenu: some View {
        if !tab.isEssential {
            Button(tab.isPinned ? "Unpin" : "Pin") { model.togglePin(tab) }
        }
        Button(tab.isEssential ? "Remove from Essentials" : "Add to Essentials") {
            tab.isEssential ? model.removeFromEssentials(tab) : model.addToEssentials(tab)
        }
        .disabled(!tab.isEssential && model.essentials.count >= BrowserModel.essentialsLimit)
        Menu("Move to folder") {
            ForEach(model.spaceFolders) { f in
                Button(f.name) { model.move(tab, to: f.id) }
                    .disabled(tab.folderID == f.id)
            }
            if !model.spaceFolders.isEmpty { Divider() }
            Button("New folder...") { model.promptNewFolder(moving: tab) }
        }
        if tab.folderID != nil || tab.isPinned || tab.isEssential {
            Button("Move to Tabs") { model.move(tab, to: nil) }
        }
    }

    @ViewBuilder var pinMenu: some View {
        if tab.keepsPinnedURL {
            Button("Back to pinned page") { model.resetPinned(tab); model.select(tab) }.disabled(!tab.isAwayFromPin)
            Button("Replace pinned address with this page") { model.replacePinnedURL(tab) }.disabled(!tab.isAwayFromPin)
            Button("Edit pinned address...") { model.promptEditPinnedURL(tab) }
        }
    }

    @ViewBuilder var webMenu: some View {
        splitMenu
        Divider()
        folderMenu
        pinMenu
        Divider()
        Button("Rename...") { model.promptRenameTab(tab) }
        if tab.customTitle != nil { Button("Use page title") { model.rename(tab, to: nil) } }
        Button("Duplicate") { model.duplicate(tab) }
        if tab.isWeb {
            Button(tab.isMuted ? "Unmute" : "Mute") { model.toggleMute(tab) }
        }
        if let u = tab.url, tab.isWeb {
            Button("Copy link") {
                BrowserModel.copyText(CleanURL.strip(u).absoluteString)
                model.toast("Copied link")
            }
        }
        Divider()
        if tab.isLoaded && (tab.isPinned || tab.folderID != nil || tab.isEssential) {
            Button("Unload") { model.close(tab) }
        }
        if !tab.isPinned && !tab.isEssential && tab.folderID == nil {
            Button("Archive") { model.archive(tab) }
        }
        Button(!(tab.isPinned || tab.folderID != nil || tab.isEssential) ? "Close" : "Remove") { model.remove(tab) }
    }

    @ViewBuilder var noteMenu: some View {
        Button("Close") { model.remove(tab) }
        if tab.isMissing {
            Button("Locate...") { model.locateNote(tab) }
        } else {
            Button("Rename...") { model.promptRenameNote(tab) }
            if let u = tab.url { Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
        }
        Divider()
        splitMenu
        folderMenu
        Divider()
        if !tab.isMissing { Button("Delete...") { model.promptDeleteNote(tab) } }
    }
}

struct FolderRow: View {
    let folder: Folder
    @EnvironmentObject var model: BrowserModel
    @State private var hovering = false
    @State private var targeted = false

    var body: some View {
        HStack(spacing: Theme.Space.rowIconGap) {
            // The glyph opens and closes with the folder, like Arc and Zen.
            FolderGlyph(isOpen: folder.isExpanded)
            Text(folder.name).font(Theme.Font.row).lineLimit(1)
            Spacer(minLength: 0)
            Text("\(model.tabs(in: folder).count)")
                .font(Theme.Font.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.Space.rowInset)
        .frame(height: Theme.Space.rowHeight)
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
                    model.place(items.compactMap(\.sidebarRef), in: .folder(folder.id), at: Int.max)
                }
            }
        }
        .contextMenu {
            Button("Rename...") { model.promptRename(folder) }
            Button("Delete folder") { model.deleteFolder(folder) }
        }
    }
}

/// Small controls at the bottom of the sidebar for tabs playing somewhere you're not looking,
/// like Zen's media controller and Arc's audio tray.
struct MediaBar: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        let playing = Array(model.playingElsewhere.prefix(2))
        VStack(spacing: 2) {
            ForEach(playing) { MediaRow(tab: $0) }
        }
        .motion(Motion.insert, value: playing.map(\.id))
    }
}

struct MediaRow: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        HStack(spacing: Theme.Space.rowIconGap) {
            ItemIcon(tab: tab, size: Theme.Space.rowIcon)
            Text(tab.displayTitle).font(Theme.Font.secondary).lineLimit(1)
                .contentShape(Rectangle())
                .onTapGesture { model.select(tab) }
            Spacer(minLength: 0)
            SmallIconButton(symbol: tab.mediaPlaying ? "pause.fill" : "play.fill", help: tab.mediaPlaying ? "Pause" : "Play") { model.togglePlayback(tab) }
            SmallIconButton(symbol: tab.isMuted ? "speaker.slash" : "speaker.wave.2", help: tab.isMuted ? "Unmute" : "Mute") { model.toggleMute(tab) }
        }
        .padding(.leading, Theme.Space.rowInset)
        .padding(.trailing, Theme.Space.xs)
        .frame(height: Theme.Space.rowHeight)
        .background(Theme.Radius.shape(Theme.Radius.row).fill(Theme.Palette.field))
        .transition(Motion.Transitions.tabRow)
        .help("Playing in \(tab.displayTitle). Click the title to go there.")
    }
}

/// The downloads button: a progress ring while something downloads, and the list on click.
struct DownloadsButton: View {
    @ObservedObject var downloads = Downloads.shared
    @Environment(\.spaceAccent) private var spaceAccent
    @EnvironmentObject var model: BrowserModel
    @State private var showing = false

    var body: some View {
        // The button arrives when the first download starts.
        Group {
        if !downloads.items.isEmpty {
            Button { showing.toggle() } label: {
                ZStack {
                    if let p = downloads.overallProgress {
                        Circle().stroke(Theme.Palette.hairline, lineWidth: 1.5).frame(width: 14, height: 14)
                        Circle().trim(from: 0, to: p).stroke(spaceAccent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            .rotationEffect(.degrees(-90)).frame(width: 14, height: 14)
                            .motion(Motion.progress, value: p)
                    }
                    Image(systemName: "arrow.down").font(.system(size: downloads.overallProgress == nil ? 12 : 7, weight: .semibold))
                }
            }
            .buttonStyle(IconButtonStyle(width: 24, height: 22, symbolSize: 12))
            .help("Downloads")
            .popover(isPresented: $showing, arrowEdge: .top) {
                DownloadsList(compact: true).frame(width: 320).padding(10)
            }
            .transition(Motion.Transitions.tabRow)
        }
        }
        .motion(Motion.insert, value: downloads.items.isEmpty)
    }
}
