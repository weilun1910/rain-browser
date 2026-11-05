import AppKit
import SwiftUI
import WebKit

/// A space: its own pins, folders, tabs and splits, with a look of its own.
struct Space: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var icon: String = "house"
    var color: String = "#7A8CA8"
    /// Where new notes made in this space go. Nil means the app-wide default.
    var newNotesFolder: String?
    var selectedTab: UUID?
    var selectedSplit: UUID?

    static let palette: [(String, String)] = [
        ("Slate", "#7A8CA8"), ("Blue", "#4C8DF6"), ("Teal", "#2FA8A0"), ("Green", "#5DA55A"),
        ("Amber", "#E0A030"), ("Orange", "#E57A3C"), ("Rose", "#D9607A"), ("Purple", "#9070D8"),
    ]
    static let icons = ["house", "briefcase", "book", "graduationcap", "hammer", "paintbrush", "globe",
                        "leaf", "flame", "star", "heart", "bolt", "cart", "airplane", "music.note", "camera"]
}

struct Folder: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var spaceID: UUID?
    var name: String
    var isExpanded: Bool = true
    var createdAt: Date = Date()
}

struct TabRecord: Codable {
    var id: UUID
    var kind: TabKind
    var url: String?
    var title: String
    var isPinned: Bool
    var folderID: UUID?
    var createdAt: Date
    var spaceID: UUID?
}

/// Two items side by side. Either side can be a page or a note.
struct SplitRecord: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var left: UUID
    var right: UUID
    var ratio: Double = 0.5
    var focusRight: Bool = false
    var createdAt: Date = Date()
    var spaceID: UUID?

    var focused: UUID { focusRight ? right : left }
    var other: UUID { focusRight ? left : right }
    func contains(_ id: UUID) -> Bool { left == id || right == id }
}

struct SavedState: Codable {
    /// 2 adds spaces. Version 1 files have none and move into "Home".
    var version: Int? = 2
    var spaces: [Space]? = nil
    var currentSpace: UUID? = nil
    var tabs: [TabRecord] = []
    var folders: [Folder] = []
    var splits: [SplitRecord]? = nil
    var selectedSplit: UUID? = nil
    var selectedTab: UUID?
    /// Older versions opened notes outside the tab list.
    var selectedDocument: String?
}

enum Selection: Hashable {
    case tab(UUID)
    case split(UUID)
}

enum PaneSide { case left, right }

@MainActor
final class BrowserModel: ObservableObject {
    @Published var spaces: [Space] = []
    @Published private(set) var currentSpaceID = UUID()
    /// Every item in every space. New items land in the current space.
    @Published var tabs: [Tab] = [] {
        didSet { for t in tabs where t.spaceID == nil { t.spaceID = currentSpaceID } }
    }
    @Published var folders: [Folder] = [] {
        didSet {
            if folders.contains(where: { $0.spaceID == nil }) {
                for i in folders.indices where folders[i].spaceID == nil { folders[i].spaceID = currentSpaceID }
            }
        }
    }
    @Published private(set) var splits: [SplitRecord] = [] {
        didSet {
            if splits.contains(where: { $0.spaceID == nil }) {
                for i in splits.indices where splits[i].spaceID == nil { splits[i].spaceID = currentSpaceID }
            }
        }
    }
    @Published private(set) var selection: Selection?
    /// The note shown in the focused pane, if it's a note.
    @Published private(set) var document: NoteDocument?
    @Published var addressText = ""
    @Published var addressFocusToken = 0
    @Published var flashMessage: String?

    var addressEditing = false
    let webConfig: WKWebViewConfiguration
    let notes = NotesStore()
    let resurfacer = Resurfacer()
    let bar = CommandBar()
    /// Open note documents, by file path.
    private(set) var docs: [String: NoteDocument] = [:]
    private var history: [Selection] = []
    private var saveWork: DispatchWorkItem?
    private var flashWork: DispatchWorkItem?

    /// The smoke test uses a throwaway WebKit store so it leaves no cookies or site data behind.
    static var useEphemeralStore = false
    /// Set by --data-dir. A separate persistent WebKit store for that profile.
    static var dataStoreID: UUID?

    init() {
        let c = WKWebViewConfiguration()
        if Self.useEphemeralStore {
            c.websiteDataStore = .nonPersistent()
        } else if let id = Self.dataStoreID {
            c.websiteDataStore = WKWebsiteDataStore(forIdentifier: id)
        } else {
            c.websiteDataStore = .default()
        }
        c.preferences.isElementFullscreenEnabled = true
        c.preferences.javaScriptCanOpenWindowsAutomatically = false
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        c.applicationNameForUserAgent = "Version/\(major).0 Safari/605.1.15"
        TypingCounter.install(on: c.userContentController)
        webConfig = c
        resurfacer.model = self
        bar.model = self
        notes.onScan = { [weak self] in self?.checkNotesOnDisk() }
        load()
    }

    // MARK: - Derived

    func tab(_ id: UUID) -> Tab? { tabs.first { $0.id == id } }

    /// The focused item: the selected tab or note, or the focused pane of a split.
    var currentTab: Tab? {
        switch selection {
        case .tab(let id): return tab(id)
        case .split(let sid): return splits.first { $0.id == sid }.flatMap { tab($0.focused) }
        case nil: return nil
        }
    }

    var currentSplit: SplitRecord? {
        if case .split(let sid) = selection { return splits.first { $0.id == sid } }
        return nil
    }

    func split(containing id: UUID) -> SplitRecord? { splits.first { $0.contains(id) } }

    private var splitTabIDs: Set<UUID> { Set(splits.flatMap { [$0.left, $0.right] }) }

    /// The focused web tab, for the address bar and navigation.
    var currentWebTab: Tab? { currentTab.flatMap { $0.kind == .web ? $0 : nil } }

    var currentSpace: Space? { spaces.first { $0.id == currentSpaceID } }
    var spaceTabs: [Tab] { tabs.filter { $0.spaceID == currentSpaceID } }
    var spaceFolders: [Folder] { folders.filter { $0.spaceID == currentSpaceID } }
    var spaceSplits: [SplitRecord] { splits.filter { $0.spaceID == currentSpaceID } }

    // Items in a split show as the split's joined row, not on their own.
    var pinnedTabs: [Tab] { let s = splitTabIDs; return spaceTabs.filter { $0.isPinned && !s.contains($0.id) } }
    var looseTabs: [Tab] {
        let s = splitTabIDs
        return spaceTabs.filter { !$0.isPinned && $0.folderID == nil && !s.contains($0.id) }.sorted { $0.createdAt > $1.createdAt }
    }
    func tabs(in folder: Folder) -> [Tab] { let s = splitTabIDs; return tabs.filter { $0.folderID == folder.id && !$0.isPinned && !s.contains($0.id) } }

    /// True for the focused item (a selected tab, or the focused pane of the selected split).
    func isSelected(_ tab: Tab) -> Bool { currentTab?.id == tab.id }

    func isVisible(_ tab: Tab) -> Bool { visibleTabs.contains { $0.id == tab.id } }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Paths.stateFile),
              let s = try? JSONDecoder.iso.decode(SavedState.self, from: data) else {
            let home = Space(name: "Home")
            spaces = [home]
            currentSpaceID = home.id
            return
        }
        // Version 1 had no spaces: everything moves into one called Home.
        var sp = s.spaces ?? []
        if sp.isEmpty {
            sp = [Space(name: "Home", selectedTab: s.selectedTab, selectedSplit: s.selectedSplit)]
        }
        spaces = sp
        let home = sp[0].id
        currentSpaceID = s.currentSpace.flatMap { id in sp.contains { $0.id == id } ? id : nil } ?? home
        folders = s.folders.map { var f = $0; if f.spaceID == nil || !sp.contains(where: { $0.id == f.spaceID }) { f.spaceID = home }; return f }
        tabs = s.tabs.map { r in
            let kind: TabKind = r.kind == .file ? .note : r.kind
            let t = Tab(id: r.id, kind: kind, url: r.url.flatMap(URL.init(string:)), title: r.title,
                        isPinned: r.isPinned, folderID: r.folderID, createdAt: r.createdAt)
            t.model = self
            t.spaceID = r.spaceID.flatMap { id in sp.contains { $0.id == id } ? id : nil } ?? home
            return t
        }
        let ids = Set(tabs.map { $0.id })
        splits = (s.splits ?? []).filter { ids.contains($0.left) && ids.contains($0.right) && $0.left != $0.right }.map { r in
            var x = r
            if x.spaceID == nil || !sp.contains(where: { $0.id == x.spaceID }) { x.spaceID = tab(r.left)?.spaceID ?? home }
            return x
        }
        checkNotesOnDisk()
        let cur = currentSpace
        if let sid = cur?.selectedSplit ?? s.selectedSplit, let sp = splits.first(where: { $0.id == sid && $0.spaceID == currentSpaceID }) {
            selectSplit(sp)
        } else if let id = cur?.selectedTab ?? s.selectedTab, let t = tab(id), t.spaceID == currentSpaceID {
            select(t)
        } else if let p = s.selectedDocument, FileManager.default.fileExists(atPath: p) {
            openNote(URL(fileURLWithPath: p))
        }
    }

    func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveNow() } }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    func saveNow() {
        rememberSelection()
        var s = SavedState()
        s.spaces = spaces
        s.currentSpace = currentSpaceID
        s.folders = folders
        s.tabs = tabs.filter { !$0.isBlank }.map {
            TabRecord(id: $0.id, kind: $0.kind, url: $0.url?.absoluteString, title: $0.title,
                      isPinned: $0.isPinned, folderID: $0.folderID, createdAt: $0.createdAt, spaceID: $0.spaceID)
        }
        s.splits = splits
        switch selection {
        case .tab(let id): s.selectedTab = id
        case .split(let sid): s.selectedSplit = sid
        case nil: break
        }
        Paths.ensure(Paths.root)
        if let data = try? JSONEncoder.pretty.encode(s) {
            try? data.write(to: Paths.stateFile, options: .atomic)
        }
    }

    func prepareForQuit() {
        if let t = currentTab { endDwell(t) }
        for d in docs.values { d.saveNow() }
        saveNow()
    }

    // MARK: - Selection

    /// Items on screen right now. Notes not on screen get saved and let go.
    var visibleTabs: [Tab] {
        if let sp = currentSplit { return [tab(sp.left), tab(sp.right)].compactMap { $0 } }
        return currentTab.map { [$0] } ?? []
    }

    private func setSelection(_ new: Selection?) {
        let old = selection
        guard old != new else { return }
        if let old { history.removeAll { $0 == old }; history.append(old) }
        if history.count > 50 { history.removeFirst(history.count - 50) }
        if case .tab(let id) = old, let t = tab(id) {
            endDwell(t)
            if t.isBlank && split(containing: t.id) == nil { tabs.removeAll { $0.id == t.id }; history.removeAll { $0 == .tab(t.id) } }
        }
        if case .split(let sid) = old, let sp = splits.first(where: { $0.id == sid }), let t = tab(sp.focused) { endDwell(t) }
        selection = new
        refreshFocus()
        syncAddress()
        scheduleSave()
    }

    /// Recomputes the focused note and drops documents that are no longer visible.
    func refreshFocus() {
        let visibleNotes = visibleTabs.filter { $0.kind == .note }.compactMap { $0.url?.standardizedFileURL.path }
        for (path, d) in docs where !visibleNotes.contains(path) {
            d.saveNow()
            docs[path] = nil
        }
        if let t = currentTab, t.kind == .note, let u = t.url { document = doc(for: u) } else { document = nil }
    }

    func doc(for url: URL) -> NoteDocument {
        let key = url.standardizedFileURL.path
        if let d = docs[key] { return d }
        let d = NoteDocument(url: url)
        d.onPause = { [weak self] doc in self?.noteDidPause(doc) }
        d.onSaved = { doc in Indexer.indexNote(url: doc.url, text: doc.text) }
        d.onMissing = { [weak self] _ in self?.checkNotesOnDisk() }
        d.onLoaded = { [weak self] doc in self?.noteDidPause(doc) }
        docs[key] = d
        return d
    }

    func noteDidPause(_ doc: NoteDocument) {
        if document === doc { resurfacer.contextFromDocument(doc) }
    }

    func select(_ tab: Tab) {
        if let sid = tab.spaceID, sid != currentSpaceID { switchSpace(to: sid, restore: false) }
        if let sp = split(containing: tab.id) {
            // Picking an item that lives in a split brings the split back, focused on it.
            selectSplit(sp, focus: sp.right == tab.id ? .right : .left)
            return
        }
        setSelection(.tab(tab.id))
        contextForFocused()
    }

    /// Points the Related panel and the dwell clock at the focused item.
    func contextForFocused() {
        guard let tab = currentTab else { return }
        if tab.kind == .note, let u = tab.url {
            refreshFocus()
            IndexStore.shared.touchOpened(key: URLKey.fileKey(u))
            if let d = document { resurfacer.contextFromDocument(d) }
            return
        }
        if tab.url != nil { _ = tab.ensureWebView() }
        startDwell(tab)
        if let u = tab.url { IndexStore.shared.touchOpened(key: URLKey.key(for: u)) }
        resurfacer.contextFromTab(tab)
    }

    func syncAddress() {
        guard !addressEditing else { return }
        addressText = currentWebTab?.url?.absoluteString ?? ""
    }

    /// Cmd-L: the bar with the focused page's address selected. Enter loads in that pane.
    func focusAddress() {
        if let t = currentWebTab, let u = t.url ?? t.webView?.url {
            bar.open(.navigate(t.id), text: u.absoluteString)
        } else if let t = currentWebTab {
            bar.open(.navigate(t.id))
        } else {
            bar.open(.newTab)
        }
    }

    /// What a pick in the command bar does, for each way the bar was opened.
    func commandPick(_ kind: Suggestion.Kind, mode: CommandBar.Mode) {
        switch kind {
        case .tab(let id):
            guard let t = tab(id) else { return }
            if mode == .split { openInSplit(t, side: .right) } else { select(t) }
        case .note(let u):
            if mode == .split { openInSplit(openNote(u, select: false), side: .right) } else { openNote(u) }
        case .newNote(let title):
            guard let url = notes.create(in: newNotesFolder, title: title) else {
                flash("Couldn't create a note in \(newNotesFolder.lastPathComponent)")
                return
            }
            if mode == .split { openInSplit(openNote(url, select: false), side: .right) } else { openNote(url) }
            DispatchQueue.main.async { NotificationCenter.default.post(name: .focusEditor, object: nil) }
        case .openURL(let u), .history(let u):
            openWeb(u, mode: mode)
        case .google(let q), .pastSearch(let q):
            IndexStore.shared.addSearch(q)
            if let u = AddressParser.search(q) { openWeb(u, mode: mode) }
        }
    }

    private func openWeb(_ u: URL, mode: CommandBar.Mode) {
        switch mode {
        case .navigate(let id):
            if let t = tab(id), t.kind == .web {
                t.load(u)
                focusWeb(t)
                scheduleSave()
                return
            }
            let t = newTab(url: u, select: true)
            focusWeb(t)
        case .newTab:
            let t = newTab(url: u, select: true)
            focusWeb(t)
        case .split:
            let t = Tab(url: u)
            t.model = self
            tabs.append(t)
            openInSplit(t, side: .right)
            _ = t.ensureWebView()
            focusWeb(t)
        }
    }

    // MARK: - Tabs

    @discardableResult
    func newTab(url: URL? = nil, select doSelect: Bool = true, focus: Bool = false,
                configuration: WKWebViewConfiguration? = nil) -> Tab {
        let t = Tab(url: url)
        t.model = self
        tabs.append(t)
        if configuration != nil { _ = t.ensureWebView(configuration: configuration) }
        if doSelect { select(t) } else if url != nil {
            _ = t.ensureWebView()
        }
        if focus { focusAddress() }
        scheduleSave()
        return t
    }

    // MARK: - Split view

    func selectSplit(_ sp: SplitRecord, focus: PaneSide? = nil) {
        if let sid = sp.spaceID, sid != currentSpaceID { switchSpace(to: sid, restore: false) }
        if let focus, let i = splits.firstIndex(where: { $0.id == sp.id }) {
            splits[i].focusRight = focus == .right
        }
        if selection == .split(sp.id) {
            refreshFocus()
            syncAddress()
        } else {
            setSelection(.split(sp.id))
        }
        for t in visibleTabs where t.kind == .web && t.url != nil { _ = t.ensureWebView() }
        contextForFocused()
        scheduleSave()
    }

    /// Pairs an item with what's on screen. In a split, it replaces the pane on that side.
    func openInSplit(_ tab: Tab, side: PaneSide = .right) {
        if let old = split(containing: tab.id) { splits.removeAll { $0.id == old.id } }
        if let sp = currentSplit, let i = splits.firstIndex(where: { $0.id == sp.id }) {
            if side == .left { splits[i].left = tab.id } else { splits[i].right = tab.id }
            splits[i].focusRight = side == .right
            if splits[i].left == splits[i].right { splits.remove(at: i); select(tab); return }
            selectSplit(splits[i])
            return
        }
        guard let cur = currentTab, cur.id != tab.id else { select(tab); return }
        if let old = split(containing: cur.id) { splits.removeAll { $0.id == old.id } }
        let sp = side == .right ? SplitRecord(left: cur.id, right: tab.id, focusRight: true)
                                : SplitRecord(left: tab.id, right: cur.id, focusRight: false)
        splits.append(sp)
        selectSplit(sp)
    }

    /// Both items go back to being normal items.
    func separate(_ sp: SplitRecord) {
        let focused = tab(sp.focused)
        splits.removeAll { $0.id == sp.id }
        if selection == .split(sp.id) {
            selection = nil
            if let focused { select(focused) }
        }
        scheduleSave()
    }

    func swap(_ sp: SplitRecord) {
        guard let i = splits.firstIndex(where: { $0.id == sp.id }) else { return }
        let l = splits[i].left
        splits[i].left = splits[i].right
        splits[i].right = l
        splits[i].focusRight.toggle()
        scheduleSave()
    }

    func focusPane(_ side: PaneSide) {
        guard let sp = currentSplit, let i = splits.firstIndex(where: { $0.id == sp.id }) else { return }
        let right = side == .right
        guard splits[i].focusRight != right else { return }
        if let t = tab(sp.focused) { endDwell(t) }
        splits[i].focusRight = right
        refreshFocus()
        syncAddress()
        contextForFocused()
        scheduleSave()
    }

    func setSplitRatio(_ r: Double, save: Bool) {
        guard let sp = currentSplit, let i = splits.firstIndex(where: { $0.id == sp.id }) else { return }
        splits[i].ratio = min(0.8, max(0.2, r))
        if save { scheduleSave() }
    }

    /// The other pane stays, full width.
    private func dissolveSplit(around removed: UUID) {
        guard let sp = split(containing: removed) else { return }
        let keep = sp.left == removed ? sp.right : sp.left
        let wasSelected = selection == .split(sp.id)
        splits.removeAll { $0.id == sp.id }
        if wasSelected, let t = tab(keep) {
            selection = nil
            select(t)
        }
    }

    /// A sidebar item dropped on one half of the content area.
    func drop(tabID: UUID, side: PaneSide) {
        guard let t = tab(tabID) else { return }
        if currentTab == nil { select(t); return }
        openInSplit(t, side: side)
    }

    /// Ctrl-Shift-=: the bar, and whatever's picked opens as the second pane.
    func splitWithNewTab() {
        bar.open(currentTab == nil ? .newTab : .split)
    }

    /// Cmd-T and New tab: the bar. Nothing is created until something is picked.
    func newTabCommand() {
        bar.open(.newTab)
    }

    func submitAddress() {
        let text = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let url = AddressParser.url(for: text) else { return }
        addressEditing = false
        if let t = currentWebTab {
            t.load(url)
            focusWeb(t)
        } else {
            let t = newTab(url: url, select: true)
            focusWeb(t)
        }
        scheduleSave()
    }

    func focusWeb(_ t: Tab) {
        DispatchQueue.main.async {
            if let wv = t.webView { wv.window?.makeFirstResponder(wv) }
        }
    }

    /// Closing a page unloads it if it's pinned or filed and removes it otherwise.
    /// Closing a note only takes it out of the sidebar; the file stays.
    func close(_ tab: Tab) {
        if split(containing: tab.id) != nil { dissolveSplit(around: tab.id) }
        let wasSelected = isSelected(tab)
        if tab.kind == .note {
            if let u = tab.url { docs[u.standardizedFileURL.path]?.saveNow() }
            if !(tab.isPinned || tab.folderID != nil) { tabs.removeAll { $0.id == tab.id } }
        } else if tab.isPinned || tab.folderID != nil {
            tab.unload()
        } else {
            tab.unload()
            tabs.removeAll { $0.id == tab.id }
        }
        history.removeAll { $0 == .tab(tab.id) && !tabs.contains(where: { $0.id == tab.id }) }
        if wasSelected { selectPrevious(excluding: .tab(tab.id)) } else { refreshFocus() }
        objectWillChange.send()
        scheduleSave()
    }

    /// Takes any item out of the sidebar. For notes the file stays on disk.
    func remove(_ tab: Tab) {
        if split(containing: tab.id) != nil { dissolveSplit(around: tab.id) }
        let wasSelected = isSelected(tab)
        if tab.kind == .note, let u = tab.url { docs[u.standardizedFileURL.path]?.saveNow() }
        tab.unload()
        tabs.removeAll { $0.id == tab.id }
        history.removeAll { $0 == .tab(tab.id) }
        if wasSelected { selectPrevious(excluding: .tab(tab.id)) } else { refreshFocus() }
        scheduleSave()
    }

    private func selectPrevious(excluding: Selection) {
        // Earlier items in other spaces stay in the history for when you go back there.
        var skipped: [Selection] = []
        defer { history.append(contentsOf: skipped.reversed()) }
        while let last = history.popLast() {
            if last == excluding { continue }
            if case .tab(let id) = last, let t = tab(id) {
                if t.spaceID != currentSpaceID { skipped.append(last); continue }
                selection = nil; select(t); return
            }
            if case .split(let sid) = last, let sp = splits.first(where: { $0.id == sid }) {
                if sp.spaceID != currentSpaceID { skipped.append(last); continue }
                selection = nil; selectSplit(sp); return
            }
        }
        if let t = looseTabs.first ?? pinnedTabs.first(where: { $0.isLoaded }) {
            selection = nil
            select(t)
        } else {
            setSelection(nil)
            resurfacer.setContext(nil)
        }
    }

    func closeCurrent() {
        guard let t = currentTab else { return }
        if split(containing: t.id) != nil {
            dissolveSplit(around: t.id)
            if t.kind == .note || !(t.isPinned || t.folderID != nil) { remove(t) } else { t.unload() }
            refreshFocus()
            scheduleSave()
            return
        }
        close(t)
    }

    func goBack() { currentWebTab?.webView?.goBack() }
    func goForward() { currentWebTab?.webView?.goForward() }
    func reload() {
        guard let t = currentWebTab else { return }
        if let wv = t.webView { t.loadError = nil; wv.reload() } else if t.url != nil { _ = t.ensureWebView() }
    }
    func zoom(_ delta: Double?) {
        guard let wv = currentWebTab?.webView else { return }
        if let delta { wv.pageZoom = max(0.5, min(3, wv.pageZoom + delta)) } else { wv.pageZoom = 1 }
    }

    func togglePin(_ tab: Tab) {
        tab.isPinned.toggle()
        if tab.isPinned { tab.folderID = nil }
        objectWillChange.send()
        scheduleSave()
    }

    func move(_ tab: Tab, to folderID: UUID?) {
        tab.folderID = folderID
        tab.isPinned = false
        if let folderID, let i = folders.firstIndex(where: { $0.id == folderID }) { folders[i].isExpanded = true }
        objectWillChange.send()
        scheduleSave()
    }

    func moveTabs(ids: [String], to folderID: UUID?, pin: Bool = false) -> Bool {
        var moved = false
        for s in ids {
            guard let id = UUID(uuidString: s), let t = tab(id) else { continue }
            if pin { t.isPinned = true; t.folderID = nil } else { move(t, to: folderID) }
            moved = true
        }
        objectWillChange.send()
        scheduleSave()
        return moved
    }

    // MARK: - Folders

    @discardableResult
    func createFolder(named name: String) -> Folder {
        let f = Folder(spaceID: currentSpaceID, name: name)
        folders.append(f)
        scheduleSave()
        return f
    }

    func renameFolder(_ f: Folder, to name: String) {
        guard let i = folders.firstIndex(where: { $0.id == f.id }) else { return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        folders[i].name = n
        scheduleSave()
    }

    /// Items in the folder go back to Tabs. Notes on disk are untouched.
    func deleteFolder(_ f: Folder) {
        for t in tabs where t.folderID == f.id { t.folderID = nil }
        folders.removeAll { $0.id == f.id }
        objectWillChange.send()
        scheduleSave()
    }

    func toggleFolder(_ f: Folder) {
        guard let i = folders.firstIndex(where: { $0.id == f.id }) else { return }
        folders[i].isExpanded.toggle()
        scheduleSave()
    }

    func promptNewFolder(moving tab: Tab? = nil) {
        guard let name = Prompt.text(title: "New folder", message: "Name", defaultValue: ""), !name.isEmpty else { return }
        let f = createFolder(named: name)
        if let tab { move(tab, to: f.id) }
    }

    func promptRename(_ f: Folder) {
        if let name = Prompt.text(title: "Rename folder", message: "Name", defaultValue: f.name) { renameFolder(f, to: name) }
    }

    func researchFolder() -> Folder {
        if let f = spaceFolders.first(where: { $0.name == "Research" }) { return f }
        return createFolder(named: "Research")
    }

    // MARK: - Notes

    /// Opens a note as a sidebar item, reusing the item if it's already there.
    @discardableResult
    func openNote(_ url: URL, select doSelect: Bool = true) -> Tab {
        let path = url.standardizedFileURL.path
        if let t = spaceTabs.first(where: { $0.kind == .note && $0.url?.standardizedFileURL.path == path }) {
            if doSelect { select(t) }
            return t
        }
        let t = Tab(kind: .note, url: url.standardizedFileURL, title: url.deletingPathExtension().lastPathComponent)
        t.model = self
        tabs.append(t)
        if doSelect { select(t) }
        scheduleSave()
        return t
    }

    /// The folder new notes go in: the space's own choice, else the app-wide default.
    var newNotesFolder: URL {
        let roots = Settings.shared.value.notesRoots
        if let p = currentSpace?.newNotesFolder {
            let u = URL(fileURLWithPath: p, isDirectory: true)
            if roots.contains(where: { FileSafety.isInside(u, $0) || $0.standardizedFileURL.path == u.standardizedFileURL.path }) { return u }
        }
        return Settings.shared.value.defaultNewNotesFolder
    }

    @discardableResult
    func newNote(title: String? = nil) -> Tab? {
        guard let url = notes.create(in: newNotesFolder, title: title) else {
            flash("Couldn't create a note in \(newNotesFolder.lastPathComponent)")
            return nil
        }
        let t = openNote(url)
        DispatchQueue.main.async { NotificationCenter.default.post(name: .focusEditor, object: nil) }
        return t
    }

    func renameNote(_ tab: Tab, to name: String) -> NotesStore.RenameResult {
        guard tab.kind == .note, let url = tab.url else { return .failed }
        let d = docs[url.standardizedFileURL.path]
        d?.saveNow()
        let r = notes.rename(url, to: name)
        if case .renamed(let newURL) = r {
            Indexer.removeFile(url: url)
            if let data = NotesScan.read(newURL) { Indexer.indexNote(url: newURL, text: NotesScan.decode(data)) }
            tab.url = newURL
            tab.title = newURL.deletingPathExtension().lastPathComponent
            if let d {
                docs[url.standardizedFileURL.path] = nil
                d.relocate(to: newURL)
                docs[newURL.standardizedFileURL.path] = d
            }
            if isSelected(tab), let d = document { resurfacer.contextFromDocument(d) }
            scheduleSave()
        }
        return r
    }

    func promptRenameNote(_ tab: Tab) {
        guard let url = tab.url else { return }
        var proposal = url.deletingPathExtension().lastPathComponent
        while let name = Prompt.text(title: "Rename note", message: "File name", defaultValue: proposal), !name.isEmpty {
            switch renameNote(tab, to: name) {
            case .renamed: return
            case .taken(let other):
                Prompt.info(title: "That name is taken", message: "There's already a note called \(other.deletingPathExtension().lastPathComponent) in this folder. Pick another name.")
                proposal = name
            case .failed:
                flash("Couldn't rename that note")
                return
            }
        }
    }

    /// Moves the note's file to the Trash and removes the item.
    func deleteNote(_ tab: Tab, completion: ((Bool) -> Void)? = nil) {
        guard tab.kind == .note, let url = tab.url else { completion?(false); return }
        docs[url.standardizedFileURL.path] = nil
        notes.trash(url) { [weak self] ok in
            guard let self else { return }
            if ok {
                Indexer.removeFile(url: url)
                self.remove(tab)
            } else {
                self.flash("Couldn't move that note to the Trash")
            }
            completion?(ok)
        }
    }

    func promptDeleteNote(_ tab: Tab) {
        guard let url = tab.url else { return }
        if Prompt.confirm(title: "Move \(url.lastPathComponent) to the Trash?",
                          message: "You can put it back from the Trash in Finder.", ok: "Move to Trash") {
            deleteNote(tab)
        }
    }

    func locateNote(_ tab: Tab) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.init(filenameExtension: "md")!]
        p.allowsMultipleSelection = false
        p.prompt = "Use this file"
        if let dir = tab.url?.deletingLastPathComponent(), FileManager.default.fileExists(atPath: dir.path) { p.directoryURL = dir }
        guard p.runModal() == .OK, let u = p.url else { return }
        let old = tab.url
        tab.url = u.standardizedFileURL
        tab.title = u.deletingPathExtension().lastPathComponent
        tab.isMissing = false
        if let old, let d = docs[old.standardizedFileURL.path] {
            docs[old.standardizedFileURL.path] = nil
            d.relocate(to: u)
            docs[u.standardizedFileURL.path] = d
        }
        refreshFocus()
        scheduleSave()
    }

    /// Marks note items whose files are gone, and lets open notes check for outside changes.
    func checkNotesOnDisk() {
        for t in tabs where t.kind == .note {
            let missing = t.url.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true
            if t.isMissing != missing { t.isMissing = missing }
        }
        for d in docs.values { d.checkDisk() }
    }

    // MARK: - Pages and context

    func tabURLChanged(_ tab: Tab, from old: URL?) {
        if isSelected(tab) { syncAddress() }
        // Same-document navigations (single page apps) don't fire didFinish.
        if let wv = tab.webView, !wv.isLoading, old != nil, old != tab.url {
            pageDidFinish(tab)
        }
        scheduleSave()
    }

    func pageWillNavigate(_ tab: Tab) {
        tab.docsExport = nil
        tab.docsExportStarted = false
        endDwell(tab)
        tab.captureWork?.cancel()
        tab.contextWork?.cancel()
    }

    func pageDidFinish(_ tab: Tab) {
        guard let wv = tab.webView, let url = wv.url else { return }
        if isSelected(tab) { startDwell(tab); syncAddress() }
        tab.captureWork?.cancel()
        tab.contextWork?.cancel()
        let indexable = URLKey.isIndexableWeb(url) && !Settings.shared.value.isExcluded(host: url.host)
        let isGoogleDoc = DocsExport.url(for: url) != nil
        // Context for the right panel, once the page settles. Google Docs draw text on a canvas,
        // so their text comes from the export instead of the page.
        let ctx = DispatchWorkItem { [weak self, weak tab] in
            MainActor.assumeIsolated {
                guard let self, let tab, tab.webView?.url == url else { return }
                tab.extract { e in
                    guard let e else { tab.lastExtract = nil; return }
                    if isGoogleDoc && !tab.docsExportStarted {
                        tab.docsExportStarted = true
                        tab.fetchDocsExport { text in
                            tab.docsExport = text
                            tab.lastExtract = PageExtract(url: e.url, title: Tab.cleanDocsTitle(e.title), description: "", text: text ?? "")
                            if self.isSelected(tab) { self.resurfacer.contextFromTab(tab) }
                        }
                        return
                    }
                    if isGoogleDoc {
                        tab.lastExtract = PageExtract(url: e.url, title: Tab.cleanDocsTitle(e.title), description: "", text: tab.docsExport ?? "")
                    } else {
                        tab.lastExtract = e
                    }
                    if self.isSelected(tab) { self.resurfacer.contextFromTab(tab) }
                }
            }
        }
        tab.contextWork = ctx
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: ctx)
        guard indexable else { return }
        // Index it if it stays open about five seconds.
        let cap = DispatchWorkItem { [weak tab] in
            MainActor.assumeIsolated {
                guard let tab, tab.webView?.url == url else { return }
                tab.extract { e in
                    guard let e, tab.webView?.url == url else { return }
                    if isGoogleDoc {
                        // The export, or the title alone if the export didn't work.
                        Indexer.indexPage(url: url, title: Tab.cleanDocsTitle(e.title), description: "", text: tab.docsExport ?? "")
                        return
                    }
                    tab.lastExtract = e
                    Indexer.indexPage(url: url, title: e.title, description: e.description, text: e.text)
                }
            }
        }
        tab.captureWork = cap
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: cap)
    }

    func startDwell(_ tab: Tab) {
        guard let u = tab.webView?.url ?? tab.url, URLKey.isIndexableWeb(u) else { return }
        if tab.activeSince == nil {
            tab.activeSince = Date()
            tab.activeKey = URLKey.key(for: u)
        }
    }

    func endDwell(_ tab: Tab) {
        guard let start = tab.activeSince, let key = tab.activeKey else { return }
        tab.activeSince = nil
        tab.activeKey = nil
        let secs = Date().timeIntervalSince(start)
        guard secs > 1 else { return }
        // Runs after the capture write, which is also queued on the indexer.
        Indexer.work.async { IndexStore.shared.addDwell(key: key, seconds: min(secs, 3600)) }
    }

    // MARK: - Cards

    func open(_ card: Card) {
        let d = card.match.doc
        guard let u = URL(string: d.url) else { return }
        switch d.source {
        case .web, .chrome: newTab(url: u, select: true)
        case .note, .markdown: openNote(u)
        }
        IndexStore.shared.touchOpened(key: d.key)
    }

    /// The editable note on screen that Add to research writes into, if any.
    var researchNote: NoteDocument? {
        if let d = document, !d.isReadOnly, d.state == .ready { return d }
        // Reading a page next to a note: the note is where research goes.
        for t in visibleTabs where t.kind == .note {
            if let u = t.url, let d = docs[u.standardizedFileURL.path], !d.isReadOnly, d.state == .ready { return d }
        }
        return nil
    }

    /// Notes get a link under "## Related". Pages get the item added to their folder, or to "Research".
    func addToResearch(_ card: Card) -> String {
        let d = card.match.doc
        if let doc = researchNote {
            guard let newText = Markdown.appendRelated(to: doc.text, title: d.title, url: d.url) else { return "Already linked" }
            doc.replaceText(newText)
            return "Added to note"
        }
        let folder: Folder
        if let fid = currentTab?.folderID, let f = spaceFolders.first(where: { $0.id == fid }) { folder = f } else { folder = researchFolder() }
        guard let u = URL(string: d.url) else { return "Couldn't add" }
        let key = u.isFileURL ? u.standardizedFileURL.path : URLKey.key(for: u)
        if tabs.contains(where: { $0.folderID == folder.id && $0.url.map { $0.isFileURL ? $0.standardizedFileURL.path : URLKey.key(for: $0) } == key }) {
            return "Already in \(folder.name)"
        }
        let isNote = d.source == .note || d.source == .markdown
        let t = Tab(kind: isNote ? .note : .web, url: u, title: isNote ? u.deletingPathExtension().lastPathComponent : d.title, folderID: folder.id)
        t.model = self
        tabs.append(t)
        if let i = folders.firstIndex(where: { $0.id == folder.id }) { folders[i].isExpanded = true }
        scheduleSave()
        return "Added to \(folder.name)"
    }

    /// "Research" for an item filed in this space, or "Work" when it lives in another space.
    func folderName(forURL s: String) -> String? {
        guard let u = URL(string: s) else { return nil }
        let key = u.isFileURL ? u.standardizedFileURL.path : URLKey.key(for: u)
        let matches = tabs.filter { t in t.url.map { ($0.isFileURL ? $0.standardizedFileURL.path : URLKey.key(for: $0)) == key } ?? false }
        if let here = matches.first(where: { $0.spaceID == currentSpaceID && $0.folderID != nil }) {
            return folders.first { $0.id == here.folderID }?.name
        }
        if matches.contains(where: { $0.spaceID == currentSpaceID }) { return nil }
        if let there = matches.first, let sp = spaces.first(where: { $0.id == there.spaceID }) {
            if let f = folders.first(where: { $0.id == there.folderID }) { return "\(sp.name), \(f.name)" }
            return sp.name
        }
        return nil
    }

    // MARK: - Spaces

    private func rememberSelection() {
        guard let i = spaces.firstIndex(where: { $0.id == currentSpaceID }) else { return }
        switch selection {
        case .tab(let id): spaces[i].selectedTab = id; spaces[i].selectedSplit = nil
        case .split(let sid): spaces[i].selectedSplit = sid; spaces[i].selectedTab = nil
        case nil: spaces[i].selectedTab = nil; spaces[i].selectedSplit = nil
        }
    }

    /// Instant: each space comes back to the tab or split it last showed.
    func switchSpace(to id: UUID, restore: Bool = true) {
        guard id != currentSpaceID, spaces.contains(where: { $0.id == id }) else { return }
        if let t = currentTab { endDwell(t) }
        rememberSelection()
        currentSpaceID = id
        selection = nil
        refreshFocus()
        if restore {
            let sp = currentSpace
            if let sid = sp?.selectedSplit, let s = splits.first(where: { $0.id == sid && $0.spaceID == id }) {
                selectSplit(s)
            } else if let tid = sp?.selectedTab, let t = tab(tid), t.spaceID == id {
                select(t)
            } else {
                syncAddress()
                resurfacer.setContext(nil)
            }
        }
        scheduleSave()
    }

    func switchSpace(index: Int) {
        guard index >= 0, index < spaces.count else { return }
        switchSpace(to: spaces[index].id)
    }

    func switchSpace(by step: Int) {
        guard let i = spaces.firstIndex(where: { $0.id == currentSpaceID }), !spaces.isEmpty else { return }
        let j = i + step
        guard j >= 0, j < spaces.count else { return }
        switchSpace(to: spaces[j].id)
    }

    @discardableResult
    func createSpace(name: String, icon: String? = nil, color: String? = nil) -> Space {
        let used = Set(spaces.map { $0.color })
        let pick = Space.palette.first { !used.contains($0.1) }?.1 ?? Space.palette[spaces.count % Space.palette.count].1
        let sp = Space(name: name, icon: icon ?? Space.icons[spaces.count % Space.icons.count], color: color ?? pick)
        spaces.append(sp)
        scheduleSave()
        return sp
    }

    func updateSpace(_ id: UUID, _ change: (inout Space) -> Void) {
        guard let i = spaces.firstIndex(where: { $0.id == id }) else { return }
        change(&spaces[i])
        scheduleSave()
    }

    func moveSpace(_ id: UUID, by step: Int) {
        guard let i = spaces.firstIndex(where: { $0.id == id }) else { return }
        let j = i + step
        guard j >= 0, j < spaces.count else { return }
        spaces.swapAt(i, j)
        scheduleSave()
    }

    /// Closes the space's tabs and drops its pins, folders and splits. Notes on disk stay.
    func deleteSpace(_ id: UUID) {
        guard spaces.count > 1, let i = spaces.firstIndex(where: { $0.id == id }) else { return }
        if currentSpaceID == id {
            let other = spaces[i == 0 ? 1 : i - 1].id
            switchSpace(to: other)
        }
        for t in tabs where t.spaceID == id {
            if t.kind == .note, let u = t.url { docs[u.standardizedFileURL.path]?.saveNow() }
            t.unload()
        }
        let gone = Set(tabs.filter { $0.spaceID == id }.map { $0.id })
        tabs.removeAll { $0.spaceID == id }
        splits.removeAll { $0.spaceID == id }
        folders.removeAll { $0.spaceID == id }
        history.removeAll { if case .tab(let t) = $0 { return gone.contains(t) }; return false }
        spaces.remove(at: i)
        refreshFocus()
        scheduleSave()
    }

    func promptDeleteSpace(_ sp: Space) {
        guard spaces.count > 1 else { Prompt.info(title: "This is your only space", message: "Make another space before deleting this one."); return }
        if Prompt.confirm(title: "Delete the \(sp.name) space?",
                          message: "Its tabs close and its pins, folders and splits go with it. Notes on disk aren't touched.", ok: "Delete space") {
            deleteSpace(sp.id)
        }
    }

    func promptNewSpace() {
        guard let name = Prompt.text(title: "New space", message: "Name", defaultValue: ""), !name.isEmpty else { return }
        let sp = createSpace(name: name)
        switchSpace(to: sp.id)
    }

    func promptRenameSpace(_ sp: Space) {
        if let name = Prompt.text(title: "Rename space", message: "Name", defaultValue: sp.name), !name.isEmpty {
            updateSpace(sp.id) { $0.name = name }
        }
    }

    func promptSpaceEmoji(_ sp: Space) {
        if let e = Prompt.text(title: "Space icon", message: "Type an emoji", defaultValue: ""), let first = e.first {
            updateSpace(sp.id) { $0.icon = String(first) }
        }
    }

    /// Moves an item to another space, loose in its Tabs list.
    func move(_ tab: Tab, toSpace id: UUID) {
        guard tab.spaceID != id else { return }
        let wasSelected = isSelected(tab)
        if split(containing: tab.id) != nil { dissolveSplit(around: tab.id) }
        if wasSelected { endDwell(tab) }
        tab.spaceID = id
        tab.folderID = nil
        tab.isPinned = false
        if wasSelected || isVisible(tab) { selectPrevious(excluding: .tab(tab.id)) }
        objectWillChange.send()
        scheduleSave()
    }

    func move(split sp: SplitRecord, toSpace id: UUID) {
        guard let i = splits.firstIndex(where: { $0.id == sp.id }), sp.spaceID != id else { return }
        let wasSelected = selection == .split(sp.id)
        for tid in [sp.left, sp.right] {
            if let t = tab(tid) { t.spaceID = id; t.folderID = nil; t.isPinned = false }
        }
        splits[i].spaceID = id
        if wasSelected { selectPrevious(excluding: .split(sp.id)) }
        objectWillChange.send()
        scheduleSave()
    }

    // MARK: - Misc

    func flash(_ message: String) {
        flashMessage = message
        flashWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.flashMessage = nil } }
        flashWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)
    }

    func openFromSystem(_ urls: [URL]) {
        for u in urls {
            if u.isFileURL && u.pathExtension.lowercased() == "md" { openNote(u) } else { newTab(url: u, select: true) }
        }
    }
}

enum AddressParser {
    static func url(for input: String) -> URL? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        let lower = s.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("about:") || lower.hasPrefix("file://") {
            return URL(string: s) ?? search(s)
        }
        if !s.contains(" ") {
            if lower.hasPrefix("localhost") || lower.range(of: "^[0-9]{1,3}(\\.[0-9]{1,3}){3}(:[0-9]+)?(/.*)?$", options: .regularExpression) != nil {
                return URL(string: "http://" + s)
            }
            if let dot = s.firstIndex(of: "."), dot != s.startIndex, s.last != ".",
               s.range(of: "^[^/?#]+\\.[a-zA-Z]{2,}(:[0-9]+)?([/?#].*)?$", options: .regularExpression) != nil {
                return URL(string: "https://" + s) ?? search(s)
            }
        }
        return search(s)
    }

    static func search(_ q: String) -> URL? {
        var c = URLComponents(string: "https://www.google.com/search")!
        c.queryItems = [URLQueryItem(name: "q", value: q)]
        return c.url
    }
}

@MainActor
enum Prompt {
    static func text(title: String, message: String, defaultValue: String) -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultValue
        a.accessoryView = field
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let v = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return v
    }

    static func info(title: String, message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    static func confirm(title: String, message: String, ok: String) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: ok)
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }
}

extension Notification.Name {
    static let focusEditor = Notification.Name("local.browserpoc.focusEditor")
}
