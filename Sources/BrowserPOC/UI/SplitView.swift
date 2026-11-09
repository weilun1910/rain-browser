import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What a sidebar drag carries. `entry` is a file or folder from the folder popup, by its path.
enum DragItem: Equatable {
    case tab(UUID), split(UUID), folder(UUID), entry(URL)
}

/// Sidebar items drag as an app-only pasteboard type, so web pages and text views don't take the drop.
/// The payload is a tab id, or "split:", "folder:" or "multi:" followed by ids, or "entry:"
/// followed by paths from the folder popup, one per line, as UTF-8.
///
/// The type is declared in Info.plist, and drop targets get it as a `UTType`. Undeclared, its name
/// alone resolves to no type, so every drop target was registered for nothing and AppKit handed
/// drags to none of them. `--drag-probe` checks that drops reach the views.
enum ItemDrag {
    static let identifier = "local.browserpoc.item"
    static let type = UTType(exportedAs: identifier, conformingTo: .data)

    /// The payload as plain bytes, which is what goes on the drag's pasteboard.
    private static func provider(payload: String) -> NSItemProvider {
        let p = NSItemProvider()
        p.registerDataRepresentation(forTypeIdentifier: identifier, visibility: .all) { done in
            done(Data(payload.utf8), nil)
            return nil
        }
        return p
    }

    static func provider(_ id: UUID) -> NSItemProvider { provider(payload: id.uuidString) }
    static func provider(split id: UUID) -> NSItemProvider { provider(payload: "split:\(id.uuidString)") }
    static func provider(folder id: UUID) -> NSItemProvider { provider(payload: "folder:\(id.uuidString)") }
    /// Files and folders from the folder popup.
    static func provider(entries urls: [URL]) -> NSItemProvider { provider(payload: "entry:" + urls.map(\.path).joined(separator: "\n")) }
    /// Several tabs at once, from a multi-selection.
    static func provider(ids: [UUID]) -> NSItemProvider {
        if ids.count == 1 { return provider(ids[0]) }
        return provider(payload: "multi:" + ids.map { $0.uuidString }.joined(separator: ","))
    }

    static func parse(_ s: String) -> [DragItem] {
        if s.hasPrefix("split:") { return UUID(uuidString: String(s.dropFirst(6))).map { [.split($0)] } ?? [] }
        if s.hasPrefix("folder:") { return UUID(uuidString: String(s.dropFirst(7))).map { [.folder($0)] } ?? [] }
        if s.hasPrefix("entry:") {
            return s.dropFirst(6).split(separator: "\n").filter { $0.hasPrefix("/") }.map { .entry(URL(fileURLWithPath: String($0))) }
        }
        if s.hasPrefix("multi:") { return s.dropFirst(6).split(separator: ",").compactMap { UUID(uuidString: String($0)) }.map { .tab($0) } }
        return UUID(uuidString: s).map { [.tab($0)] } ?? []
    }

    /// Every dragged item.
    @discardableResult
    static func loadItems(_ providers: [NSItemProvider], _ done: @escaping @MainActor ([DragItem]) -> Void) -> Bool {
        let ps = providers.filter { $0.hasItemConformingToTypeIdentifier(identifier) }
        guard !ps.isEmpty else { return false }
        let lock = NSLock()
        var items: [DragItem] = []
        let group = DispatchGroup()
        for p in ps {
            group.enter()
            _ = p.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                if let data, let s = String(data: data, encoding: .utf8) {
                    lock.lock(); items.append(contentsOf: parse(s)); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { done(items) } }
        return true
    }

    /// Dragged tabs only, as ids.
    @discardableResult
    static func load(_ providers: [NSItemProvider], _ done: @escaping @MainActor ([UUID]) -> Void) -> Bool {
        loadItems(providers) { items in done(items.compactMap { if case .tab(let id) = $0 { return id }; return nil }) }
    }
}

extension View {
    /// Rounded card for a page or note pane. A split's focused pane gets a quiet ring.
    func paneCard(focusRing: Bool = false) -> some View {
        contentCard(focused: focusRing)
    }
}

/// One pane: a page, a note, a page the app draws, or the start view.
struct PaneView: View {
    let tab: Tab?
    var body: some View {
        if let tab, tab.isNote {
            NotePane(tab: tab)
        } else if let tab, tab.isApp {
            AppPaneView(tab: tab)
        } else if let tab {
            TabContent(tab: tab)
        } else {
            StartView()
        }
    }
}

/// An app page item: its registered view, or a note that nothing draws it.
struct AppPaneView: View {
    @ObservedObject var tab: Tab
    var body: some View {
        if let p = AppPages.page(for: tab.url) {
            p.view(tab)
        } else {
            Text("Nothing draws \(tab.url?.absoluteString ?? "this page") in this build.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Pane frames in the content area, by item, for drop targets.
struct PaneFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue()) { $1 } }
}

extension SplitNode {
    /// A stable identity for the views that draw this node: the item for a pane, and its items
    /// for a branch.
    var key: String {
        switch self {
        case .leaf(let id): return id.uuidString
        case .branch(let axis, _, _): return axis.rawValue + ":" + leaves.map(\.uuidString).joined(separator: ",")
        }
    }
}

/// A split drawn from its tree: rows and columns of panes with dividers you can drag.
struct SplitPanes: View {
    let split: SplitRecord
    var body: some View {
        SplitNodeView.make(split: split, node: split.root, path: [])
            // Swaps, closes, new panes and layout changes all move the panes to their new frames on
            // the split spring. Panes are keyed by item, so each glides from where it was.
            .motion(Motion.split, value: split.root)
    }
}

private struct PaneSpaceKey: EnvironmentKey { static let defaultValue: Namespace.ID? = nil }

extension EnvironmentValues {
    /// The content area's namespace for panes, so a page going into a split, or coming out of one,
    /// moves from its old frame to its new one instead of jumping.
    var paneSpace: Namespace.ID? {
        get { self[PaneSpaceKey.self] }
        set { self[PaneSpaceKey.self] = newValue }
    }
}

extension View {
    /// Matches a pane to its page's other panes in the content area, by item.
    @ViewBuilder func matchedPane(_ id: UUID?, in space: Namespace.ID?) -> some View {
        if let id, let space { matchedGeometryEffect(id: id, in: space) } else { self }
    }
}

enum SplitNodeView {
    @MainActor static func make(split: SplitRecord, node: SplitNode, path: [Int]) -> AnyView {
        switch node {
        case .leaf(let id): return AnyView(PaneLeaf(split: split, id: id))
        case .branch(let axis, let kids, let sizes): return AnyView(SplitBranch(split: split, axis: axis, kids: kids, sizes: sizes, path: path))
        }
    }
}

struct SplitBranch: View {
    let split: SplitRecord
    let axis: SplitAxis
    let kids: [SplitNode]
    let sizes: [Double]
    let path: [Int]
    @EnvironmentObject var model: BrowserModel
    @State private var dragStart: [Double]?

    static let gap: CGFloat = Theme.Space.windowMargin
    static let minPane: CGFloat = 220

    var body: some View {
        GeometryReader { g in
            let total = axis == .row ? g.size.width : g.size.height
            let avail = max(1, total - Self.gap * CGFloat(kids.count - 1))
            let layout = Group {
                // Keyed by what each child holds, so a pane keeps its own view when the split
                // changes around it: panes glide to new places and their web views stay put.
                ForEach(Array(kids.enumerated()), id: \.element.key) { i, kid in
                    SplitNodeView.make(split: split, node: kid, path: path + [i])
                        .frame(width: axis == .row ? avail * sizes[i] : nil, height: axis == .column ? avail * sizes[i] : nil)
                    if i < kids.count - 1 { divider(i, avail: avail) }
                }
            }
            if axis == .row { HStack(spacing: 0) { layout } } else { VStack(spacing: 0) { layout } }
        }
    }

    func divider(_ i: Int, avail: CGFloat) -> some View {
        SplitDivider(axis: axis) { translation in
            let start = dragStart ?? sizes
            if dragStart == nil { dragStart = start }
            model.setSplitSizes(Self.resized(start, at: i, by: Double(translation / avail), avail: avail), at: path, in: split.id, save: false)
        } onEnd: {
            dragStart = nil
            model.scheduleSave()
        } onReset: {
            Motion.run(Motion.split) {
                model.setSplitSizes(Array(repeating: 1.0 / Double(kids.count), count: kids.count), at: path, in: split.id, save: true)
            }
        }
    }

    /// How close, in points, the divider has to come to an even split to settle on it.
    static let evenDetent: CGFloat = 12

    /// Sizes after dragging divider `i` by `delta`, a share of the room: the two panes beside it
    /// trade room, neither goes under the narrowest pane, and near an even split it settles there.
    static func resized(_ start: [Double], at i: Int, by delta: Double, avail: CGFloat) -> [Double] {
        let pair = start[i] + start[i + 1]
        let minShare = min(Double(minPane / avail), pair / 2)
        var a = min(pair - minShare, max(minShare, start[i] + delta))
        if abs(a - pair / 2) * Double(avail) <= Double(evenDetent) { a = pair / 2 }
        var s = start
        s[i] = a
        s[i + 1] = pair - a
        return s
    }
}

/// The gap between two panes, with a handle in the middle that you drag to change how much room
/// each one gets. The handle is a short bar that brightens and grows when the pointer is on the
/// gap, and takes the space's colour while you drag. Double-click evens the panes out.
struct SplitDivider: View {
    let axis: SplitAxis
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void
    let onReset: () -> Void
    @State private var hovering = false
    @State private var dragging = false
    @Environment(\.spaceAccent) private var accent

    /// The handle: 4 points thick, 36 long at rest and 56 while it's in use.
    static let thickness: CGFloat = 4
    static let restLength: CGFloat = 36
    static let activeLength: CGFloat = 56

    var body: some View {
        let row = axis == .row
        let length = hovering || dragging ? Self.activeLength : Self.restLength
        ZStack {
            Color.clear
            Capsule()
                .fill(dragging ? accent.opacity(0.9) : Color.primary.opacity(hovering ? 0.5 : 0.24))
                .frame(width: row ? Self.thickness : length, height: row ? length : Self.thickness)
                .motion(Motion.hover, value: hovering || dragging)
        }
        .frame(width: row ? SplitBranch.gap : nil, height: row ? nil : SplitBranch.gap)
        .contentShape(Rectangle())
        .pointerStyle(row ? .columnResize : .rowResize)
        .onHover { hovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { v in
                    if !dragging { dragging = true }
                    onDrag(row ? v.translation.width : v.translation.height)
                }
                .onEnded { _ in
                    dragging = false
                    onEnd()
                }
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded { onReset() })
        .help("Drag to resize. Double-click to even out.")
        .accessibilityElement()
        .accessibilityLabel("Split divider")
    }
}

/// One pane in a split, with its hover controls.
struct PaneLeaf: View {
    let split: SplitRecord
    let id: UUID
    @EnvironmentObject var model: BrowserModel
    @State private var hovering = false
    @Environment(\.paneSpace) private var paneSpace
    /// `--motion-tour glass` sets this to show every pane's controls without a pointer.
    nonisolated(unsafe) static var tourShowsControls = false

    var body: some View {
        let tab = model.tab(id)
        PaneView(tab: tab)
            .paneCard(focusRing: split.focused == id)
            .background(PaneClickCatcher { model.focusPane(item: id) })
            .overlay(alignment: .top) {
                if hovering || Self.tourShowsControls, let tab {
                    PaneControls(split: split, tab: tab).padding(.top, Theme.Space.s)
                        .transition(.opacity.combined(with: .offset(y: Motion.reduceMotion ? 0 : -3)))
                }
            }
            .onHover { h in Motion.run(Motion.hover, fadeOnly: true) { hovering = h } }
            // The page that joins a split eases in. The one already on screen moves from where it
            // was, matched by item, instead of fading in again.
            .modifier(PaneArrival(joining: split.focused == id))
            .matchedPane(id, in: paneSpace)
            .background(GeometryReader { g in Color.clear.preference(key: PaneFramesKey.self, value: [id: g.frame(in: .named("content"))]) })
    }
}

/// A pane joining a split eases in from 0.985 and fades. Others arrive as they are.
private struct PaneArrival: ViewModifier {
    let joining: Bool
    @State private var joined: Bool?
    func body(content: Content) -> some View {
        Group {
            if joined ?? joining { content.appearEffect(scale: 0.985, y: 0, animation: Motion.split) } else { content }
        }
        .onAppear { if joined == nil { joined = joining } }
    }
}

/// Zen's pane header: a handle to move the pane, Unsplit and Close. Shift-click Unsplit keeps
/// you in the split.
struct PaneControls: View {
    let split: SplitRecord
    @ObservedObject var tab: Tab
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
                .onDrag { SidebarDrag.shared.begin([tab.id]); return ItemDrag.provider(tab.id) }
                .help("Drag to another pane to move this pane")
            PaneControlButton(symbol: "rectangle.portrait.and.arrow.right", help: "Unsplit this pane. Shift-click to stay in the split.") {
                model.popOut(tab.id, stay: NSEvent.modifierFlags.contains(.shift))
            }
            PaneControlButton(symbol: "xmark", help: "Close") {
                model.focusPane(item: tab.id)
                model.closeCurrent()
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 2)
        .padding(.vertical, 1)
        .floatingSurface(radius: Theme.Radius.row)
    }
}

struct PaneControlButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        IconButton(symbol: symbol, help: help, width: 24, height: 22, symbolSize: 10, action: action)
    }
}

/// Watches clicks inside a pane, including clicks that land in a web page or a text view.
struct PaneClickCatcher: NSViewRepresentable {
    let onClick: () -> Void

    final class CatcherView: NSView {
        var onClick: (() -> Void)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
                guard let self, let w = self.window, e.window === w else { return e }
                let p = self.convert(e.locationInWindow, from: nil)
                if self.bounds.contains(p) { self.onClick?() }
                return e
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onClick = onClick
        return v
    }

    func updateNSView(_ v: CatcherView, context: Context) { v.onClick = onClick }
}

/// Where a dragged tab would land: a pane, the side of it, and where the new pane and the page
/// it joins would sit once it lands.
struct DropTarget: Equatable {
    var pane: UUID?
    var side: PaneSide
    /// The pane under the pointer, or the whole page area with no split yet.
    var rect: CGRect
    /// Where the new pane goes.
    var incoming: CGRect
    /// Where the page already there moves to.
    var staying: CGRect
    /// The tab being dragged, for the card's icon and name.
    var tab: UUID?
    /// No split yet, so the page itself moves aside to make room.
    var single: Bool
}

/// A tab dragged over the page shows where it would land before you let go, like Arc. Left of the
/// middle the page slides over to the right half and a card for the tab takes the left, and the
/// other way round on the right. Near the top or bottom edge it stacks instead. Over a split, the
/// card takes half of the pane under the pointer. Folders and splits don't drop here.
struct ContentDropDelegate: DropDelegate {
    let frames: [UUID: CGRect]
    let bounds: CGRect
    @Binding var target: DropTarget?
    let model: BrowserModel

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [ItemDrag.type]) }

    /// The target for a drag at `p`, or nil where it has nowhere to go. Pure apart from reading
    /// the model, so the tests and the offscreen shots can use it.
    @MainActor static func compute(_ p: CGPoint, frames: [UUID: CGRect], bounds: CGRect, model: BrowserModel, dragged: [DragItem]) -> DropTarget? {
        let tabID: UUID?
        switch dragged.first {
        case .tab(let id)?: tabID = id
        case nil: tabID = nil
        default: return nil
        }
        if let sp = model.currentSplit, !frames.isEmpty {
            guard let hit = frames.first(where: { $0.value.contains(p) }) else { return nil }
            if let tabID, tabID == hit.key { return nil }
            if sp.count >= SplitNode.maxPanes, let tabID, !sp.items.contains(tabID) { return nil }
            let side = DropMath.side(at: p, in: hit.value)
            let h = DropMath.halves(side, in: hit.value, gap: SplitBranch.gap)
            return DropTarget(pane: hit.key, side: side, rect: hit.value, incoming: h.incoming, staying: h.staying, tab: tabID, single: false)
        }
        guard let cur = model.currentTab, tabID != cur.id else { return nil }
        let side = DropMath.side(at: p, in: bounds)
        let h = DropMath.halves(side, in: bounds, gap: SplitBranch.gap)
        return DropTarget(pane: cur.id, side: side, rect: bounds, incoming: h.incoming, staying: h.staying, tab: tabID, single: true)
    }

    @MainActor private var dragged: [DragItem] { SidebarDrag.shared.items }

    func dropEntered(info: DropInfo) {
        // Grown Essentials boxes cover part of the page. They step aside once the drag is on it.
        MainActor.assumeIsolated {
            EssentialsBloom.shared.close()
            TabBarState.shared.closeEssentials()
        }
        _ = dropUpdated(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let (t, allowed) = MainActor.assumeIsolated { () -> (DropTarget?, Bool) in
            let d = dragged
            let t = Self.compute(info.location, frames: frames, bounds: bounds, model: model, dragged: d)
            // Over the start view a tab just opens. In the gap between panes the last target holds.
            let isTab: Bool = { if case .tab? = d.first { return true }; return d.isEmpty }()
            if t == nil, isTab, model.currentSplit != nil, !frames.values.contains(where: { $0.contains(info.location) }) { return (target, target != nil) }
            return (t, t != nil || (isTab && model.currentTab == nil))
        }
        if t != target { target = t }
        return DropProposal(operation: allowed ? .move : .forbidden)
    }

    func dropExited(info: DropInfo) { target = nil }

    func performDrop(info: DropInfo) -> Bool {
        let t = target ?? MainActor.assumeIsolated { Self.compute(info.location, frames: frames, bounds: bounds, model: model, dragged: dragged) }
        let m = model, binding = $target
        return ItemDrag.loadItems(info.itemProviders(for: [ItemDrag.type])) { items in
            // The split and the preview going away happen together, so the page stays where the
            // preview put it and the new pane takes the card's place.
            Motion.run(Motion.split) {
                if case .tab(let id)? = items.first { m.drop(tabID: id, side: t?.side ?? .right, onPane: t?.pane) }
                binding.wrappedValue = nil
            }
            SidebarDrag.shared.end()
        }
    }
}

/// The card standing in for a tab while it's dragged over the page: its icon, name and site, in
/// the half it would take.
struct SplitDropCard: View {
    let tab: Tab?
    @Environment(\.spaceAccent) private var accent

    var body: some View {
        let shape = Theme.Radius.shape(Theme.Radius.card)
        VStack(spacing: Theme.Space.s) {
            ItemIcon(tab: tab, size: 28)
                .padding(.bottom, Theme.Space.xs)
            if let tab {
                Text(tab.displayTitle)
                    .font(Theme.Font.rowEmphasis)
                    .lineLimit(1)
                if let d = tab.hoverDetail {
                    Text(d).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: 280)
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(Theme.Palette.sheet))
        .background(shape.fill(accent.opacity(0.08)))
        .overlay(shape.strokeBorder(accent.opacity(0.85), lineWidth: 1.5))
        .themeShadow(.popover)
    }
}

/// A split in the sidebar: one joined row with every pane, each with its own close button.
struct SplitRow: View {
    let split: SplitRecord
    @EnvironmentObject var model: BrowserModel
    @State private var hovering = false
    @Environment(\.pageSelection) private var pageSelection
    @Environment(\.sidebarIconsOnly) private var iconsOnly

    var selected: Bool { model.currentSplit?.id == split.id || pageSelection == .split(split.id) }

    var body: some View {
        Group {
            if iconsOnly {
                // The icon column: the panes' icons side by side on one chip, or four small ones
                // in a square for a grid. Each opens its own pane.
                let ids = Array(split.items.prefix(4))
                let size: CGFloat = ids.count > 2 ? 10 : 13
                let grid = Array(repeating: GridItem(.fixed(size), spacing: 3), count: ids.count > 2 ? 2 : ids.count)
                LazyVGrid(columns: grid, spacing: 3) {
                    ForEach(ids, id: \.self) { id in
                        ItemIcon(tab: model.tab(id), size: size)
                            .opacity(selected && split.focused != id ? 0.55 : 1)
                            .contentShape(Rectangle())
                            .onTapGesture { model.selectSplit(split, focusItem: id) }
                            .hoverCard(id: "split-\(id)", title: model.tab(id)?.displayTitle ?? "", detail: model.tab(id)?.hoverDetail)
                    }
                }
                .fixedSize()
                .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 0) {
                    ForEach(Array(split.items.enumerated()), id: \.element) { i, id in
                        if i > 0 { Rectangle().fill(Theme.Palette.hairline).frame(width: 1, height: 16) }
                        SplitHalf(tab: model.tab(id), focused: selected && split.focused == id, compact: split.count > 2, showClose: hovering) {
                            if let t = model.tab(id) { model.selectSplit(split, focusItem: id); model.focusPane(item: t.id); model.closeCurrent() }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { model.selectSplit(split, focusItem: id) }
                    }
                }
            }
        }
        .frame(height: Theme.Space.rowHeight)
        .modifier(RowBackground(selected: selected, hovering: hovering, multi: split.items.allSatisfy { model.multiSelection.contains($0) }))
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().modifiers(.option).onEnded { model.separate(split) })
        .onHover { hovering = $0 }
        .onDrag { SidebarDrag.shared.begin(items: [.split(split.id)]); return ItemDrag.provider(split: split.id) }
        .contextMenu { SplitMenu(split: split) }
        .help(split.items.compactMap { model.tab($0)?.displayTitle }.joined(separator: " | "))
    }
}

struct SplitHalf: View {
    let tab: Tab?
    let focused: Bool
    let compact: Bool
    let showClose: Bool
    let close: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            ItemIcon(tab: tab, size: 14)
            if !compact || focused {
                Text(tab?.displayTitle ?? "")
                    .font(focused ? Theme.Font.rowEmphasis : Theme.Font.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if !compact {
                IconButton(symbol: "xmark", help: "Close this pane", width: 16, height: 16, symbolSize: 8, action: close)
                    .opacity(showClose ? 1 : 0)
                    .allowsHitTesting(showClose)
                    .motion(Motion.hover, value: showClose, fadeOnly: true)
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SplitMenu: View {
    let split: SplitRecord
    @EnvironmentObject var model: BrowserModel
    var body: some View {
        Button("Separate") { model.separate(split) }
        Button(split.count == 2 ? "Swap sides" : "Rotate panes") { model.swap(split) }
        Menu("Layout") {
            ForEach(SplitLayout.allCases, id: \.self) { l in
                Button(l.title) { model.setLayout(l, for: split) }.disabled(l == .grid && split.count < 3)
            }
            Divider()
            Button("Even out") { model.evenOut(split) }
        }
        Divider()
        Button(split.isPinned ? "Unpin split" : "Pin split") { model.togglePin(split: split) }
        MoveToSpaceMenu { id in model.move(split: split, toSpace: id) }
        Divider()
        Menu("Close a pane") {
            ForEach(split.items, id: \.self) { id in
                Button(model.tab(id)?.displayTitle ?? "Pane") { model.selectSplit(split, focusItem: id); model.closeCurrent() }
            }
        }
    }
}

/// An item's icon: the site's favicon for pages, a symbol for notes and app pages.
struct ItemIcon: View {
    let tab: Tab?
    var size: CGFloat = 14
    var body: some View {
        if let tab, tab.isWeb {
            FaviconView(url: tab.url, fallback: tab.isPinned ? "pin" : "globe", size: size)
        } else if let tab, tab.isApp {
            Image(systemName: AppPages.page(for: tab.url)?.icon ?? "square.grid.2x2").font(.system(size: size * 0.8)).foregroundStyle(.secondary).frame(width: size, height: size)
        } else {
            Image(systemName: tab?.isMissing == true ? "questionmark.square.dashed" : "note.text").font(.system(size: size * 0.8)).foregroundStyle(.secondary).frame(width: size, height: size)
        }
    }
}
