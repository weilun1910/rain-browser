import AppKit
import Combine
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
    /// The profile whose cookies and logins this space uses. Nil is the default profile.
    var profile: String?
    /// The space's folder on disk, by name inside the space folders root. Added 8 Nov 2026.
    var folderName: String?
    /// Finds the folder again if it's renamed or moved in Finder.
    var folderBookmark: Data?

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
    /// Sort key among the folders beside it. Filled in on load for older files.
    var order: Double?
    /// The folder it's inside, or nil at the top of the Folders section. Added 8 Nov 2026.
    var parentID: UUID? = nil
    /// The folder on disk it shows, as SpaceFolders encodes it. Nil for a folder that lives only
    /// in state.json, from before space folders. Added 8 Nov 2026.
    var path: String? = nil
    /// Finds a pinned folder again after it's moved in Finder.
    var bookmark: Data? = nil
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
    // Added in version 3. Optional so older files still load.
    var isEssential: Bool?
    var pinnedURL: String?
    var customTitle: String?
    var order: Double?
    var lastActiveAt: Date?
    var isMuted: Bool?
    /// The saved page or note in a space folder this tab came from, relative to the space folders
    /// root when it's inside it. Added 8 Nov 2026.
    var savedFile: String?
}

struct SavedState: Codable {
    /// 2 adds spaces. 3 adds Essentials, pinned addresses, ordering and split trees.
    /// Version 1 files have no spaces and move into "Home".
    var version: Int? = 3
    var spaces: [Space]? = nil
    var currentSpace: UUID? = nil
    var tabs: [TabRecord] = []
    var folders: [Folder] = []
    var splits: [SplitRecord]? = nil
    var selectedSplit: UUID? = nil
    var selectedTab: UUID?
    /// Older versions opened notes outside the tab list.
    var selectedDocument: String?
    /// 1 once the sidebar's folders have moved onto disk. See SpaceFolderMigration. Added 8 Nov 2026.
    var diskFolders: Int? = nil
}

// Reading state.json never fails over one bad value. A field that's missing or the wrong shape
// falls back to its default, and a tab, space, folder or split that can't be read at all is left
// out. Either way SavedFile keeps a copy of the original file before the app saves over it.
// New fields must be optional or have a default here, so files from older builds keep loading.
// Decoders live in extensions so the memberwise initializers stay.

extension SavedState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.lenient(Int.self, .version, decoder)
        spaces = c.lenientArray(Space.self, .spaces, decoder)
        currentSpace = c.lenient(UUID.self, .currentSpace, decoder)
        tabs = c.lenientArray(TabRecord.self, .tabs, decoder) ?? []
        folders = c.lenientArray(Folder.self, .folders, decoder) ?? []
        splits = c.lenientArray(SplitRecord.self, .splits, decoder)
        selectedSplit = c.lenient(UUID.self, .selectedSplit, decoder)
        selectedTab = c.lenient(UUID.self, .selectedTab, decoder)
        selectedDocument = c.lenient(String.self, .selectedDocument, decoder)
        diskFolders = c.lenient(Int.self, .diskFolders, decoder)
    }
}

extension Space {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Space(name: "Space")
        id = c.lenient(UUID.self, .id, decoder) ?? UUID()
        name = c.lenient(String.self, .name, decoder) ?? d.name
        icon = c.lenient(String.self, .icon, decoder) ?? d.icon
        color = c.lenient(String.self, .color, decoder) ?? d.color
        newNotesFolder = c.lenient(String.self, .newNotesFolder, decoder)
        selectedTab = c.lenient(UUID.self, .selectedTab, decoder)
        selectedSplit = c.lenient(UUID.self, .selectedSplit, decoder)
        profile = c.lenient(String.self, .profile, decoder)
        folderName = c.lenient(String.self, .folderName, decoder)
        folderBookmark = c.lenient(Data.self, .folderBookmark, decoder)
    }
}

extension Folder {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(UUID.self, .id, decoder) ?? UUID()
        spaceID = c.lenient(UUID.self, .spaceID, decoder)
        name = c.lenient(String.self, .name, decoder) ?? "Folder"
        isExpanded = c.lenient(Bool.self, .isExpanded, decoder) ?? true
        createdAt = c.lenient(Date.self, .createdAt, decoder) ?? Date()
        order = c.lenient(Double.self, .order, decoder)
        parentID = c.lenient(UUID.self, .parentID, decoder)
        path = c.lenient(String.self, .path, decoder)
        bookmark = c.lenient(Data.self, .bookmark, decoder)
    }
}

extension TabRecord {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Without an ID, nothing else in the file (folders, splits, the selection) can point at
        // the tab, but its page is still worth keeping.
        id = c.lenient(UUID.self, .id, decoder) ?? UUID()
        // A kind this build doesn't know, say from a newer one, opens as a page.
        kind = c.lenient(TabKind.self, .kind, decoder) ?? .web
        url = c.lenient(String.self, .url, decoder)
        title = c.lenient(String.self, .title, decoder) ?? ""
        isPinned = c.lenient(Bool.self, .isPinned, decoder) ?? false
        folderID = c.lenient(UUID.self, .folderID, decoder)
        createdAt = c.lenient(Date.self, .createdAt, decoder) ?? Date()
        spaceID = c.lenient(UUID.self, .spaceID, decoder)
        isEssential = c.lenient(Bool.self, .isEssential, decoder)
        pinnedURL = c.lenient(String.self, .pinnedURL, decoder)
        customTitle = c.lenient(String.self, .customTitle, decoder)
        order = c.lenient(Double.self, .order, decoder)
        lastActiveAt = c.lenient(Date.self, .lastActiveAt, decoder)
        isMuted = c.lenient(Bool.self, .isMuted, decoder)
        savedFile = c.lenient(String.self, .savedFile, decoder)
    }
}

enum Selection: Hashable {
    case tab(UUID)
    case split(UUID)
}

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
    @Published var splits: [SplitRecord] = [] {
        didSet {
            if splits.contains(where: { $0.spaceID == nil }) {
                for i in splits.indices where splits[i].spaceID == nil { splits[i].spaceID = currentSpaceID }
            }
        }
    }
    @Published var selection: Selection?
    /// The note shown in the focused pane, if it's a note.
    @Published private(set) var document: NoteDocument?
    @Published var addressText = ""
    @Published var addressFocusToken = 0
    @Published var flashMessage: String?
    /// A short message at the bottom of the content area, sometimes with an Undo.
    @Published var toastState: ToastState?
    /// A page floating over the current one. See BrowserModel+Peek.
    @Published var peek: PeekState?
    /// Sidebar items picked with Cmd-click or Shift-click.
    @Published var multiSelection: Set<UUID> = []
    /// -1 when the last space switch went left, 1 when it went right. For the slide animation.
    @Published private(set) var spaceSwitchDirection = 0
    /// Find in page for the focused pane.
    @Published var find = FindState()
    /// The Ctrl-Tab switcher while Ctrl is held.
    @Published var switcher: SwitcherState?
    /// Keyboard focus in the sidebar (Cmd-.): the row the arrow keys are on.
    @Published var sidebarCursor: SidebarStop?

    var addressEditing = false
    let webConfig: WKWebViewConfiguration
    let notes = NotesStore()
    let resurfacer = Resurfacer()
    let bar = CommandBar()
    let closed = ClosedStore()
    /// Open note documents, by file path.
    private(set) var docs: [String: NoteDocument] = [:]
    /// Selections in the order they were left, newest last. Used to go back after a close and for Ctrl-Tab.
    var selectionHistory: [Selection] = []
    private var saveWork: DispatchWorkItem?
    private var flashWork: DispatchWorkItem?
    var toastWork: DispatchWorkItem?
    var toastAction: (() -> Void)?
    /// Where a Shift-click range starts.
    var multiAnchor: UUID?
    private var profileConfigs: [String: WKWebViewConfiguration] = [:]
    private var upkeepTimer: Timer?
    private var closedSink: AnyCancellable?
    /// The space folders' watcher and what it watches. See BrowserModel+SpaceFolders.
    let spaceFolderState = SpaceFolderState()

    /// The smoke test uses a throwaway WebKit store so it leaves no cookies or site data behind.
    static var useEphemeralStore = false
    /// Set by --data-dir. A separate persistent WebKit store for that profile.
    static var dataStoreID: UUID?

    init() {
        webConfig = Self.makeConfig(store: Self.store(forProfile: nil))
        resurfacer.model = self
        bar.model = self
        notes.onScan = { [weak self] in self?.checkNotesOnDisk() }
        MediaWatch.shared.model = self
        closedSink = closed.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        load()
    }

    // MARK: - WebKit configuration and profiles

    /// Screenshot tours set this so pages keep drawing while the window is covered or the
    /// display sleeps, which WebKit otherwise pauses.
    nonisolated(unsafe) static var keepPaintingWhenHidden = false

    static func makeConfig(store: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        if keepPaintingWhenHidden {
            c.preferences.inactiveSchedulingPolicy = .none
            // Pages that draw themselves with script wait for the page to be visible and for
            // animation frames, which never come while the screen is locked.
            c.userContentController.addUserScript(WKUserScript(source: """
            (() => { try {
              Object.defineProperty(Document.prototype, 'visibilityState', { get() { return 'visible' }, configurable: true });
              Object.defineProperty(Document.prototype, 'hidden', { get() { return false }, configurable: true });
              window.requestAnimationFrame = (cb) => setTimeout(() => cb(performance.now()), 16);
              window.cancelAnimationFrame = (id) => clearTimeout(id);
            } catch (e) {} })();
            """, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        c.websiteDataStore = store
        c.preferences.isElementFullscreenEnabled = true
        c.preferences.javaScriptCanOpenWindowsAutomatically = false
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        c.applicationNameForUserAgent = "Version/\(major).0 Safari/605.1.15"
        c.allowsAirPlayForMediaPlayback = true
        TypingCounter.install(on: c.userContentController)
        MediaWatch.install(on: c.userContentController)
        Favicons.install(on: c.userContentController)
        PasswordAutoFill.install(on: c.userContentController)
        // demo://: the demo profile's docs and meetings as read-only local pages.
        DemoScheme.install(on: c)
        return c
    }

    /// The WebKit store for a profile. The default profile keeps the store it always had.
    /// Named profiles get their own persistent store, derived from the data folder and the name.
    static func store(forProfile name: String?) -> WKWebsiteDataStore {
        if useEphemeralStore { return .nonPersistent() }
        guard let name, !name.isEmpty else {
            if let id = dataStoreID { return WKWebsiteDataStore(forIdentifier: id) }
            return .default()
        }
        return WKWebsiteDataStore(forIdentifier: profileStoreID(name))
    }

    static func profileStoreID(_ name: String) -> UUID {
        Paths.storeID(for: Paths.root.appendingPathComponent("profiles", isDirectory: true).appendingPathComponent(name.lowercased(), isDirectory: true))
    }

    func configuration(forProfile name: String?) -> WKWebViewConfiguration {
        guard let name, !name.isEmpty else { return webConfig }
        if let c = profileConfigs[name] { return c }
        let c = Self.makeConfig(store: Self.store(forProfile: name))
        profileConfigs[name] = c
        return c
    }

    /// Essentials use the default profile. Everything else uses its space's profile.
    func configuration(for tab: Tab) -> WKWebViewConfiguration {
        if tab.isEssential { return webConfig }
        return configuration(forProfile: spaces.first { $0.id == tab.spaceID }?.profile)
    }

    func profile(of tab: Tab) -> String? {
        tab.isEssential ? nil : spaces.first { $0.id == tab.spaceID }?.profile
    }

    /// Profile names in use, plus the default (nil).
    var profiles: [String] { Array(Set(spaces.compactMap { $0.profile })).sorted() }

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
    func split(_ id: UUID) -> SplitRecord? { splits.first { $0.id == id } }

    var splitTabIDs: Set<UUID> { Set(splits.flatMap { $0.items }) }

    /// The focused web tab, for the address bar and navigation.
    var currentWebTab: Tab? { currentTab.flatMap { $0.kind == .web ? $0 : nil } }

    var currentSpace: Space? { spaces.first { $0.id == currentSpaceID } }
    /// Items that belong to this space. Essentials aren't in any one space.
    var spaceTabs: [Tab] { tabs.filter { $0.spaceID == currentSpaceID && !$0.isEssential } }
    var spaceFolders: [Folder] { folders.filter { $0.spaceID == currentSpaceID }.sorted { ($0.order ?? 0) < ($1.order ?? 0) } }
    var spaceSplits: [SplitRecord] { splits.filter { $0.spaceID == currentSpaceID }.sorted { $0.order < $1.order } }

    /// The Essentials grid, shared by every space.
    var essentials: [Tab] { tabs.filter { $0.isEssential }.sorted { $0.order < $1.order } }

    // Items in a split show as the split's joined row, not on their own.
    var pinnedTabs: [Tab] { let s = splitTabIDs; return spaceTabs.filter { $0.isPinned && !s.contains($0.id) }.sorted { $0.order < $1.order } }
    var looseTabs: [Tab] {
        let s = splitTabIDs
        return spaceTabs.filter { !$0.isPinned && $0.folderID == nil && !s.contains($0.id) }.sorted { $0.order < $1.order }
    }
    func tabs(in folder: Folder) -> [Tab] {
        let s = splitTabIDs
        return tabs.filter { $0.folderID == folder.id && !$0.isPinned && !$0.isEssential && !s.contains($0.id) }.sorted { $0.order < $1.order }
    }

    /// True for the focused item (a selected tab, or the focused pane of the selected split).
    func isSelected(_ tab: Tab) -> Bool { currentTab?.id == tab.id }

    func isVisible(_ tab: Tab) -> Bool { visibleTabs.contains { $0.id == tab.id } }

    // MARK: - Persistence

    private func load() {
        SpaceFolders.customRoot = BrowserPrefs.shared.value.spaceFoldersRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
        // A file that can't be read moves into Recovered/ first, so the fresh Home below never
        // gets saved over it.
        guard var s = SavedFile.read(SavedState.self, from: Paths.stateFile, label: "spaces and tabs") else {
            let home = Space(name: "Home")
            spaces = [home]
            currentSpaceID = home.id
            // A new profile starts with its folders on disk.
            spaceFolderState.migrated = SpaceFolders.root != nil
            setUpSpaceFolders()
            return
        }
        // Version 1 had no spaces: everything moves into one called Home.
        var sp = s.spaces ?? []
        if sp.isEmpty {
            sp = [Space(name: "Home", selectedTab: s.selectedTab, selectedSplit: s.selectedSplit)]
        }
        // Today's sidebar folders move onto disk, once. The launch backup has already run. If
        // the move can't finish, the folders stay as they were and it's tried again next launch.
        var moved = false
        spaceFolderState.markedMoved = s.diskFolders == SpaceFolderMigration.version
        if let root = SpaceFolders.root {
            if s.diskFolders == SpaceFolderMigration.version {
                spaceFolderState.migrated = true
            } else {
                var before = s
                before.spaces = sp
                do {
                    let (after, report) = try SpaceFolderMigration.run(before, notesFolders: Settings.shared.value.notesFolders, root: root)
                    s = after
                    sp = after.spaces ?? sp
                    spaceFolderState.migrated = true
                    moved = true
                    appLog.notice("space folders: moved \(report.folders) folders, \(report.pages) pages, \(report.notes) notes, linked \(report.linkedFolders) notes folders, reused \(report.reused)")
                } catch {
                    appLog.error("space folders: the move didn't finish: \(String(describing: error), privacy: .public)")
                }
            }
        }
        spaces = sp
        let home = sp[0].id
        currentSpaceID = s.currentSpace.flatMap { id in sp.contains { $0.id == id } ? id : nil } ?? home
        folders = s.folders.enumerated().map { i, f0 in
            var f = f0
            if f.spaceID == nil || !sp.contains(where: { $0.id == f.spaceID }) { f.spaceID = home }
            if f.order == nil { f.order = Double(i) }
            return f
        }
        repairFolderTree()
        // Older files had no order: Today was newest first, the rest in file order.
        let byNewest = s.tabs.sorted { $0.createdAt > $1.createdAt }.map { $0.id }
        tabs = s.tabs.enumerated().map { i, r in
            let kind: TabKind = r.kind == .file ? .note : r.kind
            let t = Tab(id: r.id, kind: kind, url: r.url.flatMap(URL.init(string:)), title: r.title,
                        isPinned: r.isPinned, folderID: r.folderID, createdAt: r.createdAt)
            t.model = self
            t.spaceID = r.spaceID.flatMap { id in sp.contains { $0.id == id } ? id : nil } ?? home
            t.isEssential = r.isEssential ?? false
            t.pinnedURL = r.pinnedURL.flatMap(URL.init(string:))
            if t.keepsPinnedURL && t.pinnedURL == nil { t.pinnedURL = t.url }
            t.customTitle = r.customTitle
            t.order = r.order ?? (r.isPinned || r.folderID != nil ? Double(i) : Double(byNewest.firstIndex(of: r.id) ?? i))
            t.lastActiveAt = r.lastActiveAt ?? r.createdAt
            t.isMuted = r.isMuted ?? false
            t.savedFile = r.savedFile
            if t.kind == .web, t.savedFile != nil, t.pinnedURL == nil { t.pinnedURL = t.url }
            return t
        }
        let ids = Set(tabs.map { $0.id })
        let byNewestSplit = (s.splits ?? []).sorted { $0.createdAt > $1.createdAt }.map { $0.id }
        var seen = Set<UUID>()
        splits = (s.splits ?? []).compactMap { r in
            var x = r
            // Drop items that are gone, and anything already in an earlier split.
            for id in x.items where !ids.contains(id) || seen.contains(id) { if let n = x.root.removing(id) { x.root = n } }
            guard x.items.count >= 2, Set(x.items).count == x.items.count else { return nil }
            seen.formUnion(x.items)
            if !x.contains(x.focused) { x.focused = x.items[0] }
            if x.spaceID == nil || !sp.contains(where: { $0.id == x.spaceID }) { x.spaceID = tab(x.items[0])?.spaceID ?? home }
            if s.version ?? 1 < 3 { x.order = Double(byNewestSplit.firstIndex(of: r.id) ?? 0) - 1000 }
            return x
        }
        checkNotesOnDisk()
        setUpSpaceFolders()
        SessionFiles.prune(keeping: ids.union(closed.items.map { $0.id }))
        let cur = currentSpace
        if let sid = cur?.selectedSplit ?? s.selectedSplit, let sp = splits.first(where: { $0.id == sid && $0.spaceID == currentSpaceID }) {
            selectSplit(sp)
        } else if let id = cur?.selectedTab ?? s.selectedTab, let t = tab(id), t.spaceID == currentSpaceID || t.isEssential {
            select(t)
        } else if let p = s.selectedDocument, FileManager.default.fileExists(atPath: p) {
            openNote(URL(fileURLWithPath: p))
        }
        // The moved state is saved right away, so the move is recorded as done.
        if moved { saveNow() }
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
                      isPinned: $0.isPinned, folderID: $0.folderID, createdAt: $0.createdAt, spaceID: $0.spaceID,
                      isEssential: $0.isEssential ? true : nil, pinnedURL: $0.pinnedURL?.absoluteString,
                      customTitle: $0.customTitle, order: $0.order, lastActiveAt: $0.lastActiveAt, isMuted: $0.isMuted ? true : nil,
                      savedFile: $0.savedFile)
        }
        s.splits = splits
        s.diskFolders = spaceFolderState.migrated || spaceFolderState.markedMoved ? SpaceFolderMigration.version : nil
        switch selection {
        case .tab(let id): s.selectedTab = id
        case .split(let sid): s.selectedSplit = sid
        case nil: break
        }
        Paths.ensure(Paths.root)
        if let data = try? JSONEncoder.pretty.encode(s) {
            SavedFile.write(data, to: Paths.stateFile)
        }
        for t in tabs where t.isLoaded { t.saveSession() }
    }

    func prepareForQuit() {
        if let t = currentTab { endDwell(t) }
        for t in visibleTabs { t.lastActiveAt = Date() }
        for d in docs.values { d.saveNow() }
        saveNow()
    }

    /// Auto-archive on a timer. The app calls this once at launch. Tests drive it by hand.
    func startUpkeep() {
        archiveIdleTabs()
        upkeepTimer?.invalidate()
        upkeepTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.archiveIdleTabs() }
        }
    }

    // MARK: - Selection

    /// Items on screen right now. Notes not on screen get saved and let go.
    var visibleTabs: [Tab] {
        if let sp = currentSplit { return sp.items.compactMap { tab($0) } }
        return currentTab.map { [$0] } ?? []
    }

    func setSelection(_ new: Selection?) {
        let old = selection
        guard old != new else { return }
        let leaving = visibleTabs
        if let old { selectionHistory.removeAll { $0 == old }; selectionHistory.append(old) }
        if selectionHistory.count > 50 { selectionHistory.removeFirst(selectionHistory.count - 50) }
        if case .tab(let id) = old, let t = tab(id) {
            endDwell(t)
            if t.isBlank && split(containing: t.id) == nil { tabs.removeAll { $0.id == t.id }; selectionHistory.removeAll { $0 == .tab(t.id) } }
        }
        if case .split(let sid) = old, let sp = splits.first(where: { $0.id == sid }), let t = tab(sp.focused) { endDwell(t) }
        if peek != nil { closePeek() }
        if find.visible { closeFind() }
        multiSelection = []
        sidebarCursor = nil
        selection = new
        let now = Date()
        for t in leaving { t.lastActiveAt = now }
        for t in visibleTabs { t.lastActiveAt = now }
        // Picking something in the sidebar while the bar is open means you're done with the bar.
        if bar.isOpen { bar.close() }
        // A page that finished loading off screen gets its picture now, if it's still at the top.
        for t in visibleTabs { Thumbnails.shared.tabShown(t) }
        mediaSelectionChanged(leaving: leaving)
        refreshFocus()
        syncAddress()
        scheduleSave()
    }

    /// Recomputes the focused note and drops documents that are no longer visible.
    func refreshFocus() {
        let visibleNotes = visibleTabs.filter { $0.isNote }.compactMap { $0.url?.standardizedFileURL.path }
        for (path, d) in docs where !visibleNotes.contains(path) {
            d.saveNow()
            docs[path] = nil
        }
        if let t = currentTab, t.isNote, let u = t.url { document = doc(for: u) } else { document = nil }
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

    /// Files an open document under a note's new address.
    func docsReplace(_ old: String, _ new: String, _ d: NoteDocument) {
        docs[old] = nil
        docs[new] = d
    }

    func noteDidPause(_ doc: NoteDocument) {
        if document === doc { resurfacer.contextFromDocument(doc) }
    }

    func select(_ tab: Tab) {
        if !tab.isEssential, let sid = tab.spaceID, sid != currentSpaceID { switchSpace(to: sid, restore: false) }
        if let sp = split(containing: tab.id) {
            // Picking an item that lives in a split brings the split back, focused on it.
            selectSplit(sp, focusItem: tab.id)
            return
        }
        setSelection(.tab(tab.id))
        contextForFocused()
    }

    /// Points the Related panel and the dwell clock at the focused item.
    func contextForFocused() {
        guard let tab = currentTab else { return }
        if tab.isNote, let u = tab.url {
            refreshFocus()
            IndexStore.shared.touchOpened(key: URLKey.fileKey(u))
            if let d = document { resurfacer.contextFromDocument(d) }
            return
        }
        guard tab.isWeb else { resurfacer.setContext(nil); return }
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
    /// A second Cmd-L closes it.
    func focusAddress() {
        if bar.isOpen, case .navigate = bar.mode { bar.close(); return }
        if let t = currentWebTab, let u = t.url ?? t.webView?.url {
            bar.open(.navigate(t.id), text: u.absoluteString)
        } else if let t = currentWebTab {
            bar.open(.navigate(t.id))
        } else {
            bar.open(.newTab)
        }
    }

    /// What a pick in the command bar does, for each way the bar was opened. `route` comes from
    /// the modifier held with Enter: Option opens in split view, Shift in Peek, Cmd in a
    /// background tab.
    func commandPick(_ kind: Suggestion.Kind, mode: CommandBar.Mode, route: LinkRouting.Route? = nil) {
        let mode = route == .split && currentTab != nil ? CommandBar.Mode.split : mode
        switch kind {
        case .tab(let id):
            guard let t = tab(id) else { return }
            if mode == .split { openInSplit(t, side: .right) } else if route == .peek, let u = t.url, t.isWeb { openPeek(u, from: currentTab) } else { select(t) }
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
            openWeb(u, mode: mode, route: route)
        case .google(let q), .pastSearch(let q):
            IndexStore.shared.addSearch(q)
            if let u = AddressParser.search(q) { openWeb(u, mode: mode, route: route) }
        case .action(let id):
            bar.learner.record(id, seen: bar.shownActionIDs)
            BarActions.run(id, model: self)
        case .folder(let id):
            openFolder(id)
        case .space(let id):
            switchSpace(to: id)
        case .closed(let id):
            restoreClosed([id])
        }
    }

    private func openWeb(_ u: URL, mode: CommandBar.Mode, route: LinkRouting.Route?) {
        if route == .peek { openPeek(u, from: currentTab); return }
        if route == .backgroundTab {
            let t = newTab(url: u, select: false)
            toast("Opened in a new tab", action: "Show") { [weak self, weak t] in if let t { self?.select(t) } }
            return
        }
        switch mode {
        case .navigate(let id):
            if let t = tab(id), t.kind == .web {
                // Enter on the same address reloads, like Arc.
                if let cur = t.url, cur.absoluteString == u.absoluteString, t.webView != nil {
                    reload()
                } else {
                    t.load(u)
                }
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
            t.order = topOrder(today: currentSpaceID)
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
        t.order = topOrder(today: currentSpaceID)
        tabs.append(t)
        if configuration != nil { _ = t.ensureWebView(configuration: configuration) }
        if doSelect { select(t) } else if url != nil {
            _ = t.ensureWebView()
        }
        if focus { focusAddress() }
        scheduleSave()
        return t
    }

    /// Cmd-T and New tab: the bar. Nothing is created until something is picked. A second
    /// Cmd-T closes it.
    func newTabCommand() {
        if bar.isOpen && bar.mode == .newTab { bar.close(); return }
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

    /// Closing a page: Today tabs go to Recently Closed. Pinned tabs and Essentials go back to their
    /// pinned address and unload, like Zen. Filed pages unload. Closing a note only takes it out
    /// of the sidebar; the file stays.
    func close(_ tab: Tab) {
        if split(containing: tab.id) != nil { dissolveSplit(around: tab.id) }
        let wasSelected = isSelected(tab)
        if tab.isNote || tab.isApp {
            if let u = tab.url, tab.isNote { docs[u.standardizedFileURL.path]?.saveNow() }
            if !(tab.isPinned || tab.folderID != nil || tab.isEssential) {
                recordClosed([tab], reason: .closed)
                tabs.removeAll { $0.id == tab.id }
            }
        } else if tab.keepsPinnedURL || (tab.keepsSavedURL && tab.folderID != nil) {
            resetPinned(tab, load: false)
        } else if tab.folderID != nil {
            tab.unload()
        } else {
            recordClosed([tab], reason: .closed)
            tab.unload()
            tabs.removeAll { $0.id == tab.id }
        }
        selectionHistory.removeAll { $0 == .tab(tab.id) && !tabs.contains(where: { $0.id == tab.id }) }
        if wasSelected { selectPrevious(excluding: .tab(tab.id)) } else { refreshFocus() }
        objectWillChange.send()
        scheduleSave()
    }

    /// Takes any item out of the sidebar. For notes the file stays on disk.
    func remove(_ tab: Tab) {
        if split(containing: tab.id) != nil { dissolveSplit(around: tab.id) }
        let wasSelected = isSelected(tab)
        if tab.isNote, let u = tab.url { docs[u.standardizedFileURL.path]?.saveNow() }
        recordClosed([tab], reason: .closed)
        tab.unload()
        tabs.removeAll { $0.id == tab.id }
        selectionHistory.removeAll { $0 == .tab(tab.id) }
        multiSelection.remove(tab.id)
        if wasSelected { selectPrevious(excluding: .tab(tab.id)) } else { refreshFocus() }
        scheduleSave()
    }

    func selectPrevious(excluding: Selection) {
        // Earlier items in other spaces stay in the history for when you go back there.
        var skipped: [Selection] = []
        defer { selectionHistory.append(contentsOf: skipped.reversed()) }
        while let last = selectionHistory.popLast() {
            if last == excluding { continue }
            if case .tab(let id) = last, let t = tab(id) {
                if t.spaceID != currentSpaceID && !t.isEssential { skipped.append(last); continue }
                if t.keepsPinnedURL && !t.isLoaded { continue }
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

    /// Cmd-W. Closes Peek first if it's open. In a split, the focused pane goes and the rest stay.
    func closeCurrent() {
        if peek != nil { closePeek(); return }
        guard let t = currentTab else { return }
        if split(containing: t.id) != nil {
            dissolveSplit(around: t.id)
            if t.isNote || t.isApp || !(t.isPinned || t.folderID != nil || t.isEssential) {
                remove(t)
            } else if t.keepsPinnedURL || (t.keepsSavedURL && t.folderID != nil) {
                resetPinned(t, load: false)
            } else {
                t.unload()
            }
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
    func reloadFromOrigin() {
        guard let t = currentWebTab else { return }
        if let wv = t.webView { t.loadError = nil; wv.reloadFromOrigin() } else if t.url != nil { _ = t.ensureWebView() }
    }
    func zoom(_ delta: Double?) {
        guard let wv = currentWebTab?.webView else { return }
        if let delta { wv.pageZoom = max(0.5, min(3, wv.pageZoom + delta)) } else { wv.pageZoom = 1 }
    }

    // MARK: - Folders

    /// A new folder at the top of the Folders section, or first among `parent`'s subfolders.
    @discardableResult
    func createFolder(named name: String, in parent: UUID? = nil) -> Folder {
        let parent = parent.flatMap { folder($0) != nil && folderDepth($0) + 1 < Folder.maxDepth ? $0 : nil }
        // On disk: in the space's folder, pinned, or inside a pinned folder's tree.
        if diskFolders, parent == nil || isDiskFolder(parent), let f = createDiskFolder(named: name, in: parent) { return f }
        let space = parent.flatMap { folder($0)?.spaceID } ?? currentSpaceID
        let first = childFolders(of: parent, space: space).first?.order ?? 0
        let f = Folder(spaceID: space, name: name, order: first - 1, parentID: parent)
        folders.append(f)
        if let parent { openFolderPath(to: parent) }
        scheduleSave()
        return f
    }

    func renameFolder(_ f: Folder, to name: String) {
        guard let i = folders.firstIndex(where: { $0.id == f.id }) else { return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        if folders[i].path != nil { renameDiskFolder(folders[i], to: n); return }
        folders[i].name = n
        scheduleSave()
    }

    /// What was inside moves up a level: subfolders take the folder's place among its neighbours,
    /// and its items go into the folder it was in, or back to Tabs at the top. Notes on disk are
    /// untouched.
    func deleteFolder(_ f: Folder) {
        // A pinned folder is unpinned and one inside it goes to the Trash. Nothing is deleted outright.
        if f.path != nil {
            if f.parentID == nil { unpinFolder(f.id) } else { trashDiskFolder(f) }
            return
        }
        let kids = childFolders(of: f.id)
        var siblings = childFolders(of: f.parentID, space: f.spaceID).map(\.id)
        let at = siblings.firstIndex(of: f.id) ?? siblings.count
        siblings.removeAll { $0 == f.id }
        siblings.insert(contentsOf: kids.map(\.id), at: min(at, siblings.count))
        for (n, id) in siblings.enumerated() {
            if let i = folders.firstIndex(where: { $0.id == id }) { folders[i].parentID = f.parentID; folders[i].order = Double(n) }
        }
        if let up = f.parentID, folder(up) != nil {
            let items = refs(in: .folder(f.id))
            folders.removeAll { $0.id == f.id }
            place(items, in: .folder(up), at: Int.max)
        } else {
            for t in tabs where t.folderID == f.id { t.folderID = nil; t.order = topOrder(today: f.spaceID ?? currentSpaceID) }
            folders.removeAll { $0.id == f.id }
        }
        objectWillChange.send()
        scheduleSave()
    }

    func toggleFolder(_ f: Folder) {
        guard let i = folders.firstIndex(where: { $0.id == f.id }) else { return }
        setFolder(f.id, open: !folders[i].isExpanded)
    }

    /// Opens or closes a folder. The state is saved per folder and comes back after a relaunch.
    func setFolder(_ id: UUID, open: Bool) {
        guard let i = folders.firstIndex(where: { $0.id == id }), folders[i].isExpanded != open else { return }
        folders[i].isExpanded = open
        scheduleSave()
    }

    func isFolderOpen(_ id: UUID) -> Bool { folders.first { $0.id == id }?.isExpanded ?? false }

    /// What a closed folder still shows: the items on screen, like Arc and Zen keep the active tab
    /// visible under a collapsed folder.
    /// A closed folder hides its subfolders too, so it shows what's on screen anywhere inside it.
    func shownInClosedFolder(_ f: Folder) -> [SidebarRef] {
        let shown = Set(visibleTabs.map { $0.id })
        guard !shown.isEmpty else { return [] }
        return ([f.id] + descendants(of: f.id)).flatMap { refs(in: .folder($0)) }.filter { shown.contains($0.id) }
    }

    func setAllFolders(expanded: Bool) {
        for i in folders.indices where folders[i].spaceID == currentSpaceID { folders[i].isExpanded = expanded }
        scheduleSave()
    }

    /// From the command bar: expands the folder and shows its first item.
    func openFolder(_ id: UUID) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        if folders[i].spaceID != currentSpaceID, let sid = folders[i].spaceID { switchSpace(to: sid) }
        openFolderPath(to: id)
        if let first = tabs(in: folders[i]).first { select(first) }
        scheduleSave()
    }

    func promptNewFolder(moving tab: Tab? = nil, in parent: UUID? = nil) {
        guard let name = Prompt.text(title: parent == nil ? "New folder" : "New subfolder", message: "Name", defaultValue: ""), !name.isEmpty else { return }
        let f = createFolder(named: name, in: parent)
        if let tab { move(tab, to: f.id) }
        for id in multiSelection where id != tab?.id { if let t = self.tab(id) { move(t, to: f.id) } }
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
        if let t = (spaceTabs + essentials).first(where: { $0.isNote && $0.url?.standardizedFileURL.path == path }) {
            if doSelect { select(t) }
            return t
        }
        let t = Tab(kind: .note, url: url.standardizedFileURL, title: url.deletingPathExtension().lastPathComponent)
        t.model = self
        t.order = topOrder(today: currentSpaceID)
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
        // Otherwise the space's own folder, once space folders are on.
        if let sp = currentSpace, let u = spaceFolderURL(sp) { return u }
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
        guard tab.isNote, let url = tab.url else { return .failed }
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
        guard tab.isNote, let url = tab.url else { completion?(false); return }
        docs[url.standardizedFileURL.path] = nil
        notes.trash(url) { [weak self] ok in
            guard let self else { return }
            if ok {
                Indexer.removeFile(url: url)
                self.remove(tab)
                self.closed.take([tab.id])
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
        for t in tabs where t.isNote {
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
        Thumbnails.shared.cancel(tab)
    }

    func pageDidFinish(_ tab: Tab) {
        guard let wv = tab.webView, let url = wv.url else { return }
        if isSelected(tab) { startDwell(tab); syncAddress() }
        // A picture of the top of the page for its card, a second from now if it's on screen.
        Thumbnails.shared.pageFinished(tab, visible: isVisible(tab))
        HistoryStore.shared.record(url: url, title: wv.title ?? tab.title, spaceID: tab.isEssential ? nil : tab.spaceID)
        Favicons.shared.capture(from: tab)
        if tab.isMuted { MediaWatch.setMuted(true, in: tab) }
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
        case .web, .chrome, .notion, .gdocs, .granola: newTab(url: u, select: true)
        case .note, .markdown: openNote(u)
        }
        IndexStore.shared.touchOpened(key: d.key)
    }

    /// The editable note on screen that Add to research writes into, if any.
    var researchNote: NoteDocument? {
        if let d = document, !d.isReadOnly, d.state == .ready { return d }
        // Reading a page next to a note: the note is where research goes.
        for t in visibleTabs where t.isNote {
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
        if folder.path != nil {
            // A folder on disk: a saved page, or a link to the note.
            guard let dir = folderDirectory(folder) else { return "Couldn't add" }
            do {
                if isNote { try SpaceFolders.link(u, in: dir) } else { try SpaceFolders.savePage(u, title: d.title, in: dir) }
            } catch { return "Couldn't add" }
            syncPinnedFolders()
            setFolder(folder.id, open: true)
            return "Added to \(folder.name)"
        }
        let t = Tab(kind: isNote ? .note : .web, url: u, title: isNote ? u.deletingPathExtension().lastPathComponent : d.title, folderID: folder.id)
        t.model = self
        t.order = (tabs(in: folder).map { $0.order }.max() ?? 0) + 1
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
        if matches.contains(where: { $0.spaceID == currentSpaceID || $0.isEssential }) { return nil }
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
        if peek != nil { closePeek() }
        rememberSelection()
        let from = spaces.firstIndex { $0.id == currentSpaceID } ?? 0
        let to = spaces.firstIndex { $0.id == id } ?? 0
        spaceSwitchDirection = to >= from ? 1 : -1
        currentSpaceID = id
        selection = nil
        multiSelection = []
        refreshFocus()
        if restore {
            let sp = currentSpace
            if let sid = sp?.selectedSplit, let s = splits.first(where: { $0.id == sid && $0.spaceID == id }) {
                selectSplit(s)
            } else if let tid = sp?.selectedTab, let t = tab(tid), t.spaceID == id || t.isEssential {
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
        ensureSpaceFolder(sp.id)
        scheduleSave()
        return spaces.first { $0.id == sp.id } ?? sp
    }

    func updateSpace(_ id: UUID, _ change: (inout Space) -> Void) {
        guard let i = spaces.firstIndex(where: { $0.id == id }) else { return }
        let oldProfile = spaces[i].profile
        let oldName = spaces[i].name
        change(&spaces[i])
        if spaces[i].name != oldName { renameSpaceFolder(id) }
        if spaces[i].profile != oldProfile {
            // A different profile means a different cookie store: pages reload in the new one.
            for t in tabs where t.spaceID == id && !t.isEssential && t.isLoaded {
                t.unload()
                if isVisible(t) { _ = t.ensureWebView() }
            }
        }
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
        for t in tabs where t.spaceID == id && !t.isEssential {
            if t.isNote, let u = t.url { docs[u.standardizedFileURL.path]?.saveNow() }
            t.unload(keepSession: false)
        }
        let gone = Set(tabs.filter { $0.spaceID == id && !$0.isEssential }.map { $0.id })
        tabs.removeAll { gone.contains($0.id) }
        splits.removeAll { $0.spaceID == id }
        folders.removeAll { $0.spaceID == id }
        selectionHistory.removeAll { if case .tab(let t) = $0 { return gone.contains(t) }; return false }
        spaces.remove(at: spaces.firstIndex(where: { $0.id == id }) ?? i)
        refreshFocus()
        scheduleSave()
    }

    func promptDeleteSpace(_ sp: Space) {
        guard spaces.count > 1 else { Prompt.info(title: "This is your only space", message: "Make another space before deleting this one."); return }
        // Its folder stays on disk unless you tick the box.
        if let folder = spaceFolderURL(sp), SpaceFolders.isDirectory(folder) {
            guard let trashFolder = Prompt.confirmWithOption(title: "Delete the \(sp.name) space?",
                                                             message: "Its tabs close and its pins and splits go with it. Its folder, \(folder.lastPathComponent), stays on disk.",
                                                             option: "Also move the \(folder.lastPathComponent) folder to the Trash", ok: "Delete space") else { return }
            deleteSpace(sp.id)
            if trashFolder { SpaceFolders.trash([folder]) { [weak self] ok in if !ok { self?.toast("Couldn't move the folder to the Trash") } } }
            return
        }
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

    func promptNewProfile(for sp: Space) {
        guard let name = Prompt.text(title: "New profile", message: "Pages in \(sp.name) will use their own cookies and logins under this name.", defaultValue: ""),
              !name.isEmpty else { return }
        updateSpace(sp.id) { $0.profile = name }
    }

    /// Moves an item to another space, loose in its Tabs list.
    func move(_ tab: Tab, toSpace id: UUID) {
        guard tab.spaceID != id || tab.isEssential else { return }
        let wasSelected = isSelected(tab)
        if split(containing: tab.id) != nil { dissolveSplit(around: tab.id) }
        // Out of a folder on disk, the file stays where it is and the tab goes on its own.
        if isDiskFolder(tab.folderID) {
            tab.savedFile = nil
            if tab.isWeb { tab.pinnedURL = nil }
        }
        if wasSelected { endDwell(tab) }
        let oldProfile = profile(of: tab)
        tab.spaceID = id
        tab.folderID = nil
        tab.isPinned = false
        tab.isEssential = false
        tab.order = topOrder(today: id)
        if profile(of: tab) != oldProfile && tab.isLoaded { tab.unload() }
        if wasSelected || isVisible(tab) { selectPrevious(excluding: .tab(tab.id)) }
        objectWillChange.send()
        scheduleSave()
    }

    func move(split sp: SplitRecord, toSpace id: UUID) {
        guard let i = splits.firstIndex(where: { $0.id == sp.id }), sp.spaceID != id else { return }
        let wasSelected = selection == .split(sp.id)
        for tid in sp.items {
            if let t = tab(tid) {
                let oldProfile = profile(of: t)
                t.spaceID = id; t.folderID = nil; t.isPinned = false; t.isEssential = false
                if profile(of: t) != oldProfile && t.isLoaded { t.unload() }
            }
        }
        splits[i].spaceID = id
        splits[i].isPinned = false
        splits[i].order = topOrder(today: id)
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

    /// Links from other apps. With Little Arc on, web links open in a small window of their own.
    func openFromSystem(_ urls: [URL]) {
        for u in urls {
            if u.isFileURL && u.pathExtension.lowercased() == "md" {
                openNote(u)
            } else if BrowserPrefs.shared.value.littleArc && !u.isFileURL {
                LittleArc.shared.open(u, model: self)
            } else {
                newTab(url: u, select: true)
            }
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

    /// A confirmation with a checkbox, off by default. Nil when cancelled, else whether it was ticked.
    static func confirmWithOption(title: String, message: String, option: String, ok: String) -> Bool? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        let box = NSButton(checkboxWithTitle: option, target: nil, action: nil)
        box.state = .off
        a.accessoryView = box
        a.addButton(withTitle: ok)
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        return box.state == .on
    }
}

extension Notification.Name {
    static let focusEditor = Notification.Name("local.browserpoc.focusEditor")
}
