import Foundation

// Folders inside folders, like Arc's and Zen's. A folder lists its subfolders first, then its
// items. Dragging a folder onto the middle of another puts it inside, and onto the top or bottom
// edge puts it beside. A folder can't go inside itself or anything inside it, and the tree stops
// at `Folder.maxDepth` levels so rows don't run out of room.

extension Folder {
    /// Levels of folders, counting the top one: a folder in a folder in a folder, and so on.
    static let maxDepth = 5
}

extension BrowserModel {
    func folder(_ id: UUID) -> Folder? { folders.first { $0.id == id } }

    /// A folder's subfolders in order, or with nil the folders at the top of a space.
    func childFolders(of parent: UUID?, space: UUID? = nil) -> [Folder] {
        let list: [Folder]
        if let parent {
            list = folders.filter { $0.parentID == parent }
        } else {
            let sp = space ?? currentSpaceID
            list = folders.filter { $0.spaceID == sp && $0.parentID == nil }
        }
        return list.sorted { ($0.order ?? 0) < ($1.order ?? 0) }
    }

    /// The folder it's in, that one's, and so on, nearest first.
    func ancestors(of id: UUID) -> [UUID] {
        var out: [UUID] = []
        var cur = folder(id)?.parentID
        while let c = cur, c != id, !out.contains(c) {
            out.append(c)
            cur = folder(c)?.parentID
        }
        return out
    }

    /// 0 for a folder at the top, 1 for one inside it, and so on.
    func folderDepth(_ id: UUID) -> Int { ancestors(of: id).count }

    /// Every folder inside this one, at any depth.
    func descendants(of id: UUID) -> [UUID] {
        var out: [UUID] = []
        var queue = [id]
        while let next = queue.popLast() {
            for f in folders where f.parentID == next && f.id != id && !out.contains(f.id) {
                out.append(f.id)
                queue.append(f.id)
            }
        }
        return out
    }

    /// How many levels of subfolders a folder holds: 0 with none.
    func subtreeHeight(_ id: UUID) -> Int {
        descendants(of: id).map { folderDepth($0) }.max().map { $0 - folderDepth(id) } ?? 0
    }

    /// Whether a folder can go inside `parent`: not into itself or anything inside it, and not
    /// so deep that it or its subfolders pass the limit. Nil, the top level, always works.
    func canNest(_ id: UUID, in parent: UUID?) -> Bool {
        guard let parent else { return true }
        guard parent != id, folder(parent) != nil, !descendants(of: id).contains(parent) else { return false }
        return folderDepth(parent) + 1 + subtreeHeight(id) < Folder.maxDepth
    }

    /// The space's folders top to bottom as the sidebar lists them, open or not, with their depth.
    func folderTree(space: UUID? = nil) -> [(folder: Folder, depth: Int)] {
        var out: [(Folder, Int)] = []
        func walk(_ parent: UUID?, _ depth: Int) {
            for f in childFolders(of: parent, space: space) {
                out.append((f, depth))
                walk(f.id, depth + 1)
            }
        }
        walk(nil, 0)
        return out.map { (folder: $0.0, depth: $0.1) }
    }

    /// "Work / Q3 / Reading", for menus.
    func folderPath(_ f: Folder) -> String {
        (ancestors(of: f.id).reversed().compactMap { folder($0)?.name } + [f.name]).joined(separator: " / ")
    }

    /// Items anywhere inside a folder, for the count on its row.
    func tabCount(inTree f: Folder) -> Int {
        ([f.id] + descendants(of: f.id)).reduce(0) { $0 + refs(in: .folder($1)).count }
    }

    /// Opens a folder and every folder it's in, so what lands inside it is on screen.
    func openFolderPath(to id: UUID) {
        for fid in [id] + ancestors(of: id) {
            if let i = folders.firstIndex(where: { $0.id == fid }), !folders[i].isExpanded { folders[i].isExpanded = true }
        }
    }

    /// Moves a folder inside another, or to the top level with nil, at a position among the
    /// folders already there. Returns false if it can't go there.
    @discardableResult
    func placeFolder(_ id: UUID, in parent: UUID?, at index: Int) -> Bool {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return false }
        guard canNest(id, in: parent) else {
            if let parent, parent != id, !descendants(of: id).contains(parent) {
                toast("Folders go \(Folder.maxDepth) levels deep")
            }
            return false
        }
        let space = parent.flatMap { folder($0)?.spaceID } ?? folders[i].spaceID ?? currentSpaceID
        folders[i].parentID = parent
        // Everything inside comes along to the new space, if the parent is in another one.
        for fid in [id] + descendants(of: id) {
            if let j = folders.firstIndex(where: { $0.id == fid }) { folders[j].spaceID = space }
        }
        var list = childFolders(of: parent, space: space).map(\.id).filter { $0 != id }
        list.insert(id, at: max(0, min(index, list.count)))
        for (n, fid) in list.enumerated() {
            if let j = folders.firstIndex(where: { $0.id == fid }) { folders[j].order = Double(n) }
        }
        if let parent { openFolderPath(to: parent) }
        objectWillChange.send()
        scheduleSave()
        return true
    }

    /// A folder dropped just before or after another goes beside it, in the same parent.
    @discardableResult
    func placeFolder(_ id: UUID, next target: UUID, after: Bool) -> Bool {
        guard id != target, let t = folder(target) else { return false }
        let siblings = childFolders(of: t.parentID, space: t.spaceID).map(\.id).filter { $0 != id }
        guard let i = siblings.firstIndex(of: target) else { return false }
        return placeFolder(id, in: t.parentID, at: after ? i + 1 : i)
    }

    /// A folder dropped onto another goes inside it, after its other subfolders.
    @discardableResult
    func nestFolder(_ id: UUID, into parent: UUID) -> Bool {
        placeFolder(id, in: parent, at: Int.max)
    }

    /// On load: a folder whose parent is gone, in another space, or inside itself goes back to the
    /// top, and anything deeper than the limit moves up to fit.
    func repairFolderTree() {
        let ids = Set(folders.map(\.id))
        for i in folders.indices {
            guard let p = folders[i].parentID else { continue }
            if !ids.contains(p) || folders.first(where: { $0.id == p })?.spaceID != folders[i].spaceID {
                folders[i].parentID = nil
            }
        }
        // Break loops: walk up from each folder, and cut the link that comes back around.
        for i in folders.indices {
            var seen: Set<UUID> = [folders[i].id]
            var cur = folders[i].parentID
            while let c = cur {
                if seen.contains(c) { folders[i].parentID = nil; break }
                seen.insert(c)
                cur = folders.first { $0.id == c }?.parentID
            }
        }
        for i in folders.indices where folderDepth(folders[i].id) >= Folder.maxDepth {
            // Hang it on its ancestor at the deepest allowed level.
            let chain = ancestors(of: folders[i].id)
            folders[i].parentID = chain[chain.count - (Folder.maxDepth - 1)]
        }
    }
}
