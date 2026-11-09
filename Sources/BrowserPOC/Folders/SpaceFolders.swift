import AppKit
import CryptoKit
import Foundation

// Every space has a real folder on disk, all of them under one root: `~/Documents/Rain/` for the
// default profile, and `Space Folders/` inside the profile for one opened with --data-dir, so test
// and demo profiles never touch the real one. A folder holds notes (.md), saved pages (.webloc,
// the Mac's own saved-link format, with Rain's title and saved date inside), Finder aliases to
// things that live elsewhere, like a linked Markdown folder, and anything else, like PDFs.
// Linking never copies, moves or rewrites the original. Delete always goes to the Trash.
// The plan is notes/plans/2026-11-08-folder-popup.md.

enum SpaceFolders {
    /// On in the app, the demo seeder and the offscreen shots. The self test's older checks run
    /// with it off and keep the sidebar folders that lived only in state.json.
    nonisolated(unsafe) static var enabled = false
    /// Tests and shots point this at a throwaway folder.
    nonisolated(unsafe) static var overrideRoot: URL?
    /// Picked with Change in Settings, Browsing. Nil is the default for the profile.
    nonisolated(unsafe) static var customRoot: URL?

    /// The default profile's folders sit in Documents, where people look for their files. Any
    /// other profile keeps its own inside its folder.
    static var defaultRoot: URL {
        if Paths.overrideRoot != nil { return Paths.root.appendingPathComponent("Space Folders", isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Rain", isDirectory: true)
    }

    /// Where every space's folder lives, or nil while space folders are off.
    static var root: URL? {
        guard enabled else { return nil }
        if let overrideRoot { return overrideRoot.standardizedFileURL }
        if let customRoot { return customRoot.standardizedFileURL }
        return defaultRoot.standardizedFileURL
    }

    // MARK: Paths in saved state

    /// How a path is kept in state.json: relative to the root when it's inside it, so a copy of
    /// the profile with its own root finds its own files, and absolute otherwise.
    static func encode(_ url: URL) -> String {
        if let rel = relativePath(url) { return rel.isEmpty ? "." : rel }
        return url.standardizedFileURL.path
    }

    /// The path inside the root, "" for the root itself, or nil outside it. Links in the path,
    /// like /var and /private/var, don't matter.
    static func relativePath(_ url: URL) -> String? {
        guard let r = root else { return nil }
        let p = url.standardizedFileURL.path, rp = r.path
        if p == rp { return "" }
        if p.hasPrefix(rp + "/") { return String(p.dropFirst(rp.count + 1)) }
        let cp = canonical(url), cr = canonicalRoot(r)
        if cp == cr { return "" }
        if cp.hasPrefix(cr + "/") { return String(cp.dropFirst(cr.count + 1)) }
        return nil
    }

    nonisolated(unsafe) private static var rootCanon: (raw: String, canon: String)?
    private static let canonLock = NSLock()

    private static func canonicalRoot(_ r: URL) -> String {
        canonLock.lock(); defer { canonLock.unlock() }
        if let c = rootCanon, c.raw == r.path { return c.canon }
        let c = canonical(r)
        rootCanon = (r.path, c)
        return c
    }

    /// The path with every link resolved, the same way whether or not the file exists yet.
    static func canonical(_ url: URL) -> String {
        var cur = url.standardizedFileURL.path
        var missing: [String] = []
        while cur.count > 1 {
            if let r = realpath(cur, nil) {
                let base = String(cString: r)
                free(r)
                return missing.isEmpty ? base : base + "/" + missing.reversed().joined(separator: "/")
            }
            missing.append((cur as NSString).lastPathComponent)
            cur = (cur as NSString).deletingLastPathComponent
        }
        return url.standardizedFileURL.path
    }

    /// Whether `url` is `dir` or inside it, with links resolved.
    static func isInside(_ url: URL, _ dir: URL) -> Bool {
        let a = canonical(url), d = canonical(dir)
        return a == d || a.hasPrefix(d + "/")
    }

    static func decode(_ s: String) -> URL? {
        if s.hasPrefix("/") { return URL(fileURLWithPath: s).standardizedFileURL }
        guard let root else { return nil }
        return s == "." ? root : root.appendingPathComponent(s).standardizedFileURL
    }

    static func isInsideRoot(_ url: URL) -> Bool { relativePath(url) != nil }

    /// Rain writes inside the root, and inside the folders linked into it or chosen as notes
    /// folders. Nothing else.
    static func canWrite(_ url: URL) -> Bool {
        if isInsideRoot(url) { return true }
        return Settings.shared.value.notesRoots.contains { isInside(url, $0) }
    }

    /// A file or folder name made safe: no slashes or colons, no leading dot, not too long.
    static func safeName(_ s: String, fallback: String = "Untitled") -> String {
        var cleaned = Fmt.clean(s).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? fallback : String(cleaned.prefix(120))
    }

    /// `base.ext` in `dir`, or `base 2.ext`, `base 3.ext` and so on, whichever is free.
    static func uniqueURL(in dir: URL, base: String, ext: String = "", taken: Set<String> = []) -> URL {
        func name(_ n: Int) -> String {
            let b = n == 1 ? base : "\(base) \(n)"
            return ext.isEmpty ? b : "\(b).\(ext)"
        }
        var n = 1
        while true {
            let candidate = dir.appendingPathComponent(name(n))
            if !exists(candidate) && !taken.contains(candidate.lastPathComponent.lowercased()) { return candidate }
            n += 1
        }
    }

    /// True for anything at the path, including a link whose original is gone.
    static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    static func isDirectory(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
            && !((try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false)
    }

    // MARK: Changing things on disk

    enum Failure: Error, CustomStringConvertible {
        case notAllowed(String), exists(String), insideItself, failed(String)
        var description: String {
            switch self {
            case .notAllowed(let p): return "Rain doesn't write to \(p)"
            case .exists(let n): return "There's already something called \(n) there"
            case .insideItself: return "A folder can't go inside itself"
            case .failed(let s): return s
            }
        }
    }

    @discardableResult
    static func makeFolder(named name: String, in dir: URL) throws -> URL {
        let u = uniqueURL(in: dir, base: safeName(name, fallback: "Untitled folder"))
        guard canWrite(u) else { throw Failure.notAllowed(dir.path) }
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        changed()
        return u
    }

    /// Renames a file or folder in place. A file keeps its extension. A link is renamed, never the
    /// original it points at.
    @discardableResult
    static func rename(_ url: URL, to name: String) throws -> URL {
        let ext = isDirectory(url) ? "" : url.pathExtension
        var base = safeName(name)
        if !ext.isEmpty, base.lowercased().hasSuffix("." + ext.lowercased()) { base = String(base.dropLast(ext.count + 1)) }
        let target = url.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)")
        if target.path == url.path { return url }
        guard canWrite(url), canWrite(target) else { throw Failure.notAllowed(url.deletingLastPathComponent().path) }
        // A change of case only is a rename on a case-insensitive disk, not a clash.
        if exists(target) && target.path.lowercased() != url.path.lowercased() { throw Failure.exists(target.lastPathComponent) }
        try FileManager.default.moveItem(at: url, to: target)
        changed()
        return target
    }

    /// Moves a file or folder into `dir`, under a free name if its own is taken there.
    @discardableResult
    static func move(_ url: URL, into dir: URL) throws -> URL {
        let src = url.standardizedFileURL, d = dir.standardizedFileURL
        if src.deletingLastPathComponent().path == d.path { return src }
        if src.path == d.path || isInside(d, src) { throw Failure.insideItself }
        guard canWrite(src), canWrite(d) else { throw Failure.notAllowed(d.path) }
        let ext = isDirectory(src) ? "" : src.pathExtension
        let base = ext.isEmpty ? src.lastPathComponent : src.deletingPathExtension().lastPathComponent
        let target = uniqueURL(in: d, base: base, ext: ext)
        try FileManager.default.moveItem(at: src, to: target)
        changed()
        return target
    }

    /// Moves files and folders to the Trash, through the same path notes use, so the self test's
    /// stand-in Trash catches it. Never deletes outright. A link goes, not its original.
    @MainActor static func trash(_ urls: [URL], completion: @escaping @MainActor (Bool) -> Void) {
        let ok = urls.filter { canWrite($0) && exists($0) }
        guard !ok.isEmpty, ok.count == urls.count else { DispatchQueue.main.async { MainActor.assumeIsolated { completion(false) } }; return }
        NotesStore.recycle(ok) { moved, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    changed()
                    completion(error == nil && ok.allSatisfy { moved[$0] != nil })
                }
            }
        }
    }

    /// Writes a saved page into `dir`. The file is named after the title.
    @discardableResult
    static func savePage(_ page: URL, title: String, in dir: URL, savedAt: Date = Date()) throws -> URL {
        let base = safeName(title.isEmpty ? (page.host ?? "Page") : title, fallback: page.host ?? "Page")
        let u = uniqueURL(in: dir, base: base, ext: "webloc")
        guard canWrite(u) else { throw Failure.notAllowed(dir.path) }
        try Webloc.write(SavedPage(url: page, title: title, savedAt: savedAt), to: u)
        changed()
        return u
    }

    /// Puts a link to `target` in `dir`, named after it. Nothing is copied.
    @discardableResult
    static func link(_ target: URL, in dir: URL, name: String? = nil) throws -> URL {
        let isDir = isDirectory(target)
        let base = safeName(name ?? (isDir ? target.lastPathComponent : target.deletingPathExtension().lastPathComponent))
        let u = uniqueURL(in: dir, base: base)
        guard canWrite(u) else { throw Failure.notAllowed(dir.path) }
        try FileLink.make(to: target, at: u)
        changed()
        return u
    }

    // MARK: Change notices

    nonisolated(unsafe) private static var pendingChange: DispatchWorkItem?

    /// Tells the app something in the folders changed: right away for Rain's own changes, a
    /// moment after the watcher sees one from Finder.
    static func changed(after delay: TimeInterval = 0) {
        let post = {
            pendingChange?.cancel()
            let w = DispatchWorkItem { NotificationCenter.default.post(name: .spaceFoldersChanged, object: nil) }
            pendingChange = w
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
        }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }

    // MARK: Notes roots

    private static let rootsLock = NSLock()
    nonisolated(unsafe) private static var linkedRoots: [URL] = []

    /// The root and the folders linked into it, for the notes index. Empty while space folders
    /// are off.
    static var notesRoots: [URL] {
        guard let r = root else { return [] }
        rootsLock.lock(); defer { rootsLock.unlock() }
        return [r] + linkedRoots
    }

    /// Finds the folders linked anywhere under the root. Returns true if the list changed.
    @discardableResult
    static func refreshLinkedRoots() -> Bool {
        let found = root.map { linkedFolders(under: $0) } ?? []
        rootsLock.lock()
        let changed = found.map(\.path) != linkedRoots.map(\.path)
        linkedRoots = found
        rootsLock.unlock()
        return changed
    }

    /// Originals of the folder links under `dir`, without following them.
    static func linkedFolders(under dir: URL, depth: Int = 0) -> [URL] {
        guard depth < 8 else { return [] }
        var out: [URL] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isAliasFileKey, .isSymbolicLinkKey, .isPackageKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        for u in items {
            let rv = try? u.resourceValues(forKeys: Set(keys))
            if rv?.isAliasFile == true || rv?.isSymbolicLink == true {
                if let t = FileLink.resolve(u), isDirectory(t), !out.contains(where: { $0.path == t.path }) { out.append(t.standardizedFileURL) }
            } else if rv?.isDirectory == true, rv?.isPackage != true, !FileSafety.isSkippedFolder(u.lastPathComponent) {
                for t in linkedFolders(under: u, depth: depth + 1) where !out.contains(where: { $0.path == t.path }) { out.append(t) }
            }
        }
        return out
    }
}

extension Notification.Name {
    /// Something in the space folders changed, from Rain or from Finder.
    static let spaceFoldersChanged = Notification.Name("local.browserpoc.spaceFoldersChanged")
}

// MARK: - Saved pages

/// A page saved into a folder.
struct SavedPage: Equatable {
    var url: URL
    var title: String?
    var savedAt: Date?
}

/// `.webloc`: a property list with a `URL` key, the format Finder and Safari write. Rain adds the
/// page title and the date it was saved under keys of its own, which Finder ignores.
enum Webloc {
    static let ext = "webloc"
    static let titleKey = "RainTitle"
    static let savedKey = "RainSaved"

    static func read(_ file: URL) -> SavedPage? {
        guard let data = try? Data(contentsOf: file),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let s = plist["URL"] as? String, let u = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return SavedPage(url: u, title: plist[titleKey] as? String, savedAt: plist[savedKey] as? Date)
    }

    static func data(_ page: SavedPage) throws -> Data {
        var plist: [String: Any] = ["URL": page.url.absoluteString]
        if let t = page.title, !t.isEmpty { plist[titleKey] = t }
        if let d = page.savedAt { plist[savedKey] = d }
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// A new file is never written over another. `replacing` rewrites one that's already there.
    static func write(_ page: SavedPage, to file: URL, replacing: Bool = false) throws {
        try data(page).write(to: file, options: replacing ? .atomic : .withoutOverwriting)
    }
}

/// Finder aliases: pointers that still find their original after it's moved or renamed.
enum FileLink {
    static func make(to target: URL, at link: URL) throws {
        let data = try target.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(data, to: link)
    }

    /// A Finder alias or a symbolic link.
    static func isLink(_ url: URL) -> Bool {
        let rv = try? url.resourceValues(forKeys: [.isAliasFileKey, .isSymbolicLinkKey])
        return rv?.isAliasFile == true || rv?.isSymbolicLink == true
    }

    /// Where a link points, or nil if the original can't be found. Never asks the user or mounts a disk.
    static func resolve(_ url: URL) -> URL? {
        guard let u = try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting]) else { return nil }
        return SpaceFolders.exists(u) ? u.standardizedFileURL : nil
    }
}

/// Bookmark data for remembering a folder across moves, for pinned folders and space folders.
enum FolderBookmark {
    static func make(_ url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func resolve(_ data: Data) -> URL? {
        var stale = false
        guard let u = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        return SpaceFolders.exists(u) ? u.standardizedFileURL : nil
    }
}

// MARK: - What a folder holds

struct FolderEntry: Identifiable, Hashable {
    enum Kind: String { case folder, page, note, file }
    /// Where it sits in the folder: the link itself for a link.
    let url: URL
    /// What it is: the original for a link, else the same as `url`.
    let target: URL
    let kind: Kind
    let isLink: Bool
    /// A link whose original can't be found.
    let isBroken: Bool
    let name: String
    /// A saved page's address and title.
    let page: URL?
    let pageTitle: String?
    let savedAt: Date?
    let modified: Date?

    var id: String { url.path }
    /// The date shown and sorted on: when a page was saved, else when the file was made or changed.
    var date: Date? { savedAt ?? modified }
    var site: String? { page.flatMap { Snippet.prettyHost($0) } }
}

extension SpaceFolders {
    /// What a folder holds, unsorted. Hidden files, packages' insides and skipped folders stay out.
    static func list(_ dir: URL) -> [FolderEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isAliasFileKey, .isSymbolicLinkKey, .isPackageKey, .contentModificationDateKey, .creationDateKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return items.compactMap { entry($0) }
    }

    static func entry(_ u: URL) -> FolderEntry? {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isAliasFileKey, .isSymbolicLinkKey, .isPackageKey, .contentModificationDateKey, .creationDateKey]
        let rv = try? u.resourceValues(forKeys: keys)
        let name = u.lastPathComponent
        if name.hasPrefix(".") || name == "Icon\r" { return nil }
        let modified = rv?.contentModificationDate ?? rv?.creationDate
        let link = rv?.isAliasFile == true || rv?.isSymbolicLink == true
        if link {
            guard let t = FileLink.resolve(u) else {
                return FolderEntry(url: u, target: u, kind: .file, isLink: true, isBroken: true, name: name, page: nil, pageTitle: nil, savedAt: nil, modified: modified)
            }
            return describe(u, target: t, isLink: true, displayName: name, modified: modified)
        }
        if rv?.isDirectory == true && rv?.isPackage != true {
            if FileSafety.isSkippedFolder(name) { return nil }
            return FolderEntry(url: u, target: u, kind: .folder, isLink: false, isBroken: false, name: name, page: nil, pageTitle: nil, savedAt: nil, modified: modified)
        }
        return describe(u, target: u, isLink: false, displayName: nil, modified: modified)
    }

    private static func describe(_ u: URL, target t: URL, isLink: Bool, displayName: String?, modified: Date?) -> FolderEntry {
        let ext = t.pathExtension.lowercased()
        if isDirectory(t) {
            return FolderEntry(url: u, target: t, kind: .folder, isLink: isLink, isBroken: false, name: displayName ?? t.lastPathComponent,
                               page: nil, pageTitle: nil, savedAt: nil, modified: modified)
        }
        if ext == Webloc.ext, let p = Webloc.read(t) {
            let n = displayName ?? u.deletingPathExtension().lastPathComponent
            return FolderEntry(url: u, target: t, kind: .page, isLink: isLink, isBroken: false, name: n, page: p.url, pageTitle: p.title,
                               savedAt: p.savedAt ?? modified, modified: modified)
        }
        if ext == "md" {
            let n = displayName ?? u.deletingPathExtension().lastPathComponent
            return FolderEntry(url: u, target: t, kind: .note, isLink: isLink, isBroken: false, name: n, page: nil, pageTitle: nil, savedAt: nil, modified: modified)
        }
        return FolderEntry(url: u, target: t, kind: .file, isLink: isLink, isBroken: false, name: displayName ?? u.lastPathComponent,
                           page: nil, pageTitle: nil, savedAt: nil, modified: modified)
    }

    enum Sort: String, CaseIterable, Identifiable {
        case custom, name, saved, opened
        var id: String { rawValue }
        var title: String {
            switch self {
            case .custom: return "Your Order"
            case .name: return "Name"
            case .saved: return "Date Saved"
            case .opened: return "Last Opened"
            }
        }
    }

    /// Folders first, then everything else. Your order keeps Rain's own order for the folder,
    /// with things it hasn't seen yet at the end, by name.
    static func ordered(_ entries: [FolderEntry], in dir: URL, sort: Sort = .custom) -> [FolderEntry] {
        let byName: (FolderEntry, FolderEntry) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        func arrange(_ list: [FolderEntry]) -> [FolderEntry] {
            switch sort {
            case .name: return list.sorted(by: byName)
            case .saved: return list.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            case .opened:
                let meta = FolderMeta.shared
                return list.sorted { (meta.opened($0.url) ?? 0, $1.name) > (meta.opened($1.url) ?? 0, $0.name) }
            case .custom:
                let known = FolderMeta.shared.order(of: dir)
                let rank = Dictionary(known.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
                let seen = list.filter { rank[$0.url.lastPathComponent] != nil }.sorted { rank[$0.url.lastPathComponent]! < rank[$1.url.lastPathComponent]! }
                let fresh = list.filter { rank[$0.url.lastPathComponent] == nil }.sorted(by: byName)
                return seen + fresh
            }
        }
        return arrange(entries.filter { $0.kind == .folder }) + arrange(entries.filter { $0.kind != .folder })
    }

    /// How many things a folder holds, for its card.
    static func count(_ dir: URL) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") && $0 != "Icon\r" }.count
    }

    /// Everything under `dir` whose name, title or site matches every word of `query`, following
    /// links, folders first. Stops at a few thousand.
    static func search(_ query: String, in dir: URL, limit: Int = 400) -> [FolderEntry] {
        let words = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        var out: [FolderEntry] = []
        var visited = Set<String>()
        var budget = 5000
        func walk(_ d: URL, _ depth: Int) {
            guard depth < 10, budget > 0, visited.insert(d.resolvingSymlinksInPath().path).inserted else { return }
            for e in list(d) {
                budget -= 1
                if budget <= 0 || out.count >= limit { return }
                let hay = [e.name, e.pageTitle ?? "", e.page?.host ?? ""].joined(separator: " ").lowercased()
                if words.allSatisfy({ hay.contains($0) }) { out.append(e) }
                if e.kind == .folder { walk(e.target, depth + 1) }
            }
        }
        walk(dir, 0)
        return out.filter { $0.kind == .folder } + out.filter { $0.kind != .folder }
    }
}

// MARK: - Rain's own order and when things were last opened

/// Rain's order for the things in each folder, and when each item was last opened from a
/// folder. Kept in `space-folders.json` in the profile, so the folders themselves stay clean.
final class FolderMeta: @unchecked Sendable {
    static let shared = FolderMeta()

    struct Stored: Codable {
        var order: [String: [String]] = [:]
        var opened: [String: Double] = [:]
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            order = c.lenient([String: [String]].self, .order, decoder) ?? [:]
            opened = c.lenient([String: Double].self, .opened, decoder) ?? [:]
        }
    }

    private let lock = NSLock()
    private var stored = Stored()
    private var loadedFrom: String?
    private var saveWork: DispatchWorkItem?

    static var file: URL { Paths.root.appendingPathComponent("space-folders.json") }

    private func ensureLoaded() {
        let f = Self.file.path
        guard loadedFrom != f else { return }
        loadedFrom = f
        stored = SavedFile.read(Stored.self, from: Self.file, label: "folder order") ?? Stored()
    }

    /// Reads the file again, for tests that move between profiles.
    func reload() { lock.lock(); loadedFrom = nil; ensureLoaded(); lock.unlock() }

    func order(of dir: URL) -> [String] {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        return stored.order[SpaceFolders.encode(dir)] ?? []
    }

    func setOrder(_ names: [String], of dir: URL) {
        lock.lock()
        ensureLoaded()
        stored.order[SpaceFolders.encode(dir)] = names
        lock.unlock()
        scheduleSave()
    }

    /// Puts `name` at `index` in the folder's order, after making sure everything already in the
    /// folder has a place.
    func place(_ name: String, at index: Int, in dir: URL, current: [String]) {
        var list = current.filter { $0 != name }
        list.insert(name, at: max(0, min(index, list.count)))
        setOrder(list, of: dir)
    }

    func opened(_ url: URL) -> Double? {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        return stored.opened[SpaceFolders.encode(url)]
    }

    func markOpened(_ url: URL, at date: Date = Date()) {
        lock.lock()
        ensureLoaded()
        stored.opened[SpaceFolders.encode(url)] = date.timeIntervalSince1970
        lock.unlock()
        scheduleSave()
    }

    /// Keeps the order and dates with things Rain moved or renamed.
    func moved(from old: URL, to new: URL) {
        let o = SpaceFolders.encode(old), n = SpaceFolders.encode(new)
        guard o != n else { return }
        lock.lock()
        ensureLoaded()
        func swap(_ k: String) -> String? {
            if k == o { return n }
            if k.hasPrefix(o + "/") { return n + k.dropFirst(o.count) }
            return nil
        }
        for (k, v) in stored.order { if let nk = swap(k) { stored.order[k] = nil; stored.order[nk] = v } }
        for (k, v) in stored.opened { if let nk = swap(k) { stored.opened[k] = nil; stored.opened[nk] = v } }
        let parent = SpaceFolders.encode(old.deletingLastPathComponent())
        if old.deletingLastPathComponent().path == new.deletingLastPathComponent().path, var list = stored.order[parent],
           let i = list.firstIndex(of: old.lastPathComponent) {
            list[i] = new.lastPathComponent
            stored.order[parent] = list
        }
        lock.unlock()
        scheduleSave()
    }

    private func scheduleSave() {
        let run = { [self] in
            saveWork?.cancel()
            let w = DispatchWorkItem { [self] in saveNow() }
            saveWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
        }
        if Thread.isMainThread { run() } else { DispatchQueue.main.async(execute: run) }
    }

    func saveNow() {
        lock.lock()
        let s = stored
        let target = loadedFrom.map { URL(fileURLWithPath: $0) }
        lock.unlock()
        guard let target, let data = try? JSONEncoder.pretty.encode(s) else { return }
        Paths.ensure(target.deletingLastPathComponent())
        SavedFile.write(data, to: target)
    }
}

// MARK: - Which pages are saved

/// Every saved page under the root, by address, so the address field can show a page is saved
/// and a visit can refresh its thumbnail. Built by walking the root in the background, without
/// following links.
@MainActor
final class SavedPages: ObservableObject {
    static let shared = SavedPages()
    /// Bumped after every scan, so views that show saved state redraw.
    @Published private(set) var version = 0
    private var byKey: [String: [URL]] = [:]
    private var scanning = false
    private var again = false

    func files(for url: URL?) -> [URL] {
        guard let url else { return [] }
        return byKey[URLKey.key(for: url)] ?? []
    }

    func isSaved(_ url: URL?) -> Bool { !files(for: url).isEmpty }

    var allKeys: Set<String> { Set(byKey.keys) }

    func rescan(completion: (@MainActor () -> Void)? = nil) {
        if scanning { again = true; return }
        guard let root = SpaceFolders.root else { byKey = [:]; version += 1; completion?(); return }
        scanning = true
        Task.detached(priority: .utility) {
            var found: [String: [URL]] = [:]
            func walk(_ d: URL, _ depth: Int) {
                guard depth < 12 else { return }
                let items = (try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                                           options: [.skipsHiddenFiles])) ?? []
                for u in items {
                    let rv = try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                    if rv?.isDirectory == true && rv?.isPackage != true {
                        if !FileSafety.isSkippedFolder(u.lastPathComponent) { walk(u, depth + 1) }
                    } else if u.pathExtension.lowercased() == Webloc.ext, let p = Webloc.read(u) {
                        found[URLKey.key(for: p.url), default: []].append(u.standardizedFileURL)
                    }
                }
            }
            walk(root, 0)
            let result = found
            await MainActor.run {
                self.byKey = result
                self.scanning = false
                self.version += 1
                completion?()
                if self.again { self.again = false; self.rescan() }
            }
        }
    }

    /// Rain's own saves and removals show at once, before the next scan.
    func noteSaved(_ file: URL, page: URL) {
        byKey[URLKey.key(for: page), default: []].append(file.standardizedFileURL)
        version += 1
    }

    func noteRemoved(_ file: URL) {
        let p = file.standardizedFileURL.path
        for (k, v) in byKey { byKey[k] = v.filter { $0.path != p } }
        byKey = byKey.filter { !$0.value.isEmpty }
        version += 1
    }
}

/// Short names for thumbnail files: a hash of the page's normalized address.
enum PageHash {
    static func of(_ url: URL) -> String {
        let digest = SHA256.hash(data: Data(URLKey.key(for: url).utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
