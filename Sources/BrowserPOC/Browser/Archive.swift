import Foundation

/// A tab that left the sidebar: closed by hand, archived after sitting idle, or cleared with
/// Clear Today. It keeps what's needed to bring it back, including its back and forward history.
struct ClosedItem: Codable, Identifiable, Equatable {
    enum Reason: String, Codable { case closed, archived, cleared }

    var id: UUID
    var kind: TabKind
    var url: String?
    var title: String
    var customTitle: String?
    var spaceID: UUID?
    var closedAt: Date
    var reason: Reason
    /// Items that left together (a split, or one Clear Today) share a group.
    var group: UUID?
    /// The split they were in, so a restored group comes back as the same split.
    var splitRoot: SplitNode?

    var displayTitle: String {
        if let c = customTitle, !c.isEmpty { return c }
        if !title.isEmpty { return title }
        if let u = url.flatMap(URL.init(string:)) { return kind == .web ? (u.host ?? u.absoluteString) : u.deletingPathExtension().lastPathComponent }
        return "Untitled"
    }
}

/// Recently closed tabs and the archive, in `closed.json`. Session files for these items stay
/// in `sessions/` until the item is dropped.
@MainActor
final class ClosedStore: ObservableObject {
    @Published private(set) var items: [ClosedItem] = []
    static let recentLimit = 50
    static let archiveLimit = 1000

    static var file: URL { Paths.root.appendingPathComponent("closed.json") }

    init() { load() }

    func load() {
        if let v = SavedFile.read(LossyArray<ClosedItem>.self, from: Self.file, label: "recently closed tabs and archive") {
            items = v.items
        } else {
            items = []
        }
    }

    private func save() {
        Paths.ensure(Paths.root)
        if let data = try? JSONEncoder.pretty.encode(items) { SavedFile.write(data, to: Self.file) }
    }

    /// Recently closed, newest first.
    var recent: [ClosedItem] { items.filter { $0.reason == .closed }.sorted { $0.closedAt > $1.closedAt } }
    /// Archived and cleared, newest first.
    var archive: [ClosedItem] { items.filter { $0.reason != .closed }.sorted { $0.closedAt > $1.closedAt } }

    func add(_ new: [ClosedItem]) {
        guard !new.isEmpty else { return }
        let ids = Set(new.map { $0.id })
        items.removeAll { ids.contains($0.id) }
        items.append(contentsOf: new)
        trim()
        save()
    }

    /// Takes items out, to restore them. Their session files stay for the restored tab.
    @discardableResult
    func take(_ ids: Set<UUID>) -> [ClosedItem] {
        let out = items.filter { ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        save()
        return out
    }

    func members(of group: UUID) -> [ClosedItem] { items.filter { $0.group == group } }

    /// Empties the archive. Recently closed stays.
    func clearArchive() {
        let gone = items.filter { $0.reason != .closed }
        items.removeAll { $0.reason != .closed }
        for g in gone { SessionFiles.delete(g.id) }
        save()
    }

    private func trim() {
        var recentCount = 0, archiveCount = 0
        var keep: [ClosedItem] = []
        for i in items.sorted(by: { $0.closedAt > $1.closedAt }) {
            if i.reason == .closed {
                recentCount += 1
                if recentCount > Self.recentLimit { SessionFiles.delete(i.id); continue }
            } else {
                archiveCount += 1
                if archiveCount > Self.archiveLimit { SessionFiles.delete(i.id); continue }
            }
            keep.append(i)
        }
        items = keep.sorted { $0.closedAt < $1.closedAt }
    }
}

/// Each web tab's back and forward list, from WebKit's `interactionState`, one file per tab.
enum SessionFiles {
    static var dir: URL { Paths.root.appendingPathComponent("sessions", isDirectory: true) }
    static func url(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).session") }

    static func read(_ id: UUID) -> Data? { try? Data(contentsOf: url(id)) }

    static func write(_ data: Data, for id: UUID) {
        Paths.ensure(dir)
        try? data.write(to: url(id), options: .atomic)
    }

    static func copy(_ from: UUID, to: UUID) {
        guard let d = read(from) else { return }
        write(d, for: to)
    }

    static func delete(_ id: UUID) { try? FileManager.default.removeItem(at: url(id)) }

    /// Drops files no tab, closed item or archived item points at.
    static func prune(keeping ids: Set<UUID>) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "session" {
            if let id = UUID(uuidString: f.deletingPathExtension().lastPathComponent), !ids.contains(id) {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }
}
