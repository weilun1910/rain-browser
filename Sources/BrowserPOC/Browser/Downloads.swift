import AppKit
import WebKit

/// Downloads with their progress, for the sidebar button and the Downloads page. The list
/// survives a restart in `downloads.json`. Files go to ~/Downloads with a number if the name is taken.
@MainActor
final class Downloads: ObservableObject {
    struct Item: Codable, Identifiable, Equatable {
        enum State: String, Codable { case running, done, failed, cancelled }
        var id = UUID()
        var filename: String
        var path: String
        var source: String?
        var startedAt = Date()
        var state: State = .running
        var progress: Double = 0
        var fileURL: URL { URL(fileURLWithPath: path) }
    }

    static let shared = Downloads()
    @Published private(set) var items: [Item] = []
    private var live: [ObjectIdentifier: (UUID, WKDownload, NSKeyValueObservation?)] = [:]
    /// Tests point downloads at a throwaway folder.
    var folderOverride: URL?

    static var file: URL { Paths.root.appendingPathComponent("downloads.json") }
    private var loadedFrom: String?

    private init() { load() }

    func load() {
        loadedFrom = Self.file.path
        if let v = SavedFile.read(LossyArray<Item>.self, from: Self.file, label: "downloads list").map({ $0.items }) {
            // Anything still marked running died with the last session.
            items = v.map { var i = $0; if i.state == .running { i.state = .failed }; return i }
        } else {
            items = []
        }
    }

    private func save() {
        if loadedFrom != Self.file.path { load() }
        Paths.ensure(Paths.root)
        if let data = try? JSONEncoder.pretty.encode(Array(items.suffix(50))) { SavedFile.write(data, to: Self.file) }
    }

    var running: [Item] { items.filter { $0.state == .running } }
    /// The share of all running downloads that's done, for the sidebar ring.
    var overallProgress: Double? {
        let r = running
        guard !r.isEmpty else { return nil }
        return r.map { $0.progress }.reduce(0, +) / Double(r.count)
    }

    static func uniqueDestination(in dir: URL, name: String) -> URL {
        let clean = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var dest = dir.appendingPathComponent(clean.isEmpty ? "download" : clean)
        let base = dest.deletingPathExtension().lastPathComponent
        let ext = dest.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return dest
    }

    func destination(for download: WKDownload, suggestedFilename: String, source: URL?) -> URL {
        let dir = folderOverride ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let dest = Self.uniqueDestination(in: dir, name: suggestedFilename)
        let item = Item(filename: dest.lastPathComponent, path: dest.path, source: source?.absoluteString)
        items.append(item)
        let obs = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] p, _ in
            let f = p.fractionCompleted
            Task { @MainActor in self?.setProgress(item.id, f) }
        }
        live[ObjectIdentifier(download)] = (item.id, download, obs)
        save()
        return dest
    }

    private func setProgress(_ id: UUID, _ f: Double) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].state == .running else { return }
        if abs(items[i].progress - f) > 0.01 || f >= 1 { items[i].progress = f }
    }

    func item(for download: WKDownload) -> Item? {
        guard let id = live[ObjectIdentifier(download)]?.0 else { return nil }
        return items.first { $0.id == id }
    }

    private func finish(_ download: WKDownload, _ state: Item.State) {
        guard let (id, _, obs) = live[ObjectIdentifier(download)] else { return }
        obs?.invalidate()
        live[ObjectIdentifier(download)] = nil
        if let i = items.firstIndex(where: { $0.id == id }) {
            items[i].state = state
            if state == .done { items[i].progress = 1 }
        }
        save()
    }

    func finished(_ download: WKDownload) { finish(download, .done) }
    func failed(_ download: WKDownload, error: Error) { finish(download, .failed) }

    func cancel(_ id: UUID) {
        guard let entry = live.first(where: { $0.value.0 == id }) else { return }
        entry.value.1.cancel { _ in }
        finish(entry.value.1, .cancelled)
    }

    /// Takes finished items off the list. Files stay where they are.
    func clearFinished() {
        items.removeAll { $0.state != .running }
        save()
    }

    func reveal(_ item: Item) { NSWorkspace.shared.activateFileViewerSelecting([item.fileURL]) }
    func open(_ item: Item) { NSWorkspace.shared.open(item.fileURL) }
}
