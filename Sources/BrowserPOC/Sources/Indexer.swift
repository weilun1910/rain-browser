import CoreServices
import Foundation

/// Background work that turns pages and notes into index entries.
enum Indexer {
    static let work = DispatchQueue(label: "local.browserpoc.indexer", qos: .utility)

    static func indexPage(url: URL, title: String, description: String, text: String, dwell: Double = 0,
                          done: (@Sendable () -> Void)? = nil) {
        let settings = Settings.shared.value
        guard URLKey.isIndexableWeb(url), !settings.isExcluded(host: url.host) else { return }
        work.async {
            let key = URLKey.key(for: url)
            let now = Date().timeIntervalSince1970
            let trimmed = String(text.prefix(20000))
            let a = TextAnalysis.analyze(title: title, description: description, text: trimmed)
            let d = DocUpsert(key: key, source: .web, url: url.absoluteString, title: title.isEmpty ? (url.host ?? key) : title,
                              description: description, body: trimmed, firstSeen: now, lastSeen: now,
                              visitCount: 1, dwell: dwell)
            IndexStore.shared.recordCapture(d, analysis: a)
            done?()
        }
    }

    static func noteTitle(text: String, url: URL) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(40) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("# ") {
                let h = t.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if !h.isEmpty { return h }
            }
        }
        return url.deletingPathExtension().lastPathComponent
    }

    static func fileDoc(url: URL, text: String, root: URL?, mtime: Double) -> (DocUpsert, Analysis) {
        let title = noteTitle(text: text, url: url)
        let body = String(text.prefix(40000))
        let a = TextAnalysis.analyze(title: title, description: "", text: body)
        let project = root.map { NotesScan.project(for: url, root: $0) }
        let d = DocUpsert(key: URLKey.fileKey(url), source: .note, url: url.standardizedFileURL.absoluteString,
                          title: title, description: "", body: body, project: project,
                          root: root?.standardizedFileURL.path,
                          firstSeen: mtime, lastSeen: mtime, visitCount: 0, mtime: mtime)
        return (d, a)
    }

    static func indexNote(url: URL, text: String) {
        let roots = Settings.shared.value.notesRoots
        work.async {
            let mtime = NotesScan.mtime(url) ?? Date().timeIntervalSince1970
            let root = FileSafety.notesRoot(for: url, roots: roots)
            let (d, a) = fileDoc(url: url, text: text, root: root, mtime: mtime)
            IndexStore.shared.upsertFile(d, analysis: a)
        }
    }

    static func removeFile(url: URL) {
        work.async { IndexStore.shared.deleteDocs(keys: [URLKey.fileKey(url)]) }
    }
}

struct NoteFile: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let name: String
    let mtime: Double
    let isLocal: Bool
}

struct NoteFolder: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let name: String
    var folders: [NoteFolder]
    var files: [NoteFile]

    var allFiles: [NoteFile] { files + folders.flatMap { $0.allFiles } }

    func find(_ u: URL) -> NoteFolder? {
        if url.standardizedFileURL.path == u.standardizedFileURL.path { return self }
        for f in folders { if let hit = f.find(u) { return hit } }
        return nil
    }
}

/// Lists the notes tree on disk. Only reads directory listings and file attributes.
enum NotesScan {
    static func scan(_ root: URL, depth: Int = 0) -> NoteFolder {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .ubiquitousItemDownloadingStatusKey, .isPackageKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys,
                                                                   options: [.skipsHiddenFiles])) ?? []
        var folders: [NoteFolder] = []
        var files: [NoteFile] = []
        for u in items {
            let name = u.lastPathComponent
            let rv = try? u.resourceValues(forKeys: Set(keys))
            if rv?.isDirectory == true {
                if rv?.isPackage == true || FileSafety.isSkippedFolder(name) || name == ".build" || depth > 12 { continue }
                folders.append(scan(u, depth: depth + 1))
            } else if u.pathExtension.lowercased() == "md" && !name.hasPrefix(".") {
                let local = rv?.ubiquitousItemDownloadingStatus != .notDownloaded
                files.append(NoteFile(url: u, name: u.deletingPathExtension().lastPathComponent,
                                      mtime: rv?.contentModificationDate?.timeIntervalSince1970 ?? 0, isLocal: local))
            }
        }
        folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        files.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return NoteFolder(url: root, name: root.lastPathComponent, folders: folders, files: files)
    }

    static func project(for file: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let filePath = file.standardizedFileURL.resolvingSymlinksInPath().path
        var rel = filePath.hasPrefix(rootPath) ? String(filePath.dropFirst(rootPath.count)) : filePath
        if rel.hasPrefix("/") { rel.removeFirst() }
        let parts = rel.split(separator: "/")
        if parts.count >= 2 { return String(parts[0]) }
        return root.lastPathComponent
    }

    /// Fresh attributes, not the cached URL resource values.
    static func stat(_ url: URL) -> (mtime: Date, size: Int)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              let m = a[.modificationDate] as? Date else { return nil }
        return (m, (a[.size] as? NSNumber)?.intValue ?? 0)
    }

    static func mtime(_ url: URL) -> Double? { stat(url)?.mtime.timeIntervalSince1970 }

    /// Reads a note's bytes without changing them. Nil if it isn't readable yet (for example still in iCloud).
    static func read(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    static func decode(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}

/// Keeps the index in step with the notes folders. Files iCloud hasn't downloaded yet are asked
/// for and retried later.
final class NotesIndexer: @unchecked Sendable {
    static let shared = NotesIndexer()
    private let queue = DispatchQueue(label: "local.browserpoc.notesindexer", qos: .utility)
    private var attempts: [String: Int] = [:]
    private var retryScheduled = false

    /// Status for Settings, updated on the main thread.
    var onStatus: (@Sendable (String) -> Void)?

    func sync(roots: [NoteFolder], completion: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            var total = 0, changed = 0, waiting = 0
            for root in roots {
                let rootPath = root.url.standardizedFileURL.path
                let known = IndexStore.shared.fileMtimes(root: rootPath)
                var present = Set<String>()
                for f in root.allFiles {
                    total += 1
                    let key = URLKey.fileKey(f.url)
                    present.insert(key)
                    if let old = known[key], abs(old - f.mtime) < 0.5 { attempts[key] = nil; continue }
                    if !f.isLocal {
                        try? FileManager.default.startDownloadingUbiquitousItem(at: f.url)
                        waiting += 1
                        attempts[key, default: 0] += 1
                        continue
                    }
                    guard let data = NotesScan.read(f.url) else {
                        waiting += 1
                        attempts[key, default: 0] += 1
                        continue
                    }
                    attempts[key] = nil
                    let (d, a) = Indexer.fileDoc(url: f.url, text: NotesScan.decode(data), root: root.url, mtime: f.mtime)
                    IndexStore.shared.upsertFile(d, analysis: a)
                    changed += 1
                }
                let gone = known.keys.filter { !present.contains($0) }
                IndexStore.shared.deleteDocs(keys: Array(gone))
            }
            var msg = "\(total) notes indexed"
            if waiting > 0 { msg += ", \(waiting) waiting for iCloud" }
            onStatus?(msg)
            // Retry files that weren't readable, a few times.
            let retry = attempts.values.contains { $0 < 6 }
            if retry && !retryScheduled {
                retryScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [self] in
                    queue.async { self.retryScheduled = false }
                    NotificationCenter.default.post(name: .notesNeedRescan, object: nil)
                }
            }
            if changed > 0 {
                DispatchQueue.main.async { NotificationCenter.default.post(name: .indexChanged, object: nil) }
            }
            completion?()
        }
    }
}

/// FSEvents on the notes folders. Calls back on the main queue for changes to .md files or folders.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let callback: () -> Void

    init?(paths: [String], callback: @escaping () -> Void) {
        self.callback = callback
        guard !paths.isEmpty else { return nil }
        var ctx = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        ctx.info = Unmanaged.passUnretained(self).toOpaque()
        let cb: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let relevant = list.prefix(count).contains { p in
                let comps = p.split(separator: "/")
                if comps.contains(where: { $0.hasPrefix(".") || $0 == "node_modules" || $0.lowercased().hasSuffix(".nosync") }) { return false }
                let ext = (p as NSString).pathExtension.lowercased()
                return ext == "md" || ext.isEmpty
            }
            if relevant { me.callback() }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, cb, &ctx, paths as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else { return nil }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
        stream = s
    }

    deinit {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }
}

extension Notification.Name {
    static let notesNeedRescan = Notification.Name("local.browserpoc.notesNeedRescan")
}
