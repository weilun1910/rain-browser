import Foundation

/// Switches and status for the round 3 sources. Kept in their own file in the support folder
/// (sources.json) so they don't disturb settings.json.
struct SourceConfig: Codable, Equatable {
    var notionEnabled = false
    var googleDocsEnabled = false
    var granolaEnabled = false
    var notionStatus: String?
    var googleDocsStatus: String?
    var granolaStatus: String?
    var notionSyncedAt: Date?
    var googleDocsSyncedAt: Date?
    var granolaSyncedAt: Date?
}

final class SourceSettings: ObservableObject, @unchecked Sendable {
    static let shared = SourceSettings()
    private let lock = NSLock()
    private var stored = SourceConfig()
    @Published private(set) var published = SourceConfig()

    static var file: URL { Paths.root.appendingPathComponent("sources.json") }

    private init() { reload() }

    var value: SourceConfig {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func reload() {
        var c = SourceConfig()
        if let d = try? Data(contentsOf: Self.file), let decoded = try? JSONDecoder.iso.decode(SourceConfig.self, from: d) { c = decoded }
        lock.lock(); stored = c; lock.unlock()
        publish(c)
    }

    func update(_ change: (inout SourceConfig) -> Void) {
        lock.lock()
        change(&stored)
        let snap = stored
        lock.unlock()
        Paths.ensure(Paths.root)
        if let d = try? JSONEncoder.pretty.encode(snap) { try? d.write(to: Self.file, options: .atomic) }
        publish(snap)
    }

    private func publish(_ c: SourceConfig) {
        if Thread.isMainThread { published = c } else { DispatchQueue.main.async { self.published = c } }
    }
}

/// Copies another app's SQLite database (with its WAL and shared-memory files) into our own
/// tmp folder, so we read a snapshot and never open the original for writing.
enum ForeignDB {
    enum ReadError: Error, CustomStringConvertible {
        case notFound(String)
        case needsPermission(String)
        case failed(String)
        var description: String {
            switch self {
            case .notFound(let s), .failed(let s): return s
            case .needsPermission(let app): return "macOS needs your OK before Browser POC can read \(app)'s data. If a prompt came up, click Allow, then try again. If you clicked Don't Allow or no prompt came up, open System Settings, go to Privacy & Security, then Files & Folders, find Browser POC and turn on \(app)."
            }
        }
    }

    /// Returns the folder holding the copy. The caller deletes it.
    static func snapshot(_ src: URL, app: String) throws -> URL {
        guard FileManager.default.fileExists(atPath: src.path) else { throw ReadError.notFound("\(app)'s data wasn't found at \(src.path).") }
        Paths.ensure(Paths.tmpDir)
        let dir = Paths.tmpDir.appendingPathComponent("\(app.lowercased())-\(UUID().uuidString)", isDirectory: true)
        Paths.ensure(dir)
        let dst = dir.appendingPathComponent(src.lastPathComponent)
        do {
            try ChromeHistory.copyReadOnly(src, to: dst)
            for suffix in ["-wal", "-shm"] {
                let s = URL(fileURLWithPath: src.path + suffix)
                if FileManager.default.fileExists(atPath: s.path) {
                    try ChromeHistory.copyReadOnly(s, to: URL(fileURLWithPath: dst.path + suffix))
                }
            }
        } catch ChromeHistory.ReadError.needsPermission {
            try? FileManager.default.removeItem(at: dir)
            throw ReadError.needsPermission(app)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw ReadError.failed("Couldn't copy \(app)'s data: \(error)")
        }
        return dir
    }
}
