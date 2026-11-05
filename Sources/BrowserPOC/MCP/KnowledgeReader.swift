import Foundation
import SQLite3

/// One entry in the index, as AI clients see it. `source` is the raw source name, so sources the
/// index adds later come through without code changes here.
struct KItem {
    let id: Int64
    let key: String
    let source: String
    let url: String
    let title: String
    let description: String
    let project: String?
    let root: String?
    let firstSeen: Double
    let lastSeen: Double
    let visitCount: Int
    let dwell: Double
    let lastOpened: Double
    let hasText: Bool
    let mtime: Double

    var isNote: Bool { MCPSources.normalized(source) == MCPSources.notes }
    var fileURL: URL? { isNote ? URL(string: url).flatMap { $0.isFileURL ? $0 : nil } : nil }
    /// The latest of opened, visited and edited.
    var lastActive: Double { max(lastOpened, lastSeen, mtime) }

    /// note, doc or page. Docs are Google Docs, Notion and sites Felix writes on.
    func kind(writingSites: [String]) -> String {
        if isNote { return "note" }
        if let u = URL(string: url), WritingKey.isWritingSite(u, list: writingSites) { return "doc" }
        if !["web", "chrome"].contains(source) { return source }
        return "page"
    }
}

/// Read-only access to the index, the saved browser state and the notes folders, for `--mcp`.
/// Opens its own SQLite connection with SQLITE_OPEN_READONLY. The index is in WAL mode, so this
/// works while the app is running and writing.
final class KnowledgeReader {
    let root: URL
    private(set) var db: SQLiteDB?

    init(root: URL) {
        self.root = root
        open()
    }

    var indexURL: URL { root.appendingPathComponent("index.sqlite") }
    var indexExists: Bool { FileManager.default.fileExists(atPath: indexURL.path) }

    private func open() {
        guard indexExists else { return }
        db = try? SQLiteDB(path: indexURL.path, readOnly: true)
    }

    /// The index may appear after the server starts (first launch of the app).
    func reopenIfNeeded() {
        if db == nil && indexExists { open() }
    }

    func close() { db = nil }

    /// Changes whenever another connection commits to the index.
    func dataVersion() -> Int64 {
        guard let db else { return -1 }
        return (try? db.scalarInt("PRAGMA data_version")) ?? -1
    }

    // MARK: Items

    static let columns = "id, key, source, url, title, description, project, root, first_seen, last_seen, visit_count, dwell, last_opened, has_text, mtime"

    static func item(_ s: Statement) -> KItem {
        KItem(id: s.int(0), key: s.text(1), source: s.text(2), url: s.text(3), title: s.text(4), description: s.text(5),
              project: s.optText(6), root: s.optText(7), firstSeen: s.double(8), lastSeen: s.double(9),
              visitCount: Int(s.int(10)), dwell: s.double(11), lastOpened: s.double(12), hasText: s.int(13) != 0, mtime: s.double(14))
    }

    func items(where clause: String, _ args: [Any?] = []) -> [KItem] {
        guard let db else { return [] }
        return (try? db.query("SELECT \(Self.columns) FROM docs WHERE \(clause)", args, Self.item)) ?? []
    }

    func item(id: Int64) -> KItem? { items(where: "id = ?", [id]).first }
    func item(key: String) -> KItem? { items(where: "key = ?", [key]).first }

    func items(ids: [Int64]) -> [Int64: KItem] {
        var out: [Int64: KItem] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 300) {
            let part = Array(ids[chunk..<min(ids.count, chunk + 300)])
            let ph = Array(repeating: "?", count: part.count).joined(separator: ",")
            for it in items(where: "id IN (\(ph))", part) { out[it.id] = it }
        }
        return out
    }

    /// Finds an item from whatever an assistant passes: an id, a URL, a note path, a file URL or a key.
    func resolve(_ raw: String) -> KItem? {
        let ref = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if ref.isEmpty { return nil }
        if let n = Int64(ref) { return item(id: n) }
        if ref.hasPrefix("browser://item/"), let n = Int64(ref.dropFirst("browser://item/".count)) { return item(id: n) }
        if let hit = item(key: ref) { return hit }
        if ref.hasPrefix("/") || ref.hasPrefix("~") {
            let path = (ref as NSString).expandingTildeInPath
            return item(key: URLKey.fileKey(URL(fileURLWithPath: path)))
        }
        if let u = URL(string: ref), let scheme = u.scheme?.lowercased() {
            if scheme == "file" { return item(key: URLKey.fileKey(u)) }
            if scheme == "http" || scheme == "https" {
                if let hit = item(key: URLKey.key(for: u)) { return hit }
                return items(where: "url = ?", [ref]).first
            }
        }
        // A note's title or file name.
        return items(where: "source IN ('note','markdown') AND title = ? COLLATE NOCASE ORDER BY mtime DESC LIMIT 1", [ref]).first
    }

    func body(id: Int64) -> String {
        guard let db else { return "" }
        return (try? db.query("SELECT body FROM docs WHERE id = ?", [id]) { $0.text(0) })?.first ?? ""
    }

    func passages(id: Int64) -> [(idx: Int, text: String)] {
        guard let db else { return [] }
        return (try? db.query("SELECT idx, text FROM passages WHERE doc_id = ? ORDER BY idx", [id]) { (Int($0.int(0)), $0.text(1)) }) ?? []
    }

    func entities(id: Int64) -> [(name: String, kind: String, count: Int)] {
        guard let db else { return [] }
        return (try? db.query("SELECT display, kind, count FROM entities WHERE doc_id = ? ORDER BY count DESC", [id]) {
            ($0.text(0), $0.text(1), Int($0.int(2)))
        }) ?? []
    }

    func counts() -> [(source: String, total: Int, withText: Int)] {
        guard let db else { return [] }
        let rows = (try? db.query("SELECT source, count(*), sum(has_text) FROM docs GROUP BY source") {
            (MCPSources.normalized($0.text(0)), Int($0.int(1)), Int($0.int(2)))
        }) ?? []
        var merged: [String: (Int, Int)] = [:]
        for (s, t, w) in rows { merged[s] = ((merged[s]?.0 ?? 0) + t, (merged[s]?.1 ?? 0) + w) }
        return merged.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.source < $1.source }
    }

    /// Google Docs and Notion pages, which Settings lets Felix hide on their own.
    func docCount() -> Int {
        guard let db else { return 0 }
        return Int((try? db.scalarInt("""
            SELECT count(*) FROM docs WHERE source NOT IN ('note','markdown')
            AND (url LIKE 'https://docs.google.com/%' OR url LIKE '%notion.so/%' OR url LIKE '%notion.site/%')
            """)) ?? 0)
    }

    func lastIndexed() -> Double {
        guard let db else { return 0 }
        return (try? db.query("SELECT max(indexed_at) FROM docs") { $0.double(0) })?.first ?? 0
    }

    func searchCount() -> Int {
        guard let db else { return 0 }
        return Int((try? db.scalarInt("SELECT count(*) FROM searches")) ?? 0)
    }

    func typed(key: String) -> Int {
        guard let db else { return 0 }
        return Int((try? db.scalarInt("SELECT chars FROM typing WHERE key = ?", [key])) ?? 0)
    }

    func override(key: String) -> CardSection? {
        guard let db else { return nil }
        return (try? db.query("SELECT section FROM overrides WHERE key = ?", [key]) { CardSection(rawValue: $0.text(0)) })?.first ?? nil
    }

    /// Sites or Notes / Docs, the same rule the Related panel uses.
    func section(_ it: KItem, writingSites: [String]) -> CardSection {
        let src = SourceType(rawValue: MCPSources.normalized(it.source)) ?? .web
        return WritingKey.section(source: src, url: it.url, typed: typed(key: it.key), override: override(key: it.key), writingSites: writingSites)
    }

    func recentSearches(since: Double, limit: Int) -> [(query: String, at: Double, source: String)] {
        guard let db else { return [] }
        return (try? db.query("SELECT query, at, source FROM searches WHERE at >= ? ORDER BY at DESC LIMIT ?", [since, limit]) {
            ($0.text(0), $0.double(1), $0.text(2))
        }) ?? []
    }

    // MARK: Search

    struct SearchHit {
        let item: KItem
        let bm25: Double
        let passage: String
        let passageID: Int64
    }

    /// FTS5 over every passage. All words must match first; if that finds too little, any word may.
    func ftsSearch(_ query: String, candidates: Int = 400) -> [SearchHit] {
        guard let db else { return [] }
        let words = TextAnalysis.rawWords(query).map { TextAnalysis.fold($0) }.filter { !$0.isEmpty }.prefix(12)
        guard !words.isEmpty else { return [] }
        let quoted = words.map { "\"" + $0.replacingOccurrences(of: "\"", with: "") + "\"" }
        var exprs = [quoted.joined(separator: " ")]
        if words.count > 1 {
            let content = words.filter { TextAnalysis.isContentWord($0) }
            let any = (content.isEmpty ? Array(words) : content).map { "\"" + $0 + "\"" }
            exprs.append(any.joined(separator: " OR "))
        }
        if let last = quoted.last, words.count <= 3 {
            // A word still being typed, or a plural.
            exprs.append((quoted.dropLast() + [last + "*"]).joined(separator: " "))
        }
        var best: [Int64: (Double, Int64, String)] = [:]
        for (i, expr) in exprs.enumerated() {
            let rows = (try? db.query("""
                SELECT p.doc_id, p.id, p.text, bm25(pfts, 4.0, 1.0) FROM pfts JOIN passages p ON p.id = pfts.rowid
                WHERE pfts MATCH ? ORDER BY bm25(pfts, 4.0, 1.0) LIMIT ?
                """, [expr, candidates]) { ($0.int(0), $0.int(1), $0.text(2), $0.double(3)) }) ?? []
            // Looser queries count for less.
            let penalty = i == 0 ? 1.0 : 0.6
            for (did, pid, text, r) in rows {
                let score = -r * penalty
                if let old = best[did], old.0 >= score { continue }
                best[did] = (score, pid, text)
            }
            if best.count >= 25 { break }
        }
        let metas = items(ids: Array(best.keys))
        return best.compactMap { did, v in
            metas[did].map { SearchHit(item: $0, bm25: v.0, passage: v.2, passageID: v.1) }
        }
    }

    /// Passage vectors for a few items, for reranking by meaning.
    func vectors(ids: [Int64]) -> [Int64: [[Float]]] {
        guard let db, !ids.isEmpty else { return [:] }
        var out: [Int64: [[Float]]] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 300) {
            let part = Array(ids[chunk..<min(ids.count, chunk + 300)])
            let ph = Array(repeating: "?", count: part.count).joined(separator: ",")
            let rows = (try? db.query("SELECT doc_id, vec FROM passages WHERE vec IS NOT NULL AND doc_id IN (\(ph))", part) { ($0.int(0), $0.blob(1)) }) ?? []
            for (d, b) in rows { if let b { out[d, default: []].append(Embedder.decode(b)) } }
        }
        return out
    }

    // MARK: Notes that mention an item

    /// Notes whose text contains any of the needles (a URL, a file name in a wikilink).
    func notesMentioning(_ needles: [String], excluding: Int64) -> [KItem] {
        guard let db, !needles.isEmpty else { return [] }
        let clause = needles.map { _ in "instr(body, ?) > 0" }.joined(separator: " OR ")
        let ids = (try? db.query("SELECT id FROM docs WHERE source IN ('note','markdown') AND id != ? AND (\(clause)) LIMIT 50",
                                 [excluding] + needles) { $0.int(0) }) ?? []
        return Array(items(ids: ids).values)
    }

    /// Every note's id and file name without .md, lowercased, for resolving [[wikilinks]].
    func noteNames() -> [String: Int64] {
        var out: [String: Int64] = [:]
        for it in items(where: "source IN ('note','markdown')") {
            if let u = it.fileURL { out[u.deletingPathExtension().lastPathComponent.lowercased()] = it.id }
            out[it.title.lowercased()] = out[it.title.lowercased()] ?? it.id
        }
        return out
    }

    // MARK: Files next to the index

    func appSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("settings.json")),
              let s = try? JSONDecoder.iso.decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    func mcpSettings() -> MCPSettings { MCPSettings.load(root: root) }

    func savedState() -> SavedState? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("state.json")) else { return nil }
        return try? JSONDecoder.iso.decode(SavedState.self, from: data)
    }

    func currentContext() -> CurrentContextFile? {
        guard let data = try? Data(contentsOf: CurrentContextFile.url(root)) else { return nil }
        return try? JSONDecoder.iso.decode(CurrentContextFile.self, from: data)
    }

    /// Notes folders as the app sees them. With none chosen, the app's own Notes folder.
    func notesRoots(_ s: AppSettings) -> [URL] {
        if s.notesFolders.isEmpty { return [root.appendingPathComponent("Notes", isDirectory: true)] }
        return s.notesFolders.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}
