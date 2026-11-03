import Foundation
import os

let appLog = Logger(subsystem: "local.browserpoc", category: "app")

enum Paths {
    /// Set by the self test so nothing touches the real support folder.
    nonisolated(unsafe) static var overrideRoot: URL?

    static var root: URL {
        if let overrideRoot { return overrideRoot }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("BrowserPOC", isDirectory: true)
    }
    static var stateFile: URL { root.appendingPathComponent("state.json") }
    static var settingsFile: URL { root.appendingPathComponent("settings.json") }
    static var indexFile: URL { root.appendingPathComponent("index.sqlite") }
    static var defaultNotesDir: URL { root.appendingPathComponent("Notes", isDirectory: true) }
    static var tmpDir: URL { root.appendingPathComponent("tmp", isDirectory: true) }

    static func ensure(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

/// The app only ever writes inside its own support folder and the notes folder.
/// Everything else (Markdown folders Felix adds, Chrome's files) is read-only.
enum FileSafety {
    static func isInside(_ url: URL, _ dir: URL) -> Bool {
        let a = url.standardizedFileURL.resolvingSymlinksInPath().path
        var d = dir.standardizedFileURL.resolvingSymlinksInPath().path
        if !d.hasSuffix("/") { d += "/" }
        return a.hasPrefix(d)
    }

    static func canWriteNote(_ url: URL, notesDir: URL) -> Bool {
        guard url.pathExtension.lowercased() == "md" else { return false }
        guard isInside(url, notesDir) else { return false }
        for root in Settings.shared.value.markdownRoots {
            let r = URL(fileURLWithPath: root)
            // A notes folder inside an added Markdown folder is still the app's own,
            // but a file in a Markdown folder outside the notes folder never is.
            if isInside(url, r) && !isInside(notesDir, r) { return false }
        }
        return true
    }
}

struct AppSettings: Codable, Equatable {
    var notesFolder: String?
    var markdownRoots: [String] = []
    var excludedDomains: [String] = AppSettings.defaultExcluded
    var threshold: Double = 0.40
    var keywordWeight: Double = 1.0
    var semanticWeight: Double = 0.7
    var entityWeight: Double = 0.3
    var showScores: Bool = false
    var rightPanelOpen: Bool = true
    var firstRunDone: Bool = false
    var chromeImportedAt: Date?
    var chromeSummary: String?

    static let defaultExcluded: [String] = [
        "mail.google.com", "accounts.google.com", "pay.google.com",
        "chase.com", "bankofamerica.com", "wellsfargo.com", "citi.com", "capitalone.com",
        "americanexpress.com", "discover.com", "usbank.com", "pnc.com", "ally.com",
        "schwab.com", "fidelity.com", "vanguard.com", "robinhood.com", "etrade.com",
        "paypal.com", "venmo.com", "wise.com", "revolut.com", "coinbase.com",
        "dbs.com.sg", "dbs.com", "posb.com.sg", "ocbc.com", "uob.com.sg", "uobgroup.com",
        "1password.com", "bitwarden.com", "irs.gov", "ssa.gov",
    ]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        notesFolder = try c.decodeIfPresent(String.self, forKey: .notesFolder)
        markdownRoots = try c.decodeIfPresent([String].self, forKey: .markdownRoots) ?? d.markdownRoots
        excludedDomains = try c.decodeIfPresent([String].self, forKey: .excludedDomains) ?? d.excludedDomains
        threshold = try c.decodeIfPresent(Double.self, forKey: .threshold) ?? d.threshold
        keywordWeight = try c.decodeIfPresent(Double.self, forKey: .keywordWeight) ?? d.keywordWeight
        semanticWeight = try c.decodeIfPresent(Double.self, forKey: .semanticWeight) ?? d.semanticWeight
        entityWeight = try c.decodeIfPresent(Double.self, forKey: .entityWeight) ?? d.entityWeight
        showScores = try c.decodeIfPresent(Bool.self, forKey: .showScores) ?? d.showScores
        rightPanelOpen = try c.decodeIfPresent(Bool.self, forKey: .rightPanelOpen) ?? d.rightPanelOpen
        firstRunDone = try c.decodeIfPresent(Bool.self, forKey: .firstRunDone) ?? d.firstRunDone
        chromeImportedAt = try c.decodeIfPresent(Date.self, forKey: .chromeImportedAt)
        chromeSummary = try c.decodeIfPresent(String.self, forKey: .chromeSummary)
    }

    var notesDir: URL {
        if let notesFolder, !notesFolder.isEmpty { return URL(fileURLWithPath: notesFolder, isDirectory: true) }
        return Paths.defaultNotesDir
    }

    func isExcluded(host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        for raw in excludedDomains {
            let d = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if d.isEmpty { continue }
            if host == d || host.hasSuffix("." + d) { return true }
        }
        return false
    }
}

final class Settings: ObservableObject, @unchecked Sendable {
    static let shared = Settings()
    private let lock = NSLock()
    private var stored = AppSettings()

    @Published private(set) var published = AppSettings()

    /// Thread-safe snapshot.
    var value: AppSettings {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    private init() {
        if let data = try? Data(contentsOf: Paths.settingsFile),
           let s = try? JSONDecoder.iso.decode(AppSettings.self, from: data) {
            stored = s
        }
        published = stored
    }

    func reloadFromDisk() {
        var s = AppSettings()
        if let data = try? Data(contentsOf: Paths.settingsFile),
           let decoded = try? JSONDecoder.iso.decode(AppSettings.self, from: data) {
            s = decoded
        }
        lock.lock(); stored = s; lock.unlock()
        publish(s)
    }

    func update(_ change: (inout AppSettings) -> Void) {
        lock.lock()
        change(&stored)
        let snapshot = stored
        lock.unlock()
        save(snapshot)
        publish(snapshot)
    }

    private func publish(_ s: AppSettings) {
        if Thread.isMainThread { published = s } else { DispatchQueue.main.async { self.published = s } }
    }

    private func save(_ s: AppSettings) {
        Paths.ensure(Paths.root)
        if let data = try? JSONEncoder.pretty.encode(s) {
            try? data.write(to: Paths.settingsFile, options: .atomic)
        }
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

enum Fmt {
    static func day(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "today" }
        if cal.isDateInYesterday(date) { return "yesterday" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = cal.component(.year, from: date) == cal.component(.year, from: now) ? "d MMM" : "d MMM yyyy"
        return f.string(from: date)
    }

    static func onDay(_ date: Date) -> String {
        let d = day(date)
        return (d == "today" || d == "yesterday") ? d : "on \(d)"
    }

    /// Strips characters Felix doesn't want in UI text: Unicode dashes and dot separators.
    static func clean(_ s: String) -> String {
        var out = s
        for ch in ["\u{2014}", "\u{2013}", "\u{2012}", "\u{2011}", "\u{2010}", "\u{2015}", "\u{2212}"] {
            out = out.replacingOccurrences(of: ch, with: "-")
        }
        for ch in ["\u{00B7}", "\u{2022}", "\u{2027}", "\u{30FB}", "\u{2219}"] {
            out = out.replacingOccurrences(of: ch, with: ",")
        }
        return out
    }
}

/// Normalizes page URLs so the same page maps to one index entry.
enum URLKey {
    static let trackingParams: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
        "gclid", "fbclid", "mc_cid", "mc_eid", "ref_src", "igshid",
    ]

    static func key(for url: URL) -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        c.fragment = nil
        c.scheme = c.scheme?.lowercased()
        c.host = c.host?.lowercased()
        if let items = c.queryItems {
            let kept = items.filter { !trackingParams.contains($0.name.lowercased()) }
            c.queryItems = kept.isEmpty ? nil : kept
        }
        var s = c.string ?? url.absoluteString
        if s.hasSuffix("/") && (c.path.count > 1) { s.removeLast() }
        return s
    }

    static func fileKey(_ url: URL) -> String {
        url.standardizedFileURL.absoluteString
    }

    static func isIndexableWeb(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased() else { return false }
        guard scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host, !host.isEmpty else { return false }
        return true
    }
}
