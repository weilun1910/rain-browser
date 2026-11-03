import AppKit
import Foundation

struct NoteItem: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    let title: String
    let mtime: Date
}

/// The app's own notes: plain .md files in the notes folder.
@MainActor
final class NotesStore: ObservableObject {
    @Published var notes: [NoteItem] = []

    var dir: URL { Settings.shared.value.notesDir }

    func reload() {
        let d = dir
        Paths.ensure(d)
        let files = (try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey],
                                                                  options: [.skipsHiddenFiles])) ?? []
        var items: [NoteItem] = []
        for f in files where f.pathExtension.lowercased() == "md" {
            let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let head = Self.head(of: f)
            items.append(NoteItem(url: f, title: Self.title(from: head, url: f), mtime: m))
        }
        notes = items.sorted { $0.mtime > $1.mtime }
    }

    static func head(of url: URL) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: 2048)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// First heading, else first line, else the file name.
    static func title(from text: String, url: URL) -> String {
        for line in text.split(separator: "\n").prefix(20) {
            var t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if t.hasPrefix("#") { t = t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces) }
            if !t.isEmpty { return String(t.prefix(80)) }
        }
        let name = url.deletingPathExtension().lastPathComponent
        return name.hasPrefix("Note ") ? "Untitled" : name
    }

    func create() -> URL? {
        let d = dir
        Paths.ensure(d)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmmss"
        var url = d.appendingPathComponent("Note \(f.string(from: Date())).md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = d.appendingPathComponent("Note \(f.string(from: Date())) \(n).md"); n += 1
        }
        guard FileSafety.canWriteNote(url, notesDir: d) else { return nil }
        do { try "".write(to: url, atomically: true, encoding: .utf8) } catch { return nil }
        reload()
        return url
    }

    func rename(_ url: URL, to name: String) -> URL? {
        let clean = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let target = url.deletingLastPathComponent().appendingPathComponent(clean + ".md")
        guard FileSafety.canWriteNote(url, notesDir: dir), FileSafety.canWriteNote(target, notesDir: dir),
              !FileManager.default.fileExists(atPath: target.path) else { return nil }
        do { try FileManager.default.moveItem(at: url, to: target) } catch { return nil }
        reload()
        return target
    }

    func trash(_ url: URL) {
        guard FileSafety.canWriteNote(url, notesDir: dir) else { return }
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        reload()
    }
}

/// An open note or Markdown file. Files outside the notes folder are read-only.
@MainActor
final class NoteDocument: ObservableObject {
    let url: URL
    let isReadOnly: Bool
    let notesDir: URL
    @Published private(set) var text: String
    @Published var showPreview = false
    /// Bumped when the text changes from outside the editor (e.g. Add to research).
    @Published private(set) var externalRevision = 0

    var onPause: ((NoteDocument) -> Void)?
    var onSaved: ((NoteDocument) -> Void)?
    private var lastSaved: String
    private var saveWork: DispatchWorkItem?
    private var pauseWork: DispatchWorkItem?

    init(url: URL, notesDir: URL) {
        self.url = url
        self.notesDir = notesDir
        let writable = FileSafety.canWriteNote(url, notesDir: notesDir)
        isReadOnly = !writable
        let t = (writable ? (try? String(contentsOf: url, encoding: .utf8)) : MarkdownFolders.read(url)) ?? ""
        text = t
        lastSaved = t
        if isReadOnly { showPreview = true }
    }

    var title: String { NotesStore.title(from: text, url: url) }

    var projectLabel: String? {
        for root in Settings.shared.value.markdownRoots {
            let r = URL(fileURLWithPath: root)
            if FileSafety.isInside(url, r) { return MarkdownFolders.project(for: url, root: r) }
        }
        return nil
    }

    func userEdited(_ newText: String) {
        guard !isReadOnly, newText != text else { return }
        text = newText
        scheduleSave()
        schedulePause()
    }

    func replaceText(_ newText: String) {
        guard !isReadOnly else { return }
        text = newText
        externalRevision += 1
        saveNow()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: w)
    }

    private func schedulePause() {
        pauseWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.onPause?(self)
        }
        pauseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: w)
    }

    func saveNow() {
        saveWork?.cancel()
        guard !isReadOnly, text != lastSaved, FileSafety.canWriteNote(url, notesDir: notesDir) else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            lastSaved = text
            onSaved?(self)
        } catch {
            appLog.error("note save failed: \(String(describing: error), privacy: .public)")
        }
    }
}
