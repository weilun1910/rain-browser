import Foundation

/// What AI clients may see and do. Lives in `mcp.json` in the support folder, next to
/// settings.json, so the app's own settings file never changes shape.
struct MCPSettings: Codable, Equatable {
    /// Source ids hidden from AI clients: "note", "web", "chrome", "docs", "searches", or any
    /// source the index adds later. Past searches start hidden.
    var hiddenSources: [String] = [MCPSources.searches]
    /// The focused item, the space, its open tabs and the Related cards on screen.
    var shareCurrentContext = true
    /// create_note, append_to_note and add_link. Off until Felix turns them on.
    var allowWrites = false
    /// The served log in mcp-log.jsonl.
    var keepLog = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MCPSettings()
        hiddenSources = try c.decodeIfPresent([String].self, forKey: .hiddenSources) ?? d.hiddenSources
        // Before the Engine's sources, one "docs" switch covered Google Docs and Notion.
        if let i = hiddenSources.firstIndex(of: "docs") {
            hiddenSources.remove(at: i)
            for s in [MCPSources.gdocs, MCPSources.notion] where !hiddenSources.contains(s) { hiddenSources.append(s) }
        }
        shareCurrentContext = try c.decodeIfPresent(Bool.self, forKey: .shareCurrentContext) ?? d.shareCurrentContext
        allowWrites = try c.decodeIfPresent(Bool.self, forKey: .allowWrites) ?? d.allowWrites
        keepLog = try c.decodeIfPresent(Bool.self, forKey: .keepLog) ?? d.keepLog
    }

    static func file(_ root: URL) -> URL { root.appendingPathComponent("mcp.json") }

    static func load(root: URL) -> MCPSettings {
        guard let s = SavedFile.read(MCPSettings.self, from: file(root), label: "AI client privacy settings") else {
            return MCPSettings()
        }
        return s
    }

    func save(root: URL) {
        Paths.ensure(root)
        if let data = try? JSONEncoder.pretty.encode(self) { SavedFile.write(data, to: Self.file(root)) }
    }

    func isHidden(_ source: String) -> Bool { hiddenSources.contains(source) }
}

/// Source ids as AI clients and the Settings switches see them. They're the index's own source
/// names, plus "searches" for past searches.
enum MCPSources {
    static let notes = "note"
    static let web = "web"
    static let chrome = "chrome"
    static let gdocs = "gdocs"
    static let notion = "notion"
    static let granola = "granola"
    static let searches = "searches"

    /// The switches Settings always shows, in order. Sources the index adds later show after these.
    static let builtIn: [(id: String, label: String, detail: String)] = [
        (notes, "Notes", "Markdown notes in your notes folders"),
        (web, "Pages you read here", "Pages captured while you browse in this app"),
        (chrome, "Chrome history", "Pages imported from Chrome"),
        (gdocs, "Google Docs", "Docs, Sheets and Slides, synced and opened in the browser"),
        (notion, "Notion", "Pages from the Notion app, and Notion pages opened in the browser"),
        (granola, "Granola meetings", "Meeting notes synced from Granola"),
        (searches, "Past searches", "What you typed into search, here and in Chrome"),
    ]

    static func label(_ id: String) -> String {
        builtIn.first { $0.id == id }?.label ?? id.prefix(1).uppercased() + id.dropFirst()
    }

    /// Notes used to be stored as "markdown".
    static func normalized(_ source: String) -> String { source == "markdown" ? notes : source }

    static func isDocURL(_ url: URL) -> Bool { WritingKey.isNotion(url) || WritingKey.googleDoc(url) != nil }

    /// Which switch covers a document's URL, whichever source it came through: a Google Doc read
    /// in the browser and the same doc from the Google Docs sync share one switch.
    static func docSwitch(_ url: URL) -> String? {
        if WritingKey.googleDoc(url) != nil { return gdocs }
        if WritingKey.isNotion(url) { return notion }
        return nil
    }

    /// The index sources an id filters on. Google Docs and Notion also match pages read in the browser.
    static func indexSources(_ id: String) -> Set<String> {
        switch id {
        case notes: return ["note", "markdown"]
        case gdocs: return [gdocs, web, chrome]
        case notion: return [notion, web, chrome]
        case "docs": return [gdocs, notion, web, chrome]
        default: return [id]
        }
    }

    /// Whether an item matches a requested source id.
    static func matches(_ id: String, source rawSource: String, url: String) -> Bool {
        let source = normalized(rawSource)
        if source == id { return true }
        guard [web, chrome].contains(source), let u = URL(string: url) else { return false }
        if id == "docs" { return isDocURL(u) }
        return docSwitch(u) == id
    }
}

/// Decides what an AI client may see. Every item, tab and URL that goes out passes through here.
struct MCPPrivacy {
    let settings: MCPSettings
    let app: AppSettings

    enum Decision: Equatable {
        case allowed
        case hidden(String)
    }

    /// Notes always pass the URL checks: their URLs are file paths on Felix's Mac.
    func check(source rawSource: String, url: String) -> Decision {
        let source = MCPSources.normalized(rawSource)
        if settings.isHidden(source) { return .hidden("source \(source) is hidden") }
        guard let u = URL(string: url) else { return source == MCPSources.notes ? .allowed : .hidden("not a URL") }
        if u.isFileURL { return .allowed }
        if let sw = MCPSources.docSwitch(u), settings.isHidden(sw) { return .hidden("\(MCPSources.label(sw)) is hidden") }
        return urlDecision(u)
    }

    func allows(source: String, url: String) -> Bool { check(source: source, url: url) == .allowed }

    /// The app's exclude list, plus the URL filter's rules for sign-in links, tokens and similar.
    /// Doc ids in Google Docs and Notion paths are names for a document, not secrets, so the
    /// token check reads the query string only.
    func urlDecision(_ u: URL) -> Decision {
        guard let scheme = u.scheme?.lowercased() else { return .hidden("no scheme") }
        if scheme == "file" { return .allowed }
        guard scheme == "http" || scheme == "https" else { return .hidden("not a web page") }
        if app.isExcluded(host: u.host) { return .hidden("on the exclude list") }
        let query = u.query ?? ""
        let pathQuery = (u.path + "?" + query).lowercased()
        for w in URLFilter.sensitiveSubstrings where pathQuery.contains(w) { return .hidden("sensitive word: \(w)") }
        for t in URLFilter.tokens(u.path + "?" + query) {
            for w in URLFilter.sensitiveTokens where t == w || (t.count > w.count && t.hasSuffix(w) && (w == "key" || w == "code")) {
                return .hidden("sensitive word: \(w)")
            }
        }
        if !query.isEmpty && URLFilter.looksLikeToken(query) { return .hidden("looks like a one-time token") }
        return .allowed
    }

    func allowsSearches() -> Bool { !settings.isHidden(MCPSources.searches) }
}

/// What was served to which client. One JSON object per line in mcp-log.jsonl.
struct MCPLogEntry: Codable, Identifiable {
    var id: String { "\(at.timeIntervalSince1970)-\(name)-\(served)" }
    let at: Date
    let client: String
    /// tool, resource or prompt
    let kind: String
    let name: String
    /// The query, item or URI asked for, shortened.
    let detail: String
    let served: Int
    let titles: [String]
    let hidden: Int
    /// The MCP version the client spoke, like 2026-07-28 or 2025-06-18.
    var protocolVersion: String? = nil
}

enum MCPLog {
    static func file(_ root: URL) -> URL { root.appendingPathComponent("mcp-log.jsonl") }
    static let maxBytes = 1_000_000

    static func append(_ e: MCPLogEntry, root: URL) {
        let url = file(root)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard var line = try? enc.encode(e) else { return }
        line.append(0x0A)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            if size > UInt64(maxBytes) {
                try? h.close()
                trim(url)
                append(e, root: root)
                return
            }
            try? h.write(contentsOf: line)
        } else {
            Paths.ensure(root)
            try? line.write(to: url, options: .atomic)
        }
    }

    /// Keeps the newer half when the file grows past the cap.
    private static func trim(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let lines = data.split(separator: 0x0A)
        let kept = lines.suffix(lines.count / 2)
        var out = Data()
        for l in kept { out.append(contentsOf: l); out.append(0x0A) }
        try? out.write(to: url, options: .atomic)
    }

    static func read(root: URL, limit: Int = 200) -> [MCPLogEntry] {
        guard let data = try? Data(contentsOf: file(root)) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let lines = data.split(separator: 0x0A).suffix(limit)
        return lines.compactMap { try? dec.decode(MCPLogEntry.self, from: Data($0)) }.reversed()
    }

    static func clear(root: URL) {
        try? FileManager.default.removeItem(at: file(root))
    }
}
