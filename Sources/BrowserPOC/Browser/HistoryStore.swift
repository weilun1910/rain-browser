import Foundation

/// Every page visit, in its own `history.sqlite`. The index keeps one row per page for
/// resurfacing. This keeps each visit, for the history view, autocomplete and Ctrl-Tab.
@MainActor
final class HistoryStore: ObservableObject {
    struct Visit: Identifiable, Equatable {
        let id: Int64
        let url: String
        let title: String
        let host: String
        let at: Date
        let spaceID: UUID?
    }

    private static var _shared: HistoryStore?
    static var shared: HistoryStore {
        if let s = _shared, s.path == file.path { return s }
        let s = HistoryStore(path: file.path)
        _shared = s
        return s
    }
    static var file: URL { Paths.root.appendingPathComponent("history.sqlite") }

    /// Bumped on every change, so views can refresh.
    @Published private(set) var generation = 0
    let path: String
    private let db: SQLiteDB?
    /// The same address again within this window updates the last visit instead of adding one.
    static let mergeWindow: TimeInterval = 10 * 60

    init(path: String) {
        self.path = path
        Paths.ensure(URL(fileURLWithPath: path).deletingLastPathComponent())
        db = try? SQLiteDB(path: path)
        try? db?.exec("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS visits(id INTEGER PRIMARY KEY, url TEXT NOT NULL, title TEXT NOT NULL DEFAULT '',
                host TEXT NOT NULL DEFAULT '', at REAL NOT NULL, space TEXT);
            CREATE INDEX IF NOT EXISTS visits_at ON visits(at);
            CREATE INDEX IF NOT EXISTS visits_host ON visits(host);
            CREATE INDEX IF NOT EXISTS visits_url ON visits(url);
            """)
    }

    static func host(_ u: URL) -> String {
        var h = u.host?.lowercased() ?? ""
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    func record(url: URL, title: String, spaceID: UUID?, at: Date = Date()) {
        guard let db, URLKey.isIndexableWeb(url) else { return }
        let s = url.absoluteString
        let last = try? db.query("SELECT id, at FROM visits WHERE url = ? ORDER BY at DESC LIMIT 1", [s]) { ($0.int(0), $0.double(1)) }.first
        if let last, at.timeIntervalSince1970 - last.1 < Self.mergeWindow {
            _ = try? db.run("UPDATE visits SET at = ?, title = CASE WHEN ? = '' THEN title ELSE ? END WHERE id = ?",
                            [at.timeIntervalSince1970, title, title, last.0])
        } else {
            _ = try? db.run("INSERT INTO visits(url, title, host, at, space) VALUES(?, ?, ?, ?, ?)",
                            [s, title, Self.host(url), at.timeIntervalSince1970, spaceID?.uuidString])
        }
        generation += 1
    }

    /// Titles often arrive after the page finishes.
    func updateTitle(url: URL, title: String) {
        guard let db, !title.isEmpty else { return }
        let n = (try? db.run("UPDATE visits SET title = ? WHERE id = (SELECT id FROM visits WHERE url = ? ORDER BY at DESC LIMIT 1) AND title != ?",
                             [title, url.absoluteString, title])) ?? 0
        if n > 0 { generation += 1 }
    }

    private func visit(_ s: Statement) -> Visit {
        Visit(id: s.int(0), url: s.text(1), title: s.text(2), host: s.text(3), at: Date(timeIntervalSince1970: s.double(4)),
              spaceID: s.optText(5).flatMap(UUID.init(uuidString:)))
    }

    /// Newest first. With a query, every word has to appear in the title or address.
    func visits(matching q: String = "", limit: Int = 300) -> [Visit] {
        guard let db else { return [] }
        let words = q.lowercased().split(whereSeparator: { $0 == " " }).map(String.init).filter { !$0.isEmpty }
        var sql = "SELECT id, url, title, host, at, space FROM visits"
        var args: [Any?] = []
        if !words.isEmpty {
            sql += " WHERE " + words.map { _ in "(lower(title) LIKE ? OR lower(url) LIKE ?)" }.joined(separator: " AND ")
            for w in words { args.append("%\(w)%"); args.append("%\(w)%") }
        }
        sql += " ORDER BY at DESC LIMIT ?"
        args.append(limit)
        return (try? db.query(sql, args, visit)) ?? []
    }

    var count: Int { Int((try? db?.scalarInt("SELECT COUNT(*) FROM visits")) ?? 0) }

    func delete(_ id: Int64) {
        _ = try? db?.run("DELETE FROM visits WHERE id = ?", [id])
        generation += 1
    }

    /// Clears visits since a date, or everything.
    func clear(since: Date? = nil) {
        if let since { _ = try? db?.run("DELETE FROM visits WHERE at >= ?", [since.timeIntervalSince1970]) } else { _ = try? db?.run("DELETE FROM visits") }
        generation += 1
    }

    /// The most visited hosts that start with what's typed, for inline autocomplete.
    func hosts(prefix: String, limit: Int = 5) -> [(host: String, visits: Int)] {
        let p = prefix.lowercased()
        guard let db, !p.isEmpty else { return [] }
        return (try? db.query("SELECT host, COUNT(*) AS n FROM visits WHERE host LIKE ? ESCAPE '\\' GROUP BY host ORDER BY n DESC LIMIT ?",
                              [p.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%", limit]) { ($0.text(0), Int($0.int(1))) }) ?? []
    }
}
