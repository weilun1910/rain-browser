import AppKit
import Foundation

// Filing things in the space folders from the popup: moving, linking, renaming, new folders and
// the Trash. A file inside a linked folder, like a note in an Obsidian vault, is never moved out
// of it. Filing it somewhere else puts a link there instead, so the original stays put.
extension BrowserModel {
    /// The linked folder an item lives in, if it's inside one.
    func linkedOriginal(containing u: URL) -> URL? {
        SpaceFolders.notesRoots.dropFirst().first { SpaceFolders.isInside(u, $0) }
    }

    /// Moves things into `dir`, or links them there when they live inside a linked folder that
    /// `dir` isn't part of. Returns how many were filed.
    @discardableResult
    func fileEntries(_ urls: [URL], into dir: URL) -> Int {
        var done = 0
        for u in urls {
            let src = u.standardizedFileURL
            if src.deletingLastPathComponent().path == dir.standardizedFileURL.path || src.path == dir.standardizedFileURL.path { continue }
            do {
                if let orig = linkedOriginal(containing: src), linkedOriginal(containing: dir)?.path != orig.path {
                    let target = FileLink.isLink(src) ? (FileLink.resolve(src) ?? src) : src
                    try SpaceFolders.link(target, in: dir)
                } else {
                    let moved = try SpaceFolders.move(src, into: dir)
                    rewriteStoredPaths(from: src, to: moved)
                }
                done += 1
            } catch {
                toast("Couldn't move \(src.lastPathComponent): \(error)")
            }
        }
        if done > 0 {
            toast(done == 1 ? "Moved to \(dir.lastPathComponent)" : "Moved \(done) items to \(dir.lastPathComponent)")
            SpaceFolders.changed()
        }
        return done
    }

    /// Dragged tabs dropped on a folder: pages are saved there, and notes are filed there. A
    /// note that already lives in the space folders moves, and one that lives elsewhere gets a
    /// link. Returns how many were filed.
    @discardableResult
    func fileTabs(_ ids: [UUID], into dir: URL) -> Int {
        var done = 0
        for id in ids {
            guard let t = tab(id) else { continue }
            if t.isWeb || t.isApp {
                if savePage(t, in: dir, quiet: true) != nil { done += 1 }
            } else if t.isNote, let u = t.url?.standardizedFileURL, SpaceFolders.exists(u) {
                do {
                    if SpaceFolders.isInsideRoot(u) && linkedOriginal(containing: u) == nil {
                        if u.deletingLastPathComponent().path == dir.standardizedFileURL.path { continue }
                        let moved = try SpaceFolders.move(u, into: dir)
                        rewriteStoredPaths(from: u, to: moved)
                    } else {
                        try SpaceFolders.link(u, in: dir)
                    }
                    done += 1
                } catch {
                    toast("Couldn't file \(t.displayTitle): \(error)")
                }
            }
        }
        if done > 0 {
            toast(done == 1 ? "Saved to \(dir.lastPathComponent)" : "Saved \(done) to \(dir.lastPathComponent)")
            SpaceFolders.changed()
        }
        return done
    }

    /// New Folder: asks for a name and makes it inside `dir`.
    @discardableResult
    func promptNewDiskFolder(in dir: URL) -> URL? {
        guard let name = Prompt.text(title: "New folder", message: "Name", defaultValue: ""), !name.isEmpty else { return nil }
        do { return try SpaceFolders.makeFolder(named: name, in: dir) } catch {
            toast("Couldn't make the folder: \(error)")
            return nil
        }
    }

    /// Rename: a file keeps its extension, and a link is renamed, never its original.
    func promptRenameEntry(_ e: FolderEntry) {
        guard let name = Prompt.text(title: "Rename", message: "Name", defaultValue: e.name), !name.isEmpty, name != e.name else { return }
        renameEntry(e, to: name)
    }

    @discardableResult
    func renameEntry(_ e: FolderEntry, to name: String) -> URL? {
        do {
            let new = try SpaceFolders.rename(e.url, to: name)
            rewriteStoredPaths(from: e.url, to: new)
            return new
        } catch {
            toast("Couldn't rename it: \(error)")
            return nil
        }
    }

    /// Move to Trash. The Trash is how they come back.
    func trashEntries(_ es: [FolderEntry], completion: ((Bool) -> Void)? = nil) {
        let urls = es.map(\.url)
        guard !urls.isEmpty else { completion?(false); return }
        SpaceFolders.trash(urls) { [weak self] ok in
            guard let self else { return }
            if ok {
                for u in urls { SavedPages.shared.noteRemoved(u) }
                let gone = Set(urls.map { SpaceFolders.encode($0) })
                for t in self.tabs where t.savedFile.map(gone.contains) == true && t.folderID == nil {
                    t.savedFile = nil
                    if t.isWeb && !t.isPinned && !t.isEssential { t.pinnedURL = nil }
                }
                self.toast(urls.count == 1 ? "Moved \(es[0].name) to the Trash" : "Moved \(urls.count) items to the Trash")
                self.scheduleSave()
            } else {
                self.toast("Couldn't move that to the Trash")
            }
            completion?(ok)
        }
    }
}
