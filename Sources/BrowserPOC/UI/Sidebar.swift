import AppKit
import SwiftUI

struct LeftSidebar: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var settings = Settings.shared

    @State private var addressHover = false
    @State private var spaceSteps = StepTracker()
    @Environment(\.spaceAccent) private var accent

    var body: some View {
        // Which way the list slides when the space changes.
        let step = spaceSteps.step(for: model.spaces.firstIndex { $0.id == model.currentSpaceID })
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            topBar
            addressField
            ZStack(alignment: .leading) {
                if let sp = model.currentSpace {
                    HStack(spacing: Theme.Space.s) {
                        SpaceIcon(icon: sp.icon, size: 11).foregroundStyle(accent)
                        Text(sp.name).font(Theme.Font.spaceTitle).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, Theme.Space.rowInset)
                    .padding(.top, Theme.Space.xxs)
                    .id(sp.id)
                    .transition(Motion.Transitions.spaceSlide(step))
                }
            }
            ScrollView {
                // The list is keyed by space, so moving between spaces slides the new list in.
                ZStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: Theme.Space.sectionGap) {
                        pinnedSection
                        foldersSection
                        tabsSection
                    }
                    .padding(.bottom, Theme.Space.l)
                    .id(model.currentSpaceID)
                    .transition(Motion.Transitions.spaceSlide(step))
                }
            }
            .scrollIndicators(.never)
            bottomBar
        }
        .motion(Motion.spaceSwitch, value: model.currentSpaceID)
        .padding(.horizontal, Theme.Space.sidebarInset)
        .background(SpaceSwipeCatcher { step in model.switchSpace(by: step) })
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
        }
        .padding(.horizontal, Theme.Space.l - 2)
        .frame(height: 32)
        .background(Theme.Radius.shape(Theme.Radius.row).fill(addressHover ? Theme.Palette.fieldHover : Theme.Palette.field))
        .contentShape(Rectangle())
        .onTapGesture { model.focusAddress() }
        .onHover { addressHover = $0 }
        .motion(Motion.hover, value: addressHover, fadeOnly: true)
        .help(model.addressText)
    }

    // MARK: Sections

    @ViewBuilder private var pinnedSection: some View {
        let pinned = model.pinnedTabs
        if !pinned.isEmpty {
            // Like Zen, pins sit under the space's name with no label, and a hairline closes them off.
            SectionBox(title: "", onDrop: { ids in model.moveTabs(ids: ids, to: nil, pin: true) }) {
                ForEach(pinned) { TabRow(tab: $0).transition(Motion.Transitions.tabRow) }
                SectionDivider()
            }
            .motion(Motion.insert, value: pinned.map { $0.id })
        }
    }

    private var foldersSection: some View {
        SectionBox(title: "Folders", trailing: AnyView(SmallIconButton(symbol: "plus", help: "New folder") { model.promptNewFolder() })) {
            ForEach(model.spaceFolders) { f in
                FolderRow(folder: f)
                FolderReveal(isOpen: f.isExpanded) {
                    VStack(spacing: Theme.Space.rowGap) {
                        ForEach(model.tabs(in: f)) { TabRow(tab: $0).transition(Motion.Transitions.tabRow) }
                        if model.tabs(in: f).isEmpty {
                            Text("Empty")
                                .font(Theme.Font.secondary).foregroundStyle(.secondary)
                                .padding(.leading, Theme.Space.rowInset).frame(height: 24)
                        }
                    }
                    .padding(.top, Theme.Space.rowGap)
                    // Child icons line up under the folder's name.
                    .padding(.leading, Theme.Space.folderIndent)
                }
            }
        }
        .motion(Motion.insert, value: model.spaceFolders.map { model.tabs(in: $0).map { $0.id } })
    }

    private var tabsSection: some View {
        SectionBox(title: "Tabs", trailing: AnyView(SmallIconButton(symbol: "square.and.pencil", help: "New note") { model.newNote() }),
                   onDrop: { ids in model.moveTabs(ids: ids, to: nil) }) {
            Button { model.newTabCommand() } label: {
                HStack(spacing: Theme.Space.m) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: Theme.Space.rowIcon)
                    Text("New tab")
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(SidebarActionRowStyle())
            ForEach(model.spaceSplits.reversed()) { SplitRow(split: $0).transition(Motion.Transitions.tabRow) }
            ForEach(model.looseTabs) { TabRow(tab: $0).transition(Motion.Transitions.tabRow) }
        }
        .motion(Motion.insert, value: model.looseTabs.map { $0.id } + model.spaceSplits.map { $0.id })
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if let msg = model.flashMessage {
                Text(msg)
                    .font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.horizontal, Theme.Space.rowInset)
                    .transition(.opacity)
            }
            HStack(spacing: 0) {
                SmallIconButton(symbol: "gearshape", help: "Settings") { AppDelegate.shared?.openSettings() }
                Spacer(minLength: Theme.Space.m)
                SpaceBar()
            }
            .frame(height: 32)
        }
        .motion(Motion.hover, value: model.flashMessage, fadeOnly: true)
        .padding(.bottom, Theme.Space.m)
    }
}

struct SectionBox<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    var onDrop: (([String]) -> Bool)? = nil
    @ViewBuilder var content: () -> Content
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.rowGap) {
            if title.isEmpty {
                // No label: a thin drop strip above the rows.
                Theme.Radius.shape(Theme.Radius.xs)
                    .fill(targeted ? Theme.Palette.rowHover : .clear)
                    .frame(height: 4)
                    .modifier(DropModifier(onDrop: onDrop, targeted: $targeted))
            } else {
                SectionHeader(title: title, highlighted: targeted) { trailing ?? AnyView(EmptyView()) }
                    .modifier(DropModifier(onDrop: onDrop, targeted: $targeted))
            }
            content()
        }
    }
}

struct DropModifier: ViewModifier {
    let onDrop: (([String]) -> Bool)?
    @Binding var targeted: Bool
    func body(content: Content) -> some View {
        if let onDrop {
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
    func body(content: Content) -> some View {
        content.sidebarRow(selected: selected, hovering: hovering)
    }
}

struct TabRow: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var model: BrowserModel
    @State private var hovering = false

    var icon: String {
        switch tab.kind {
        case .web: return tab.isPinned ? "pin" : "globe"
        case .note, .file: return tab.isMissing ? "questionmark.square.dashed" : "note.text"
        }
    }

    var body: some View {
        HStack(spacing: Theme.Space.rowIconGap) {
            ZStack {
                if tab.kind == .web {
                    // The site's icon, or its monogram until one arrives. Loading shows as a soft fade.
                    FaviconView(image: FaviconLookup.image(for: tab.url), size: Theme.Space.rowIcon,
                                fallback: tab.url == nil ? .symbol("globe") : .site(tab.url))
                        .opacity(tab.isLoading ? 0.45 : 1)
                        .motion(Motion.hover, value: tab.isLoading, fadeOnly: true)
                } else {
                    RowIcon(symbol: icon)
                }
            }
            .frame(width: Theme.Space.rowIcon)
            Text(tab.displayTitle)
                .font(Theme.Font.row)
                .lineLimit(1)
                .strikethrough(tab.isMissing, color: .secondary)
                // Pages that aren't loaded are only a little quieter, so a folder of sources
                // doesn't look half disabled.
                .foregroundStyle(tab.isMissing ? AnyShapeStyle(.secondary)
                                 : (tab.isLoaded || tab.kind != .web || model.isSelected(tab) ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(0.72))))
            if tab.isMissing && hovering {
                Button("Locate") { model.locateNote(tab) }
                    .buttonStyle(QuietActionStyle())
            }
            Spacer(minLength: 0)
            // Always laid out, so the title doesn't jump when the close button appears on hover.
            IconButton(symbol: "xmark", help: tab.isPinned || tab.folderID != nil ? "Unload" : "Close",
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
        .modifier(RowBackground(selected: model.isSelected(tab), hovering: hovering))
        .contentShape(Rectangle())
        .onTapGesture { model.select(tab) }
        .onHover { hovering = $0 }
        .onDrag { ItemDrag.provider(tab.id) }
        .contextMenu { TabMenu(tab: tab) }
    }
}

struct TabMenu: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        if tab.kind == .web { webMenu } else { noteMenu }
    }

    @ViewBuilder var splitMenu: some View {
        Button("Open in split view") { model.openInSplit(tab, side: .right) }
            .disabled(model.currentTab?.id == tab.id && model.currentSplit == nil)
        MoveToSpaceMenu { id in model.move(tab, toSpace: id) }
    }

    @ViewBuilder var folderMenu: some View {
        Button(tab.isPinned ? "Unpin" : "Pin") { model.togglePin(tab) }
        Menu("Move to folder") {
            ForEach(model.spaceFolders) { f in
                Button(f.name) { model.move(tab, to: f.id) }
                    .disabled(tab.folderID == f.id)
            }
            if !model.spaceFolders.isEmpty { Divider() }
            Button("New folder...") { model.promptNewFolder(moving: tab) }
        }
        if tab.folderID != nil || tab.isPinned {
            Button("Move to Tabs") { model.move(tab, to: nil) }
        }
    }

    @ViewBuilder var webMenu: some View {
        splitMenu
        Divider()
        folderMenu
        Divider()
        if let u = tab.url {
            Button("Copy link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(u.absoluteString, forType: .string)
            }
        }
        Divider()
        if tab.isLoaded && (tab.isPinned || tab.folderID != nil) {
            Button("Unload") { model.close(tab) }
        }
        Button(!(tab.isPinned || tab.folderID != nil) ? "Close" : "Remove") { model.remove(tab) }
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
        .contentShape(Rectangle())
        .onTapGesture { model.toggleFolder(folder) }
        .onHover { hovering = $0 }
        .onDrop(of: [ItemDrag.type], isTargeted: $targeted) { providers in
            ItemDrag.load(providers) { ids in _ = model.moveTabs(ids: ids.map { $0.uuidString }, to: folder.id) }
        }
        .contextMenu {
            Button("Rename...") { model.promptRename(folder) }
            Button("Delete folder") { model.deleteFolder(folder) }
        }
    }
}
