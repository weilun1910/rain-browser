import Foundation

// Moving the sidebar's folders onto disk, once, on the first launch of the build with space
// folders. It runs after the launch backup, which every new build makes before reading anything.
//
// - Each space gets its folder.
// - Each sidebar folder and subfolder becomes a real folder in its space's folder, in the same
//   order, and the top ones are pinned.
// - Pages in folders become saved pages (.webloc), at their pinned address or else where they are.
// - Notes in folders become links to their files, so the files themselves don't move.
// - The notes folders from Settings are linked into Home, or the first space.
//
// Every file is written before state.json changes. If anything fails, the old state stays as it
// was and keeps working, and the move is tried again next launch. Running it again reuses what an
// earlier run wrote, so nothing is made twice. The state records that it finished.

enum SpaceFolderMigration {
    /// The version in state.json once the folders are on disk.
    static let version = 1

    struct Report: Equatable {
        var spaces = 0, folders = 0, pages = 0, notes = 0, linkedFolders = 0, reused = 0
    }

    /// The state with its folders on disk, or throws and leaves the state to the caller as it was.
    static func run(_ old: SavedState, notesFolders: [String], root: URL) throws -> (SavedState, Report) {
        let fm = FileManager.default
        var s = old
        var report = Report()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var spaces = s.spaces ?? []

        // Each space's folder.
        var taken = Set(spaces.compactMap { $0.folderName?.lowercased() })
        var spaceDir: [UUID: URL] = [:]
        for i in spaces.indices {
            var name = spaces[i].folderName ?? ""
            if name.isEmpty {
                let base = SpaceFolders.safeName(spaces[i].name, fallback: "Space")
                name = base
                var n = 2
                while taken.contains(name.lowercased()) { name = "\(base) \(n)"; n += 1 }
                taken.insert(name.lowercased())
            }
            let d = root.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            spaces[i].folderName = name
            spaces[i].folderBookmark = FolderBookmark.make(d)
            spaceDir[spaces[i].id] = d
            report.spaces += 1
        }

        // Folders, top down, in their order. Two folders with the same name side by side get a number.
        // A folder in a space that's gone goes to the first space, and one whose parent is gone,
        // in another space or in a loop goes to the top, the way loading repairs them.
        let spaceIDs = Set(spaces.map(\.id))
        var legacy = s.folders.filter { $0.path == nil }.map { f -> Folder in
            var f = f
            if f.spaceID.map({ !spaceIDs.contains($0) }) ?? true { f.spaceID = spaces.first?.id }
            return f
        }
        let legacyIDs = Set(legacy.map(\.id))
        for i in legacy.indices {
            if let p = legacy[i].parentID, !legacyIDs.contains(p) || legacy.first(where: { $0.id == p })?.spaceID != legacy[i].spaceID {
                legacy[i].parentID = nil
            }
        }
        var dirFor: [UUID: URL] = [:]
        var order: [URL: [String]] = [:]
        func walk(_ parent: UUID?, _ space: UUID, _ dir: URL) throws {
            let kids = legacy.filter { $0.parentID == parent && (parent != nil || $0.spaceID == space) }.sorted { ($0.order ?? 0) < ($1.order ?? 0) }
            var used = Set<String>()
            for f in kids {
                let base = SpaceFolders.safeName(f.name, fallback: "Folder")
                var name = base
                var n = 2
                while used.contains(name.lowercased()) { name = "\(base) \(n)"; n += 1 }
                used.insert(name.lowercased())
                let d = dir.appendingPathComponent(name, isDirectory: true)
                if SpaceFolders.isDirectory(d) { report.reused += 1 } else { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
                dirFor[f.id] = d
                order[dir, default: []].append(name)
                report.folders += 1
                try walk(f.id, space, d)
            }
        }
        for sp in spaces { if let d = spaceDir[sp.id] { try walk(nil, sp.id, d) } }
        // Anything a loop kept out of reach goes at the top of its space.
        for i in legacy.indices where dirFor[legacy[i].id] == nil {
            legacy[i].parentID = nil
            if let sp = legacy[i].spaceID, let d = spaceDir[sp] {
                let u = SpaceFolders.uniqueURL(in: d, base: SpaceFolders.safeName(legacy[i].name, fallback: "Folder"))
                try fm.createDirectory(at: u, withIntermediateDirectories: true)
                dirFor[legacy[i].id] = u
                order[d, default: []].append(u.lastPathComponent)
                report.folders += 1
            }
        }

        // What's in each folder, in its order.
        var fileFor: [UUID: URL] = [:]
        var leftOut = Set<UUID>()
        for f in legacy {
            guard let d = dirFor[f.id] else { continue }
            var names = Set(((try? fm.contentsOfDirectory(atPath: d.path)) ?? []).map { $0.lowercased() })
            let items = s.tabs.filter { $0.folderID == f.id && !$0.isPinned && $0.isEssential != true }.sorted { ($0.order ?? 0) < ($1.order ?? 0) }
            for t in items {
                switch t.kind {
                case .web, .app:
                    guard let u = (t.pinnedURL ?? t.url).flatMap(URL.init(string:)) else { leftOut.insert(t.id); continue }
                    let title = t.customTitle?.isEmpty == false ? t.customTitle! : (t.title.isEmpty ? (u.host ?? "Page") : t.title)
                    let base = SpaceFolders.safeName(title, fallback: u.host ?? "Page")
                    // A saved page an earlier run wrote for this address is used again.
                    if let again = existing(in: d, base: base, ext: Webloc.ext, matches: { Webloc.read($0)?.url.absoluteString == u.absoluteString }) {
                        fileFor[t.id] = again
                        report.reused += 1
                    } else {
                        let file = SpaceFolders.uniqueURL(in: d, base: base, ext: Webloc.ext, taken: names)
                        try Webloc.write(SavedPage(url: u, title: t.title.isEmpty ? title : t.title, savedAt: t.createdAt), to: file)
                        names.insert(file.lastPathComponent.lowercased())
                        fileFor[t.id] = file
                        report.pages += 1
                    }
                case .note, .file:
                    guard let u = t.url.flatMap(URL.init(string:)), u.isFileURL, SpaceFolders.exists(u) else { leftOut.insert(t.id); continue }
                    let target = u.standardizedFileURL
                    let base = SpaceFolders.safeName(target.deletingPathExtension().lastPathComponent)
                    if let again = existing(in: d, base: base, ext: "", matches: { FileLink.resolve($0)?.path == target.path }) {
                        fileFor[t.id] = again
                        report.reused += 1
                    } else {
                        let link = SpaceFolders.uniqueURL(in: d, base: base, taken: names)
                        try FileLink.make(to: target, at: link)
                        names.insert(link.lastPathComponent.lowercased())
                        fileFor[t.id] = link
                        report.notes += 1
                    }
                }
                if let file = fileFor[t.id] { order[d, default: []].append(file.lastPathComponent) }
            }
        }

        // The notes folders, linked into Home.
        let home = spaces.first { $0.name.lowercased() == "home" } ?? spaces.first
        if let home, let d = spaceDir[home.id] {
            for p in notesFolders {
                let target = URL(fileURLWithPath: p, isDirectory: true).standardizedFileURL
                guard SpaceFolders.isDirectory(target) else { continue }
                let base = SpaceFolders.safeName(target.lastPathComponent)
                if existing(in: d, base: base, ext: "", matches: { FileLink.resolve($0)?.path == target.path }) != nil {
                    report.reused += 1
                    continue
                }
                try FileLink.make(to: target, at: SpaceFolders.uniqueURL(in: d, base: base))
                report.linkedFolders += 1
            }
        }

        // Every file is written. Now the state.
        s.spaces = spaces
        for i in s.folders.indices {
            guard s.folders[i].path == nil, let d = dirFor[s.folders[i].id] else { continue }
            if let f = legacy.first(where: { $0.id == s.folders[i].id }) { s.folders[i].parentID = f.parentID; s.folders[i].spaceID = f.spaceID }
            s.folders[i].path = SpaceFolders.encode(d)
            s.folders[i].name = d.lastPathComponent
            if s.folders[i].parentID == nil { s.folders[i].bookmark = FolderBookmark.make(d) }
        }
        let movedFolders = Set(dirFor.keys)
        for i in s.tabs.indices {
            if let f = fileFor[s.tabs[i].id] {
                s.tabs[i].savedFile = SpaceFolders.encode(f)
                if s.tabs[i].kind == .web, s.tabs[i].pinnedURL == nil { s.tabs[i].pinnedURL = s.tabs[i].url }
            } else if leftOut.contains(s.tabs[i].id), let fid = s.tabs[i].folderID, movedFolders.contains(fid) {
                // A page with no address or a note whose file is gone stays, in Tabs.
                s.tabs[i].folderID = nil
            }
        }
        for (dir, names) in order {
            FolderMeta.shared.setOrder(names, of: dir)
        }
        FolderMeta.shared.saveNow()
        s.diskFolders = version
        return (s, report)
    }

    /// `base.ext` or `base N.ext` in `dir` that `matches`, from an earlier run.
    private static func existing(in dir: URL, base: String, ext: String, matches: (URL) -> Bool) -> URL? {
        for n in 1...50 {
            let name = n == 1 ? base : "\(base) \(n)"
            let u = dir.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
            if !SpaceFolders.exists(u) { if n > 1 { return nil }; continue }
            if matches(u) { return u }
        }
        return nil
    }
}
