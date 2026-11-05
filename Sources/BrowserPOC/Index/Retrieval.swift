import Accelerate
import Foundation

/// What hybrid retrieval knows about the current context. Built outside the index lock,
/// because embedding the queries and asking the language model take time.
struct HybridQuery {
    let input: ContextInput
    let counts: TermCounts
    /// Folded names from NLTagger and from the model's description.
    var entities: [String: String]   // folded -> display
    let nouns: Set<String>
    /// Search queries: the model's, or the title and top words when there's no model.
    var queries: [String]
    /// Query vectors per embedder that has vectors in the index.
    var queryVectors: [EmbedderID: [[Float]]]
    /// A compact description of the context for the cross-encoder.
    var rerankQuery: String
    var work: WorkingContextSummary?
}

/// One retrieved item before the reranker and the judgment.
struct Candidate {
    let doc: DocMeta
    var section: CardSection
    var passage: String
    var fused: Double
    var keywordWeight: Double
    var dense: Float
    /// Meaning match in 0...1, calibrated per embedder.
    var meaning: Double
    var sharedTerms: [String]
    var sharedEntities: [String]
    var topicTerms: [String]
    var foundBy: [String]
    var penalized: Bool
}

struct CandidateSet {
    var sites: [Candidate] = []
    var docs: [Candidate] = []
    var terms: [String] = []
    /// What a full keyword match weighs, for the no-reranker fallback score.
    var keywordNorm: Double = 1
    var all: [Candidate] { sites + docs }
}

/// A Notion page or Google Doc has one identity whether it was read in the browser or came
/// from its source, so the panel never shows it twice.
enum CanonicalID {
    static func of(url: String) -> String? {
        guard let u = URL(string: url) else { return nil }
        if let d = WritingKey.googleDoc(u) { return "gdoc:" + d.id }
        if WritingKey.isNotion(u) || u.host?.lowercased() == "app.notion.com" {
            let last = u.path.split(separator: "/").last.map(String.init) ?? ""
            let hex = last.filter { $0.isHexDigit }
            if hex.count >= 32 { return "notion:" + String(hex.suffix(32)).lowercased() }
        }
        return nil
    }
}

extension IndexStore {
    static let rrfK = 60.0

    /// Runs keyword, meaning and name retrieval over passages and fuses them with reciprocal
    /// rank fusion, per section. Returns up to `perSection` candidates each, with their best passage.
    func hybridCandidates(_ q: HybridQuery, _ p: RankParams, perSection: Int = 24) -> CandidateSet {
        queue.sync {
            do { return try hybridLocked(q, p, perSection: perSection) } catch {
                appLog.error("hybrid retrieve failed: \(String(describing: error), privacy: .public)")
                return CandidateSet()
            }
        }
    }

    private func hybridLocked(_ q: HybridQuery, _ p: RankParams, perSection: Int) throws -> CandidateSet {
        var out = CandidateSet()
        let now = p.now.timeIntervalSince1970
        let totalDocs = Int(try db.scalarInt("SELECT count(*) FROM docs"))
        guard totalDocs > 0 else { return out }
        let excluded = Set(try db.query("SELECT id FROM docs WHERE key = ? OR max(last_opened, last_seen) > ?",
                                        [q.input.key, now - p.recentWindow]) { $0.int(0) })
        // A page read in the browser and the same doc from its source count as the current item too.
        let currentCanon = CanonicalID.of(url: q.input.key)
        let eligible = max(1, totalDocs - excluded.count)
        let totalPassages = max(1, Int(try db.scalarInt("SELECT count(*) FROM passages")))
        let sectionOf = try sectionMap(p.writingSites)

        // 1. Distinctive context words: frequent here, rare in the index.
        let vocab = try db.prepare("SELECT doc FROM pfts_vocab WHERE term = ?")
        var weighted: [(String, Double)] = []
        for (t, tf) in q.counts.counts.sorted(by: { $0.value > $1.value }).prefix(150) {
            var pdf = 0
            for v in Self.termVariants(t) { vocab.bind([v]); if try vocab.step() { pdf += Int(vocab.int(0)) } }
            guard pdf > 0, Double(pdf) < max(6, 0.15 * Double(totalPassages)) else { continue }
            let idf = log(Double(totalPassages + 1) / (Double(pdf) + 0.5))
            weighted.append((t, (1 + log(tf)) * idf))
        }
        weighted.sort { $0.1 > $1.1 }
        let terms = Array(weighted.prefix(14))
        out.terms = terms.map { $0.0 }
        let termWeight = Dictionary(uniqueKeysWithValues: terms)
        out.keywordNorm = max(terms.prefix(8).reduce(0) { $0 + $1.1 }, 4 * log(1 + Double(eligible)))

        // Ranked lists of doc ids, per section. Each list is one retriever.
        var lists: [(name: String, ranked: [CardSection: [Int64]])] = []
        var bestPassage: [Int64: (Int64, Double)] = [:]   // doc -> (passage, strength)
        var denseBest: [Int64: Float] = [:]
        var meaningBest: [Int64: Double] = [:]

        func bm25List(_ expr: String, name: String) throws {
            let stmt = try db.prepare("""
                SELECT p.id, p.doc_id FROM pfts JOIN passages p ON p.id = pfts.rowid
                WHERE pfts MATCH ? ORDER BY bm25(pfts, 3.0, 1.0) LIMIT 3000
                """)
            stmt.bind([expr])
            var seen = Set<Int64>()
            var ranked: [CardSection: [Int64]] = [:]
            var rank = 0
            while try stmt.step() {
                let pid = stmt.int(0), did = stmt.int(1)
                if excluded.contains(did) || seen.contains(did) { continue }
                seen.insert(did)
                let sec = sectionOf[did] ?? .sites
                if ranked[sec, default: []].count >= 200 { continue }
                ranked[sec, default: []].append(did)
                rank += 1
                let strength = 1.0 / Double(rank + 1)
                if (bestPassage[did]?.1 ?? 0) < strength { bestPassage[did] = (pid, strength) }
            }
            if !ranked.isEmpty { lists.append((name, ranked)) }
        }

        // 2. BM25 over the context's own words.
        if !terms.isEmpty {
            let expr = terms.map { t in Self.termVariants(t.0).map(Self.quote).joined(separator: " OR ") }.joined(separator: " OR ")
            try bm25List(expr, name: "keyword")
        }
        // 3. BM25 over each search query.
        for query in q.queries.prefix(4) {
            let words = TextAnalysis.rawWords(query).map(TextAnalysis.fold).filter(TextAnalysis.isContentWord)
            guard words.count >= 1 else { continue }
            try bm25List(words.prefix(8).map(Self.quote).joined(separator: " OR "), name: "queries")
        }

        // 4. Dense search, one list per embedder that has both query and passage vectors.
        for (model, qvecs) in q.queryVectors {
            guard let set = vectorSets[model], let d = vectorDims[model], !qvecs.isEmpty else { continue }
            let qs = qvecs.filter { $0.count == d }
            guard !qs.isEmpty else { continue }
            var scored: [(Int64, Float)] = []
            scored.reserveCapacity(set.count)
            for (did, plist) in set where !excluded.contains(did) {
                var best: Float = -1
                var bestPid: Int64 = 0
                for (pid, v) in plist {
                    var m: Float = -1
                    v.withUnsafeBufferPointer { vp in
                        for c in qs {
                            var r: Float = 0
                            c.withUnsafeBufferPointer { cp in vDSP_dotpr(vp.baseAddress!, 1, cp.baseAddress!, 1, &r, vDSP_Length(d)) }
                            m = max(m, r)
                        }
                    }
                    if m > best { best = m; bestPid = pid }
                }
                scored.append((did, best))
                let floor = Self.denseFloor(model), strong = Self.denseStrong(model)
                let calibrated = Double(max(0, min(1, (best - floor) / max(0.01, strong - floor + 0.12))))
                meaningBest[did] = max(meaningBest[did] ?? 0, calibrated)
                if best > (denseBest[did] ?? -1) {
                    denseBest[did] = best
                    // Meaning picks the passage when it's the stronger signal.
                    if (bestPassage[did]?.1 ?? 0) < Double(best) { bestPassage[did] = (bestPid, Double(best)) }
                }
            }
            scored.sort { $0.1 > $1.1 }
            var ranked: [CardSection: [Int64]] = [:]
            for (did, s) in scored where s > Self.denseFloor(model) {
                let sec = sectionOf[did] ?? .sites
                if ranked[sec, default: []].count < 150 { ranked[sec, default: []].append(did) }
            }
            if !ranked.isEmpty { lists.append(("meaning", ranked)) }
        }

        // 5. Shared names, rarer names first.
        var docEntities: [Int64: [String]] = [:]
        let names = Array(q.entities.keys.prefix(40))
        if !names.isEmpty {
            let ph = Array(repeating: "?", count: names.count).joined(separator: ",")
            let rows = try db.query("SELECT doc_id, name, display FROM entities WHERE name IN (\(ph))", names) { ($0.int(0), $0.text(1), $0.text(2)) }
            var df: [String: Int] = [:]
            for (_, n, _) in rows { df[n, default: 0] += 1 }
            var score: [Int64: Double] = [:]
            for (did, n, disp) in rows where !excluded.contains(did) {
                if !(docEntities[did]?.contains(disp) ?? false) { docEntities[did, default: []].append(disp) }
                score[did, default: 0] += log(Double(eligible + 1) / Double((df[n] ?? 1) + 1))
            }
            var ranked: [CardSection: [Int64]] = [:]
            for (did, _) in score.sorted(by: { $0.value > $1.value }) {
                ranked[sectionOf[did] ?? .sites, default: []].append(did)
            }
            if !ranked.isEmpty { lists.append(("names", ranked)) }
        }

        // 6. Reciprocal rank fusion, per section.
        var fused: [Int64: Double] = [:]
        var foundBy: [Int64: Set<String>] = [:]
        for l in lists {
            for (_, ids) in l.ranked {
                for (r, did) in ids.enumerated() {
                    fused[did, default: 0] += 1 / (Self.rrfK + Double(r + 1))
                    foundBy[did, default: []].insert(l.name)
                }
            }
        }
        // Keep items already on screen in the pool so they can stay.
        for id in p.keepIDs where fused[id] == nil && !excluded.contains(id) { fused[id] = 0 }
        guard !fused.isEmpty else { return out }

        // Dismissals: hidden for this context, lower in similar ones.
        var hidden = Set<Int64>()
        var penalty: [Int64: Double] = [:]
        let termSet = Set(out.terms)
        for (d, ck, ts) in try db.query("SELECT doc_id, context_key, terms FROM dismissals", [], { ($0.int(0), $0.text(1), $0.text(2)) }) {
            if ck == q.input.key { hidden.insert(d); continue }
            let s = Set(ts.split(separator: " ").map(String.init))
            let overlap = termSet.isEmpty || s.isEmpty ? 0 : Double(termSet.intersection(s).count) / Double(min(termSet.count, s.count))
            if overlap >= 0.4 { penalty[d] = 0.7 }
        }

        var top: [CardSection: [Int64]] = [:]
        for (did, f) in fused.sorted(by: { $0.value > $1.value }) where !hidden.contains(did) {
            let sec = sectionOf[did] ?? .sites
            if top[sec, default: []].count < perSection || p.keepIDs.contains(did) {
                top[sec, default: []].append(did)
                _ = f
            }
        }
        let ids = top.values.flatMap { $0 }
        guard !ids.isEmpty else { return out }

        // 7. Metadata and passages for the pool.
        let ph = Array(repeating: "?", count: ids.count).joined(separator: ",")
        var metas: [Int64: DocMeta] = [:]
        for m in try db.query("SELECT \(Self.metaColumns) FROM docs WHERE id IN (\(ph))", ids, Self.meta) { metas[m.id] = m }
        var passages: [Int64: [(Int64, String)]] = [:]
        for (pid, did, text) in try db.query("SELECT id, doc_id, text FROM passages WHERE doc_id IN (\(ph)) ORDER BY idx", ids, {
            ($0.int(0), $0.int(1), $0.text(2))
        }) { passages[did, default: []].append((pid, text)) }

        var seenCanon: [String: (CardSection, Int)] = [:]
        for sec in CardSection.allCases {
            var list: [Candidate] = []
            for did in top[sec] ?? [] {
                guard let meta = metas[did] else { continue }
                let canon = CanonicalID.of(url: meta.url)
                if let canon, canon == currentCanon { continue }
                let plist = passages[did] ?? []
                let chosen = plist.first { $0.0 == bestPassage[did]?.0 }?.1 ?? plist.first?.1 ?? meta.description
                // Shared words, checked against every passage of the item.
                let folded = plist.map { TextAnalysis.fold(Substring($0.1)) }.joined(separator: " ") + " " + TextAnalysis.fold(Substring(meta.title))
                let shared = terms.filter { t in Self.termVariants(t.0).contains { folded.contains($0) } }.map { $0.0 }
                let kw = shared.reduce(0) { $0 + (termWeight[$1] ?? 0) }
                let c = Candidate(
                    doc: meta, section: sec,
                    passage: meta.hasText ? Snippet.make(chosen, terms: shared.map { q.counts.display[$0] ?? $0 } + (docEntities[did] ?? []), title: meta.title, length: 600) : Snippet.prettyURL(meta.url),
                    fused: fused[did] ?? 0, keywordWeight: kw, dense: denseBest[did] ?? -1, meaning: meaningBest[did] ?? 0,
                    sharedTerms: shared.map { q.counts.display[$0] ?? $0 },
                    sharedEntities: docEntities[did] ?? [],
                    topicTerms: Self.topicOrder(shared.filter { q.nouns.contains($0) }, title: meta.title).map { q.counts.display[$0] ?? $0 },
                    foundBy: Array(foundBy[did] ?? []).sorted(),
                    penalized: penalty[did] != nil)
                if let canon {
                    if let (s0, i) = seenCanon[canon] {
                        // One card per document: keep the copy that has text.
                        if s0 == sec, !list[i].doc.hasText && meta.hasText { list[i] = c }
                        continue
                    }
                    seenCanon[canon] = (sec, list.count)
                }
                list.append(c)
            }
            list.sort { $0.fused > $1.fused }
            if sec == .sites { out.sites = list } else { out.docs = list }
        }
        return out
    }

    static func termVariants(_ t: String) -> [String] {
        var out = [t]
        if t.count > 4 && t.hasSuffix("ies") { out.append(String(t.dropLast(3)) + "y") }
        else if t.count > 4 && t.hasSuffix("s") && !t.hasSuffix("ss") { out.append(String(t.dropLast())) }
        else if !t.hasSuffix("s") { out.append(t + "s") }
        return out
    }

    static func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    /// Below this cosine a passage isn't a meaning match at all. Each model has its own scale.
    static func denseFloor(_ m: EmbedderID) -> Float {
        switch m {
        case .gemma: return 0.45
        case .contextual: return 0.6
        case .sentence: return 0.6
        }
    }

    /// Cosine at which meaning alone counts as strong evidence, per model.
    static func denseStrong(_ m: EmbedderID) -> Float {
        switch m {
        case .gemma: return 0.62
        case .contextual: return 0.85
        case .sentence: return 0.78
        }
    }
}
