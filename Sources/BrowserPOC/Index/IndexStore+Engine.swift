import Foundation

/// A visit to an item, with what Felix was doing at the time.
struct Visit {
    let at: Double
    let kind: String      // read, edited, imported, met, opened
    let during: String?   // what he was writing or working on then
}

/// Index upkeep for round 3: vectors per model, topics, visits and source sync state.
extension IndexStore {
    // MARK: Vectors

    struct PendingPassage { let pid: Int64; let did: Int64; let title: String; let text: String }

    func passagesNeedingVectors(model: EmbedderID, limit: Int) -> [PendingPassage] {
        queue.sync {
            (try? db.query("""
                SELECT p.id, p.doc_id, d.title, p.text FROM passages p JOIN docs d ON d.id = p.doc_id
                WHERE p.vec_model IS NULL OR p.vec_model != ?
                ORDER BY d.source IN ('note','notion','gdocs','granola') DESC, max(d.last_seen, d.mtime) DESC
                LIMIT ?
                """, [model.rawValue, limit]) { PendingPassage(pid: $0.int(0), did: $0.int(1), title: $0.text(2), text: $0.text(3)) }) ?? []
        }
    }

    func setVectors(_ rows: [(pid: Int64, did: Int64, vec: [Float])], model: EmbedderID, failed: [Int64] = []) {
        queue.sync {
            do {
                try db.transaction {
                    for r in rows {
                        try db.run("UPDATE passages SET vec = ?, vec_model = ? WHERE id = ?", [Embedder.encode(r.vec), model.rawValue, r.pid])
                    }
                    for pid in failed {
                        try db.run("UPDATE passages SET vec = NULL, vec_model = ? WHERE id = ?", [model.rawValue, pid])
                    }
                }
                // Swap the in-memory vectors for the touched passages.
                let touched = Set(rows.map { $0.pid } + failed)
                for k in vectorSets.keys {
                    for (did, list) in vectorSets[k] ?? [:] where list.contains(where: { touched.contains($0.0) }) {
                        let kept = list.filter { !touched.contains($0.0) }
                        vectorSets[k]?[did] = kept.isEmpty ? nil : kept
                    }
                }
                for r in rows { addVector(r.vec, pid: r.pid, did: r.did, model: model) }
                generation += 1
            } catch {
                appLog.error("vector write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// How many passages have vectors from each model.
    func vectorCounts() -> [EmbedderID: Int] {
        queue.sync {
            var out: [EmbedderID: Int] = [:]
            for (k, set) in vectorSets { out[k] = set.values.reduce(0) { $0 + $1.count } }
            return out
        }
    }

    func passageCount() -> Int {
        queue.sync { Int((try? db.scalarInt("SELECT count(*) FROM passages")) ?? 0) }
    }

    // MARK: Topics

    func docsNeedingTopics(limit: Int) -> [(Int64, String, String)] {
        queue.sync {
            (try? db.query("""
                SELECT id, title, body FROM docs WHERE has_text = 1
                AND id NOT IN (SELECT doc_id FROM topics WHERE source = 'model')
                ORDER BY max(last_seen, mtime) DESC LIMIT ?
                """, [limit]) { ($0.int(0), $0.text(1), $0.text(2)) }) ?? []
        }
    }

    func setTopics(docID: Int64, topics: [String], source: String) {
        queue.sync {
            try? db.transaction {
                try db.run("DELETE FROM topics WHERE doc_id = ? AND source = ?", [docID, source])
                // An empty list still records that the item was tagged.
                let list = topics.isEmpty ? [""] : topics
                for t in list.prefix(6) {
                    try db.run("INSERT INTO topics(doc_id, topic, source) VALUES(?,?,?)", [docID, t, source])
                }
            }
        }
    }

    // MARK: Visits

    func recordVisit(docID: Int64, at: Double, kind: String, during: String?) {
        queue.sync { recordVisitLocked(docID: docID, at: at, kind: kind, during: during) }
    }

    func recordVisit(key: String, at: Double, kind: String, during: String?) {
        queue.sync {
            guard let id = (try? db.query("SELECT id FROM docs WHERE key = ?", [key]) { $0.int(0) })?.first else { return }
            recordVisitLocked(docID: id, at: at, kind: kind, during: during)
        }
    }

    func recordVisitLocked(docID: Int64, at: Double, kind: String, during: String?) {
        // One row per item per hour is enough history.
        let recent = (try? db.scalarInt("SELECT count(*) FROM visits WHERE doc_id = ? AND kind = ? AND abs(at - ?) < 3600", [docID, kind, at])) ?? 0
        if recent > 0 {
            if let during { _ = try? db.run("UPDATE visits SET during = ? WHERE doc_id = ? AND kind = ? AND abs(at - ?) < 3600 AND during IS NULL", [during, docID, kind, at]) }
            return
        }
        _ = try? db.run("INSERT INTO visits(doc_id, at, kind, during) VALUES(?,?,?,?)", [docID, at, kind, during])
    }

    func visits(docID: Int64, limit: Int = 20) -> [Visit] {
        queue.sync { visitsLocked(docID: docID, limit: limit) }
    }

    func visitsLocked(docID: Int64, limit: Int = 20) -> [Visit] {
        (try? db.query("SELECT at, kind, during FROM visits WHERE doc_id = ? ORDER BY at DESC LIMIT ?", [docID, limit]) {
            Visit(at: $0.double(0), kind: $0.text(1), during: $0.optText(2))
        }) ?? []
    }

    // MARK: Source state

    func sourceState(_ key: String) -> String? {
        queue.sync { (try? db.query("SELECT value FROM source_state WHERE source = ?", [key]) { $0.text(0) })?.first }
    }

    func setSourceState(_ key: String, _ value: String) {
        queue.sync { _ = try? db.run("INSERT OR REPLACE INTO source_state(source, value) VALUES(?,?)", [key, value]) }
    }

    // MARK: Source documents

    /// A document from Notion, Google Docs or Granola. Replaces the text when it changed and
    /// keeps visit counts. A page Felix read in the browser keeps its source, so its history
    /// stays, and only gains the fresher text.
    @discardableResult
    func upsertSourceDoc(_ d: DocUpsert, analysis: Analysis, visitKind: String) -> Bool {
        queue.sync {
            var changed = false
            do {
                try db.transaction {
                    let existing = try db.query("SELECT id, source, mtime, body FROM docs WHERE key = ?", [d.key]) {
                        ($0.int(0), $0.text(1), $0.double(2), $0.text(3))
                    }.first
                    let id: Int64
                    if let (eid, esource, emtime, ebody) = existing {
                        if abs(emtime - d.mtime) < 0.5 && ebody == d.body { return }
                        let keepSource = esource == "web" ? "web" : d.source.rawValue
                        try db.run("""
                            UPDATE docs SET source = ?, url = ?, title = ?, description = ?, body = ?, project = ?,
                              first_seen = min(first_seen, ?), last_seen = max(last_seen, ?), mtime = ?, has_text = ?, indexed_at = ?
                            WHERE id = ?
                            """, [keepSource, d.url, d.title, d.description, d.body, d.project, d.firstSeen, d.lastSeen, d.mtime,
                                  d.body.isEmpty ? 0 : 1, Date().timeIntervalSince1970, eid])
                        id = eid
                    } else {
                        try db.run("""
                            INSERT INTO docs(key, source, url, title, description, body, project, root, first_seen, last_seen,
                              visit_count, dwell, has_text, mtime, indexed_at)
                            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                            """, [d.key, d.source.rawValue, d.url, d.title, d.description, d.body, d.project, d.root,
                                  d.firstSeen, d.lastSeen, d.visitCount, d.dwell, d.body.isEmpty ? 0 : 1, d.mtime, Date().timeIntervalSince1970])
                        id = db.lastInsertRowID
                    }
                    try replacePassages(docID: id, title: d.title, analysis: analysis)
                    recordVisitLocked(docID: id, at: d.lastSeen, kind: visitKind, during: d.project)
                    changed = true
                }
                if changed { generation += 1 }
            } catch {
                appLog.error("source write failed: \(String(describing: error), privacy: .public)")
            }
            return changed
        }
    }

    /// Removes everything a source brought in, when its switch is turned off. Pages read in
    /// the browser stay.
    func deleteSource(_ source: SourceType) {
        let keys = queue.sync { (try? db.query("SELECT key FROM docs WHERE source = ?", [source.rawValue]) { $0.text(0) }) ?? [] }
        deleteDocs(keys: keys)
    }

    /// Keys and modification times for one source, so syncs only touch what changed.
    func sourceMtimes(_ source: SourceType) -> [String: Double] {
        fileMtimes(source: source)
    }

    /// Google Docs, Sheets and Slides seen in this browser or Chrome, newest first.
    func googleDocURLs(limit: Int = 300) -> [(key: String, url: String, title: String, lastSeen: Double, hasText: Bool, indexedAt: Double, source: SourceType)] {
        queue.sync {
            (try? db.query("""
                SELECT key, url, title, last_seen, has_text, indexed_at, source FROM docs
                WHERE key LIKE 'https://docs.google.com/%/d/%' ORDER BY last_seen DESC LIMIT ?
                """, [limit]) { (key: $0.text(0), url: $0.text(1), title: $0.text(2), lastSeen: $0.double(3), hasText: $0.int(4) != 0,
                                 indexedAt: $0.double(5), source: SourceType(rawValue: $0.text(6)) ?? .web) }) ?? []
        }
    }
}
