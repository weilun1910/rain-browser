import AppKit
import Combine
import SwiftUI

// The folder popup: a file manager Rain draws over the page for the space folders, with a picture
// for each page and note. It grows out of the icon that opened it and shrinks back into it. A
// left column lists every space's folder, the toolbar has back and forward, the path, search,
// sort, New Folder and Link Folder, and the rest is a grid of cards. It also picks a folder to
// save a page in or move things to. The plan is notes/plans/2026-11-08-folder-popup.md.

@MainActor
final class FolderPopup: ObservableObject {
    static let shared = FolderPopup()
    /// The icon on every button that opens it.
    static let icon = "rectangle.grid.2x2"

    enum Mode: Equatable {
        case browse
        /// Picking a folder to save this tab's page in.
        case save(UUID)
        /// Picking a folder to move these into.
        case move([URL])
    }

    /// One step of the path, from a space's folder down.
    struct Crumb: Hashable {
        let name: String
        let url: URL
        var spaceID: UUID? = nil
    }

    @Published private(set) var isOpen = false
    @Published private(set) var mode: Mode = .browse
    @Published private(set) var trail: [Crumb] = []
    @Published private(set) var entries: [FolderEntry] = []
    @Published var query = "" { didSet { if query != oldValue { scheduleSearch() } } }
    @Published private(set) var results: [FolderEntry]?
    @Published var sort: SpaceFolders.Sort = .custom { didSet { if sort != oldValue { reload() } } }
    @Published var selection: String?
    /// 1 going into a folder, -1 coming back out, 0 for a jump, for the grid's slide.
    @Published private(set) var direction = 0
    @Published var saveName = ""
    /// Hidden while a Peek opened from it is up.
    @Published private(set) var suspended = false
    /// Bumped by Cmd-F to put the cursor in the search field.
    @Published private(set) var focusSearch = 0
    /// Where the popup grew from, in window coordinates, so it can shrink back there.
    private(set) var origin: CGRect?
    /// Where the buttons that open it sit, by name, in window coordinates.
    var anchors: [String: CGRect] = [:]
    /// Where the panel sits while it's open, in window coordinates from the top left.
    var panelFrame: CGRect = .zero
    /// How many cards fit across, for the arrow keys.
    var columns = 4

    private var back: [[Crumb]] = []
    private var ahead: [[Crumb]] = []
    private var searchToken = 0
    private var searchWork: DispatchWorkItem?
    private var observer: NSObjectProtocol?
    private var peekSink: AnyCancellable?
    weak var model: BrowserModel?

    var current: URL? { trail.last?.url }
    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !ahead.isEmpty }
    var shown: [FolderEntry] { results ?? entries }
    var isPicking: Bool { mode != .browse }
    var selectedEntry: FolderEntry? { selection.flatMap { id in shown.first { $0.id == id } } }

    // MARK: Opening and closing

    /// Opens on the current space's folder, or on `start`. `anchor` names the button it grows from.
    func open(_ model: BrowserModel, at start: URL? = nil, from anchor: String? = nil, mode: Mode = .browse) {
        self.model = model
        guard model.spaceFoldersOn, let sp = model.currentSpace, model.ensureSpaceFolder(sp.id) != nil else {
            model.toast("Space folders aren't available")
            return
        }
        observe()
        origin = anchor.flatMap { anchors[$0] }
        self.mode = mode
        back = []
        ahead = []
        query = ""
        results = nil
        selection = nil
        if case .save(let id) = mode { saveName = model.tab(id)?.displayTitle ?? "" }
        let t = start.map { trail(for: $0) } ?? home()
        direction = 0
        trail = t
        reload()
        guard !isOpen else { return }
        HoverCards.shared.hide()
        if model.bar.isOpen { model.bar.close() }
        Motion.run(Motion.barGrow) { isOpen = true }
    }

    /// Show Folders: opens, or closes if it's open.
    func toggle(_ model: BrowserModel, from anchor: String? = nil) {
        if isOpen { close() } else { open(model, from: anchor) }
    }

    func close() {
        guard isOpen else { return }
        Motion.run(Motion.barShrink) { isOpen = false }
        mode = .browse
        suspended = false
        peekSink = nil
        searchWork?.cancel()
    }

    private func observe() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .spaceFoldersChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.isOpen == true { self?.reload() } }
        }
    }

    /// The current space's folder.
    func home() -> [Crumb] {
        guard let model, let sp = model.currentSpace, let u = model.spaceFolderURL(sp) else { return [] }
        return [Crumb(name: sp.name, url: u, spaceID: sp.id)]
    }

    /// The path to a folder, from its space's folder down. A folder outside the space folders is
    /// a path of one.
    func trail(for url: URL) -> [Crumb] {
        let u = url.standardizedFileURL
        guard let root = SpaceFolders.root, let rel = SpaceFolders.relativePath(u), !rel.isEmpty, let model else { return [Crumb(name: u.lastPathComponent, url: u)] }
        let parts = rel.split(separator: "/").map(String.init)
        var out: [Crumb] = []
        var cur = root
        for (i, p) in parts.enumerated() {
            cur = cur.appendingPathComponent(p, isDirectory: true)
            if i == 0, let sp = model.spaces.first(where: { $0.folderName == p }) {
                out.append(Crumb(name: sp.name, url: cur, spaceID: sp.id))
            } else {
                out.append(Crumb(name: p, url: cur))
            }
        }
        return out
    }

    // MARK: Moving around

    func go(_ t: [Crumb], direction d: Int) {
        guard !t.isEmpty, t != trail else { return }
        back.append(trail)
        ahead = []
        move(to: t, direction: d)
    }

    private func move(to t: [Crumb], direction d: Int) {
        // The direction lands first, so the grid that leaves slides the right way.
        direction = d
        query = ""
        results = nil
        selection = nil
        Motion.run(Motion.spaceSwitch) {
            trail = t
            reload()
        }
    }

    /// Into a folder card.
    func enter(_ e: FolderEntry) {
        guard e.kind == .folder, !e.isBroken else { return }
        if results != nil {
            // From search results, the folder's own path.
            go(trail(for: e.url).count > 1 ? trail(for: e.url).dropLast() + [Crumb(name: e.name, url: e.target)] : [Crumb(name: e.name, url: e.target)], direction: 1)
            return
        }
        go(trail + [Crumb(name: e.name, url: e.target)], direction: 1)
    }

    /// A step of the path, clicked.
    func jump(to index: Int) {
        guard trail.indices.contains(index), index < trail.count - 1 else { return }
        go(Array(trail.prefix(index + 1)), direction: -1)
    }

    func goSpace(_ sp: Space) {
        guard let model, let u = model.ensureSpaceFolder(sp.id) else { return }
        go([Crumb(name: sp.name, url: u, spaceID: sp.id)], direction: 0)
    }

    func goBack() {
        guard let t = back.popLast() else { return }
        ahead.append(trail)
        move(to: t, direction: -1)
    }

    func goForward() {
        guard let t = ahead.popLast() else { return }
        back.append(trail)
        move(to: t, direction: 1)
    }

    func goUp() {
        guard trail.count > 1 else { return }
        go(Array(trail.dropLast()), direction: -1)
    }

    /// Lists the folder again. Folders are small, so it's read right away and the grid never
    /// shows the folder you left with the new one's name on it.
    func reload() {
        guard let dir = current else { entries = []; return }
        entries = SpaceFolders.ordered(SpaceFolders.list(dir), in: dir, sort: sort)
        if let s = selection, !shown.contains(where: { $0.id == s }) { selection = nil }
        if !query.isEmpty { scheduleSearch(now: true) }
    }

    // MARK: Search

    private func scheduleSearch(now: Bool = false) {
        searchWork?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let dir = current else { results = nil; return }
        searchToken += 1
        let token = searchToken
        let w = DispatchWorkItem { [weak self] in
            Task.detached(priority: .userInitiated) {
                let found = SpaceFolders.search(q, in: dir)
                await MainActor.run {
                    guard let self, token == self.searchToken else { return }
                    self.results = found
                    self.selection = nil
                }
            }
        }
        searchWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (now ? 0 : 0.15), execute: w)
    }

    func clearSearch() { query = ""; results = nil }

    // MARK: Acting on cards

    /// Click: a folder opens, a page or note opens as a tab and the popup closes. Cmd-click
    /// opens it in the background and keeps the popup open.
    func activate(_ e: FolderEntry, background: Bool = false) {
        guard let model else { return }
        if e.kind == .folder { enter(e); return }
        guard !isPicking else { return }
        model.openFolderEntry(e, background: background)
        if background {
            model.toast("Opened \(e.name) in the background")
        } else {
            close()
        }
    }

    func openInSplit(_ e: FolderEntry) {
        guard let model, e.kind != .folder else { return }
        model.openFolderEntry(e, split: true)
        close()
    }

    /// Space: Peek a page without opening it. The popup steps aside until the Peek closes.
    func peek(_ e: FolderEntry) {
        guard let model, e.kind == .page, let u = e.page else { return }
        suspended = true
        model.openPeek(u, from: model.currentTab)
        peekSink = model.$peek.dropFirst().sink { [weak self] p in
            guard p == nil else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.suspended = false; self?.peekSink = nil } }
        }
    }

    func startMove(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        mode = .move(urls)
    }

    /// Save, in save mode: the page goes in the folder you're looking at, under the name in the field.
    func save() {
        guard case .save(let id) = mode, let model, let tab = model.tab(id), let dir = current else { return }
        let name = saveName.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.savePage(tab, in: dir, name: name.isEmpty ? nil : name) != nil { close() }
    }

    /// Move Here, in move mode.
    func moveHere() {
        guard case .move(let urls) = mode, let model, let dir = current else { return }
        model.fileEntries(urls, into: dir)
        mode = .browse
        reload()
    }

    func cancelPick() {
        if case .move = mode { mode = .browse } else { close() }
    }

    func newFolder() {
        guard let model, let dir = current else { return }
        if let u = model.promptNewDiskFolder(in: dir) {
            reload()
            selection = u.path
        }
    }

    func linkFolder() {
        guard let model, let dir = current else { return }
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.prompt = "Link"
        p.message = "Pick a folder to link here. Nothing is copied, and its notes are edited where they are."
        guard p.runModal() == .OK, let u = p.url else { return }
        if let link = model.linkFolder(u, into: dir) {
            reload()
            selection = link.path
        }
    }

    // MARK: Keys

    /// Keys while the popup is up. Returns true when the key was used.
    func handleKey(_ e: NSEvent) -> Bool {
        guard isOpen, !suspended else { return false }
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        let typing = (NSApp.keyWindow?.firstResponder as? NSTextView)?.isFieldEditor == true
        switch e.keyCode {
        case 53: // Esc
            if case .move = mode { mode = .browse; return true }
            close()
            return true
        case 36, 76: // Return
            if case .save = mode { save(); return true }
            if case .move = mode { moveHere(); return true }
            if let s = selectedEntry ?? (typing ? shown.first : nil) { activate(s, background: mods.contains(.command)) }
            return true
        case 49 where !typing && mods.isEmpty: // Space
            if let s = selectedEntry { peek(s) }
            return true
        case 3 where mods == [.command]: // Cmd-F
            focusSearch += 1
            return true
        case 13 where mods == [.command]: // Cmd-W
            close()
            return true
        case 51 where mods == [.command] && !typing: // Cmd-Delete
            if let s = selectedEntry, !isPicking, let model { model.trashEntries([s]) }
            return true
        case 33 where mods == [.command]: goBack(); return true // Cmd-[
        case 30 where mods == [.command]: goForward(); return true // Cmd-]
        case 126 where mods == [.command]: goUp(); return true // Cmd-Up
        case 125 where mods == [.command]: // Cmd-Down
            if let s = selectedEntry { activate(s) }
            return true
        case 123, 124, 125, 126 where mods.isEmpty && (!typing || e.keyCode == 125):
            if typing { NSApp.keyWindow?.makeFirstResponder(nil) }
            moveSelection(e.keyCode)
            return true
        case 17 where mods == [.command], 37 where mods == [.command]: // Cmd-T, Cmd-L go to the command bar
            close()
            return false
        default:
            return false
        }
    }

    func moveSelection(_ key: UInt16) {
        let list = shown
        guard !list.isEmpty else { return }
        guard let cur = selection.flatMap({ id in list.firstIndex { $0.id == id } }) else { selection = list[0].id; return }
        let step: Int
        switch key {
        case 123: step = -1
        case 124: step = 1
        case 125: step = max(1, columns)
        default: step = -max(1, columns)
        }
        selection = list[max(0, min(list.count - 1, cur + step))].id
    }
}

// MARK: - The layer over the window

/// Drawn from the layout's root, above the page's web view, so clicks on the popup reach it and
/// not the page. It covers the page area and leaves the sidebar alone, so the pinned folders stay
/// in view to drag things onto. A click on the sidebar that picks another tab or space closes it.
struct FolderPopupLayer: View {
    @ObservedObject var popup = FolderPopup.shared
    @EnvironmentObject var model: BrowserModel
    /// The sidebar's width on either side, kept clear.
    var leadingClear: CGFloat = 0
    var trailingClear: CGFloat = 0

    /// The panel fills the page area, less a margin, up to 1100 by 760.
    static func panelSize(in size: CGSize) -> CGSize {
        CGSize(width: min(1100, max(0, size.width - 2 * sideMargin).rounded()),
               height: min(760, (size.height * 0.8).rounded()))
    }
    static let sideMargin: CGFloat = 32

    /// The panel, centred in the layer.
    static func panelFrame(in layer: CGRect) -> CGRect {
        let s = panelSize(in: layer.size)
        return CGRect(x: layer.minX + (layer.width - s.width) / 2, y: layer.minY + (layer.height - s.height) / 2,
                      width: s.width, height: s.height)
    }

    var body: some View {
        GeometryReader { g in
            let frame = g.frame(in: .global)
            let size = Self.panelSize(in: g.size)
            ZStack {
                if popup.isOpen && !popup.suspended {
                    Theme.Palette.scrim
                        .contentShape(Rectangle())
                        .onTapGesture { popup.close() }
                        .transition(.opacity)
                    FolderPanel()
                        .frame(width: size.width, height: size.height)
                        .transition(FolderPopupMotion.transition(origin: popup.origin, layer: frame, panel: size))
                }
            }
            .frame(width: g.size.width, height: g.size.height)
            // Worked out from the layer rather than measured, so the grow animation doesn't skew it.
            .onAppear { popup.panelFrame = Self.panelFrame(in: frame) }
            .onChange(of: frame) { _, f in popup.panelFrame = Self.panelFrame(in: f) }
        }
        .padding(.leading, leadingClear)
        .padding(.trailing, trailingClear)
        .onChange(of: model.selection) { _, _ in if popup.isOpen && !popup.suspended { popup.close() } }
        .onChange(of: model.currentSpaceID) { _, _ in if popup.isOpen { popup.close() } }
    }
}

/// The popup grows out of the button that opened it and shrinks back into it. Opened from the
/// keyboard it grows a little from the middle. With Reduce Motion it fades.
enum FolderPopupMotion {
    struct Grow: ViewModifier {
        let scale: CGFloat
        let opacity: Double
        let anchor: UnitPoint
        func body(content: Content) -> some View {
            content.scaleEffect(scale, anchor: anchor).opacity(opacity)
        }
    }

    static func transition(origin: CGRect?, layer: CGRect, panel: CGSize) -> AnyTransition {
        if Motion.suppressed { return .identity }
        if Motion.reduceMotion { return .opacity }
        guard let o = origin, panel.width > 0, panel.height > 0 else {
            return .modifier(active: Grow(scale: 0.96, opacity: 0, anchor: .center), identity: Grow(scale: 1, opacity: 1, anchor: .center))
        }
        let x0 = layer.minX + (layer.width - panel.width) / 2, y0 = layer.minY + (layer.height - panel.height) / 2
        let anchor = UnitPoint(x: (o.midX - x0) / panel.width, y: (o.midY - y0) / panel.height)
        return .modifier(active: Grow(scale: 0.04, opacity: 0, anchor: anchor), identity: Grow(scale: 1, opacity: 1, anchor: anchor))
    }
}

/// Remembers where a button that opens the popup sits, so the popup can grow out of it.
struct FolderPopupAnchor: ViewModifier {
    let name: String
    func body(content: Content) -> some View {
        content.background(GeometryReader { g in
            Color.clear
                .onAppear { FolderPopup.shared.anchors[name] = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { _, f in FolderPopup.shared.anchors[name] = f }
        })
    }
}

extension View {
    func folderPopupAnchor(_ name: String) -> some View { modifier(FolderPopupAnchor(name: name)) }
}

// MARK: - The panel

struct FolderPanel: View {
    @ObservedObject var popup = FolderPopup.shared
    @EnvironmentObject var model: BrowserModel
    static let columnWidth: CGFloat = 196

    var body: some View {
        let inner = Theme.Radius.shape(Theme.Radius.sheet)
        HStack(spacing: 0) {
            FolderColumn()
                .frame(width: Self.columnWidth)
                .background(Theme.Palette.field)
            Hairline(vertical: true)
            VStack(spacing: 0) {
                FolderToolbar()
                Hairline()
                FolderGrid()
                if popup.isPicking {
                    Hairline()
                    FolderPickBar()
                }
            }
        }
        .background(Theme.Palette.card)
        .clipShape(inner)
        .overlay(inner.strokeBorder(Theme.Palette.hairline, lineWidth: 0.5).allowsHitTesting(false))
        .padding(6)
        // The frame is glass, like Rain's other floating layers, drawn behind the inside so the
        // inside stays solid and its text isn't blended with the page.
        .background { Color.clear.glassPanel(radius: Theme.Radius.sheet + 6, fallbackShadow: .sheet, wash: false) }
        .contentShape(Rectangle())
        .onTapGesture {}
    }
}

struct Hairline: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(Theme.Palette.hairline)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// Every space's folder, with its icon and colour.
struct FolderColumn: View {
    @ObservedObject var popup = FolderPopup.shared
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                label("Spaces")
                ForEach(model.spaces) { sp in
                    let at = popup.trail.first?.spaceID == sp.id
                    FolderColumnRow(title: sp.name, selected: at && popup.trail.count == 1, within: at && popup.trail.count > 1,
                                    target: model.spaceFolderURL(sp)) {
                        SpaceIcon(icon: sp.icon, size: 12).foregroundStyle(Theme.Palette.accent(sp.color))
                    } action: { popup.goSpace(sp) }
                }
                let pinned = model.pinnedFolders.compactMap { f in model.folderDirectory(f).map { (f, $0) } }
                if !pinned.isEmpty {
                    label("Pinned").padding(.top, 10)
                    ForEach(pinned, id: \.0.id) { f, dir in
                        FolderColumnRow(title: f.name, selected: popup.current?.path == dir.path, target: dir) {
                            FolderGlyph(isOpen: false, size: 14, ground: Theme.Palette.card)
                        } action: { popup.go(popup.trail(for: dir), direction: 0) }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.never)
    }

    func label(_ s: String) -> some View {
        Text(s).font(Theme.Font.label).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 4)
    }
}

/// A row in the popup's left column. Things dropped on it go into its folder.
struct FolderColumnRow<Icon: View>: View {
    let title: String
    var selected = false
    /// You're in a folder inside this one.
    var within = false
    var target: URL?
    @ViewBuilder var icon: () -> Icon
    let action: () -> Void
    @EnvironmentObject var model: BrowserModel
    @State private var hovering = false
    @State private var targeted = false
    @Environment(\.spaceAccent) private var accent

    var body: some View {
        HStack(spacing: 8) {
            icon().frame(width: 16)
            Text(title).font(Theme.Font.row).lineLimit(1)
                .foregroundStyle(selected || within ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(0.85)))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Theme.Radius.shape(Theme.Radius.row).fill(selected ? Theme.Palette.rowSelected : (hovering ? Theme.Palette.rowHover : .clear)))
        .overlay {
            if targeted { Theme.Radius.shape(Theme.Radius.row).strokeBorder(accent.opacity(0.8), lineWidth: 1.5) }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
        .motion(Motion.hover, value: hovering, fadeOnly: true)
        .onDrop(of: [ItemDrag.type], isTargeted: $targeted) { providers in
            guard let target else { return false }
            return ItemDrag.loadItems(providers) { items in FolderDropActions.drop(items, into: target, model: model) }
        }
    }
}

/// What a drop on a folder in the popup does: tabs are saved or filed there, and files and
/// folders from the popup move there.
@MainActor
enum FolderDropActions {
    static func drop(_ items: [DragItem], into dir: URL, model: BrowserModel) {
        let tabs = items.compactMap { if case .tab(let id) = $0 { return id }; return nil }
        let entries = items.compactMap { if case .entry(let u) = $0 { return u }; return nil }
            .filter { $0.standardizedFileURL.path != dir.standardizedFileURL.path }
        if !tabs.isEmpty { model.fileTabs(tabs, into: dir) }
        if !entries.isEmpty { model.fileEntries(entries, into: dir) }
        SidebarDrag.shared.end()
        FolderPopup.shared.reload()
    }
}

// MARK: - Toolbar

struct FolderToolbar: View {
    @ObservedObject var popup = FolderPopup.shared
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        HStack(spacing: 2) {
            IconButton(symbol: "chevron.left", help: "Back (Cmd-[)", width: 26, height: 26, symbolSize: 12) { popup.goBack() }
                .disabled(!popup.canGoBack)
            IconButton(symbol: "chevron.right", help: "Forward (Cmd-])", width: 26, height: 26, symbolSize: 12) { popup.goForward() }
                .disabled(!popup.canGoForward)
            FolderPath()
                .padding(.leading, 6)
                .layoutPriority(1)
            Spacer(minLength: 12)
            FolderSearchField()
                .frame(width: 200)
            Menu {
                Picker("Sort by", selection: $popup.sort) {
                    ForEach(SpaceFolders.Sort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .menuStyle(.button)
            .buttonStyle(IconButtonStyle(width: 28, height: 26, symbolSize: 12))
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort")
            .padding(.leading, 6)
            IconButton(symbol: "folder.badge.plus", help: "New Folder", width: 28, height: 26, symbolSize: 12) { popup.newFolder() }
            if !popup.isPicking {
                IconButton(symbol: "link", help: "Link Folder...", width: 28, height: 26, symbolSize: 12) { popup.linkFolder() }
            }
            IconButton(symbol: "xmark", help: "Close (Esc)", width: 28, height: 26, symbolSize: 11) { popup.close() }
                .padding(.leading, 4)
        }
        .padding(.horizontal, 10)
        .frame(height: 46)
    }
}

/// The path you're in. Click any part of it to go there.
struct FolderPath: View {
    @ObservedObject var popup = FolderPopup.shared

    var body: some View {
        let t = popup.trail
        // A long path keeps its first step and the last two.
        let shown: [(Int, FolderPopup.Crumb)] = t.count > 4 ? [(0, t[0])] + t.enumerated().suffix(2).map { ($0.offset, $0.element) }
            : Array(t.enumerated()).map { ($0.offset, $0.element) }
        HStack(spacing: 3) {
            ForEach(Array(shown.enumerated()), id: \.element.0) { n, pair in
                if n > 0 {
                    PathChevron()
                    if t.count > 4 && n == 1 { Text("...").font(Theme.Font.row).foregroundStyle(.secondary); PathChevron() }
                }
                let last = pair.0 == t.count - 1
                Button { popup.jump(to: pair.0) } label: {
                    Text(pair.1.name)
                        .font(last ? Theme.Font.rowEmphasis : Theme.Font.row)
                        .foregroundStyle(last ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .allowsHitTesting(!last)
            }
            if popup.results != nil {
                PathChevron()
                Text("Search").font(Theme.Font.rowEmphasis).lineLimit(1)
            }
        }
    }
}

struct PathChevron: View {
    var body: some View {
        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).opacity(0.7)
    }
}

struct FolderSearchField: View {
    @ObservedObject var popup = FolderPopup.shared
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            TextField("Search this folder", text: $popup.query)
                .textFieldStyle(.plain)
                .font(Theme.Font.row)
                .focused($focused)
            if !popup.query.isEmpty {
                Button { popup.clearSearch() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
                    .help("Clear")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Theme.Radius.shape(Theme.Radius.row).fill(Theme.Palette.field))
        .onChange(of: popup.focusSearch) { _, _ in focused = true }
    }
}

// MARK: - Save and move

struct FolderPickBar: View {
    @ObservedObject var popup = FolderPopup.shared
    @EnvironmentObject var model: BrowserModel
    @FocusState private var nameFocused: Bool
    @Environment(\.spaceAccent) private var accent

    var body: some View {
        HStack(spacing: 10) {
            switch popup.mode {
            case .save:
                Text("Save as").font(Theme.Font.row).foregroundStyle(.secondary)
                TextField("Name", text: $popup.saveName)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.row)
                    .focused($nameFocused)
                    .onSubmit { popup.save() }
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .frame(maxWidth: 340)
                    .background(Theme.Radius.shape(Theme.Radius.row).fill(Theme.Palette.field))
                Text("in \(popup.trail.last?.name ?? "")").font(Theme.Font.row).foregroundStyle(.secondary).lineLimit(1)
            case .move(let urls):
                Text(urls.count == 1 ? "Move \(urls[0].deletingPathExtension().lastPathComponent) to \(popup.trail.last?.name ?? "")"
                     : "Move \(urls.count) items to \(popup.trail.last?.name ?? "")")
                    .font(Theme.Font.row).lineLimit(1)
            case .browse:
                EmptyView()
            }
            Spacer(minLength: 8)
            Button("Cancel") { popup.cancelPick() }
                .keyboardShortcut(.cancelAction)
            Button(isSave ? "Save" : "Move Here") { isSave ? popup.save() : popup.moveHere() }
                .buttonStyle(.borderedProminent)
                .tint(accent)
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .onAppear { if isSave { DispatchQueue.main.async { nameFocused = true } } }
    }

    var isSave: Bool { if case .save = popup.mode { return true }; return false }
}

extension BrowserModel {
    /// Cmd-Option-B, the Folders menu, the icon by the Folders header and the tab bar's button.
    func showFolders(from anchor: String? = nil) {
        FolderPopup.shared.toggle(self, from: anchor)
    }

    /// Files and folders from the popup dropped in Tabs open as tabs.
    func openEntriesAsTabs(_ urls: [URL]) {
        for u in urls { if let e = SpaceFolders.entry(u), e.kind != .folder { openFolderEntry(e) } }
    }
}
