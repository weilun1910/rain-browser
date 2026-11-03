import Foundation

enum SourceType: String, CaseIterable {
    case web, note, markdown, chrome
}

struct DocMeta {
    let id: Int64
    let key: String
    let source: SourceType
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
}

struct DocUpsert {
    var key: String
    var source: SourceType
    var url: String
    var title: String
    var description: String = ""
    var body: String = ""
    var project: String? = nil
    var root: String? = nil
    var firstSeen: Double
    var lastSeen: Double
    var visitCount: Int = 1
    var dwell: Double = 0
    var mtime: Double = 0
}

enum ContextKind { case page, note, file }

struct ContextInput {
    let key: String
    let title: String
    let text: String
    let kind: ContextKind
}

/// Everything about the context that can be computed without the database.
struct ContextAnalysis {
    let input: ContextInput
    let counts: TermCounts
    let vectors: [[Float]]
    let entities: [Entity]
    let nouns: Set<String>

    static func make(_ input: ContextInput) -> ContextAnalysis {
        let counts = TextAnalysis.termCounts(title: input.title, text: input.text)
        var vecs: [[Float]] = []
        let chunks = TextAnalysis.chunk(input.text, target: 700, maxChunks: 4)
        if let first = chunks.first {
            if let v = Embedder.shared.vector(input.title.isEmpty ? first : input.title + ". " + first) { vecs.append(v) }
            for c in chunks.dropFirst() { if let v = Embedder.shared.vector(c) { vecs.append(v) } }
        } else if !input.title.isEmpty, let v = Embedder.shared.vector(input.title) {
            vecs.append(v)
        }
        let ents = TextAnalysis.entities(input.title + "\n" + input.text)
        let nouns = TextAnalysis.nounKeys(input.title + "\n" + input.text)
        return ContextAnalysis(input: input, counts: counts, vectors: vecs, entities: ents, nouns: nouns)
    }
}

struct RankParams {
    var threshold: Double
    var keywordWeight: Double
    var semanticWeight: Double
    var entityWeight: Double
    var limit: Int = 5
    var now: Date = Date()
    var recentWindow: TimeInterval = 600
    /// Docs already on screen. They're scored even when slightly under the threshold so
    /// cards don't flicker in and out.
    var keepIDs: Set<Int64> = []

    static func fromSettings(_ s: AppSettings) -> RankParams {
        RankParams(threshold: s.threshold, keywordWeight: s.keywordWeight,
                   semanticWeight: s.semanticWeight, entityWeight: s.entityWeight)
    }
}

struct Match {
    let doc: DocMeta
    var keyword: Double
    var semantic: Double
    var entity: Double
    var score: Double
    var passage: String
    var sharedTerms: [String]
    var sharedEntities: [String]
    /// Shared terms that read as topics (nouns), for the reason line.
    var topicTerms: [String]
    var penalized: Bool
}

struct RetrievalResult {
    var matches: [Match] = []
    var kept: [Int64: Match] = [:]
    var terms: [String] = []
    var termDisplay: [String: String] = [:]
}

struct SourceCount {
    let source: SourceType
    let total: Int
    let withText: Int
}

final class IndexStore: @unchecked Sendable {
    nonisolated(unsafe) static var shared: IndexStore!

    private let queue = DispatchQueue(label: "local.browserpoc.index")
    private let db: SQLiteDB
    /// doc id -> [(passage id, unit vector)]
    private var vectors: [Int64: [(Int64, [Float])]] = [:]
    private var dim = 0
    /// Bumped on every write so the UI can tell the index changed.
    private(set) var generation = 0

    init(url: URL) throws {
        Paths.ensure(url.deletingLastPathComponent())
        db = try SQLiteDB(path: url.path)
        try queue.sync {
            try db.exec("PRAGMA journal_mode=WAL")
            try db.exec("PRAGMA synchronous=NORMAL")
            try db.exec("""
            CREATE TABLE IF NOT EXISTS docs(
              id INTEGER PRIMARY KEY,
              key TEXT UNIQUE NOT NULL,
              source TEXT NOT NULL,
              url TEXT NOT NULL,
              title TEXT NOT NULL DEFAULT '',
              description TEXT NOT NULL DEFAULT '',
              body TEXT NOT NULL DEFAULT '',
              project TEXT,
              root TEXT,
              first_seen REAL NOT NULL DEFAULT 0,
              last_seen REAL NOT NULL DEFAULT 0,
              visit_count INTEGER NOT NULL DEFAULT 0,
              dwell REAL NOT NULL DEFAULT 0,
              last_opened REAL NOT NULL DEFAULT 0,
              has_text INTEGER NOT NULL DEFAULT 0,
              mtime REAL NOT NULL DEFAULT 0,
              indexed_at REAL NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS docs_source ON docs(source);
            CREATE INDEX IF NOT EXISTS docs_root ON docs(root);
            CREATE TABLE IF NOT EXISTS passages(
              id INTEGER PRIMARY KEY,
              doc_id INTEGER NOT NULL,
              idx INTEGER NOT NULL,
              text TEXT NOT NULL,
              vec BLOB
            );
            CREATE INDEX IF NOT EXISTS passages_doc ON passages(doc_id);
            CREATE VIRTUAL TABLE IF NOT EXISTS pfts USING fts5(title, body, tokenize='unicode61 remove_diacritics 2');
            CREATE VIRTUAL TABLE IF NOT EXISTS pfts_vocab USING fts5vocab(pfts, 'row');
            CREATE TABLE IF NOT EXISTS entities(
              doc_id INTEGER NOT NULL,
              name TEXT NOT NULL,
              display TEXT NOT NULL,
              kind TEXT NOT NULL,
              count INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS entities_name ON entities(name);
            CREATE INDEX IF NOT EXISTS entities_doc ON entities(doc_id);
            CREATE TABLE IF NOT EXISTS dismissals(
              doc_id INTEGER NOT NULL,
              context_key TEXT NOT NULL,
              terms TEXT NOT NULL,
              at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS dismissals_doc ON dismissals(doc_id);
            CREATE TABLE IF NOT EXISTS reasons(
              doc_id INTEGER NOT NULL,
              context_key TEXT NOT NULL,
              text TEXT NOT NULL,
              PRIMARY KEY(doc_id, context_key)
            );
            """)
            try loadVectors()
        }
    }

    private func loadVectors() throws {
        vectors = [:]
        let rows = try db.query("SELECT id, doc_id, vec FROM passages WHERE vec IS NOT NULL") { s in
            (s.int(0), s.int(1), s.blob(2))
        }
        for (pid, did, blob) in rows {
            guard let blob else { continue }
            let v = Embedder.decode(blob)
            if dim == 0 { dim = v.count }
            guard v.count == dim else { continue }
            vectors[did, default: []].append((pid, v))
        }
    }

    // MARK: - Reads

    private static let metaColumns = "id, key, source, url, title, description, project, root, first_seen, last_seen, visit_count, dwell, last_opened, has_text, mtime"

    private static func meta(_ s: Statement) -> DocMeta {
        DocMeta(id: s.int(0), key: s.text(1), source: SourceType(rawValue: s.text(2)) ?? .web,
                url: s.text(3), title: s.text(4), description: s.text(5), project: s.optText(6),
                root: s.optText(7), firstSeen: s.double(8), lastSeen: s.double(9),
                visitCount: Int(s.int(10)), dwell: s.double(11), lastOpened: s.double(12),
                hasText: s.int(13) != 0, mtime: s.double(14))
    }

    func doc(key: String) -> DocMeta? {
        queue.sync {
            (try? db.query("SELECT \(Self.metaColumns) FROM docs WHERE key = ?", [key], Self.meta))?.first
        }
    }

    func counts() -> [SourceCount] {
        queue.sync {
            let rows = (try? db.query("SELECT source, count(*), sum(has_text) FROM docs GROUP BY source") { s in
                SourceCount(source: SourceType(rawValue: s.text(0)) ?? .web, total: Int(s.int(1)), withText: Int(s.int(2)))
            }) ?? []
            return rows
        }
    }

    func count(root: String) -> Int {
        queue.sync { Int((try? db.scalarInt("SELECT count(*) FROM docs WHERE root = ?", [root])) ?? 0) }
    }

    func fileMtimes(root: String) -> [String: Double] {
        queue.sync {
            let rows = (try? db.query("SELECT key, mtime FROM docs WHERE root = ?", [root]) { ($0.text(0), $0.double(1)) }) ?? []
            return Dictionary(rows, uniquingKeysWith: { a, _ in a })
        }
    }

    func fileMtimes(source: SourceType) -> [String: Double] {
        queue.sync {
            let rows = (try? db.query("SELECT key, mtime FROM docs WHERE source = ?", [source.rawValue]) { ($0.text(0), $0.double(1)) }) ?? []
            return Dictionary(rows, uniquingKeysWith: { a, _ in a })
        }
    }

    func chromeDocsWithoutText() -> Set<String> {
        queue.sync {
            Set((try? db.query("SELECT key FROM docs WHERE source = 'chrome' AND has_text = 0") { $0.text(0) }) ?? [])
        }
    }

    func cachedReason(docID: Int64, contextKey: String) -> String? {
        queue.sync {
            (try? db.query("SELECT text FROM reasons WHERE doc_id = ? AND context_key = ?", [docID, contextKey]) { $0.text(0) })?.first
        }
    }

    // MARK: - Writes

    func saveReason(docID: Int64, contextKey: String, text: String) {
        queue.sync {
            _ = try? db.run("INSERT OR REPLACE INTO reasons(doc_id, context_key, text) VALUES(?,?,?)", [docID, contextKey, text])
        }
    }

    func touchOpened(key: String, at: Date = Date()) {
        queue.sync {
            _ = try? db.run("UPDATE docs SET last_opened = ? WHERE key = ?", [at.timeIntervalSince1970, key])
        }
    }

    func addDwell(key: String, seconds: Double) {
        guard seconds > 0 else { return }
        queue.sync {
            _ = try? db.run("UPDATE docs SET dwell = dwell + ? WHERE key = ?", [seconds, key])
        }
    }

    func dismiss(docID: Int64, contextKey: String, terms: [String]) {
        queue.sync {
            _ = try? db.run("INSERT INTO dismissals(doc_id, context_key, terms, at) VALUES(?,?,?,?)",
                            [docID, contextKey, terms.joined(separator: " "), Date().timeIntervalSince1970])
        }
    }

    /// A page stayed open long enough to count as a visit.
    func recordCapture(_ d: DocUpsert, analysis: Analysis) {
        queue.sync {
            do {
                try db.transaction {
                    let existing = try db.query("SELECT id FROM docs WHERE key = ?", [d.key]) { $0.int(0) }.first
                    let id: Int64
                    if let existing {
                        try db.run("""
                            UPDATE docs SET source = 'web', url = ?, title = ?, description = ?, body = ?,
                              last_seen = ?, visit_count = visit_count + 1, has_text = ?, indexed_at = ?
                            WHERE id = ?
                            """, [d.url, d.title, d.description, d.body, d.lastSeen, d.body.isEmpty ? 0 : 1,
                                  Date().timeIntervalSince1970, existing])
                        id = existing
                    } else {
                        id = try insert(d, hasText: !d.body.isEmpty)
                    }
                    try replacePassages(docID: id, title: d.title, analysis: analysis)
                }
                generation += 1
            } catch {
                appLog.error("capture write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Chrome history rows. Never overwrites text already captured in the app.
    /// Returns how many entries were new.
    func importChrome(_ docs: [(DocUpsert, Analysis)]) -> Int {
        queue.sync {
            var inserted = 0
            do {
                try db.transaction {
                    for (d, analysis) in docs {
                        let existing = try db.query("SELECT id FROM docs WHERE key = ?", [d.key]) { $0.int(0) }.first
                        if let existing {
                            try db.run("""
                                UPDATE docs SET visit_count = max(visit_count, ?), last_seen = max(last_seen, ?),
                                  first_seen = min(first_seen, ?),
                                  title = CASE WHEN title = '' THEN ? ELSE title END
                                WHERE id = ?
                                """, [d.visitCount, d.lastSeen, d.firstSeen, d.title, existing])
                        } else {
                            let id = try insert(d, hasText: false)
                            try replacePassages(docID: id, title: d.title, analysis: analysis)
                            inserted += 1
                        }
                    }
                }
                generation += 1
            } catch {
                appLog.error("chrome import failed: \(String(describing: error), privacy: .public)")
            }
            return inserted
        }
    }

    /// Text fetched for a Chrome history page. Only fills in title-only Chrome entries.
    func setChromeText(key: String, title: String, description: String, body: String, analysis: Analysis) {
        queue.sync {
            do {
                try db.transaction {
                    guard let id = try db.query("SELECT id FROM docs WHERE key = ? AND source = 'chrome' AND has_text = 0", [key], { $0.int(0) }).first else { return }
                    try db.run("""
                        UPDATE docs SET title = CASE WHEN ? != '' THEN ? ELSE title END,
                          description = ?, body = ?, has_text = 1, indexed_at = ? WHERE id = ?
                        """, [title, title, description, body, Date().timeIntervalSince1970, id])
                    try replacePassages(docID: id, title: title.isEmpty ? key : title, analysis: analysis)
                }
                generation += 1
            } catch {
                appLog.error("chrome text write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Notes and Markdown files. Replaces the whole entry.
    func upsertFile(_ d: DocUpsert, analysis: Analysis) {
        queue.sync {
            do {
                try db.transaction {
                    let existing = try db.query("SELECT id FROM docs WHERE key = ?", [d.key]) { $0.int(0) }.first
                    let id: Int64
                    if let existing {
                        try db.run("""
                            UPDATE docs SET source = ?, url = ?, title = ?, description = ?, body = ?, project = ?, root = ?,
                              last_seen = ?, mtime = ?, has_text = ?, indexed_at = ? WHERE id = ?
                            """, [d.source.rawValue, d.url, d.title, d.description, d.body, d.project, d.root,
                                  d.lastSeen, d.mtime, d.body.isEmpty ? 0 : 1, Date().timeIntervalSince1970, existing])
                        id = existing
                    } else {
                        id = try insert(d, hasText: !d.body.isEmpty)
                    }
                    try replacePassages(docID: id, title: d.title, analysis: analysis)
                }
                generation += 1
            } catch {
                appLog.error("file write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func deleteDocs(keys: [String]) {
        guard !keys.isEmpty else { return }
        queue.sync {
            do {
                try db.transaction {
                    for k in keys {
                        if let id = try db.query("SELECT id FROM docs WHERE key = ?", [k], { $0.int(0) }).first {
                            try deleteDoc(id: id)
                        }
                    }
                }
                generation += 1
            } catch {
                appLog.error("delete failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func deleteRoot(_ root: String) {
        queue.sync {
            do {
                try db.transaction {
                    let ids = try db.query("SELECT id FROM docs WHERE root = ?", [root]) { $0.int(0) }
                    for id in ids { try deleteDoc(id: id) }
                }
                generation += 1
            } catch {
                appLog.error("delete root failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func deleteExcluded(_ isExcluded: (String) -> Bool) {
        queue.sync {
            do {
                try db.transaction {
                    let rows = try db.query("SELECT id, url FROM docs WHERE source IN ('web','chrome')") { ($0.int(0), $0.text(1)) }
                    for (id, url) in rows where isExcluded(URL(string: url)?.host ?? "") {
                        try deleteDoc(id: id)
                    }
                }
                generation += 1
            } catch {}
        }
    }

    func clearAll() {
        queue.sync {
            do {
                try db.exec("""
                DELETE FROM docs; DELETE FROM passages; DELETE FROM pfts; DELETE FROM entities;
                DELETE FROM dismissals; DELETE FROM reasons;
                """)
                try? db.exec("VACUUM")
                vectors = [:]
                generation += 1
            } catch {
                appLog.error("clear failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func insert(_ d: DocUpsert, hasText: Bool) throws -> Int64 {
        try db.run("""
            INSERT INTO docs(key, source, url, title, description, body, project, root, first_seen, last_seen,
              visit_count, dwell, has_text, mtime, indexed_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [d.key, d.source.rawValue, d.url, d.title, d.description, d.body, d.project, d.root,
                  d.firstSeen, d.lastSeen, d.visitCount, d.dwell, hasText ? 1 : 0, d.mtime, Date().timeIntervalSince1970])
        return db.lastInsertRowID
    }

    private func deleteDoc(id: Int64) throws {
        let pids = try db.query("SELECT id FROM passages WHERE doc_id = ?", [id]) { $0.int(0) }
        for pid in pids { try db.run("DELETE FROM pfts WHERE rowid = ?", [pid]) }
        try db.run("DELETE FROM passages WHERE doc_id = ?", [id])
        try db.run("DELETE FROM entities WHERE doc_id = ?", [id])
        try db.run("DELETE FROM dismissals WHERE doc_id = ?", [id])
        try db.run("DELETE FROM reasons WHERE doc_id = ?", [id])
        try db.run("DELETE FROM docs WHERE id = ?", [id])
        vectors[id] = nil
    }

    private func replacePassages(docID: Int64, title: String, analysis: Analysis) throws {
        let pids = try db.query("SELECT id FROM passages WHERE doc_id = ?", [docID]) { $0.int(0) }
        for pid in pids { try db.run("DELETE FROM pfts WHERE rowid = ?", [pid]) }
        try db.run("DELETE FROM passages WHERE doc_id = ?", [docID])
        try db.run("DELETE FROM entities WHERE doc_id = ?", [docID])
        // Old reasons were written for old text.
        try db.run("DELETE FROM reasons WHERE doc_id = ?", [docID])
        var vecs: [(Int64, [Float])] = []
        for (i, p) in analysis.passages.enumerated() {
            let v = i < analysis.vectors.count ? analysis.vectors[i] : nil
            try db.run("INSERT INTO passages(doc_id, idx, text, vec) VALUES(?,?,?,?)",
                       [docID, i, p, v.map(Embedder.encode)])
            let pid = db.lastInsertRowID
            try db.run("INSERT INTO pfts(rowid, title, body) VALUES(?,?,?)", [pid, title, p])
            if let v {
                if dim == 0 { dim = v.count }
                if v.count == dim { vecs.append((pid, v)) }
            }
        }
        vectors[docID] = vecs.isEmpty ? nil : vecs
        for e in analysis.entities {
            try db.run("INSERT INTO entities(doc_id, name, display, kind, count) VALUES(?,?,?,?,?)",
                       [docID, e.name, e.display, e.kind, e.count])
        }
    }

    // MARK: - Retrieval

    private static func ftsQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func variants(_ t: String) -> [String] {
        var out = [t]
        if t.count > 4 && t.hasSuffix("ies") { out.append(String(t.dropLast(3)) + "y") }
        else if t.count > 4 && t.hasSuffix("s") && !t.hasSuffix("ss") { out.append(String(t.dropLast())) }
        else if !t.hasSuffix("s") { out.append(t + "s") }
        return out
    }

    /// Terms in the item's own title read best in a reason, so they go first.
    static func topicOrder(_ terms: [String], title: String) -> [String] {
        let titleWords = Set(TextAnalysis.rawWords(title).map(TextAnalysis.fold))
        let inTitle = terms.filter { titleWords.contains($0) || titleWords.contains($0 + "s") || titleWords.contains(String($0.dropLast())) }
        return inTitle + terms.filter { !inTitle.contains($0) }
    }

    static let debug = ProcessInfo.processInfo.environment["BROWSERPOC_DEBUG"] != nil

    static func calibrateSemantic(_ raw: Float) -> Double {
        max(0, min(1, (Double(raw) - 0.55) / 0.33))
    }

    func retrieve(_ ctx: ContextAnalysis, _ p: RankParams) -> RetrievalResult {
        queue.sync {
            do { return try retrieveLocked(ctx, p) } catch {
                appLog.error("retrieve failed: \(String(describing: error), privacy: .public)")
                return RetrievalResult()
            }
        }
    }

    private func retrieveLocked(_ ctx: ContextAnalysis, _ p: RankParams) throws -> RetrievalResult {
        let now = p.now.timeIntervalSince1970
        let cutoff = now - p.recentWindow
        var result = RetrievalResult()
        result.termDisplay = ctx.counts.display

        let totalDocs = Int(try db.scalarInt("SELECT count(*) FROM docs"))
        guard totalDocs > 0 else { return result }
        let excluded = Set(try db.query("""
            SELECT id FROM docs WHERE key = ? OR max(last_opened, last_seen) > ?
            """, [ctx.input.key, cutoff]) { $0.int(0) })
        let eligibleCount = max(1, totalDocs - excluded.count)
        let totalPassages = max(1, Int(try db.scalarInt("SELECT count(*) FROM passages")))

        // 1. Rough first cut of context terms by passage frequency.
        let vocab = try db.prepare("SELECT doc FROM pfts_vocab WHERE term = ?")
        var rough: [(String, Double, Double)] = []   // term, tf, score
        let topByTF = ctx.counts.counts.sorted { $0.value > $1.value }.prefix(150)
        for (t, tf) in topByTF {
            var pdf = 0
            for v in Self.variants(t) {
                vocab.bind([v])
                if try vocab.step() { pdf += Int(vocab.int(0)) }
            }
            guard pdf > 0 else { continue }
            let idf = log(Double(totalPassages + 1) / (Double(pdf) + 0.5))
            rough.append((t, tf, (1 + log(tf)) * idf))
        }
        rough.sort { $0.2 > $1.2 }

        // 2. Exact doc sets per term, ignoring the current item and recent ones.
        let termQuery = try db.prepare("""
            SELECT pfts.rowid, p.doc_id FROM pfts JOIN passages p ON p.id = pfts.rowid
            WHERE pfts MATCH ? LIMIT 5000
            """)
        var termDocs: [String: Set<Int64>] = [:]
        var termPassages: [String: Set<Int64>] = [:]
        var termTF: [String: Double] = [:]
        for (t, tf, _) in rough.prefix(30) {
            let expr = Self.variants(t).map(Self.ftsQuote).joined(separator: " OR ")
            termQuery.bind([expr])
            var docs = Set<Int64>(), pids = Set<Int64>()
            while try termQuery.step() {
                let did = termQuery.int(1)
                if excluded.contains(did) { continue }
                docs.insert(did); pids.insert(termQuery.int(0))
            }
            if docs.isEmpty { continue }
            termDocs[t] = docs; termPassages[t] = pids; termTF[t] = tf
        }
        let commonLimit = max(5.0, 0.2 * Double(eligibleCount))
        var weighted: [(String, Double)] = []
        for (t, docs) in termDocs {
            if Double(docs.count) > commonLimit { continue }
            let idf = log(Double(eligibleCount + 1) / (Double(docs.count) + 0.5))
            weighted.append((t, (1 + log(termTF[t] ?? 1)) * idf))
        }
        weighted.sort { $0.1 > $1.1 }
        let finalTerms = Array(weighted.prefix(12))
        result.terms = finalTerms.map { $0.0 }
        let weightOf = Dictionary(uniqueKeysWithValues: finalTerms)
        let normalizer = max(finalTerms.prefix(8).reduce(0) { $0 + $1.1 }, 4 * log(1 + Double(eligibleCount)))

        // 3. Keyword evidence per doc and per passage.
        var docTerms: [Int64: Set<String>] = [:]
        var passageWeight: [Int64: Double] = [:]
        var passageDoc: [Int64: Int64] = [:]
        if !finalTerms.isEmpty {
            let pdoc = try db.prepare("SELECT id, doc_id FROM passages WHERE id = ?")
            for (t, w) in finalTerms {
                for pid in termPassages[t] ?? [] {
                    passageWeight[pid, default: 0] += w
                    if passageDoc[pid] == nil {
                        pdoc.bind([pid])
                        if try pdoc.step() { passageDoc[pid] = pdoc.int(1) }
                    }
                }
                for d in termDocs[t] ?? [] { docTerms[d, default: []].insert(t) }
            }
        }
        var bestPassageKW: [Int64: Double] = [:]
        for (pid, w) in passageWeight {
            guard let d = passageDoc[pid] else { continue }
            bestPassageKW[d] = max(bestPassageKW[d] ?? 0, w)
        }

        // 4. Semantic scan over every eligible passage vector.
        var semDoc: [Int64: Float] = [:]
        var semPassage: [Int64: Float] = [:]
        if !ctx.vectors.isEmpty && dim > 0 {
            let ctxVecs = ctx.vectors.filter { $0.count == dim }
            for (did, list) in vectors where !excluded.contains(did) {
                var best: Float = -1
                for (pid, v) in list {
                    var m: Float = -1
                    v.withUnsafeBufferPointer { vp in
                        for c in ctxVecs { m = max(m, Embedder.dot(vp.baseAddress!, c, dim)) }
                    }
                    semPassage[pid] = m
                    best = max(best, m)
                }
                semDoc[did] = best
            }
        }

        // 5. Entity overlap.
        var docEntities: [Int64: [String]] = [:]
        let ctxEntityNames = Array(Set(ctx.entities.map { $0.name })).prefix(40)
        if !ctxEntityNames.isEmpty {
            let placeholders = Array(repeating: "?", count: ctxEntityNames.count).joined(separator: ",")
            let rows = try db.query("SELECT doc_id, display FROM entities WHERE name IN (\(placeholders))", Array(ctxEntityNames)) {
                ($0.int(0), $0.text(1))
            }
            for (d, disp) in rows where !excluded.contains(d) {
                if !(docEntities[d]?.contains(disp) ?? false) { docEntities[d, default: []].append(disp) }
            }
        }

        // 6. Candidate pool.
        var pool = Set<Int64>()
        pool.formUnion(docTerms.keys.sorted { (docTerms[$0]?.count ?? 0) > (docTerms[$1]?.count ?? 0) }.prefix(250))
        pool.formUnion(semDoc.filter { $0.value >= 0.65 }.sorted { $0.value > $1.value }.prefix(40).map { $0.key })
        pool.formUnion(docEntities.keys)
        pool.formUnion(p.keepIDs.subtracting(excluded))
        guard !pool.isEmpty else { return result }

        var metas: [Int64: DocMeta] = [:]
        let poolList = Array(pool)
        for chunkStart in stride(from: 0, to: poolList.count, by: 200) {
            let part = Array(poolList[chunkStart..<min(poolList.count, chunkStart + 200)])
            let ph = Array(repeating: "?", count: part.count).joined(separator: ",")
            for m in try db.query("SELECT \(Self.metaColumns) FROM docs WHERE id IN (\(ph))", part, Self.meta) {
                metas[m.id] = m
            }
        }

        // Dismissals.
        let dismissRows = try db.query("SELECT doc_id, context_key, terms FROM dismissals") { ($0.int(0), $0.text(1), $0.text(2)) }
        var hidden = Set<Int64>()
        var penalty: [Int64: Double] = [:]
        let termSet = Set(result.terms)
        for (d, ck, terms) in dismissRows {
            if ck == ctx.input.key { hidden.insert(d); continue }
            let ts = Set(terms.split(separator: " ").map(String.init))
            let overlap = termSet.isEmpty || ts.isEmpty ? 0 : Double(termSet.intersection(ts).count) / Double(min(termSet.count, ts.count))
            if overlap >= 0.4 { penalty[d] = min(penalty[d] ?? 1, 0.7) }
        }

        let wSum = p.keywordWeight + p.semanticWeight + p.entityWeight
        var scored: [Match] = []
        for d in pool {
            guard let meta = metas[d], !hidden.contains(d) else { continue }
            let shared = (docTerms[d] ?? []).sorted { (weightOf[$0] ?? 0) > (weightOf[$1] ?? 0) }
            let sharedW = shared.reduce(0) { $0 + (weightOf[$1] ?? 0) }
            var k: Double
            if meta.hasText {
                let kDoc = min(1, sharedW / normalizer)
                let kPass = min(1, (bestPassageKW[d] ?? 0) / (normalizer * 0.6))
                k = 0.5 * kDoc + 0.5 * kPass
            } else {
                k = min(1, sharedW / (normalizer * 0.5))
            }
            if shared.count < 2 { k *= 0.5 }
            let s = Self.calibrateSemantic(semDoc[d] ?? 0)
            let ents = docEntities[d] ?? []
            let e = min(1, Double(ents.count) / 2.0)
            var score: Double
            if meta.hasText {
                score = wSum > 0 ? (p.keywordWeight * k + p.semanticWeight * s + p.entityWeight * e) / wSum : 0
            } else {
                // A bare title embeds poorly, so title-only entries are judged on words and names.
                let w = p.keywordWeight + p.entityWeight
                score = w > 0 ? (p.keywordWeight * k + p.entityWeight * e) / w : 0
                if k < 0.35 { score *= 0.5 }
            }
            // Conservative gate: one shared word alone is not enough.
            let enoughEvidence = shared.count >= 2 || ents.count >= 2 || s >= 0.75
            if !enoughEvidence { score *= 0.5 }
            if !meta.hasText && shared.count < 2 { score *= 0.5 }
            let pen = penalty[d]
            if let pen { score *= pen }
            scored.append(Match(doc: meta, keyword: k, semantic: s, entity: e, score: score, passage: "",
                                sharedTerms: shared.map { ctx.counts.display[$0] ?? $0 }, sharedEntities: ents,
                                topicTerms: Self.topicOrder(shared.filter { ctx.nouns.contains($0) }, title: meta.title)
                                    .map { ctx.counts.display[$0] ?? $0 },
                                penalized: pen != nil))
        }
        scored.sort { $0.score > $1.score }
        if Self.debug {
            for m in scored {
                print(String(format: "        cand %.3f k%.2f s%.2f(raw %.2f) e%.2f terms=%d  %@", m.score, m.keyword, m.semantic,
                             semDoc[m.doc.id] ?? -1, m.entity, m.sharedTerms.count, String(m.doc.title.prefix(40))))
            }
        }

        let above = scored.filter { $0.score >= p.threshold }.prefix(p.limit)
        var chosen = Array(above)
        for m in scored where p.keepIDs.contains(m.doc.id) {
            result.kept[m.doc.id] = m
        }

        // 7. Best passage for the cards we'll show.
        var needIDs = Set(chosen.map { $0.doc.id })
        needIDs.formUnion(result.kept.keys)
        var passagesByDoc: [Int64: [(Int64, String)]] = [:]
        if !needIDs.isEmpty {
            let ids = Array(needIDs)
            let ph = Array(repeating: "?", count: ids.count).joined(separator: ",")
            for (pid, did, text) in try db.query("SELECT id, doc_id, text FROM passages WHERE doc_id IN (\(ph)) ORDER BY idx", ids, {
                ($0.int(0), $0.int(1), $0.text(2))
            }) {
                passagesByDoc[did, default: []].append((pid, text))
            }
        }
        func best(_ m: Match) -> String {
            guard let list = passagesByDoc[m.doc.id], !list.isEmpty else { return m.doc.description }
            var bestText = list[0].1
            var bestScore = -1.0
            for (pid, text) in list {
                let kw = (passageWeight[pid] ?? 0) / normalizer
                let sem = Self.calibrateSemantic(semPassage[pid] ?? 0)
                let sc = kw + sem
                if sc > bestScore { bestScore = sc; bestText = text }
            }
            if !m.doc.hasText { return Snippet.prettyURL(m.doc.url) }
            return Snippet.make(bestText, terms: m.sharedTerms + m.sharedEntities, title: m.doc.title)
        }
        for i in chosen.indices { chosen[i].passage = best(chosen[i]) }
        for (id, m) in result.kept {
            var mm = m
            mm.passage = best(m)
            result.kept[id] = mm
        }
        result.matches = chosen
        return result
    }
}

enum Snippet {
    static func prettyURL(_ s: String) -> String {
        guard let u = URL(string: s), let host = u.host else { return s }
        let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let path = u.path == "/" ? "" : u.path
        return h + path
    }

    /// Picks a stretch of the passage around the first shared term, starting at a sentence edge.
    static func make(_ text: String, terms: [String], title: String, length: Int = 260) -> String {
        var t = text.replacingOccurrences(of: "\n", with: " ")
        if !title.isEmpty, t.hasPrefix(title) { t = String(t.dropFirst(title.count)).trimmingCharacters(in: .whitespaces) }
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        var start = t.startIndex
        for term in terms where !term.isEmpty {
            if let r = t.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
                // Back up to the start of the sentence, at most ~120 characters.
                var s = r.lowerBound
                var steps = 0
                while s > t.startIndex && steps < 120 {
                    let prev = t.index(before: s)
                    if ".!?".contains(t[prev]) { break }
                    s = prev; steps += 1
                }
                start = s
                break
            }
        }
        let tail = t[start...].trimmingCharacters(in: .whitespaces)
        return String(tail.prefix(length))
    }
}
