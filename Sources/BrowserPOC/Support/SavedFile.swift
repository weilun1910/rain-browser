import Foundation
import os

/// Reads and writes the JSON files Rain saves (state.json, settings.json and the rest).
///
/// When the app finds a file it can't read, it would otherwise start from defaults and save over
/// the file on the next change. Instead the file moves into `Recovered/` first, and the app says
/// so once its window is up. A file that only partly reads (a tab it can't make sense of, a value
/// of the wrong type) loads what it can, and a copy of the whole file goes into `Recovered/`
/// before anything is saved over it. If a file can't be moved or copied, Rain doesn't write to
/// it for the rest of the session.
enum SavedFile {
    /// Only the app itself repairs files. Tools that read a profile (the MCP server, evals) leave
    /// everything where it is.
    nonisolated(unsafe) static var mayRepair = false
    private static let lock = NSLock()
    nonisolated(unsafe) private static var blocked: Set<String> = []

    static var recoveredDir: URL { Paths.root.appendingPathComponent("Recovered", isDirectory: true) }

    /// The decoded file, or nil when it's missing or couldn't be read. `label` names it for you,
    /// as in "Rain couldn't read your spaces and tabs".
    static func read<T: Decodable>(_ type: T.Type, from url: URL, label: String) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let tally = RepairTally()
        let decoder = JSONDecoder.iso
        decoder.userInfo[.repairTally] = tally
        do {
            let data = try Data(contentsOf: url)
            let value = try decoder.decode(T.self, from: data)
            if tally.count > 0, mayRepair { keepCopy(url, label: label, skipped: tally.count) }
            return value
        } catch {
            appLog.error("Couldn't read \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            if mayRepair { setAside(url, label: label) }
            return nil
        }
    }

    /// Writes a file atomically, unless it's one Rain couldn't read and couldn't set aside.
    @discardableResult
    static func write(_ data: Data, to url: URL) -> Bool {
        lock.lock(); let isBlocked = blocked.contains(url.standardizedFileURL.path); lock.unlock()
        if isBlocked { return false }
        do { try data.write(to: url, options: .atomic); return true } catch { return false }
    }

    static func isBlocked(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return blocked.contains(url.standardizedFileURL.path)
    }

    /// "2026-11-05 14.02.11", local time.
    static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: d)
    }

    /// For the self test.
    static func unblockAll() { lock.lock(); blocked = []; lock.unlock() }

    /// Moves an unreadable file into Recovered/, so the defaults that replace it can't overwrite it.
    private static func setAside(_ url: URL, label: String) {
        let fm = FileManager.default
        if let dest = place(for: url) {
            // Moving is the normal case. A copy also does: the original is safe in Recovered.
            if (try? fm.moveItem(at: url, to: dest)) != nil || (try? fm.copyItem(at: url, to: dest)) != nil {
                DataNotices.add(.setAside(label: label, file: dest))
                return
            }
        }
        block(url)
        DataNotices.add(.untouched(label: label))
    }

    /// Keeps a copy of a file that only partly read, before the app saves over it.
    private static func keepCopy(_ url: URL, label: String, skipped: Int) {
        if let dest = place(for: url), (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
            DataNotices.add(.partlyRead(label: label, skipped: skipped, file: dest))
        } else {
            block(url)
            DataNotices.add(.untouched(label: label))
        }
    }

    private static func block(_ url: URL) {
        lock.lock(); blocked.insert(url.standardizedFileURL.path); lock.unlock()
    }

    /// "state 2026-11-05 14.02.11.json", numbered if that name is taken.
    private static func place(for url: URL) -> URL? {
        let fm = FileManager.default
        do { try fm.createDirectory(at: recoveredDir, withIntermediateDirectories: true) } catch { return nil }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        let stamp = Self.stamp(Date())
        var dest = recoveredDir.appendingPathComponent("\(base) \(stamp)\(ext)")
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = recoveredDir.appendingPathComponent("\(base) \(stamp) \(n)\(ext)")
            n += 1
        }
        return dest
    }
}

/// Counts values a decoder had to leave out or replace with a default, so SavedFile can keep a
/// copy of the original. Passed in the decoder's userInfo.
final class RepairTally: @unchecked Sendable {
    var count = 0
}

extension CodingUserInfoKey {
    static let repairTally = CodingUserInfoKey(rawValue: "rain.repairTally")!
}

extension Decoder {
    var repairTally: RepairTally? { userInfo[.repairTally] as? RepairTally }
}

extension KeyedDecodingContainer {
    /// The value, or nil when it's missing or null. A value that's there but can't be read also
    /// gives nil, and is counted, so the caller falls back to a default without losing the file.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key, _ decoder: Decoder) -> T? {
        guard contains(key) else { return nil }
        if (try? decodeNil(forKey: key)) == true { return nil }
        if let v = try? decode(T.self, forKey: key) { return v }
        decoder.repairTally?.count += 1
        return nil
    }

    /// An array that keeps every element it can read and counts the ones it can't.
    func lenientArray<T: Decodable>(_ type: T.Type, _ key: Key, _ decoder: Decoder) -> [T]? {
        lenient(LossyArray<T>.self, key, decoder)?.items
    }
}

/// An array that skips elements it can't read instead of failing the whole file.
struct LossyArray<Element: Decodable>: Decodable {
    var items: [Element]

    private struct Attempt: Decodable {
        let value: Element?
        init(from decoder: Decoder) throws {
            value = try? Element(from: decoder)
            if value == nil { decoder.repairTally?.count += 1 }
        }
    }

    init(from decoder: Decoder) throws {
        items = try [Attempt](from: decoder).compactMap { $0.value }
    }
}

/// What Rain tells you about your saved data: a file it set aside, part of a file it couldn't
/// read, or a backup it couldn't make. Collected from any thread, shown once the window is up.
enum DataNotices {
    enum Notice: Equatable {
        case setAside(label: String, file: URL)
        case partlyRead(label: String, skipped: Int, file: URL)
        case untouched(label: String)
        case backupFailed(String)

        var sentence: String {
            switch self {
            case .setAside(let label, _):
                return "Rain couldn't read your \(label), so it started those over. The old file is kept in Recovered."
            case .partlyRead(let label, let n, _):
                return "Rain couldn't read \(n == 1 ? "one part" : "\(n) parts") of your \(label) and left \(n == 1 ? "it" : "them") out. A copy of the whole file is kept in Recovered."
            case .untouched(let label):
                return "Rain couldn't read your \(label) or keep a copy, so it won't save over that file until you restart."
            case .backupFailed(let why):
                return "Rain couldn't back up your data before this update. \(why)"
            }
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: [Notice] = []
    /// Set by the app, to show a notice that arrives after launch.
    nonisolated(unsafe) static var onNotice: (@Sendable () -> Void)?

    static func add(_ n: Notice) {
        lock.lock()
        pending.append(n)
        let handler = onNotice
        lock.unlock()
        handler?()
    }

    /// Everything not shown yet, and clears it.
    static func take() -> [Notice] {
        lock.lock(); defer { pending = []; lock.unlock() }
        return pending
    }

    static func peek() -> [Notice] {
        lock.lock(); defer { lock.unlock() }
        return pending
    }
}
