import AppKit
import Foundation

/// The watcher on the space folders and what it watches.
@MainActor
final class SpaceFolderState {
    var watcher: FolderWatcher?
    var watchedPaths: [String] = []
    var observer: NSObjectProtocol?
}

// Space folders in the model: each space's folder on disk, opening what's in them as tabs, and
// saving pages into them. The disk side is SpaceFolders.swift.
extension BrowserModel {
    /// On once space folders are on and this profile's root could be made.
    var spaceFoldersOn: Bool { SpaceFolders.root != nil }

    /// Makes the root and every space's folder, and starts watching them. Called once the saved
    /// state is loaded.
    func setUpSpaceFolders() {
        SpaceFolders.customRoot = BrowserPrefs.shared.value.spaceFoldersRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard let root = SpaceFolders.root else { return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            appLog.error("space folders root: \(error.localizedDescription, privacy: .public)")
            return
        }
        FolderMeta.shared.reload()
        for sp in spaces { ensureSpaceFolder(sp.id) }
        if spaceFolderState.observer == nil {
            spaceFolderState.observer = NotificationCenter.default.addObserver(forName: .spaceFoldersChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.spaceFoldersDidChange() }
            }
        }
        refreshSpaceFolderWatch()
        if SpaceFolders.refreshLinkedRoots() { NotificationCenter.default.post(name: .notesNeedRescan, object: nil) }
        SavedPages.shared.rescan()
    }

    /// Something changed in the folders, from Rain or from Finder.
    func spaceFoldersDidChange() {
        guard spaceFoldersOn else { return }
        refreshSpaceFolderWatch()
        if SpaceFolders.refreshLinkedRoots() {
            refreshSpaceFolderWatch()
            NotificationCenter.default.post(name: .notesNeedRescan, object: nil)
        }
        SavedPages.shared.rescan()
        checkNotesOnDisk()
        objectWillChange.send()
    }

    /// Watches the root and every folder linked into it.
    func refreshSpaceFolderWatch() {
        guard let root = SpaceFolders.root else { spaceFolderState.watcher = nil; spaceFolderState.watchedPaths = []; return }
        let paths = ([root] + SpaceFolders.notesRoots.dropFirst()).map { $0.standardizedFileURL.path }
        guard paths != spaceFolderState.watchedPaths else { return }
        spaceFolderState.watchedPaths = paths
        spaceFolderState.watcher = FolderWatcher(paths: paths, anyFile: true) {
            SpaceFolders.changed(after: 0.3)
        }
    }

    // MARK: Each space's folder

    /// The space's folder, if space folders are on and it has one. Doesn't touch the disk.
    func spaceFolderURL(_ space: Space) -> URL? {
        guard let root = SpaceFolders.root, let name = space.folderName else { return nil }
        return root.appendingPathComponent(name, isDirectory: true)
    }

    func spaceFolderURL(id: UUID) -> URL? { spaces.first { $0.id == id }.flatMap { spaceFolderURL($0) } }

    /// The space's folder, made if it isn't there. A folder renamed or moved in Finder, still
    /// under the root, is found again by its bookmark.
    @discardableResult
    func ensureSpaceFolder(_ id: UUID) -> URL? {
        guard let root = SpaceFolders.root, let i = spaces.firstIndex(where: { $0.id == id }) else { return nil }
        if let name = spaces[i].folderName {
            let u = root.appendingPathComponent(name, isDirectory: true)
            if SpaceFolders.isDirectory(u) {
                if spaces[i].folderBookmark == nil { spaces[i].folderBookmark = FolderBookmark.make(u); scheduleSave() }
                return u
            }
            if let data = spaces[i].folderBookmark, let found = FolderBookmark.resolve(data),
               found.deletingLastPathComponent().standardizedFileURL.path == root.path, SpaceFolders.isDirectory(found) {
                rewriteStoredPaths(from: u, to: found)
                spaces[i].folderName = found.lastPathComponent
                scheduleSave()
                return found
            }
        }
        var name = spaces[i].folderName ?? ""
        if name.isEmpty {
            // Named after the space, and not the same as another space's folder.
            let taken = Set(spaces.filter { $0.id != id }.compactMap { $0.folderName?.lowercased() })
            let base = SpaceFolders.safeName(spaces[i].name, fallback: "Space")
            name = base
            var n = 2
            while taken.contains(name.lowercased()) { name = "\(base) \(n)"; n += 1 }
        }
        let u = root.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        } catch {
            appLog.error("space folder: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        spaces[i].folderName = name
        spaces[i].folderBookmark = FolderBookmark.make(u)
        scheduleSave()
        return u
    }

    /// Renaming a space renames its folder, unless another folder already has the new name.
    func renameSpaceFolder(_ id: UUID) {
        guard let root = SpaceFolders.root, let i = spaces.firstIndex(where: { $0.id == id }), let old = spaces[i].folderName else { return }
        let want = SpaceFolders.safeName(spaces[i].name, fallback: "Space")
        guard want != old else { return }
        let from = root.appendingPathComponent(old, isDirectory: true), to = root.appendingPathComponent(want, isDirectory: true)
        guard SpaceFolders.isDirectory(from) else { return }
        if SpaceFolders.exists(to) && want.lowercased() != old.lowercased() {
            toast("Kept the folder name \(old), since there's already a folder called \(want)")
            return
        }
        do { try FileManager.default.moveItem(at: from, to: to) } catch {
            toast("Couldn't rename the space's folder")
            return
        }
        spaces[i].folderName = want
        spaces[i].folderBookmark = FolderBookmark.make(to)
        rewriteStoredPaths(from: from, to: to)
        SpaceFolders.changed()
        scheduleSave()
    }

    /// Paths kept in state.json follow a folder or file that Rain moved or renamed.
    func rewriteStoredPaths(from old: URL, to new: URL) {
        let o = SpaceFolders.encode(old), n = SpaceFolders.encode(new)
        guard o != n else { return }
        func swap(_ s: String?) -> String? {
            guard let s else { return nil }
            if s == o { return n }
            if s.hasPrefix(o + "/") { return n + s.dropFirst(o.count) }
            return nil
        }
        for i in folders.indices { if let p = swap(folders[i].path) { folders[i].path = p } }
        for t in tabs {
            if let p = swap(t.savedFile) { t.savedFile = p }
            // A note's own address moves with it.
            if t.isNote, let u = t.url, let p = swap(SpaceFolders.encode(u)), let nu = SpaceFolders.decode(p) {
                if let d = docs[u.standardizedFileURL.path] {
                    replaceDoc(from: u, to: nu, d)
                }
                t.url = nu
            }
        }
        FolderMeta.shared.moved(from: old, to: new)
        scheduleSave()
    }

    // MARK: Opening what's in a folder

    /// Opens a page, note or file from a folder as a tab in the current space. A page or note
    /// already open in this space is selected instead of opened twice. `background` opens it
    /// without leaving the page you're on, and `split` beside it.
    @discardableResult
    func openFolderEntry(_ e: FolderEntry, background: Bool = false, split: Bool = false) -> Tab? {
        guard !e.isBroken else { toast("The original of \(e.name) can't be found"); return nil }
        FolderMeta.shared.markOpened(e.url)
        let enc = SpaceFolders.encode(e.url)
        func show(_ t: Tab) {
            if split, currentTab != nil, currentTab?.id != t.id { openInSplit(t, side: .right) } else if !background { select(t) }
        }
        switch e.kind {
        case .folder:
            return nil
        case .page:
            guard let page = e.page else { return nil }
            if let t = (spaceTabs + essentials).first(where: { $0.savedFile == enc }) {
                show(t)
                return t
            }
            let isApp = page.scheme == AppPages.scheme
            let t = Tab(kind: isApp ? .app : .web, url: page, title: e.pageTitle ?? e.name)
            t.model = self
            t.savedFile = enc
            if !isApp { t.pinnedURL = page }
            t.order = topOrder(today: currentSpaceID)
            tabs.append(t)
            if background && !split { if !isApp { _ = t.ensureWebView() } } else { show(t) }
            scheduleSave()
            return t
        case .note:
            let t = openNote(e.target, select: false)
            if e.isLink && t.savedFile == nil && t.folderID == nil { t.savedFile = enc }
            show(t)
            return t
        case .file:
            if let t = spaceTabs.first(where: { $0.url?.standardizedFileURL.path == e.target.standardizedFileURL.path }) {
                show(t)
                return t
            }
            let t = Tab(url: e.target, title: e.name)
            t.model = self
            t.savedFile = enc
            t.order = topOrder(today: currentSpaceID)
            tabs.append(t)
            if background && !split { _ = t.ensureWebView() } else { show(t) }
            scheduleSave()
            return t
        }
    }

    // MARK: Saving pages

    /// Saves a tab's page into `dir` as a .webloc named `name`, or the page's title. A Today tab
    /// then remembers the file, so its saved address works like a pinned tab's.
    @discardableResult
    func savePage(_ tab: Tab, in dir: URL, name: String? = nil, quiet: Bool = false) -> URL? {
        guard tab.isWeb || tab.isApp, let u = tab.webView?.url ?? tab.url else { return nil }
        let title = (name?.isEmpty == false ? name! : tab.displayTitle)
        do {
            let file = try SpaceFolders.savePage(u, title: title, in: dir)
            SavedPages.shared.noteSaved(file, page: u)
            if tab.folderID == nil && !tab.isPinned && !tab.isEssential && tab.savedFile == nil {
                tab.savedFile = SpaceFolders.encode(file)
                if tab.isWeb { tab.pinnedURL = u }
            }
            Thumbnails.shared.pageSaved(tab, url: u)
            if !quiet { toast("Saved to \(dir.lastPathComponent)") }
            scheduleSave()
            return file
        } catch {
            toast("Couldn't save the page: \(error)")
            return nil
        }
    }

    /// Update Saved Address: the saved page now points at where the tab is.
    func updateSavedAddress(_ tab: Tab) {
        guard let enc = tab.savedFile, let file = SpaceFolders.decode(enc), let u = tab.webView?.url ?? tab.url,
              SpaceFolders.canWrite(file), var p = Webloc.read(file) else { toast("Couldn't find the saved page"); return }
        p.url = u
        if !tab.title.isEmpty { p.title = tab.title }
        do { try Webloc.write(p, to: file, replacing: true) } catch { toast("Couldn't update the saved page"); return }
        tab.pinnedURL = u
        SavedPages.shared.noteRemoved(file)
        SavedPages.shared.noteSaved(file, page: u)
        Thumbnails.shared.pageSaved(tab, url: u)
        SpaceFolders.changed()
        toast("Saved address is now this page")
        scheduleSave()
    }

    /// The saved page files for the tab's page, wherever they are.
    func savedFiles(for tab: Tab?) -> [URL] {
        guard let tab, tab.isWeb || tab.isApp else { return [] }
        var out = SavedPages.shared.files(for: tab.webView?.url ?? tab.url)
        if let enc = tab.savedFile, let f = SpaceFolders.decode(enc), f.pathExtension.lowercased() == Webloc.ext,
           !out.contains(where: { $0.path == f.path }), SpaceFolders.exists(f) { out.append(f) }
        return out
    }

    /// Removes a saved page: its file goes to the Trash, and tabs that came from it forget it.
    func removeSavedPage(_ file: URL, completion: ((Bool) -> Void)? = nil) {
        SpaceFolders.trash([file]) { [weak self] ok in
            guard let self else { return }
            if ok {
                SavedPages.shared.noteRemoved(file)
                let enc = SpaceFolders.encode(file)
                for t in self.tabs where t.savedFile == enc && t.folderID == nil { t.savedFile = nil; if !t.isPinned && !t.isEssential { t.pinnedURL = nil } }
                self.toast("Moved \(file.deletingPathExtension().lastPathComponent) to the Trash")
                self.scheduleSave()
            } else {
                self.toast("Couldn't move that to the Trash")
            }
            completion?(ok)
        }
    }

    /// Change in Settings, Browsing: the space folders move to `newRoot`. A space whose folder
    /// name is already taken there uses the folder that's there.
    func changeSpaceFoldersRoot(to newRoot: URL) {
        guard let old = SpaceFolders.root else { return }
        let new = newRoot.standardizedFileURL
        guard new.path != old.path else { return }
        guard !SpaceFolders.isInside(new, old) else { toast("Pick a folder outside the current space folders"); return }
        do { try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true) } catch {
            toast("Couldn't use that folder")
            return
        }
        var moved: [(URL, URL)] = []
        for sp in spaces {
            guard let name = sp.folderName else { continue }
            let from = old.appendingPathComponent(name, isDirectory: true), to = new.appendingPathComponent(name, isDirectory: true)
            if SpaceFolders.isDirectory(from) && !SpaceFolders.exists(to), (try? FileManager.default.moveItem(at: from, to: to)) != nil {
                moved.append((from, to))
            }
        }
        // Notes open from those folders follow them.
        for (from, to) in moved {
            for t in tabs where t.isNote {
                guard let u = t.url?.standardizedFileURL, u.path == from.path || u.path.hasPrefix(from.path + "/") else { continue }
                let nu = URL(fileURLWithPath: to.path + u.path.dropFirst(from.path.count))
                if let d = docs[u.path] { replaceDoc(from: u, to: nu, d) }
                t.url = nu
            }
        }
        BrowserPrefs.shared.update { $0.spaceFoldersRoot = new.path }
        SpaceFolders.customRoot = new
        for i in spaces.indices { spaces[i].folderBookmark = nil }
        let oldPath = old.path
        Task.detached { IndexStore.shared.deleteRoot(oldPath) }
        setUpSpaceFolders()
        NotificationCenter.default.post(name: .notesNeedRescan, object: nil)
        SpaceFolders.changed()
        scheduleSave()
        toast("Space folders are now in \(new.lastPathComponent)")
    }

    /// Link folder: an alias to `target` in `dir`, or the current space's folder. Nothing is copied.
    @discardableResult
    func linkFolder(_ target: URL, into dir: URL? = nil) -> URL? {
        guard let d = dir ?? currentSpace.flatMap({ ensureSpaceFolder($0.id) }) else { return nil }
        do {
            let link = try SpaceFolders.link(target, in: d)
            toast("Linked \(target.lastPathComponent) into \(d.lastPathComponent)")
            return link
        } catch {
            toast("Couldn't link that folder: \(error)")
            return nil
        }
    }

    /// A folder path for people: "Home / Work", from the root down.
    func displayPath(_ url: URL) -> String {
        guard let rel = SpaceFolders.relativePath(url), !rel.isEmpty else { return url.lastPathComponent }
        var parts = rel.split(separator: "/").map(String.init)
        if let first = parts.first, let sp = spaces.first(where: { $0.folderName == first }) { parts[0] = sp.name }
        return parts.joined(separator: " / ")
    }
}

extension BrowserModel {
    /// Moves an open note's document to its new address.
    func replaceDoc(from old: URL, to new: URL, _ d: NoteDocument) {
        docsReplace(old.standardizedFileURL.path, new.standardizedFileURL.path, d)
        d.relocate(to: new)
    }
}
