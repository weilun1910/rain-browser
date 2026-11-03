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
    var selectedDocument: String?
}

enum Selection: Hashable {
    case tab(UUID)
    case document(URL)
}

@MainActor
final class BrowserModel: ObservableObject {
    @Published var tabs: [Tab] = []
    @Published var folders: [Folder] = []
    @Published private(set) var selection: Selection?
    @Published var document: NoteDocument?
    @Published var addressText = ""
    @Published var addressFocusToken = 0
    @Published var flashMessage: String?

    var addressEditing = false
    let webConfig: WKWebViewConfiguration
    let notes = NotesStore()
    let resurfacer = Resurfacer()
    private var history: [Selection] = []
    private var saveWork: DispatchWorkItem?
    private var flashWork: DispatchWorkItem?

    init() {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = .default()
        c.preferences.isElementFullscreenEnabled = true
        c.preferences.javaScriptCanOpenWindowsAutomatically = false
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        c.applicationNameForUserAgent = "Version/\(major).0 Safari/605.1.15"
        webConfig = c
        resurfacer.model = self
        load()
    }

    // MARK: - Derived

    var currentTab: Tab? {
        if case .tab(let id) = selection { return tabs.first { $0.id == id } }
        return nil
    }

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
            let t = Tab(id: r.id, kind: r.kind, url: r.url.flatMap(URL.init(string:)), title: r.title,
                        isPinned: r.isPinned, folderID: r.folderID, createdAt: r.createdAt)
            t.model = self
            return t
        }
        if let id = s.selectedTab, let t = tabs.first(where: { $0.id == id }) {
            select(t)
        } else if let p = s.selectedDocument, FileManager.default.fileExists(atPath: p) {
            openDocument(URL(fileURLWithPath: p))
        }
    }

    func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
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
        switch selection {
        case .tab(let id): s.selectedTab = id
        case .document(let u): s.selectedDocument = u.path
        case nil: break
        }
        Paths.ensure(Paths.root)
        if let data = try? JSONEncoder.pretty.encode(s) {
            try? data.write(to: Paths.stateFile, options: .atomic)
        }
    }

    func prepareForQuit() {
        if let t = currentTab { endDwell(t) }
        document?.saveNow()
        saveNow()
    }

    // MARK: - Selection

    private func setSelection(_ new: Selection?) {
        let old = selection
        guard old != new else { return }
        if let old { history.removeAll { $0 == old }; history.append(old) }
        if history.count > 50 { history.removeFirst(history.count - 50) }

        // Leaving a tab: stop its dwell clock; drop it if it never went anywhere.
        if case .tab(let id) = old, let t = tabs.first(where: { $0.id == id }) {
            endDwell(t)
            if t.isBlank { tabs.removeAll { $0.id == t.id }; history.removeAll { $0 == .tab(t.id) } }
        }
        // Leaving a document: save it.
        if let doc = document {
            let stillOpen: Bool
            switch new {
            case .document(let u): stillOpen = u == doc.url
            case .tab(let id): stillOpen = tabs.first { $0.id == id }.map { $0.kind != .web && $0.url == doc.url } ?? false
            case nil: stillOpen = false
            }
            if !stillOpen { doc.saveNow(); document = nil }
        }
        selection = new
        syncAddress()
        scheduleSave()
    }

    func select(_ tab: Tab) {
        if tab.kind != .web, let u = tab.url {
            setSelection(.tab(tab.id))
            showDocument(u)
            return
        }
        setSelection(.tab(tab.id))
        if tab.url != nil { _ = tab.ensureWebView() }
        startDwell(tab)
        if let u = tab.url { IndexStore.shared.touchOpened(key: URLKey.key(for: u)) }
        resurfacer.contextFromTab(tab)
    }

    func syncAddress() {
        guard !addressEditing else { return }
        if let t = currentTab, t.kind == .web { addressText = t.url?.absoluteString ?? "" } else { addressText = "" }
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
            // Background tabs load right away so they're ready.
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
        if let t = currentTab, t.kind == .web {
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

    func close(_ tab: Tab) {
        let wasSelected = isSelected(tab)
        if tab.isPinned || tab.folderID != nil {
            // Pinned and filed tabs stay in the sidebar; closing just unloads them.
            tab.unload()
        } else {
            tab.unload()
            tabs.removeAll { $0.id == tab.id }
        }
        history.removeAll { $0 == .tab(tab.id) && !tabs.contains(where: { $0.id == tab.id }) }
        if wasSelected { selectPrevious(excluding: .tab(tab.id)) }
        objectWillChange.send()
        scheduleSave()
    }

    func remove(_ tab: Tab) {
        let wasSelected = isSelected(tab)
        tab.unload()
        tabs.removeAll { $0.id == tab.id }
        history.removeAll { $0 == .tab(tab.id) }
        if wasSelected { selectPrevious(excluding: .tab(tab.id)) }
        scheduleSave()
    }

    private func selectPrevious(excluding: Selection) {
        while let last = history.popLast() {
            if last == excluding { continue }
            switch last {
            case .tab(let id):
                if let t = tabs.first(where: { $0.id == id }) { selection = nil; select(t); return }
            case .document(let u):
                if FileManager.default.fileExists(atPath: u.path) { selection = nil; openDocument(u); return }
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
        switch selection {
        case .tab(let id):
            if let t = tabs.first(where: { $0.id == id }) {
                if t.kind != .web {
                    let wasDoc = document
                    wasDoc?.saveNow()
                    document = nil
                    selectPrevious(excluding: .tab(id))
                } else {
                    close(t)
                }
            }
        case .document(let u):
            document?.saveNow()
            document = nil
            selectPrevious(excluding: .document(u))
        case nil:
            break
        }
    }

    func goBack() { currentTab?.webView?.goBack() }
    func goForward() { currentTab?.webView?.goForward() }
    func reload() {
        guard let t = currentTab, t.kind == .web else { return }
        if let wv = t.webView { t.loadError = nil; wv.reload() } else if t.url != nil { _ = t.ensureWebView() }
    }
    func zoom(_ delta: Double?) {
        guard let wv = currentTab?.webView else { return }
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
            guard let id = UUID(uuidString: s), let t = tabs.first(where: { $0.id == id }) else { continue }
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

    func deleteFolder(_ f: Folder) {
        // Web tabs in the folder go back to Tabs. Note and file links are just removed.
        for t in tabs where t.folderID == f.id {
            if t.kind == .web { t.folderID = nil } else { t.unload() }
        }
        tabs.removeAll { $0.folderID == f.id && $0.kind != .web }
        folders.removeAll { $0.id == f.id }
        scheduleSave()
    }

    func toggleFolder(_ f: Folder) {
        guard let i = folders.firstIndex(where: { $0.id == f.id }) else { return }
        folders[i].isExpanded.toggle()
        scheduleSave()
    }

    func promptNewFolder(moving tab: Tab? = nil) {
        guard let name = Prompt.text(title: "New folder", message: "Name", defaultValue: "") , !name.isEmpty else { return }
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

    // MARK: - Documents

    func openDocument(_ url: URL) {
        setSelection(.document(url))
        showDocument(url)
    }

    private func showDocument(_ url: URL) {
        if document?.url != url {
            document?.saveNow()
            let doc = NoteDocument(url: url, notesDir: Settings.shared.value.notesDir)
            doc.onPause = { [weak self] d in self?.resurfacer.contextFromDocument(d) }
            doc.onSaved = { [weak self] d in
                Indexer.indexNote(url: d.url, text: d.text)
                self?.notes.reload()
            }
            document = doc
        }
        IndexStore.shared.touchOpened(key: URLKey.fileKey(url))
        if let d = document { resurfacer.contextFromDocument(d) }
        syncAddress()
    }

    func newNote() {
        guard let url = notes.create() else { flash("Couldn't create a note in the notes folder"); return }
        openDocument(url)
        DispatchQueue.main.async { NotificationCenter.default.post(name: .focusEditor, object: nil) }
    }

    func renameNote(_ url: URL) {
        let current = url.deletingPathExtension().lastPathComponent
        guard let name = Prompt.text(title: "Rename note", message: "File name", defaultValue: current), !name.isEmpty else { return }
        let wasOpen = document?.url == url
        document?.saveNow()
        guard let newURL = notes.rename(url, to: name) else { flash("Couldn't rename that note"); return }
        Indexer.removeFile(url: url)
        if let text = try? String(contentsOf: newURL, encoding: .utf8) { Indexer.indexNote(url: newURL, text: text) }
        for t in tabs where t.url == url { t.url = newURL }
        if wasOpen { document = nil; openDocument(newURL) }
        scheduleSave()
    }

    func trashNote(_ url: URL) {
        if document?.url == url {
            document?.saveNow()
            document = nil
            selectPrevious(excluding: .document(url))
        }
        notes.trash(url)
        Indexer.removeFile(url: url)
        tabs.removeAll { $0.url == url && $0.kind != .web }
        scheduleSave()
    }

    func addDocumentToFolder(_ url: URL, folder: Folder) {
        if tabs.contains(where: { $0.url == url && $0.folderID == folder.id }) { return }
        let isNote = FileSafety.isInside(url, Settings.shared.value.notesDir)
        let t = Tab(kind: isNote ? .note : .file, url: url, title: Indexer.noteTitle(text: (try? String(contentsOf: url, encoding: .utf8)) ?? "", url: url), folderID: folder.id)
        t.model = self
        tabs.append(t)
        scheduleSave()
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
        // Context for the right panel, once the page settles.
        let ctx = DispatchWorkItem { [weak self, weak tab] in
            guard let self, let tab, tab.webView?.url == url else { return }
            tab.extract { e in
                tab.lastExtract = e
                if self.isSelected(tab) { self.resurfacer.contextFromTab(tab) }
            }
        }
        tab.contextWork = ctx
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: ctx)
        guard indexable else { return }
        // Index it if it stays open about five seconds.
        let cap = DispatchWorkItem { [weak tab] in
            guard let tab, tab.webView?.url == url else { return }
            tab.extract { e in
                guard let e, tab.webView?.url == url else { return }
                tab.lastExtract = e
                Indexer.indexPage(url: url, title: e.title, description: e.description, text: e.text)
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
        switch d.source {
        case .web, .chrome:
            if let u = URL(string: d.url) { newTab(url: u, select: true) }
        case .note, .markdown:
            if let u = URL(string: d.url) { openDocument(u) }
        }
        IndexStore.shared.touchOpened(key: d.key)
    }

    /// Notes get a link under "## Related". Pages get the item added to their folder, or to "Research".
    func addToResearch(_ card: Card) -> String {
        let d = card.match.doc
        if let doc = document, !doc.isReadOnly {
            guard let newText = Markdown.appendRelated(to: doc.text, title: d.title, url: d.url) else { return "Already linked" }
            doc.replaceText(newText)
            return "Added to note"
        }
        let folder: Folder
        if let fid = currentTab?.folderID, let f = folders.first(where: { $0.id == fid }) { folder = f } else { folder = researchFolder() }
        guard let u = URL(string: d.url) else { return "Couldn't add" }
        if tabs.contains(where: { $0.folderID == folder.id && $0.url.map { URLKey.key(for: $0) } == URLKey.key(for: u) }) {
            return "Already in \(folder.name)"
        }
        let kind: TabKind = d.source == .note ? .note : (d.source == .markdown ? .file : .web)
        let t = Tab(kind: kind, url: u, title: d.title, folderID: folder.id)
        t.model = self
        tabs.append(t)
        if let i = folders.firstIndex(where: { $0.id == folder.id }) { folders[i].isExpanded = true }
        scheduleSave()
        return "Added to \(folder.name)"
    }

    func folderName(forURL s: String) -> String? {
        guard let u = URL(string: s) else { return nil }
        let key = URLKey.key(for: u)
        for t in tabs where t.folderID != nil {
            if let tu = t.url, URLKey.key(for: tu) == key { return folders.first { $0.id == t.folderID }?.name }
        }
        return nil
    }

    // MARK: - Misc

    func flash(_ message: String) {
        flashMessage = message
        flashWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.flashMessage = nil }
        flashWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)
    }

    func openFromSystem(_ urls: [URL]) {
        for u in urls {
            if u.isFileURL && u.pathExtension.lowercased() == "md" { openDocument(u) } else { newTab(url: u, select: true) }
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
