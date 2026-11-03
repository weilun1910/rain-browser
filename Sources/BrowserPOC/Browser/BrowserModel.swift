import AppKit
import SwiftUI
import WebKit

struct Folder: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
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
}

struct SavedState: Codable {
    var tabs: [TabRecord] = []
    var folders: [Folder] = []
    var selectedTab: UUID?
    /// Older versions opened notes outside the tab list.
    var selectedDocument: String?
}

enum Selection: Hashable {
    case tab(UUID)
}

@MainActor
final class BrowserModel: ObservableObject {
    @Published var tabs: [Tab] = []
    @Published var folders: [Folder] = []
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
    /// Open note documents, by file path.
    private(set) var docs: [String: NoteDocument] = [:]
    private var history: [Selection] = []
    private var saveWork: DispatchWorkItem?
    private var flashWork: DispatchWorkItem?

    /// The smoke test uses a throwaway WebKit store so it leaves no cookies or site data behind.
    static var useEphemeralStore = false

    init() {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = Self.useEphemeralStore ? .nonPersistent() : .default()
        c.preferences.isElementFullscreenEnabled = true
        c.preferences.javaScriptCanOpenWindowsAutomatically = false
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        c.applicationNameForUserAgent = "Version/\(major).0 Safari/605.1.15"
        TypingCounter.install(on: c.userContentController)
        webConfig = c
        resurfacer.model = self
        notes.onScan = { [weak self] in self?.checkNotesOnDisk() }
        load()
    }

    // MARK: - Derived

    func tab(_ id: UUID) -> Tab? { tabs.first { $0.id == id } }

    var currentTab: Tab? {
        if case .tab(let id) = selection { return tab(id) }
        return nil
    }

    /// The focused web tab, for the address bar and navigation.
    var currentWebTab: Tab? { currentTab.flatMap { $0.kind == .web ? $0 : nil } }

    var pinnedTabs: [Tab] { tabs.filter { $0.isPinned } }
    var looseTabs: [Tab] { tabs.filter { !$0.isPinned && $0.folderID == nil }.sorted { $0.createdAt > $1.createdAt } }
    func tabs(in folder: Folder) -> [Tab] { tabs.filter { $0.folderID == folder.id && !$0.isPinned } }

    func isSelected(_ tab: Tab) -> Bool { selection == .tab(tab.id) }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Paths.stateFile),
              let s = try? JSONDecoder.iso.decode(SavedState.self, from: data) else { return }
        folders = s.folders
        tabs = s.tabs.map { r in
            let kind: TabKind = r.kind == .file ? .note : r.kind
            let t = Tab(id: r.id, kind: kind, url: r.url.flatMap(URL.init(string:)), title: r.title,
                        isPinned: r.isPinned, folderID: r.folderID, createdAt: r.createdAt)
            t.model = self
            return t
        }
        checkNotesOnDisk()
        if let id = s.selectedTab, let t = tab(id) {
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
        var s = SavedState()
        s.folders = folders
        s.tabs = tabs.filter { !$0.isBlank }.map {
            TabRecord(id: $0.id, kind: $0.kind, url: $0.url?.absoluteString, title: $0.title,
                      isPinned: $0.isPinned, folderID: $0.folderID, createdAt: $0.createdAt)
        }
        if case .tab(let id) = selection { s.selectedTab = id }
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
    var visibleTabs: [Tab] { currentTab.map { [$0] } ?? [] }

    private func setSelection(_ new: Selection?) {
        let old = selection
        guard old != new else { return }
        if let old { history.removeAll { $0 == old }; history.append(old) }
        if history.count > 50 { history.removeFirst(history.count - 50) }
        if case .tab(let id) = old, let t = tab(id) {
            endDwell(t)
            if t.isBlank { tabs.removeAll { $0.id == t.id }; history.removeAll { $0 == .tab(t.id) } }
        }
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
        setSelection(.tab(tab.id))
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

    func focusAddress() {
        addressFocusToken += 1
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

    func newTabCommand() {
        if let t = currentTab, t.isBlank { focusAddress(); return }
        newTab(url: nil, select: true, focus: true)
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
        let wasSelected = isSelected(tab)
        if tab.kind == .note, let u = tab.url { docs[u.standardizedFileURL.path]?.saveNow() }
        tab.unload()
        tabs.removeAll { $0.id == tab.id }
        history.removeAll { $0 == .tab(tab.id) }
        if wasSelected { selectPrevious(excluding: .tab(tab.id)) } else { refreshFocus() }
        scheduleSave()
    }

    private func selectPrevious(excluding: Selection) {
        while let last = history.popLast() {
            if last == excluding { continue }
            if case .tab(let id) = last, let t = tab(id) { selection = nil; select(t); return }
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
        if let t = currentTab { close(t) }
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
        let f = Folder(name: name)
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
        if let f = folders.first(where: { $0.name == "Research" }) { return f }
        return createFolder(named: "Research")
    }

    // MARK: - Notes

    /// Opens a note as a sidebar item, reusing the item if it's already there.
    @discardableResult
    func openNote(_ url: URL, select doSelect: Bool = true) -> Tab {
        let path = url.standardizedFileURL.path
        if let t = tabs.first(where: { $0.kind == .note && $0.url?.standardizedFileURL.path == path }) {
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

    /// The folder new notes go in.
    var newNotesFolder: URL { Settings.shared.value.defaultNewNotesFolder }

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
        if let fid = currentTab?.folderID, let f = folders.first(where: { $0.id == fid }) { folder = f } else { folder = researchFolder() }
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

    func folderName(forURL s: String) -> String? {
        guard let u = URL(string: s) else { return nil }
        let key = u.isFileURL ? u.standardizedFileURL.path : URLKey.key(for: u)
        for t in tabs where t.folderID != nil {
            if let tu = t.url, (tu.isFileURL ? tu.standardizedFileURL.path : URLKey.key(for: tu)) == key {
                return folders.first { $0.id == t.folderID }?.name
            }
        }
        return nil
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
