import Accelerate
import Foundation

/// An item close in meaning to another.
struct Neighbour {
    let doc: DocMeta
    let similarity: Double
    let passage: String
}

struct ItemEntity {
    let name: String
    let display: String
    let kind: String
    let count: Int
}

struct SearchFilters {
    /// Nil means every source.
    var sources: Set<SourceType>? = nil
    var section: CardSection? = nil
    /// Last seen or edited on or after.
    var since: Date? = nil
    var until: Date? = nil
    /// Use the cross-encoder when it's ready.
    var rerank: Bool = true
    var writingSites: [String] = AppSettings.defaultWritingSites
}

struct SearchHit {
    let doc: DocMeta
    let score: Double
    let passage: String
    let lastSeen: Date
    /// When and in what context Felix saw it, like the card reasons.
    let history: String
}

/// Read calls for the graph view and the MCP server. Synchronous and thread-safe. Call them
/// off the main thread.
extension IndexStore {
    func item(id: Int64) -> DocMeta? {
        queue.sync { (try? db.query("SELECT \(Self.metaColumns) FROM docs WHERE id = ?", [id], Self.meta))?.first }
    }

    /// The k items closest in meaning, using the best embedder this item has vectors from.
    func semanticNeighbours(itemID: Int64, k: Int = 10) -> [Neighbour] {
        queue.sync {
            let order: [EmbedderID] = [.gemma, .contextual, .sentence]
            guard let model = order.first(where: { vectorSets[$0]?[itemID]?.isEmpty == false }),
                  let mine = vectorSets[model]?[itemID], let set = vectorSets[model], let d = vectorDims[model] else { return [] }
            var mean = [Float](repeating: 0, count: d)
            for (_, v) in mine { vDSP_vadd(mean, 1, v, 1, &mean, 1, vDSP_Length(d)) }
            guard let centroid = VectorMath.normalized(mean) else { return [] }
            var scored: [(Int64, Float, Int64)] = []
            for (did, plist) in set where did != itemID {
                var best: Float = -1, bestPid: Int64 = 0
                for (pid, v) in plist {
                    var r: Float = 0
                    vDSP_dotpr(v, 1, centroid, 1, &r, vDSP_Length(d))
                    if r > best { best = r; bestPid = pid }
                }
                scored.append((did, best, bestPid))
            }
            scored.sort { $0.1 > $1.1 }
            var out: [Neighbour] = []
            let mineCanon = (try? db.query("SELECT url FROM docs WHERE id = ?", [itemID]) { $0.text(0) })?.first.flatMap(CanonicalID.of)
            for (did, sim, pid) in scored where out.count < k {
                guard let meta = (try? db.query("SELECT \(Self.metaColumns) FROM docs WHERE id = ?", [did], Self.meta))?.first else { continue }
                if let c = mineCanon, CanonicalID.of(url: meta.url) == c { continue }
                let text = (try? db.query("SELECT text FROM passages WHERE id = ?", [pid]) { $0.text(0) })?.first ?? ""
                out.append(Neighbour(doc: meta, similarity: Double(sim), passage: String(text.prefix(400))))
            }
            return out
        }
    }

    /// People, organisations and places named in the item, most mentioned first.
    func entities(itemID: Int64) -> [ItemEntity] {
        queue.sync {
            (try? db.query("SELECT name, display, kind, count FROM entities WHERE doc_id = ? ORDER BY count DESC", [itemID]) {
                ItemEntity(name: $0.text(0), display: $0.text(1), kind: $0.text(2), count: Int($0.int(3)))
            }) ?? []
        }
    }

    /// Topics from the content-tagging model when it has run on this item, otherwise the item's
    /// most distinctive words.
    func topics(itemID: Int64) -> [String] {
        queue.sync {
            let model = ((try? db.query("SELECT topic FROM topics WHERE doc_id = ? AND source = 'model'", [itemID]) { $0.text(0) }) ?? [])
                .filter { !$0.isEmpty }
            if !model.isEmpty { return model }
            guard let (title, body) = (try? db.query("SELECT title, body FROM docs WHERE id = ?", [itemID]) { ($0.text(0), $0.text(1)) })?.first else { return [] }
            let counts = TextAnalysis.termCounts(title: title, text: body)
            let total = max(1, Int((try? db.scalarInt("SELECT count(*) FROM passages")) ?? 1))
            guard let vocab = try? db.prepare("SELECT doc FROM pfts_vocab WHERE term = ?") else { return [] }
            var scored: [(String, Double)] = []
            for (t, tf) in counts.counts.sorted(by: { $0.value > $1.value }).prefix(60) {
                vocab.bind([t])
                let pdf = ((try? vocab.step()) == true) ? Int(vocab.int(0)) : 1
                scored.append((counts.display[t] ?? t, (1 + log(tf)) * log(Double(total + 1) / Double(pdf + 1))))
            }
            return scored.sorted { $0.1 > $1.1 }.prefix(5).map { $0.0 }
        }
    }

    /// The same hybrid retrieval as Related (keywords, meaning, names, rank fusion, then the
    /// reranker when it's ready), for a typed query. No model judgment, so it stays fast.
    func search(_ query: String, filters: SearchFilters = SearchFilters(), limit: Int = 20) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let input = ContextInput(key: "search:" + q, title: q, text: q, kind: .page)
        let work = WorkingContextSummary(topic: q, intent: "", entities: [], queries: [q], fromModel: false)
        var hq = Pipeline.makeQuery(input, work: work, store: self)
        // Typed queries are short. Embed them with the query prompt, not as a passage.
        for (m, _) in hq.queryVectors {
            let v = Intelligence.shared.embedQueries([q], using: m).compactMap { $0 }
            if !v.isEmpty { hq.queryVectors[m] = v }
        }
        hq.rerankQuery = q
        hq.queryTexts = [q]
        hq.chunkCount = 1
        var p = RankParams.fromSettings(AppSettings())
        p.recentWindow = 0
        p.writingSites = filters.writingSites
        let cands = hybridCandidates(hq, p, perSection: max(limit, 40))
        var pool = cands.all.filter { c in
            if let s = filters.sources, !s.contains(c.doc.source) { return false }
            if let sec = filters.section, c.section != sec { return false }
            let seen = max(c.doc.lastSeen, c.doc.mtime)
            if let since = filters.since, seen < since.timeIntervalSince1970 { return false }
            if let until = filters.until, seen > until.timeIntervalSince1970 { return false }
            return true
        }
        pool.sort { $0.fused > $1.fused }
        var scores: [Double] = pool.map { $0.fused * 30 }
        if filters.rerank, Intelligence.shared.hasReranker, !pool.isEmpty {
            let head = Array(pool.prefix(30))
            if let rr = Intelligence.shared.rerank(query: q, documents: head.map { "Title: \($0.doc.title)\n\($0.passage)" }) {
                for i in head.indices { scores[i] = Double(rr[i]) + 1 }  // reranked items stay above the rest
            }
        }
        let ranked = zip(pool, scores).sorted { $0.1 > $1.1 }.prefix(limit)
        return ranked.map { c, s in
            SearchHit(doc: c.doc, score: s, passage: c.passage, lastSeen: Date(timeIntervalSince1970: max(c.doc.lastSeen, c.doc.mtime)),
                      history: Reasons.history(c.doc, visits: visits(docID: c.doc.id, limit: 5)))
        }
    }
}
