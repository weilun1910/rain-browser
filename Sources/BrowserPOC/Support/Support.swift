import CryptoKit
import Foundation
import os

let appLog = Logger(subsystem: "local.browserpoc", category: "app")

enum Paths {
    /// Set by the self test so nothing touches the real support folder.
    nonisolated(unsafe) static var overrideRoot: URL?

    static var root: URL {
        if let overrideRoot { return overrideRoot }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(AppIdentity.supportFolder, isDirectory: true)
    }
    static var stateFile: URL { root.appendingPathComponent("state.json") }
    static var settingsFile: URL { root.appendingPathComponent("settings.json") }
    static var indexFile: URL { root.appendingPathComponent("index.sqlite") }
    static var defaultNotesDir: URL { root.appendingPathComponent("Notes", isDirectory: true) }
    static var tmpDir: URL { root.appendingPathComponent("tmp", isDirectory: true) }

    /// A stable WebKit store ID for a --data-dir folder, so each profile keeps its own cookies.
    static func storeID(for dir: URL) -> UUID {
        let digest = SHA256.hash(data: Data(dir.standardizedFileURL.path.utf8))
        var b = Array(digest.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x40
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    static func ensure(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

/// The app writes only inside its own support folder and to .md files inside the chosen
/// notes folders. Chrome's files and everything else are read-only.
enum FileSafety {
    static func isInside(_ url: URL, _ dir: URL) -> Bool {
        let a = url.standardizedFileURL.resolvingSymlinksInPath().path
        var d = dir.standardizedFileURL.resolvingSymlinksInPath().path
        if !d.hasSuffix("/") { d += "/" }
        return a.hasPrefix(d)
    }

    /// Folder names the notes tree never shows or writes into.
    static func isSkippedFolder(_ name: String) -> Bool {
        name.hasPrefix(".") || name == "node_modules" || name.lowercased().hasSuffix(".nosync")
    }

    /// The chosen root that holds this URL, if it's in a visible part of the tree.
    static func notesRoot(for url: URL, roots: [URL]) -> URL? {
        for r in roots where isInside(url, r) {
            let rootPath = r.standardizedFileURL.resolvingSymlinksInPath().path
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            let rel = path.dropFirst(rootPath.count).split(separator: "/").map(String.init)
            if rel.isEmpty { return nil }
            if rel.dropLast().contains(where: isSkippedFolder) { return nil }
            if rel.last?.hasPrefix(".") == true { return nil }
            return r
        }
        return nil
    }

    static func canWriteNote(_ url: URL, roots: [URL]? = nil) -> Bool {
        guard url.pathExtension.lowercased() == "md" else { return false }
        return notesRoot(for: url, roots: roots ?? Settings.shared.value.notesRoots) != nil
    }
}

struct AppSettings: Codable, Equatable {
    /// Folders whose .md files are the browser's notes. Empty means the fallback folder.
    var notesFolders: [String] = []
    /// Where new notes go when no folder is selected in the tree. Nil means the first notes folder.
    var newNotesFolder: String?
    var excludedDomains: [String] = AppSettings.defaultExcluded
    /// Sites you write on. Their pages go under Notes / Docs. Notion and Google Docs are built in.
    var writingSites: [String] = AppSettings.defaultWritingSites
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

    static let defaultWritingSites: [String] = [
        "coda.io", "quip.com", "paper.dropbox.com", "overleaf.com", "hackmd.io", "craft.do",
        "*.atlassian.net/wiki", "figma.com",
    ]

    enum CodingKeys: String, CodingKey {
        case notesFolders, newNotesFolder, excludedDomains, writingSites, threshold, keywordWeight, semanticWeight,
             entityWeight, showScores, rightPanelOpen, firstRunDone, chromeImportedAt, chromeSummary
        case markdownRoots // older name, read once for migration
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        notesFolders = try c.decodeIfPresent([String].self, forKey: .notesFolders)
            ?? c.decodeIfPresent([String].self, forKey: .markdownRoots) ?? []
        newNotesFolder = try c.decodeIfPresent(String.self, forKey: .newNotesFolder)
        excludedDomains = try c.decodeIfPresent([String].self, forKey: .excludedDomains) ?? d.excludedDomains
        writingSites = try c.decodeIfPresent([String].self, forKey: .writingSites) ?? d.writingSites
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

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(notesFolders, forKey: .notesFolders)
        try c.encodeIfPresent(newNotesFolder, forKey: .newNotesFolder)
        try c.encode(excludedDomains, forKey: .excludedDomains)
        try c.encode(writingSites, forKey: .writingSites)
        try c.encode(threshold, forKey: .threshold)
        try c.encode(keywordWeight, forKey: .keywordWeight)
        try c.encode(semanticWeight, forKey: .semanticWeight)
        try c.encode(entityWeight, forKey: .entityWeight)
        try c.encode(showScores, forKey: .showScores)
        try c.encode(rightPanelOpen, forKey: .rightPanelOpen)
        try c.encode(firstRunDone, forKey: .firstRunDone)
        try c.encodeIfPresent(chromeImportedAt, forKey: .chromeImportedAt)
        try c.encodeIfPresent(chromeSummary, forKey: .chromeSummary)
    }

    /// True when no folder is chosen and the app's own Notes folder stands in.
    var usesFallbackNotes: Bool { notesFolders.isEmpty }

    /// The folders you chose, or the app's own, then the space folders and the folders linked
    /// into them. A space folder that's already inside a chosen folder isn't listed twice.
    var notesRoots: [URL] {
        var out = notesFolders.isEmpty ? [Paths.defaultNotesDir] : notesFolders.map { URL(fileURLWithPath: $0, isDirectory: true) }
        for r in SpaceFolders.notesRoots where !out.contains(where: { $0.standardizedFileURL.path == r.standardizedFileURL.path || FileSafety.isInside(r, $0) }) {
            out.append(r)
        }
        return out
    }

    /// The folder new notes go in when nothing is selected in the tree.
    var defaultNewNotesFolder: URL {
        let roots = notesRoots
        if let p = newNotesFolder {
            let u = URL(fileURLWithPath: p, isDirectory: true)
            if roots.contains(where: { FileSafety.isInside(u, $0) || $0.standardizedFileURL.path == u.standardizedFileURL.path }) { return u }
        }
        return roots[0]
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
        if let s = SavedFile.read(AppSettings.self, from: Paths.settingsFile, label: "settings") {
            stored = s
        }
        published = stored
    }

    func reloadFromDisk() {
        var s = AppSettings()
        if let decoded = SavedFile.read(AppSettings.self, from: Paths.settingsFile, label: "settings") {
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
            SavedFile.write(data, to: Paths.settingsFile)
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
        // One entry per Google Doc and per Notion page, whatever tab or view is in the URL.
        if let doc = WritingKey.googleDoc(url) { return "https://docs.google.com/\(doc.type)/d/\(doc.id)" }
        if WritingKey.isNotion(url), var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            c.query = nil; c.fragment = nil
            c.host = c.host?.lowercased()
            return c.string ?? url.absoluteString
        }
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


/// Which Related section an item belongs in.
enum CardSection: String, CaseIterable {
    case sites, docs

    var title: String { self == .sites ? "Sites" : "Notes / Docs" }
}

enum WritingKey {
    static let typedThreshold = 200

    static func googleDoc(_ url: URL) -> (type: String, id: String)? {
        guard url.host?.lowercased() == "docs.google.com" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard let first = parts.first, ["document", "spreadsheets", "presentation"].contains(first) else { return nil }
        // /document/d/<id>/edit or /document/u/0/d/<id>/edit
        guard let d = parts.firstIndex(of: "d"), d + 1 < parts.count else { return nil }
        let id = parts[d + 1]
        guard id.count >= 10, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return (first, id)
    }

    static func isNotion(_ url: URL) -> Bool {
        guard let h = url.host?.lowercased() else { return false }
        return h == "notion.so" || h.hasSuffix(".notion.so") || h == "notion.site" || h.hasSuffix(".notion.site")
    }

    /// Typing counts are kept per document for Docs and Notion and per page elsewhere.
    static func key(_ url: URL) -> String { URLKey.key(for: url) }

    /// Matches entries like "coda.io", "*.atlassian.net/wiki" or "paper.dropbox.com".
    static func matches(_ url: URL, pattern raw: String) -> Bool {
        var p = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if p.isEmpty { return false }
        if p.hasPrefix("https://") { p.removeFirst(8) } else if p.hasPrefix("http://") { p.removeFirst(7) }
        var hostPart = p
        var pathPart = ""
        if let slash = p.firstIndex(of: "/") { hostPart = String(p[..<slash]); pathPart = String(p[slash...]) }
        if hostPart.hasPrefix("*.") { hostPart.removeFirst(2) }
        guard let host = url.host?.lowercased(), host == hostPart || host.hasSuffix("." + hostPart) else { return false }
        if pathPart.isEmpty || pathPart == "/" { return true }
        return url.path.lowercased().hasPrefix(pathPart)
    }

    /// Built-in rules plus the editable list. Typed characters and manual choices are checked by the caller.
    static func isWritingSite(_ url: URL, list: [String]) -> Bool {
        if isNotion(url) || googleDoc(url) != nil { return true }
        return list.contains { matches(url, pattern: $0) }
    }

    static func section(source: SourceType, url: String, typed: Int, override: CardSection?, writingSites: [String]) -> CardSection {
        if let override { return override }
        if source.isWriting { return .docs }
        guard let u = URL(string: url) else { return .sites }
        if isWritingSite(u, list: writingSites) { return .docs }
        if typed >= typedThreshold { return .docs }
        return .sites
    }
}

/// Google Docs draws text on a canvas, so the app asks Google for the plain export instead,
/// from inside Felix's own tab (the same as File > Download).
enum DocsExport {
    static func url(for doc: URL) -> URL? {
        guard let d = WritingKey.googleDoc(doc) else { return nil }
        switch d.type {
        case "document": return URL(string: "https://docs.google.com/document/d/\(d.id)/export?format=txt")
        case "spreadsheets": return URL(string: "https://docs.google.com/spreadsheets/d/\(d.id)/export?format=csv")
        case "presentation": return URL(string: "https://docs.google.com/presentation/d/\(d.id)/export/txt")
        default: return nil
        }
    }
}
