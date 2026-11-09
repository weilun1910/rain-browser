import AppKit
import Foundation

// The sidebar's Folders section shows pinned folders. A pinned folder is a shortcut to a folder on
// disk, at any depth: pinning never moves it, and unpinning never deletes anything. Under each
// one the sidebar shows what's on disk, subfolders first, five levels deep, with Rain's own order
// for each folder and things it hasn't seen yet at the end, by name.
//
// In the model a pinned folder is a top-level `Folder` with a `path`, and the folders and items
// under it are read from disk into `Folder`s and `Tab`s by `syncPinnedFolders`, so the sidebar's
// rows, drags, drop zones and spring-open work on them unchanged. Each item's tab remembers its
// file in `savedFile`, which is how the next read finds it again.

extension BrowserModel {
    /// Folders live on disk: space folders are on and today's folders have moved there.
    var diskFolders: Bool { spaceFoldersOn && spaceFolderState.migrated }

    func isDiskFolder(_ id: UUID?) -> Bool { id.flatMap { folder($0)?.path } != nil }

    /// Where a folder's things are on disk: the folder, or the original of a linked one.
    func folderDirectory(_ f: Folder) -> URL? {
        guard let p = f.path, let loc = SpaceFolders.decode(p) else { return nil }
        if SpaceFolders.isDirectory(loc) { return loc }
        if FileLink.isLink(loc), let t = FileLink.resolve(loc), SpaceFolders.isDirectory(t) { return t }
        return nil
    }

    /// The sidebar folder showing `dir` in a space, if one does.
    func diskFolderID(for dir: URL, space: UUID?) -> UUID? {
        let p = dir.standardizedFileURL.path
        return folders.first { $0.path != nil && $0.spaceID == space && folderDirectory($0)?.path == p }?.id
    }

    // MARK: Reading the folders from disk

    /// Reads every pinned folder's tree from disk into the sidebar. Called after loading and
    /// whenever something in the folders changes, from Rain or from Finder.
    func syncPinnedFolders() {
        guard diskFolders else { return }
        let before = folderSignatureAll()
        for top in folders where top.parentID == nil && top.path != nil {
            guard let dir = locatePinned(top.id) else {
                // Gone from disk: the pin goes, and nothing else is touched.
                dropDiskTree(top.id)
                continue
            }
            syncTree(top.id, dir: dir, depth: 0)
        }
        if folderSignatureAll() != before {
            objectWillChange.send()
            scheduleSave()
        }
    }

    private func folderSignatureAll() -> [String] {
        folders.map { "\($0.id)|\($0.name)|\($0.parentID?.uuidString ?? "")|\($0.order ?? 0)|\($0.path ?? "")" }
            + tabs.filter { $0.folderID != nil }.map { "\($0.id)|\($0.folderID!)|\($0.order)|\($0.savedFile ?? "")|\($0.customTitle ?? "")" }
    }

    /// A pinned folder's place on disk. One moved or renamed in Finder is found by its bookmark.
    func locatePinned(_ id: UUID) -> URL? {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return nil }
        if let d = folderDirectory(folders[i]) {
            if folders[i].bookmark == nil { folders[i].bookmark = FolderBookmark.make(d) }
            return d
        }
        guard let data = folders[i].bookmark, let found = FolderBookmark.resolve(data), SpaceFolders.isDirectory(found),
              let oldPath = folders[i].path, let old = SpaceFolders.decode(oldPath) else { return nil }
        rewriteStoredPaths(from: old, to: found)
        if let j = folders.firstIndex(where: { $0.id == id }) {
            folders[j].path = SpaceFolders.encode(found)
            folders[j].name = found.lastPathComponent
        }
        return found
    }

    private func syncTree(_ fid: UUID, dir: URL, depth: Int) {
        guard let parent = folder(fid) else { return }
        let entries = SpaceFolders.ordered(SpaceFolders.list(dir), in: dir)
        // Subfolders, while there's room for another level.
        var keep: [(UUID, URL)] = []
        if depth + 1 < Folder.maxDepth {
            for (n, e) in entries.filter({ $0.kind == .folder && !$0.isBroken }).enumerated() {
                let enc = SpaceFolders.encode(e.url)
                if let i = folders.firstIndex(where: { $0.parentID == fid && $0.path == enc }) {
                    if folders[i].name != e.name { folders[i].name = e.name }
                    if folders[i].order != Double(n) { folders[i].order = Double(n) }
                    if folders[i].spaceID != parent.spaceID { folders[i].spaceID = parent.spaceID }
                    keep.append((folders[i].id, e.target))
                } else {
                    let f = Folder(spaceID: parent.spaceID, name: e.name, isExpanded: false, order: Double(n), parentID: fid, path: enc)
                    folders.append(f)
                    keep.append((f.id, e.target))
                }
            }
        }
        let kept = Set(keep.map(\.0))
        for f in folders where f.parentID == fid && !kept.contains(f.id) { dropDiskTree(f.id) }
        // Pages, notes and files.
        var seen = Set<UUID>()
        for (n, e) in entries.filter({ $0.kind != .folder && !$0.isBroken }).enumerated() {
            let enc = SpaceFolders.encode(e.url)
            if let t = tabs.first(where: { $0.folderID == fid && $0.savedFile == enc }) {
                refresh(t, from: e)
                t.order = Double(n)
                seen.insert(t.id)
            } else if let t = makeTab(for: e, in: parent) {
                t.order = Double(n)
                tabs.append(t)
                seen.insert(t.id)
            }
        }
        for t in tabs where t.folderID == fid && !seen.contains(t.id) && t.savedFile != nil { fileVanished(t) }
        for (id, d) in keep { syncTree(id, dir: d, depth: depth + 1) }
    }

    private func makeTab(for e: FolderEntry, in f: Folder) -> Tab? {
        let t: Tab
        switch e.kind {
        case .page:
            guard let page = e.page else { return nil }
            let isApp = page.scheme == AppPages.scheme
            t = Tab(kind: isApp ? .app : .web, url: page, title: e.pageTitle ?? e.name, folderID: f.id)
            if !isApp { t.pinnedURL = page }
        case .note:
            t = Tab(kind: .note, url: e.target, title: e.name, folderID: f.id)
        case .file:
            t = Tab(url: e.target, title: e.name, folderID: f.id)
        case .folder:
            return nil
        }
        t.model = self
        t.spaceID = f.spaceID
        t.savedFile = SpaceFolders.encode(e.url)
        if e.kind == .page { t.customTitle = e.name }
        return t
    }

    /// A file renamed, re-pointed or edited outside Rain: the tab follows it.
    private func refresh(_ t: Tab, from e: FolderEntry) {
        switch e.kind {
        case .page:
            if t.customTitle != e.name { t.customTitle = e.name }
            if let page = e.page, t.isWeb, t.pinnedURL.map({ !Tab.samePage($0, page) }) ?? true {
                t.pinnedURL = page
                if !t.isLoaded { t.url = page }
            }
        case .note:
            if let u = t.url, u.standardizedFileURL.path != e.target.path {
                if let d = docs[u.standardizedFileURL.path] { replaceDoc(from: u, to: e.target, d) }
                t.url = e.target
            }
        case .file, .folder:
            break
        }
    }

    /// The file behind a folder tab is gone. What's on screen or loaded stays, in Tabs. The rest
    /// goes quietly, since the file was the thing.
    private func fileVanished(_ t: Tab) {
        if t.isLoaded || isVisible(t) || split(containing: t.id) != nil {
            t.folderID = nil
            t.savedFile = nil
            if !t.isPinned && !t.isEssential { t.pinnedURL = nil }
            t.order = topOrder(today: t.spaceID ?? currentSpaceID)
        } else {
            tabs.removeAll { $0.id == t.id }
            selectionHistory.removeAll { $0 == .tab(t.id) }
        }
    }

    /// Takes a folder and everything under it out of the sidebar. Nothing on disk changes.
    func dropDiskTree(_ id: UUID) {
        let all = [id] + descendants(of: id)
        for fid in all { for t in tabs where t.folderID == fid { fileVanished(t) } }
        folders.removeAll { all.contains($0.id) }
    }

    // MARK: Pinning

    /// Pins a folder from the popup, a linked one included. It stays where it is on disk.
    @discardableResult
    func pinFolder(_ url: URL, at index: Int = Int.max, space: UUID? = nil) -> Folder? {
        guard diskFolders else { return nil }
        let sp = space ?? currentSpaceID
        let loc = url.standardizedFileURL
        let enc = SpaceFolders.encode(loc)
        if let f = folders.first(where: { $0.parentID == nil && $0.spaceID == sp && $0.path == enc }) {
            openFolderPath(to: f.id)
            toast("\(f.name) is already pinned")
            return f
        }
        let target = FileLink.isLink(loc) ? FileLink.resolve(loc) : loc
        guard let target, SpaceFolders.isDirectory(target) else { toast("Only folders can be pinned"); return nil }
        let f = Folder(spaceID: sp, name: loc.lastPathComponent, isExpanded: true, order: 0, parentID: nil, path: enc,
                       bookmark: FolderBookmark.make(loc))
        folders.append(f)
        var list = childFolders(of: nil, space: sp).map(\.id).filter { $0 != f.id }
        list.insert(f.id, at: max(0, min(index, list.count)))
        for (n, id) in list.enumerated() { if let i = folders.firstIndex(where: { $0.id == id }) { folders[i].order = Double(n) } }
        syncPinnedFolders()
        objectWillChange.send()
        scheduleSave()
        return folder(f.id)
    }

    /// Unpin: the folder leaves the sidebar and stays on disk with everything in it.
    func unpinFolder(_ id: UUID) {
        guard let f = folder(id), f.parentID == nil, f.path != nil else { return }
        dropDiskTree(id)
        toast("Unpinned \(f.name). It's still in Folders.")
        objectWillChange.send()
        scheduleSave()
    }

    /// Whether `url` is pinned in this space.
    func isPinnedFolder(_ url: URL, space: UUID? = nil) -> Bool {
        let enc = SpaceFolders.encode(url)
        return folders.contains { $0.parentID == nil && $0.spaceID == (space ?? currentSpaceID) && $0.path == enc }
    }

    var pinnedFolders: [Folder] { childFolders(of: nil).filter { $0.path != nil } }

    // MARK: Changing folders on disk

    /// A new folder in the space's folder, pinned at the top, or inside a pinned folder's tree.
    func createDiskFolder(named name: String, in parent: UUID?) -> Folder? {
        if let parent, let pf = folder(parent) {
            guard let dir = folderDirectory(pf) else { return nil }
            guard let u = try? SpaceFolders.makeFolder(named: name, in: dir) else { toast("Couldn't make the folder"); return nil }
            let siblings = childFolders(of: parent).compactMap { $0.path.flatMap(SpaceFolders.decode)?.lastPathComponent }
            let files = tabs.filter { $0.folderID == parent }.sorted { $0.order < $1.order }.compactMap { $0.savedFile.flatMap(SpaceFolders.decode)?.lastPathComponent }
            FolderMeta.shared.setOrder([u.lastPathComponent] + siblings + files, of: dir)
            let f = Folder(spaceID: pf.spaceID, name: u.lastPathComponent, isExpanded: true, order: (childFolders(of: parent).first?.order ?? 0) - 1,
                           parentID: parent, path: SpaceFolders.encode(u))
            folders.append(f)
            openFolderPath(to: parent)
            scheduleSave()
            return f
        }
        guard let dir = ensureSpaceFolder(currentSpaceID), let u = try? SpaceFolders.makeFolder(named: name, in: dir) else {
            toast("Couldn't make the folder")
            return nil
        }
        let first = childFolders(of: nil).first?.order ?? 0
        let f = Folder(spaceID: currentSpaceID, name: u.lastPathComponent, isExpanded: true, order: first - 1, parentID: nil,
                       path: SpaceFolders.encode(u), bookmark: FolderBookmark.make(u))
        folders.append(f)
        scheduleSave()
        return f
    }

    /// Rename renames the folder on disk. A linked folder's link is renamed, never its original.
    func renameDiskFolder(_ f: Folder, to name: String) {
        guard let p = f.path, let loc = SpaceFolders.decode(p) else { return }
        do {
            let new = try SpaceFolders.rename(loc, to: name)
            rewriteStoredPaths(from: loc, to: new)
            if let i = folders.firstIndex(where: { $0.id == f.id }) {
                folders[i].name = new.lastPathComponent
                if folders[i].parentID == nil { folders[i].bookmark = FolderBookmark.make(new) }
            }
            syncPinnedFolders()
        } catch {
            toast("Couldn't rename the folder: \(error)")
        }
    }

    /// Move to Trash for a folder inside a pinned one.
    func trashDiskFolder(_ f: Folder) {
        guard let p = f.path, let loc = SpaceFolders.decode(p) else { return }
        SpaceFolders.trash([loc]) { [weak self] ok in
            guard let self else { return }
            if ok {
                self.dropDiskTree(f.id)
                self.toast("Moved \(f.name) to the Trash")
                self.syncPinnedFolders()
            } else {
                self.toast("Couldn't move \(f.name) to the Trash")
            }
        }
    }

    func promptTrashDiskFolder(_ f: Folder) {
        if Prompt.confirm(title: "Move \(f.name) to the Trash?",
                          message: "Everything in it goes too. You can put it back from the Trash in Finder.", ok: "Move to Trash") {
            trashDiskFolder(f)
        }
    }

    /// A folder dragged into another moves there on disk. One that lives in a linked folder is
    /// linked instead, so the original stays put. Dragged to the top of the section, it's pinned
    /// where it is. Returns false if it can't go there.
    func placeDiskFolder(_ id: UUID, in parent: UUID?, at index: Int) -> Bool {
        guard let f = folder(id), let p = f.path, let loc = SpaceFolders.decode(p) else { return false }
        guard let parent else {
            if f.parentID == nil { return reorderPins(id, at: index) }
            return pinFolder(loc, at: index, space: f.spaceID) != nil
        }
        guard let pf = folder(parent), let pdir = folderDirectory(pf) else { return false }
        guard canNest(id, in: parent) else {
            if parent != id, !descendants(of: id).contains(parent) { toast("Folders go \(Folder.maxDepth) levels deep") }
            return false
        }
        if loc.deletingLastPathComponent().standardizedFileURL.path == pdir.path {
            // Already there: a new place among its neighbours.
            var list = childFolders(of: parent).map(\.id).filter { $0 != id }
            list.insert(id, at: max(0, min(index, list.count)))
            for (n, fid) in list.enumerated() { if let i = folders.firstIndex(where: { $0.id == fid }) { folders[i].order = Double(n); folders[i].parentID = parent } }
            writeOrder(of: parent)
            objectWillChange.send()
            scheduleSave()
            return true
        }
        do {
            if let orig = linkedOriginal(containing: loc), linkedOriginal(containing: pdir)?.path != orig.path {
                try SpaceFolders.link(folderDirectory(f) ?? loc, in: pdir)
            } else {
                let new = try SpaceFolders.move(loc, into: pdir)
                rewriteStoredPaths(from: loc, to: new)
                if let i = folders.firstIndex(where: { $0.id == id }) {
                    // It keeps its rows, now inside the folder it went into.
                    folders[i].parentID = parent
                    folders[i].bookmark = nil
                    folders[i].name = new.lastPathComponent
                    folders[i].spaceID = pf.spaceID
                }
                for d in descendants(of: id) { if let i = folders.firstIndex(where: { $0.id == d }) { folders[i].spaceID = pf.spaceID } }
            }
        } catch {
            toast("Couldn't move \(f.name): \(error)")
            return false
        }
        openFolderPath(to: parent)
        syncPinnedFolders()
        if let new = folder(id), let d = folderDirectory(new) {
            let names = childFolders(of: parent).filter { $0.id != id }.compactMap { $0.path.flatMap(SpaceFolders.decode)?.lastPathComponent }
            var list = names
            list.insert(d.lastPathComponent, at: max(0, min(index, list.count)))
            FolderMeta.shared.setOrder(list + itemNames(in: parent), of: pdir)
            syncPinnedFolders()
        }
        objectWillChange.send()
        scheduleSave()
        return true
    }

    private func reorderPins(_ id: UUID, at index: Int) -> Bool {
        guard let f = folder(id) else { return false }
        var list = childFolders(of: nil, space: f.spaceID).map(\.id).filter { $0 != id }
        list.insert(id, at: max(0, min(index, list.count)))
        for (n, fid) in list.enumerated() { if let i = folders.firstIndex(where: { $0.id == fid }) { folders[i].order = Double(n) } }
        objectWillChange.send()
        scheduleSave()
        return true
    }

    private func itemNames(in fid: UUID) -> [String] {
        tabs.filter { $0.folderID == fid }.sorted { $0.order < $1.order }.compactMap { $0.savedFile.flatMap(SpaceFolders.decode)?.lastPathComponent }
    }

    /// Writes the folder's sidebar order as Rain's order for it on disk.
    func writeOrder(of fid: UUID) {
        guard let f = folder(fid), let dir = folderDirectory(f) else { return }
        let subs = childFolders(of: fid).compactMap { $0.path.flatMap(SpaceFolders.decode)?.lastPathComponent }
        FolderMeta.shared.setOrder(subs + itemNames(in: fid), of: dir)
    }

    // MARK: Tabs going in and out of folders

    /// Files a tab in a folder on disk: a page is saved there, or moved there if it's already
    /// saved in a folder, and a note moves there if it lives in the space folders or is linked
    /// there if it lives elsewhere. Returns the file, or nil if it couldn't.
    @discardableResult
    func fileTabOnDisk(_ t: Tab, into dir: URL) -> URL? {
        let current = t.savedFile.flatMap(SpaceFolders.decode).flatMap { SpaceFolders.exists($0) ? $0 : nil }
        do {
            if t.isWeb || t.isApp {
                if let cur = current, cur.pathExtension.lowercased() == Webloc.ext, t.folderID != nil || t.keepsSavedURL {
                    if cur.deletingLastPathComponent().standardizedFileURL.path == dir.standardizedFileURL.path { return cur }
                    let new = try SpaceFolders.move(cur, into: dir)
                    rewriteStoredPaths(from: cur, to: new)
                    return new
                }
                guard let u = t.webView?.url ?? t.url else { return nil }
                let file = try SpaceFolders.savePage(u, title: t.displayTitle, in: dir)
                SavedPages.shared.noteSaved(file, page: u)
                t.savedFile = SpaceFolders.encode(file)
                if t.isWeb { t.pinnedURL = u }
                Thumbnails.shared.pageSaved(t, url: u)
                return file
            }
            guard t.isNote, let u = t.url?.standardizedFileURL, SpaceFolders.exists(u) else { return nil }
            // Something already filed in a folder moves along with it: the note or its link.
            let src = t.folderID != nil ? (current ?? u) : u
            if src.deletingLastPathComponent().standardizedFileURL.path == dir.standardizedFileURL.path { return src }
            // It moves within the space folders, or within the linked folder it lives in. Anywhere
            // else it gets a link, so the original stays put.
            let srcOrigin = linkedOriginal(containing: src)
            let canMove = srcOrigin.map { linkedOriginal(containing: dir)?.path == $0.path } ?? SpaceFolders.isInsideRoot(src)
            if canMove {
                let new = try SpaceFolders.move(src, into: dir)
                rewriteStoredPaths(from: src, to: new)
                t.savedFile = SpaceFolders.encode(new)
                return new
            }
            let link = try SpaceFolders.link(u, in: dir)
            t.savedFile = SpaceFolders.encode(link)
            return link
        } catch {
            toast("Couldn't put \(t.displayTitle) there: \(error)")
            return nil
        }
    }

    /// A page dragged out of a folder on disk: its saved page goes to the Trash, so it can come
    /// back from there, and the tab keeps its page.
    func takeOutOfDiskFolder(_ t: Tab) {
        guard let enc = t.savedFile, let file = SpaceFolders.decode(enc) else { return }
        t.savedFile = nil
        if file.pathExtension.lowercased() == Webloc.ext && SpaceFolders.exists(file) {
            SpaceFolders.trash([file]) { ok in if ok { SavedPages.shared.noteRemoved(file) } }
        }
    }

    /// Remove from Folder, from a folder tab's menu: a saved page or a link goes to the Trash.
    /// A note that lives in the folder isn't removed this way. Delete does that.
    func removeFromDiskFolder(_ t: Tab) {
        guard let enc = t.savedFile, let file = SpaceFolders.decode(enc) else { return }
        let wasSelected = isSelected(t)
        SpaceFolders.trash([file]) { [weak self] ok in
            guard let self else { return }
            guard ok else { self.toast("Couldn't move that to the Trash"); return }
            SavedPages.shared.noteRemoved(file)
            if self.split(containing: t.id) != nil { self.dissolveSplit(around: t.id) }
            t.unload()
            self.tabs.removeAll { $0.id == t.id }
            self.selectionHistory.removeAll { $0 == .tab(t.id) }
            if wasSelected { self.selectPrevious(excluding: .tab(t.id)) }
            self.toast("Moved \(file.deletingPathExtension().lastPathComponent) to the Trash")
            self.scheduleSave()
        }
    }

    /// Whether a folder tab's file is a note that lives in the folder, rather than a saved page or a link.
    func isFiledNote(_ t: Tab) -> Bool {
        guard t.isNote, let f = t.savedFile.flatMap(SpaceFolders.decode) else { return false }
        return !FileLink.isLink(f)
    }
}
