import Foundation
import SQLite3

extension IndexStore {
    /// The index file this store has open, from its SQLite connection.
    var fileURL: URL {
        let path = db.handle.flatMap { sqlite3_db_filename($0, "main") }.map { String(cString: $0) } ?? ""
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }
}

/// Read-only queries the graph needs from the index tables (`docs`, `passages`, `entities`,
/// `topics`, `typing`, `overrides`). They run on the graph's own SQLite connection, so the graph
/// doesn't edit `IndexStore.swift`. Similarity in the app goes through the Engine's own calls
/// (`EngineNeighbours`). Not thread-safe; `GraphStore` calls it from its own queue.
final class IndexReader {
    let db: SQLiteDB

    init(db: SQLiteDB) { self.db = db }

    struct DocRow {
        let id: Int64
        let key: String
        let source: String
        let url: String
        let title: String
        let project: String?
        let firstSeen: Double
        let lastSeen: Double
        let visits: Int
        let hasText: Bool
    }

    struct ChangedDoc {
        let id: Int64
        let key: String
        let source: String
        let url: String
        let body: String
        let hasText: Bool
        let indexedAt: Double
    }

    struct TopicRow {
        let name: String
        let display: String
        let kind: String
        let docIDs: [Int64]
    }

    func hasIndexTables() -> Bool {
        ((try? db.scalarInt("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'docs'")) ?? 0) > 0
    }

    func docCount() -> Int {
        Int((try? db.scalarInt("SELECT count(*) FROM docs")) ?? 0)
    }

    func allDocs() -> [DocRow] {
        (try? db.query("""
            SELECT id, key, source, url, title, project, first_seen, last_seen, visit_count, has_text FROM docs
            """) { s in
            DocRow(id: s.int(0), key: s.text(1), source: s.text(2), url: s.text(3), title: s.text(4), project: s.optText(5),
                   firstSeen: s.double(6), lastSeen: s.double(7), visits: Int(s.int(8)), hasText: s.int(9) != 0)
        }) ?? []
    }

    /// Docs written to the index after `since`, oldest first.
    func changedDocs(since: Double, limit: Int = 2000) -> [ChangedDoc] {
        (try? db.query("""
            SELECT id, key, source, url, body, has_text, indexed_at FROM docs WHERE indexed_at > ? ORDER BY indexed_at LIMIT ?
            """, [since, limit]) { s in
            ChangedDoc(id: s.int(0), key: s.text(1), source: s.text(2), url: s.text(3), body: s.text(4),
                       hasText: s.int(5) != 0, indexedAt: s.double(6))
        }) ?? []
    }

    func docID(forKey key: String) -> Int64? {
        (try? db.query("SELECT id FROM docs WHERE key = ?", [key]) { $0.int(0) })?.first
    }

    func allKeys() -> Set<String> {
        Set((try? db.query("SELECT key FROM docs") { $0.text(0) }) ?? [])
    }

    func columns(_ table: String) -> Set<String> {
        Set((try? db.query("PRAGMA table_info(\(table))") { $0.text(1) }) ?? [])
    }

    func hasTable(_ name: String) -> Bool {
        ((try? db.scalarInt("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = ?", [name])) ?? 0) > 0
    }

    /// The index can hold vectors from several models (round 3 added EmbeddingGemma and Apple's
    /// contextual embedding next to the old sentence vectors). This reader only uses the sentence
    /// ones, so vectors of different models never get averaged together.
    private var sentenceOnly: String {
        columns("passages").contains("vec_model") ? " AND (p.vec_model IS NULL OR p.vec_model = 'nlsent')" : ""
    }

    func vectorDimension() -> Int {
        let rows = (try? db.query("SELECT p.vec FROM passages p WHERE p.vec IS NOT NULL\(sentenceOnly) LIMIT 1") { $0.blob(0) }) ?? []
        guard let first = rows.first, let blob = first else { return 0 }
        return blob.count / MemoryLayout<Float>.size
    }

    /// Each doc's passage vectors averaged and normalized. Only docs with real text.
    func meanVectors(docIDs: [Int64]?, dim: Int) -> [(Int64, [Float])] {
        var sums: [Int64: [Float]] = [:]
        func add(_ did: Int64, _ blob: Data?) {
            guard let blob, !blob.isEmpty else { return }
            let v = Embedder.decode(blob)
            if dim > 0 && v.count != dim { return }
            if var s = sums[did] {
                guard s.count == v.count else { return }
                for i in 0..<s.count { s[i] += v[i] }
                sums[did] = s
            } else {
                sums[did] = v
            }
        }
        if let docIDs {
            for chunk in stride(from: 0, to: docIDs.count, by: 300) {
                let part = Array(docIDs[chunk..<min(docIDs.count, chunk + 300)])
                let ph = Array(repeating: "?", count: part.count).joined(separator: ",")
                let rows = (try? db.query("""
                    SELECT p.doc_id, p.vec FROM passages p JOIN docs d ON d.id = p.doc_id
                    WHERE p.vec IS NOT NULL AND d.has_text = 1 AND p.doc_id IN (\(ph))\(sentenceOnly)
                    """, part) { ($0.int(0), $0.blob(1)) }) ?? []
                for (d, b) in rows { add(d, b) }
            }
        } else {
            let rows = (try? db.query("""
                SELECT p.doc_id, p.vec FROM passages p JOIN docs d ON d.id = p.doc_id WHERE p.vec IS NOT NULL AND d.has_text = 1\(sentenceOnly)
                """) { ($0.int(0), $0.blob(1)) }) ?? []
            for (d, b) in rows { add(d, b) }
        }
        var out: [(Int64, [Float])] = []
        for (d, var s) in sums {
            var norm: Float = 0
            for x in s { norm += x * x }
            norm = norm.squareRoot()
            guard norm > 0 else { continue }
            for i in 0..<s.count { s[i] /= norm }
            out.append((d, s))
        }
        return out
    }

    /// Names that appear in at least `minDocs` and at most `maxDocs` docs with text.
    func sharedTopics(minDocs: Int = 2, maxDocs: Int = 40, limit: Int = 600) -> [TopicRow] {
        let rows = (try? db.query("""
            SELECT e.name, e.display, e.kind, e.doc_id FROM entities e
            JOIN (SELECT name FROM entities GROUP BY name HAVING count(DISTINCT doc_id) BETWEEN ? AND ?
                  ORDER BY count(DISTINCT doc_id) DESC LIMIT ?) t ON t.name = e.name
            JOIN docs d ON d.id = e.doc_id WHERE d.has_text = 1
            """, [minDocs, maxDocs, limit]) { ($0.text(0), $0.text(1), $0.text(2), $0.int(3)) }) ?? []
        var byName: [String: (String, String, [Int64])] = [:]
        for (name, display, kind, doc) in rows {
            if var e = byName[name] {
                if !e.2.contains(doc) { e.2.append(doc) }
                byName[name] = e
            } else {
                byName[name] = (display, kind, [doc])
            }
        }
        // Topics the Engine's content-tagging model gave items, when it has run.
        if hasTable("topics") {
            let tagged = (try? db.query("""
                SELECT t.topic, t.doc_id FROM topics t JOIN docs d ON d.id = t.doc_id WHERE t.source = 'model' AND d.has_text = 1
                """) { ($0.text(0), $0.int(1)) }) ?? []
            var byTopic: [String: (String, Set<Int64>)] = [:]
            for (topic, doc) in tagged where !topic.isEmpty {
                let key = TextAnalysis.fold(Substring(topic))
                byTopic[key, default: (topic, [])].1.insert(doc)
            }
            for (key, e) in byTopic where e.1.count >= minDocs && e.1.count <= maxDocs {
                let name = "topic:" + key
                if byName[name] == nil { byName[name] = (e.0, "topic", Array(e.1)) }
            }
        }
        return byName.compactMap { name, e in
            e.2.count >= minDocs ? TopicRow(name: name, display: e.0, kind: e.1, docIDs: e.2.sorted()) : nil
        }.sorted { $0.name < $1.name }
    }

    /// What the Related panel uses to put a page under Notes / Docs: typed characters and Felix's own choices.
    func sectionInputs() -> (typed: [String: Int], overrides: [String: CardSection]) {
        let typed = Dictionary(((try? db.query("SELECT key, chars FROM typing") { ($0.text(0), Int($0.int(1))) }) ?? []),
                               uniquingKeysWith: { a, _ in a })
        let over = Dictionary(((try? db.query("SELECT key, section FROM overrides") { ($0.text(0), CardSection(rawValue: $0.text(1))) }) ?? [])
            .compactMap { k, v in v.map { (k, $0) } }, uniquingKeysWith: { a, _ in a })
        return (typed, over)
    }

    /// Which kind of node a doc becomes. Reads the raw source name, so new sources from the
    /// Engine agent (Granola, Notion, Google Docs) land in the right place without changes here.
    static func kind(source: String, url: String, key: String, typed: Int, override: CardSection?, writingSites: [String]) -> GraphNodeKind {
        let s = source.lowercased()
        if s == "note" || s == "markdown" { return .note }
        if s.contains("granola") || s.contains("meeting") { return .meeting }
        if s.contains("notion") || s.contains("gdoc") || s.contains("google") || s.contains("doc") { return .doc }
        let st = SourceType(rawValue: s) ?? .web
        return WritingKey.section(source: st, url: url, typed: typed, override: override, writingSites: writingSites) == .docs ? .doc : .site
    }
}
