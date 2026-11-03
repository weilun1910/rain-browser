import AppKit
import SwiftUI

struct LeftSidebar: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var settings = Settings.shared
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            topBar
            addressField
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    pinnedSection
                    foldersSection
                    tabsSection
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            bottomBar
        }
        .padding(.horizontal, 10)
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

    private var addressField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.tertiary)
            TextField("Search or enter address", text: $model.addressText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($addressFocused)
                .onSubmit { model.submitAddress(); addressFocused = false }
                .onExitCommand { addressFocused = false; model.addressEditing = false; model.syncAddress() }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(addressFocused ? 0.09 : 0.055)))
        .onChange(of: model.addressFocusToken) { addressFocused = true }
        .onChange(of: addressFocused) { _, f in
            model.addressEditing = f
            if !f { model.syncAddress() }
        }
    }

    // MARK: Sections

    @ViewBuilder private var pinnedSection: some View {
        let pinned = model.pinnedTabs
        if !pinned.isEmpty {
            SectionBox(title: "Pinned", onDrop: { ids in model.moveTabs(ids: ids, to: nil, pin: true) }) {
                ForEach(pinned) { TabRow(tab: $0) }
            }
        }
    }

    private var foldersSection: some View {
        SectionBox(title: "Folders", trailing: AnyView(SmallIconButton(symbol: "plus", help: "New folder") { model.promptNewFolder() })) {
            if model.folders.isEmpty {
                Text("No folders yet").font(.system(size: 12)).foregroundStyle(.tertiary).padding(.leading, 8)
            }
            ForEach(model.folders) { f in
                FolderRow(folder: f)
                if f.isExpanded {
                    VStack(spacing: 1) {
                        ForEach(model.tabs(in: f)) { TabRow(tab: $0) }
                        if model.tabs(in: f).isEmpty {
                            Text("Empty").font(.system(size: 12)).foregroundStyle(.tertiary).padding(.leading, 8).frame(height: 22)
                        }
                    }
                    .padding(.leading, 14)
                }
            }
        }
    }

    private var tabsSection: some View {
        SectionBox(title: "Tabs", trailing: AnyView(SmallIconButton(symbol: "square.and.pencil", help: "New note") { model.newNote() }),
                   onDrop: { ids in model.moveTabs(ids: ids, to: nil) }) {
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
            }
            .buttonStyle(.plain)
            ForEach(model.splits.reversed()) { SplitRow(split: $0) }
            ForEach(model.looseTabs) { TabRow(tab: $0) }
        }
    }

    private var bottomBar: some View {
        HStack {
            SmallIconButton(symbol: "gearshape", help: "Settings") { AppDelegate.shared?.openSettings() }
            if let msg = model.flashMessage {
                Text(msg).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .frame(height: 30)
        .padding(.bottom, 6)
    }
}

struct SectionBox<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    var onDrop: (([String]) -> Bool)? = nil
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
            .modifier(DropModifier(onDrop: onDrop, targeted: $targeted))
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
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.primary.opacity(0.11) : (hovering ? Color.primary.opacity(0.05) : .clear))
            )
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
        HStack(spacing: 8) {
            ZStack {
                if tab.isLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 16)
            Text(tab.displayTitle)
                .font(.system(size: 13))
                .lineLimit(1)
                .strikethrough(tab.isMissing, color: .secondary)
                .foregroundStyle(tab.isMissing ? .secondary : (tab.isLoaded || tab.kind != .web || model.isSelected(tab) ? .primary : .secondary))
            if tab.isMissing && hovering {
                Button("Locate") { model.locateNote(tab) }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color.accentColor)
            }
            Spacer(minLength: 0)
            if hovering {
                Button { tab.kind == .web ? model.close(tab) : model.remove(tab) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(tab.isPinned || tab.folderID != nil ? "Unload" : "Close")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
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
    }

    @ViewBuilder var folderMenu: some View {
        Button(tab.isPinned ? "Unpin" : "Pin") { model.togglePin(tab) }
        Menu("Move to folder") {
            ForEach(model.folders) { f in
                Button(f.name) { model.move(tab, to: f.id) }
                    .disabled(tab.folderID == f.id)
            }
            if !model.folders.isEmpty { Divider() }
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
        .onDrop(of: [ItemDrag.type], isTargeted: $targeted) { providers in
            ItemDrag.load(providers) { ids in _ = model.moveTabs(ids: ids.map { $0.uuidString }, to: folder.id) }
        }
        .contextMenu {
            Button("Rename...") { model.promptRename(folder) }
            Button("Delete folder") { model.deleteFolder(folder) }
        }
    }
}
