import AppKit
import SwiftUI

struct LeftSidebar: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var settings = Settings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            topBar
            addressField
            EssentialsGrid()
            SpaceHeader()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    pinnedSection
                    foldersSection
                    tabsSection
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            MediaBar()
            bottomBar
        }
        .padding(.horizontal, 10)
        .background(SpaceSwipeCatcher { step in model.switchSpace(by: step) })
        .background((model.currentSpace.map { Color(hex: $0.color) } ?? .clear).opacity(0.07).ignoresSafeArea())
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
            NavButton(symbol: "sidebar.right", help: "Related panel") {
                Settings.shared.update { $0.rightPanelOpen.toggle() }
            }
        }
        .frame(height: 30)
        .padding(.top, 4)
    }

    /// Shows the focused page's address. Clicking it opens the command bar, like Cmd-L.
    private var addressField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.tertiary)
            Text(model.addressText.isEmpty ? "Search or enter address" : Snippet.prettyURL(model.addressText))
                .font(.system(size: 13))
                .foregroundStyle(model.addressText.isEmpty ? .tertiary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if model.currentTab?.url != nil, model.currentTab?.isApp == false {
                Button { model.copyCurrentURL() } label: {
                    Image(systemName: "link").font(.system(size: 10)).frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.tertiary).help("Copy link (Shift-Cmd-C)")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.055)))
        .contentShape(Rectangle())
        .onTapGesture { model.focusAddress() }
        .help(model.addressText)
    }

    // MARK: Sections

    private var pinnedSection: some View {
        let rows = model.refs(in: .pinned)
        return SectionBox(title: "Pinned", onDropItems: { items in model.place(items.compactMap(\.sidebarRef), in: .pinned, at: Int.max) }) {
            if rows.isEmpty {
                Text("Drag tabs here to pin them").font(.system(size: 12)).foregroundStyle(.tertiary).padding(.leading, 8).frame(height: 22)
            }
            ForEach(rows, id: \.self) { SidebarRow(ref: $0) }
        }
    }

    private var foldersSection: some View {
        SectionBox(title: "Folders", trailing: AnyView(SmallIconButton(symbol: "plus", help: "New folder") { model.promptNewFolder() })) {
            if model.spaceFolders.isEmpty {
                Text("No folders yet").font(.system(size: 12)).foregroundStyle(.tertiary).padding(.leading, 8)
            }
            ForEach(model.spaceFolders) { f in
                FolderRow(folder: f)
                if f.isExpanded {
                    VStack(spacing: 1) {
                        let rows = model.refs(in: .folder(f.id))
                        ForEach(rows, id: \.self) { SidebarRow(ref: $0) }
                        if rows.isEmpty {
                            Text("Empty").font(.system(size: 12)).foregroundStyle(.tertiary).padding(.leading, 8).frame(height: 22)
                        }
                    }
                    .padding(.leading, 14)
                }
            }
        }
    }

    private var tabsSection: some View {
        let rows = model.refs(in: .today)
        let trailing = HStack(spacing: 2) {
            if !rows.isEmpty {
                Button("Clear") { _ = model.clearToday() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                    .help("Archive every tab here (Shift-Cmd-K)")
                    .padding(.trailing, 4)
            }
            SmallIconButton(symbol: "square.and.pencil", help: "New note") { model.newNote() }
        }
        return SectionBox(title: "Tabs", trailing: AnyView(trailing), onDropItems: { items in model.place(items.compactMap(\.sidebarRef), in: .today, at: 0) }) {
            Button { model.newTabCommand() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus").frame(width: 16)
                    Text("New tab")
                    Spacer()
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .contentShape(Rectangle())
                .modifier(RowBackground(selected: model.bar.isOpen && model.bar.mode == .newTab, hovering: false))
            }
            .buttonStyle(.plain)
            ForEach(rows, id: \.self) { SidebarRow(ref: $0) }
        }
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let msg = model.flashMessage {
                Text(msg).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).padding(.horizontal, 8)
            }
            HStack(spacing: 2) {
                SmallIconButton(symbol: "gearshape", help: "Settings") { AppDelegate.shared?.openSettings() }
                SmallIconButton(symbol: "clock", help: "History (Cmd-Y)") { model.openAppPage("history") }
                DownloadsButton()
                Spacer()
                SpaceBar()
            }
            .frame(height: 30)
        }
        .padding(.bottom, 6)
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
    @EnvironmentObject var model: BrowserModel
    @State private var targeted = false

    var body: some View {
        if let sp = model.currentSpace {
            HStack(spacing: 6) {
                SpaceIcon(icon: sp.icon, size: 11).foregroundStyle(Color(hex: sp.color))
                Text(targeted && model.essentials.isEmpty ? "Add to Essentials" : sp.name)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                if let p = sp.profile {
                    Text(p).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 6).fill(targeted && model.essentials.isEmpty ? Color.accentColor.opacity(0.15) : .clear))
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
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: min(4, max(3, items.count))), spacing: 6) {
                ForEach(items) { EssentialTile(tab: $0) }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 10).fill(targeted ? Color.accentColor.opacity(0.1) : .clear))
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
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Color.primary.opacity(0.13) : Color.primary.opacity(hovering ? 0.08 : 0.045)))
                .opacity(tab.isLoaded || tab.isNote || tab.isApp || selected ? 1 : 0.7)
            if tab.isAwayFromPin {
                Circle().fill(Color.secondary).frame(width: 5, height: 5).padding(5).help("Away from its pinned page. Double-click to go back.")
            }
            if tab.mediaPlaying || tab.isMuted {
                Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 8)).foregroundStyle(.secondary).padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
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
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                trailing
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(targeted ? Color.accentColor.opacity(0.15) : .clear))
            .modifier(DropModifier(onDrop: onDrop, onDropItems: onDropItems, targeted: $targeted))
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
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .secondary : .quaternary)
        .help(help)
    }
}

struct SmallIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

struct RowBackground: ViewModifier {
    let selected: Bool
    let hovering: Bool
    var multi: Bool = false
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.primary.opacity(0.11) : (multi ? Color.accentColor.opacity(0.14) : (hovering ? Color.primary.opacity(0.05) : .clear)))
            )
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
        let y = info.location.y
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
            if split, refs.count == 1, case .tab(let id) = refs[0] {
                model.dropForSplit(id, onto: ref.id)
            } else {
                model.place(refs, next: ref, after: after)
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

    var body: some View {
        Group {
            switch ref {
            case .tab(let id): if let t = model.tab(id) { TabRow(tab: t, splitting: indicator == .split) }
            case .split(let id): if let s = model.split(id) { SplitRow(split: s) }
            }
        }
        .overlay(alignment: indicator == .above ? .top : .bottom) {
            if indicator == .above || indicator == .below {
                Rectangle().fill(Color.accentColor).frame(height: 2).padding(.horizontal, 6).allowsHitTesting(false)
            }
        }
        .onDrop(of: [ItemDrag.type], delegate: RowDropDelegate(ref: ref, height: 28, canSplit: { if case .tab = ref { return true }; return false }(),
                                                               model: model, indicator: $indicator, clock: clock))
    }
}

struct TabRow: View {
    @ObservedObject var tab: Tab
    var splitting = false
    @EnvironmentObject var model: BrowserModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                if tab.isLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    ItemIcon(tab: tab, size: 14)
                }
            }
            .frame(width: 16)
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
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .strikethrough(tab.isMissing, color: .secondary)
                    .foregroundStyle(tab.isMissing ? .secondary : (tab.isLoaded || tab.kind != .web || model.isSelected(tab) ? .primary : .secondary))
                if tab.isAwayFromPin {
                    Text("/").font(.system(size: 13)).foregroundStyle(.tertiary).help("This pinned tab has moved away from its pinned page")
                }
            }
            if model.peek?.parentID == tab.id {
                RoundedRectangle(cornerRadius: 2).strokeBorder(Color.secondary, lineWidth: 1).frame(width: 9, height: 9).help("Peek is open from this tab")
            }
            if splitting {
                Text("Split").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.accentColor)
            }
            if tab.isMissing && hovering {
                Button("Locate") { model.locateNote(tab) }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color.accentColor)
            }
            Spacer(minLength: 0)
            if tab.mediaPlaying || tab.isMuted {
                Button { model.toggleMute(tab) } label: {
                    Image(systemName: tab.isMuted ? "speaker.slash" : "speaker.wave.2").font(.system(size: 10)).frame(width: 16, height: 16)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help(tab.isMuted ? "Unmute" : "Mute")
            }
            if hovering {
                Button { tab.kind == .web ? model.close(tab) : model.remove(tab) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(tab.keepsPinnedURL ? "Back to pinned page and unload" : (tab.folderID != nil ? "Unload" : "Close"))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .modifier(RowBackground(selected: model.isSelected(tab) || splitting, hovering: hovering, multi: model.multiSelection.contains(tab.id)))
        .contentShape(Rectangle())
        .onTapGesture { click() }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if !NSEvent.modifierFlags.contains(.command) && !NSEvent.modifierFlags.contains(.shift) { model.promptRenameTab(tab) }
        })
        .onHover { hovering = $0 }
        .onDrag {
            let picked = model.multiSelection.contains(tab.id) && model.multiSelection.count > 1
            return picked ? ItemDrag.provider(ids: model.multiSelectedTabs.map { $0.id }) : ItemDrag.provider(tab.id)
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
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(folder.isExpanded ? 90 : 0))
                .foregroundStyle(.tertiary)
                .frame(width: 10)
            Image(systemName: folder.isExpanded ? "folder" : "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(folder.name).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 0)
            Text("\(model.tabs(in: folder).count)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .modifier(RowBackground(selected: targeted, hovering: hovering))
        .contentShape(Rectangle())
        .onTapGesture { model.toggleFolder(folder) }
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
        if !playing.isEmpty {
            VStack(spacing: 2) {
                ForEach(playing) { MediaRow(tab: $0) }
            }
        }
    }
}

struct MediaRow: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        HStack(spacing: 8) {
            ItemIcon(tab: tab, size: 14)
            Text(tab.displayTitle).font(.system(size: 12)).lineLimit(1)
                .contentShape(Rectangle())
                .onTapGesture { model.select(tab) }
            Spacer(minLength: 0)
            SmallIconButton(symbol: tab.mediaPlaying ? "pause.fill" : "play.fill", help: tab.mediaPlaying ? "Pause" : "Play") { model.togglePlayback(tab) }
            SmallIconButton(symbol: tab.isMuted ? "speaker.slash" : "speaker.wave.2", help: tab.isMuted ? "Unmute" : "Mute") { model.toggleMute(tab) }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .help("Playing in \(tab.displayTitle). Click the title to go there.")
    }
}

/// The downloads button: a progress ring while something downloads, and the list on click.
struct DownloadsButton: View {
    @ObservedObject var downloads = Downloads.shared
    @EnvironmentObject var model: BrowserModel
    @State private var showing = false

    var body: some View {
        if !downloads.items.isEmpty {
            Button { showing.toggle() } label: {
                ZStack {
                    if let p = downloads.overallProgress {
                        Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1.5).frame(width: 14, height: 14)
                        Circle().trim(from: 0, to: p).stroke(Color.accentColor, lineWidth: 1.5).rotationEffect(.degrees(-90)).frame(width: 14, height: 14)
                    }
                    Image(systemName: "arrow.down").font(.system(size: downloads.overallProgress == nil ? 12 : 7, weight: .semibold))
                }
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Downloads")
            .popover(isPresented: $showing, arrowEdge: .top) {
                DownloadsList(compact: true).frame(width: 320).padding(10)
            }
        }
    }
}
