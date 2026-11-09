import AppKit
import Foundation

/// The notes folders on disk: scanning, watching and file operations Felix asks for.
/// Nothing here writes to a note unless Felix created, renamed, deleted or edited it.
@MainActor
final class NotesStore: ObservableObject {
    @Published private(set) var roots: [NoteFolder] = []
    @Published private(set) var status = ""
    /// Called after every scan, so open notes can check the disk.
    var onScan: (() -> Void)?

    private var watcher: FolderWatcher?
    private var watchedPaths: [String] = []
    private var scanQueued = false
    private var scanning = false
    private var rescanObserver: NSObjectProtocol?

    init() {
        NotesIndexer.shared.onStatus = { [weak self] msg in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.status = msg } }
        }
        rescanObserver = NotificationCenter.default.addObserver(forName: .notesNeedRescan, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    var rootURLs: [URL] { Settings.shared.value.notesRoots }

    var allFiles: [NoteFile] { roots.flatMap { $0.allFiles } }

    /// Rescans the folders, re-indexes changed files and restarts the watcher if the roots changed.
    func reload(completion: (() -> Void)? = nil) {
        if scanning { scanQueued = true; return }
        scanning = true
        let urls = rootURLs
        if Settings.shared.value.usesFallbackNotes { Paths.ensure(Paths.defaultNotesDir) }
        // A root inside another is scanned on its own, and skipped inside the outer one.
        let skips = urls.map { r in Set(urls.filter { $0.standardizedFileURL.path != r.standardizedFileURL.path && FileSafety.isInside($0, r) }.map { $0.standardizedFileURL.path }) }
        Task.detached(priority: .utility) {
            let scanned = zip(urls, skips).map { NotesScan.scan($0, skipping: $1) }
            await MainActor.run {
                self.roots = scanned
                self.scanning = false
                self.watch(urls)
                self.onScan?()
                NotesIndexer.shared.sync(roots: scanned) {
                    DispatchQueue.main.async { MainActor.assumeIsolated { completion?() } }
                }
                if self.scanQueued { self.scanQueued = false; self.reload() }
            }
        }
    }

    private func watch(_ urls: [URL]) {
        let paths = urls.map { $0.standardizedFileURL.path }
        guard paths != watchedPaths else { return }
        watchedPaths = paths
        watcher = FolderWatcher(paths: paths) { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
    }

    private var reloadWork: DispatchWorkItem?
    func scheduleReload() {
        reloadWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.reload() } }
        reloadWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: w)
    }

    /// Creates an empty note. `title` becomes the file name and the first heading.
    func create(in folder: URL, title: String? = nil) -> URL? {
        let base = Self.safeName(title?.isEmpty == false ? title! : "Untitled")
        var url = folder.appendingPathComponent(base + ".md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n).md"); n += 1
        }
        guard FileSafety.canWriteNote(url) else { return nil }
        let body = (title?.isEmpty == false) ? "# \(title!)\n\n" : ""
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(body.utf8).write(to: url, options: .withoutOverwriting)
        } catch { return nil }
        scheduleReload()
        return url
    }

    static func safeName(_ s: String) -> String {
        let cleaned = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = cleaned.hasPrefix(".") ? String(cleaned.drop(while: { $0 == "." })) : cleaned
        return trimmed.isEmpty ? "Untitled" : String(trimmed.prefix(120))
    }

    enum RenameResult { case renamed(URL), taken(URL), failed }

    func rename(_ url: URL, to name: String) -> RenameResult {
        let target = url.deletingLastPathComponent().appendingPathComponent(Self.safeName(name) + ".md")
        if target.standardizedFileURL.path == url.standardizedFileURL.path { return .renamed(url) }
        guard FileSafety.canWriteNote(url), FileSafety.canWriteNote(target) else { return .failed }
        if FileManager.default.fileExists(atPath: target.path) { return .taken(target) }
        do { try FileManager.default.moveItem(at: url, to: target) } catch { return .failed }
        scheduleReload()
        return .renamed(target)
    }

    /// How notes reach the Trash. The self test swaps in a fixture folder so it never fills the real Trash.
    static var recycle: ([URL], @escaping @Sendable ([URL: URL], (any Error)?) -> Void) -> Void = { urls, done in
        NSWorkspace.shared.recycle(urls, completionHandler: done)
    }

    /// Moves a note to the Trash. Never deletes it outright.
    func trash(_ url: URL, completion: @escaping (Bool) -> Void) {
        guard FileSafety.canWriteNote(url) else { completion(false); return }
        Self.recycle([url]) { [weak self] moved, error in
            MainActor.assumeIsolated {
                self?.scheduleReload()
                completion(error == nil && moved[url] != nil)
            }
        }
    }
}

/// An open note. Loads the exact bytes, writes only after a real edit, and never writes over
/// a file that changed on disk since it was loaded unless Felix says so.
@MainActor
final class NoteDocument: ObservableObject {
    enum LoadState: Equatable { case loading, waitingForICloud, ready, failed(String) }
    enum DiskChange: Equatable { case changed, missing }

    private(set) var url: URL
    @Published private(set) var text = ""
    @Published private(set) var state: LoadState = .loading
    @Published private(set) var isReadOnly: Bool
    @Published private(set) var notUTF8 = false
    @Published var showPreview = false
    /// Bumped when the text changes from outside the editor (disk reload, Add to research).
    @Published private(set) var externalRevision = 0
    @Published private(set) var diskChange: DiskChange?

    var onPause: ((NoteDocument) -> Void)?
    var onSaved: ((NoteDocument) -> Void)?
    var onMissing: ((NoteDocument) -> Void)?
    /// Called each time the text is (re)loaded from disk.
    var onLoaded: ((NoteDocument) -> Void)?

    private var lastSaved = ""
    private var diskStat: (mtime: Date, size: Int)?
    private var saveWork: DispatchWorkItem?
    private var pauseWork: DispatchWorkItem?
    private var loadAttempts = 0

    var hasUnsavedEdits: Bool { state == .ready && text != lastSaved }

    init(url: URL) {
        self.url = url
        isReadOnly = !FileSafety.canWriteNote(url)
        load()
    }

    var title: String { Indexer.noteTitle(text: text, url: url) }

    // MARK: Loading

    func load() {
        state = loadAttempts == 0 ? .loading : state
        let u = url
        Task.detached(priority: .userInitiated) {
            let rv = try? u.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if rv?.ubiquitousItemDownloadingStatus == .notDownloaded {
                try? FileManager.default.startDownloadingUbiquitousItem(at: u)
                await MainActor.run { self.retryLoad(waiting: true) }
                return
            }
            let stat = NotesScan.stat(u)
            let data = NotesScan.read(u)
            await MainActor.run {
                guard let data, let stat else {
                    if FileManager.default.fileExists(atPath: u.path) { self.retryLoad(waiting: true) } else {
                        self.state = .failed("This file isn't there anymore.")
                        self.onMissing?(self)
                    }
                    return
                }
                self.applyLoaded(data, stat: stat)
            }
        }
    }

    private func retryLoad(waiting: Bool) {
        loadAttempts += 1
        if loadAttempts > 40 { state = .failed("Couldn't read this file from iCloud yet."); return }
        state = .waitingForICloud
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated { self?.load() }
        }
    }

    private func applyLoaded(_ data: Data, stat: (mtime: Date, size: Int)) {
        if let s = String(data: data, encoding: .utf8) {
            notUTF8 = false
            text = s
        } else {
            // Never write back a file we couldn't decode exactly.
            notUTF8 = true
            text = String(decoding: data, as: UTF8.self)
        }
        isReadOnly = notUTF8 || !FileSafety.canWriteNote(url)
        lastSaved = text
        diskStat = stat
        diskChange = nil
        state = .ready
        externalRevision += 1
        onLoaded?(self)
    }

    // MARK: Editing and saving

    func userEdited(_ newText: String) {
        guard state == .ready, !isReadOnly, newText != text else { return }
        text = newText
        scheduleSave()
        schedulePause()
    }

    func replaceText(_ newText: String) {
        guard state == .ready, !isReadOnly else { return }
        text = newText
        externalRevision += 1
        saveNow()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { _ = self?.saveNow() } }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: w)
    }

    private func schedulePause() {
        pauseWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onPause?(self)
            }
        }
        pauseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: w)
    }

    /// Writes only when the text differs from what was loaded or last saved, only to a .md file
    /// inside a notes folder, and only if the file on disk is still the one that was loaded.
    @discardableResult
    func saveNow(force: Bool = false) -> Bool {
        saveWork?.cancel()
        guard state == .ready, !isReadOnly, text != lastSaved, FileSafety.canWriteNote(url) else { return false }
        if diskChange != nil && !force { return false }
        let now = NotesScan.stat(url)
        if !force {
            guard let now else { diskChange = .missing; onMissing?(self); return false }
            if let was = diskStat, now.mtime != was.mtime || now.size != was.size {
                diskChange = .changed
                return false
            }
        }
        let data = Data(text.utf8)
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { u in
            do { try data.write(to: u, options: .atomic) } catch { writeError = error }
        }
        if let e = coordError ?? writeError as NSError? {
            appLog.error("note save failed: \(e.localizedDescription, privacy: .public)")
            return false
        }
        lastSaved = text
        diskStat = NotesScan.stat(url)
        diskChange = nil
        onSaved?(self)
        return true
    }

    /// Called when the folder watcher fires or the app comes forward.
    func checkDisk() {
        guard state == .ready else {
            if case .failed = state, FileManager.default.fileExists(atPath: url.path) { loadAttempts = 0; load() }
            return
        }
        guard let now = NotesScan.stat(url) else {
            diskChange = .missing
            onMissing?(self)
            return
        }
        if let was = diskStat, now.mtime == was.mtime && now.size == was.size {
            if diskChange == .missing { diskChange = nil }
            return
        }
        if hasUnsavedEdits {
            diskChange = .changed
        } else if let data = NotesScan.read(url) {
            applyLoaded(data, stat: now)
        }
    }

    /// Drops unsaved edits and shows the file as it is on disk.
    func loadDiskVersion() {
        saveWork?.cancel()
        guard let now = NotesScan.stat(url), let data = NotesScan.read(url) else { return }
        applyLoaded(data, stat: now)
    }

    /// Keeps Felix's text and saves it over the disk version.
    func keepMine() {
        if diskChange == .missing {
            // Recreating the file is an explicit choice, and only inside a notes folder.
            guard FileSafety.canWriteNote(url) else { return }
        }
        diskChange = nil
        saveNow(force: true)
    }

    /// The file moved (rename in the app, or Locate after it went missing).
    func relocate(to newURL: URL) {
        url = newURL
        isReadOnly = notUTF8 || !FileSafety.canWriteNote(newURL)
        diskStat = NotesScan.stat(newURL)
        diskChange = nil
        if !hasUnsavedEdits, let data = NotesScan.read(newURL), let st = diskStat { applyLoaded(data, stat: st) }
    }
}
