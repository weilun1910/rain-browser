import Foundation

/// Background work that turns pages, notes and Markdown files into index entries.
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
            if t.hasPrefix("#") {
                let h = t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if !h.isEmpty { return h }
            }
        }
        return url.deletingPathExtension().lastPathComponent
    }

    static func fileDoc(url: URL, text: String, source: SourceType, project: String?, root: String?, mtime: Double) -> (DocUpsert, Analysis) {
        let title = noteTitle(text: text, url: url)
        let body = String(text.prefix(40000))
        let a = TextAnalysis.analyze(title: title, description: "", text: body)
        let d = DocUpsert(key: URLKey.fileKey(url), source: source, url: url.standardizedFileURL.absoluteString,
                          title: title, description: "", body: body, project: project, root: root,
                          firstSeen: mtime, lastSeen: mtime, visitCount: 0, mtime: mtime)
        return (d, a)
    }

    static func indexNote(url: URL, text: String) {
        work.async {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? Date().timeIntervalSince1970
            let (d, a) = fileDoc(url: url, text: text, source: .note, project: "Notes", root: nil, mtime: mtime)
            IndexStore.shared.upsertFile(d, analysis: a)
        }
    }

    static func removeFile(url: URL) {
        work.async { IndexStore.shared.deleteDocs(keys: [URLKey.fileKey(url)]) }
    }

    /// Brings the app's own notes folder up to date with the index.
    static func syncNotes(dir: URL) {
        work.async {
            let known = IndexStore.shared.fileMtimes(source: .note)
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            var present = Set<String>()
            for f in files where f.pathExtension.lowercased() == "md" {
                let key = URLKey.fileKey(f)
                present.insert(key)
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
                if let old = known[key], abs(old - m) < 0.5 { continue }
                guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
                let (d, a) = fileDoc(url: f, text: text, source: .note, project: "Notes", root: nil, mtime: m)
                IndexStore.shared.upsertFile(d, analysis: a)
            }
            let gone = known.keys.filter { !present.contains($0) && (URL(string: $0).map { FileSafety.isInside($0, dir) } ?? false) }
            IndexStore.shared.deleteDocs(keys: Array(gone))
        }
    }
}

/// Markdown folders Felix adds. Strictly read-only: files are listed and read, never written.
enum MarkdownFolders {
    static let skipDirs: Set<String> = [".git", "node_modules", ".build"]

    struct Found {
        var files: [(url: URL, mtime: Double)] = []
        var notDownloaded = 0
        var tooBig = 0
    }

    static func scan(root: URL) -> Found {
        var found = Found()
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey, .ubiquitousItemDownloadingStatusKey]
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                      options: [.skipsPackageDescendants],
                                                      errorHandler: { _, _ in true }) else { return found }
        for case let url as URL in en {
            let name = url.lastPathComponent
            let rv = try? url.resourceValues(forKeys: Set(keys))
            if rv?.isDirectory == true {
                if skipDirs.contains(name) || name.lowercased().hasSuffix(".nosync") { en.skipDescendants() }
                continue
            }
            guard url.pathExtension.lowercased() == "md" else { continue }
            if let status = rv?.ubiquitousItemDownloadingStatus, status == .notDownloaded {
                // Reading it would make iCloud download it. Leave it alone.
                found.notDownloaded += 1
                continue
            }
            if (rv?.fileSize ?? 0) > 2_000_000 { found.tooBig += 1; continue }
            found.files.append((url, rv?.contentModificationDate?.timeIntervalSince1970 ?? 0))
        }
        return found
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

    /// Reads a file without changing it. Data(contentsOf:) opens it read-only.
    static func read(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.uncached]) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
}

@MainActor
final class MarkdownIndexer: ObservableObject {
    static let shared = MarkdownIndexer()

    @Published var status: String = ""
    @Published var running = false
    private var queued = false

    func rescanAll() {
        if running { queued = true; return }
        let roots = Settings.shared.value.markdownRoots
        guard !roots.isEmpty else { status = ""; return }
        running = true
        status = "Checking folders..."
        Task.detached(priority: .utility) {
            var total = 0, changed = 0, notLocal = 0
            for rootPath in roots {
                let root = URL(fileURLWithPath: rootPath, isDirectory: true)
                let found = MarkdownFolders.scan(root: root)
                notLocal += found.notDownloaded
                total += found.files.count
                let known = IndexStore.shared.fileMtimes(root: rootPath)
                var present = Set<String>()
                var i = 0
                for (url, mtime) in found.files {
                    i += 1
                    let key = URLKey.fileKey(url)
                    present.insert(key)
                    if let old = known[key], abs(old - mtime) < 0.5 { continue }
                    guard let text = MarkdownFolders.read(url) else { continue }
                    let (d, a) = Indexer.fileDoc(url: url, text: text, source: .markdown,
                                                 project: MarkdownFolders.project(for: url, root: root),
                                                 root: rootPath, mtime: mtime)
                    IndexStore.shared.upsertFile(d, analysis: a)
                    changed += 1
                    if changed % 10 == 0 {
                        let msg = "Indexing \(root.lastPathComponent): \(i) of \(found.files.count)"
                        await MainActor.run { self.status = msg }
                    }
                }
                let gone = known.keys.filter { !present.contains($0) }
                IndexStore.shared.deleteDocs(keys: Array(gone))
            }
            var msg = "\(total) Markdown files indexed"
            if notLocal > 0 { msg += ", \(notLocal) skipped because they're only in iCloud" }
            let final = msg
            await MainActor.run {
                self.status = final
                self.running = false
                NotificationCenter.default.post(name: .indexChanged, object: nil)
                if self.queued { self.queued = false; self.rescanAll() }
            }
        }
    }

    func removeRoot(_ path: String) {
        Settings.shared.update { $0.markdownRoots.removeAll { $0 == path } }
        Task.detached { IndexStore.shared.deleteRoot(path) }
    }
}
