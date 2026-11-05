import Foundation
import FoundationModels

/// What Felix is doing right now, as the on-device model reads it.
struct WorkingContextSummary: Equatable, Sendable {
    var topic: String
    var intent: String
    var entities: [String]
    var queries: [String]
    var fromModel: Bool
}

/// Reads what's in front of Felix and describes it with Foundation Models' guided generation.
enum ContextReader {
    @Generable
    struct Description {
        @Guide(description: "What the user is working on, as a short noun phrase of 3 to 8 words")
        var topic: String
        @Guide(description: "What the user is trying to do right now, in one short sentence")
        var intent: String
        @Guide(description: "Specific people, companies, products, projects, papers or technologies named in the text", .maximumCount(8))
        var entities: [String]
        @Guide(description: "Three different search queries, each 3 to 8 words, that would find earlier pages, notes, docs or meetings that help with this work", .count(3))
        var queries: [String]
    }

    static let instructions = """
    You read what is on the user's screen in a browser and describe their current work for a search system \
    that brings back things they saw or wrote before. Use only what the text says. Be specific: name the \
    actual subject, not the kind of page.
    """

    /// The part of the context the model sees. The on-device model has a 4,096-token window, so
    /// this stays well under it: the title, the start of the text, and for notes the latest part,
    /// which is where Felix is typing.
    static func window(_ input: ContextInput, limit: Int = 2400) -> String {
        let text = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var body: String
        if text.count <= limit {
            body = text
        } else if input.kind == .note {
            body = String(text.prefix(limit / 3)) + "\n...\n" + String(text.suffix(limit * 2 / 3))
        } else {
            body = String(text.prefix(limit))
        }
        let kind = input.kind == .page ? "Web page" : "Note being written"
        body = "\(kind): \(input.title)\n\(body)"
        return body
    }

    static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    static func describe(_ input: ContextInput) async -> WorkingContextSummary? {
        guard isAvailable else { return nil }
        let session = LanguageModelSession(instructions: instructions)
        do {
            let r = try await session.respond(to: window(input), generating: Description.self,
                                              options: GenerationOptions(sampling: .greedy))
            let d = r.content
            return WorkingContextSummary(topic: Fmt.clean(d.topic), intent: Fmt.clean(d.intent),
                                         entities: d.entities.map(Fmt.clean).filter { !$0.isEmpty },
                                         queries: d.queries.map(Fmt.clean).filter { !$0.isEmpty }, fromModel: true)
        } catch {
            appLog.notice("context description failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Without the model: the title as the topic, and the top words as one query.
    static func fallback(_ input: ContextInput, counts: TermCounts, entities: [Entity]) -> WorkingContextSummary {
        let top = counts.counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(6).map { counts.display[$0.key] ?? $0.key }
        var queries: [String] = []
        if !input.title.isEmpty { queries.append(input.title) }
        if !top.isEmpty { queries.append(top.joined(separator: " ")) }
        return WorkingContextSummary(topic: input.title, intent: "", entities: entities.prefix(8).map { $0.display },
                                     queries: queries, fromModel: false)
    }
}

/// A yes or no from the on-device model on whether an item helps right now.
struct Judgment: Equatable, Sendable {
    let helpful: Bool
    let confidence: Double
    let reason: String
}

enum Judge {
    @Generable
    struct Verdict {
        @Guide(description: "One short sentence, at most 12 words, naming what the earlier item covers that bears on the current work. Use only facts from the earlier item. Start with It covers or a similar plain opening.")
        var reason: String
        @Guide(description: "True if the earlier item would help with the current work, even partly or as background")
        var helpful: Bool
        @Guide(description: "How sure you are, from 0 to 100", .range(0...100))
        var confidence: Int
    }

    static let instructions = """
    You help a browser decide whether to show the user something they read or wrote before, next to what \
    they are working on now. An item is helpful when it covers the same subject, a source they might cite, \
    a detail they need, or background for the task. It is not helpful when it only shares a common word \
    or a broad field. Write the reason about the earlier item's content. Never say what the user did \
    beyond reading or writing it. No dashes, no quotes, no emoji.
    """

    static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    static func prompt(work: WorkingContextSummary?, input: ContextInput, item: Candidate, history: String) -> String {
        var s = "Current work: \(input.title)\n"
        if let w = work, w.fromModel {
            s += "Topic: \(w.topic)\nIntent: \(w.intent)\n"
        }
        s += "Excerpt: \(ContextReader.window(input, limit: 700))\n\n"
        s += "Earlier item: \(item.doc.title)\n\(history)\n\(item.passage.prefix(800))\n\nIs the earlier item helpful for the current work?"
        return s
    }

    static func judge(work: WorkingContextSummary?, input: ContextInput, item: Candidate, history: String) async -> Judgment? {
        guard isAvailable else { return nil }
        let session = LanguageModelSession(instructions: instructions)
        do {
            let r = try await session.respond(to: prompt(work: work, input: input, item: item, history: history),
                                              generating: Verdict.self, options: GenerationOptions(sampling: .greedy))
            let v = r.content
            return Judgment(helpful: v.helpful, confidence: Double(v.confidence) / 100, reason: Reasons.tidy(v.reason) ?? "")
        } catch {
            appLog.notice("judgment failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

/// The whole ranking pass: build the query, retrieve, rerank and gate. The judgment runs
/// separately, because it's slow and the panel shows confident cards before it finishes.
enum Pipeline {
    struct Gate {
        /// The bar a card's score must clear.
        let bar: Double
        /// Above this a card shows without waiting for the judgment.
        let strong: Double
        let usesReranker: Bool
    }

    struct Ranked {
        var sites: [Match] = []
        var docs: [Match] = []
        /// Items on screen that still score, for hysteresis.
        var kept: [Int64: Match] = [:]
        var terms: [String] = []
        var gate: Gate
        var candidates: [Int64: Candidate] = [:]
        /// Every scored candidate, best first, for the eval and the debug log.
        var scored: [(title: String, score: Double)] = []
        var matches: [Match] { sites + docs }
    }

    static let debugRank = ProcessInfo.processInfo.environment["BROWSERPOC_DEBUG_RANK"] != nil
    /// With the reranker, meaning has to agree too: a passage the embedder doesn't see as close
    /// doesn't show on the cross-encoder's word alone.
    static let meaningFloor = 0.8
    static let fusedWeight = Double(ProcessInfo.processInfo.environment["BROWSERPOC_FW"] ?? "") ?? 1.2
    /// Whether the model's search queries also run as keyword searches. They help recall on
    /// sparse indexes, but on the demo they pulled in loosely related pages.
    static let modelQueriesForKeywords = ProcessInfo.processInfo.environment["BROWSERPOC_FMQ"] != nil
    static let modelForRetrieval = ProcessInfo.processInfo.environment["BROWSERPOC_FM_RETRIEVAL"] != nil
    static let mmrWeight = Double(ProcessInfo.processInfo.environment["BROWSERPOC_MMR"] ?? "") ?? 1.5
    static let fusedFloor = Double(ProcessInfo.processInfo.environment["BROWSERPOC_FF"] ?? "") ?? 0.6

    static func gate(_ p: RankParams, reranker: Bool) -> Gate {
        if reranker {
            // Each candidate is judged against the part of the context it matched, which makes the
            // reranker generous, so the bar sits above the middle. The slider (0.1 to 0.9, default
            // 0.4) moves it from 0.3 to 0.95. Cards under `strong` wait for the model's judgment.
            var bar = min(0.95, max(0.3, p.threshold + 0.3))
            if let o = ProcessInfo.processInfo.environment["BROWSERPOC_BAR"], let v = Double(o) { bar = v }
            return Gate(bar: bar, strong: max(bar + 0.2, 0.9), usesReranker: true)
        }
        // Without the reranker the bar sits a little under the slider, and the judgment decides
        // the borderline band above it.
        let bar = max(0.1, p.threshold - 0.1)
        return Gate(bar: bar, strong: bar + 0.25, usesReranker: false)
    }

    /// Context words, names and query vectors. Embeds queries with every embedder the index has
    /// vectors from, so passages not yet re-embedded still match.
    static func makeQuery(_ input: ContextInput, work: WorkingContextSummary?, store: IndexStore) -> HybridQuery {
        let counts = TextAnalysis.termCounts(title: input.title, text: input.text)
        let ents = TextAnalysis.entities(input.title + "\n" + input.text)
        let nouns = TextAnalysis.nounKeys(input.title + "\n" + input.text)
        // The model's reading feeds the judgment and the reasons. Retrieval runs on the text itself,
        // so the cards don't change when the model's description does.
        let fallback = ContextReader.fallback(input, counts: counts, entities: ents)
        let summary = modelForRetrieval ? (work ?? fallback) : fallback
        var entities: [String: String] = [:]
        for e in ents { entities[e.name] = e.display }
        for e in summary.entities {
            let folded = TextAnalysis.fold(Substring(e)).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if folded.count >= 3 && entities[folded] == nil { entities[folded] = e }
        }
        // Query texts for dense search: the context's own passages plus the search queries.
        // Each part of a long note or page is its own query, so an item that matches one part
        // can be found and judged against that part.
        var texts: [String] = []
        let chunks = TextAnalysis.chunk(Snippet.body(String(input.text.prefix(12000)), title: input.title), target: 650, maxChunks: 10)
            .filter { IndexStore.proseFactor($0) > 0.4 || $0.count > 200 }
        texts.append(contentsOf: chunks)
        if summary.fromModel {
            texts.append(summary.topic + ". " + summary.intent)
            texts.append(contentsOf: summary.queries)
        }
        if texts.isEmpty && !input.title.isEmpty { texts.append(input.title) }
        var qv: [EmbedderID: [[Float]]] = [:]
        let present = store.vectorCounts().filter { $0.value > 0 }.map { $0.key }
        for m in present {
            // Kept aligned with the texts. A text that couldn't be embedded holds an empty vector.
            let vs = Intelligence.shared.embedQueries(texts, using: m).map { $0 ?? [] }
            if vs.contains(where: { !$0.isEmpty }) { qv[m] = vs }
        }
        let rq = rerankQuery(input, summary: summary, terms: counts)
        var hq = HybridQuery(input: input, counts: counts, entities: entities, nouns: nouns,
                             queries: (summary.fromModel && modelQueriesForKeywords) || !summary.fromModel ? summary.queries : [input.title],
                             queryVectors: qv, rerankQuery: String(rq.prefix(1200)), work: work)
        hq.queryTexts = texts
        hq.chunkCount = chunks.count
        return hq
    }

    /// What the cross-encoder reads as the query: the title, the model's reading when it ran, and
    /// the two parts of the text that carry the most distinctive words. Page chrome like
    /// newsletter banners and the note's own heading are left out.
    static func rerankQuery(_ input: ContextInput, summary: WorkingContextSummary, terms: TermCounts) -> String {
        let body = Snippet.body(input.text, title: input.title)
        let chunks = TextAnalysis.chunk(body, target: 320, maxChunks: 40)
        let top = Set(terms.counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(25).map { $0.key })
        var scored: [(Int, Double)] = []
        for (i, c) in chunks.enumerated() {
            let words = Set(TextAnalysis.rawWords(c).map(TextAnalysis.fold))
            let hits = Double(words.intersection(top).count)
            // Notes being written: the newest part matters a little more.
            let recency = input.kind == .note ? Double(i) / Double(max(1, chunks.count)) * 0.5 : 0
            scored.append((i, hits * IndexStore.proseFactor(c) + recency))
        }
        let picked = scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.prefix(2).map { $0.0 }.sorted()
        var q = input.title
        if summary.fromModel {
            q += "\nTopic: \(summary.topic)"
            if !summary.intent.isEmpty { q += "\nIntent: \(summary.intent)" }
        }
        let text = picked.map { chunks[$0] }.joined(separator: "\n")
        q += "\n" + (text.isEmpty ? String(body.prefix(600)) : String(text.prefix(700)))
        return String(q.prefix(1100))
    }

    /// How central each part of the context is: its similarity to the context as a whole. An
    /// aside scores lower than the part the note is mostly about.
    static func chunkCentrality(_ q: HybridQuery) -> [Double] {
        let n = q.chunkCount
        guard n > 1, let vs = (q.queryVectors[.gemma] ?? q.queryVectors.values.first), vs.count >= n else { return Array(repeating: 1, count: max(n, 0)) }
        let parts = vs.prefix(n).filter { !$0.isEmpty }
        guard let d = parts.first?.count, parts.count == n else { return Array(repeating: 1, count: n) }
        var mean = [Float](repeating: 0, count: d)
        for v in parts { for i in 0..<d { mean[i] += v[i] } }
        guard let m = VectorMath.normalized(mean) else { return Array(repeating: 1, count: n) }
        return parts.map { Double(VectorMath.dot($0, m)) }
    }

    /// The context as one vector: the mean of its parts.
    static func contextCentroid(_ q: HybridQuery) -> [Float]? {
        guard let vs = q.queryVectors[.gemma] ?? q.queryVectors.values.first else { return nil }
        let parts = vs.prefix(max(1, q.chunkCount)).filter { !$0.isEmpty }
        guard let d = parts.first?.count else { return nil }
        var mean = [Float](repeating: 0, count: d)
        for v in parts where v.count == d { for i in 0..<d { mean[i] += v[i] } }
        return VectorMath.normalized(mean)
    }

    /// How much an item is about the context as a whole, not just one part of it.
    static func globalSimilarity(_ c: Candidate, _ centroid: [Float]?) -> Double {
        guard let x = c.centroid, let y = centroid, x.count == y.count else { return 0 }
        return Double(VectorMath.dot(x, y))
    }

    /// The query one candidate is judged against: the part of the context its passage matched,
    /// with the title and the model's reading. Falls back to the whole-context query.
    static func rerankQuery(for c: Candidate, _ q: HybridQuery) -> String {
        guard let i = c.queryIndex, i < q.chunkCount, i < q.queryTexts.count else { return q.rerankQuery }
        // The title and the matched part only. The model's topic line made scores swing between
        // runs without making them better.
        return String((q.input.title + "\n" + q.queryTexts[i].prefix(700)).prefix(1000))
    }

    /// Retrieves, reranks and gates. Synchronous; run it off the main thread.
    static func rank(_ q: HybridQuery, _ p: RankParams, store: IndexStore) -> Ranked {
        let cands = store.hybridCandidates(q, p, perSection: 40)
        let useReranker = Intelligence.shared.hasReranker
        var g = gate(p, reranker: useReranker)
        var out = Ranked(gate: g)
        out.terms = cands.terms
        for c in cands.all { out.candidates[c.doc.id] = c }

        var scored: [(Candidate, Double, Double?)] = []
        if useReranker {
            for list in [cands.sites, cands.docs] where !list.isEmpty {
                // The reranker reads the top 24 by fusion, the closest item to each part of the
                // context (so a strong match for one paragraph isn't lost behind items that match
                // everything a little), and anything on screen.
                var pool = Array(list.prefix(20))
                var inPool = Set(pool.map { $0.doc.id })
                var extra: [Candidate] = []
                for qi in 0..<q.chunkCount {
                    let best = list.filter { $0.queryIndex == qi }.sorted { $0.dense != $1.dense ? $0.dense > $1.dense : $0.doc.id < $1.doc.id }.prefix(2)
                    for w in best where !inPool.contains(w.doc.id) { extra.append(w); inPool.insert(w.doc.id) }
                }
                pool += extra.sorted { $0.dense != $1.dense ? $0.dense > $1.dense : $0.doc.id < $1.doc.id }.prefix(14)
                for c in list.dropFirst(20) where p.keepIDs.contains(c.doc.id) && !inPool.contains(c.doc.id) { pool.append(c); inPool.insert(c.doc.id) }
                let docs = pool.map { "Title: \($0.doc.title)\n\($0.rawPassage.isEmpty ? $0.passage : $0.rawPassage)" }
                if let scores = Intelligence.shared.rerank(queries: pool.map { rerankQuery(for: $0, q) }, documents: docs) {
                    for (i, c) in pool.enumerated() {
                        var s = Double(scores[i])
                        if c.penalized { s *= 0.7 }
                        // A bare title can't carry a strong match on its own.
                        if !c.doc.hasText { s *= 0.8 }
                        if c.meaning < meaningFloor && !p.keepIDs.contains(c.doc.id) { s = min(s, 0.29) }
                        scored.append((c, s, Double(scores[i])))
                    }
                } else {
                    g = gate(p, reranker: false)
                    out.gate = g
                    for c in list { scored.append((c, fallbackScore(c, norm: cands.keywordNorm), nil)) }
                }
            }
        } else {
            for c in cands.all { scored.append((c, fallbackScore(c, norm: cands.keywordNorm), nil)) }
        }
        scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.doc.id < $1.0.doc.id }
        out.scored = scored.map { ($0.0.doc.title, $0.1) }
        if debugRank {
            for sec in CardSection.allCases {
                let rows = scored.filter { $0.0.section == sec }.prefix(Int(ProcessInfo.processInfo.environment["BROWSERPOC_DEBUG_N"] ?? "14") ?? 14).map { String(format: "%.2f q%d f%.3f m%.2f %@", $0.1, $0.0.queryIndex ?? -1, $0.0.fused, $0.0.meaning, String($0.0.doc.title.prefix(30))) }
                FileHandle.standardError.write(Data("    [\(sec.rawValue)] \(rows.joined(separator: " | "))\n".utf8))
            }
        }
        for (c, s, rr) in scored where p.keepIDs.contains(c.doc.id) {
            out.kept[c.doc.id] = match(c, score: s, rerank: rr, norm: cands.keywordNorm)
        }
        for sec in CardSection.allCases {
            let passing = scored.filter { $0.0.section == sec && $0.1 >= g.bar }
            let picked = select(passing, limit: p.limit + 2, keep: p.keepIDs, reranked: g.usesReranker)
            let ms = picked.map { match($0.0, score: $0.1, rerank: $0.2, norm: cands.keywordNorm) }
            if sec == .sites { out.sites = ms } else { out.docs = ms }
        }
        return out
    }

    /// Titles that only differ by a version, an export tag or a plural are the same item.
    static func titleKey(_ t: String) -> String {
        var s = TextAnalysis.fold(Substring(t))
        for pat in ["\\(export\\)", "\\(copy\\)", "\\bv[0-9]+\\b", "\\bdraft\\b", "\\bfinal\\b", " - wikipedia$"] {
            s = s.replacingOccurrences(of: pat, with: "", options: .regularExpression)
        }
        let words = TextAnalysis.rawWords(s).map { w -> String in
            let x = String(w)
            return x.count > 4 && x.hasSuffix("s") && !x.hasSuffix("ss") ? String(x.dropLast()) : x
        }
        return words.joined(separator: " ")
    }

    static func similarity(_ a: Candidate, _ b: Candidate) -> Float {
        guard let x = a.centroid, let y = b.centroid, x.count == y.count else { return 0 }
        return VectorMath.dot(x, y)
    }

    static func isNearDuplicate(_ a: Candidate, _ b: Candidate) -> Bool {
        if titleKey(a.doc.title) == titleKey(b.doc.title) && !titleKey(a.doc.title).isEmpty { return true }
        return similarity(a, b) >= 0.94
    }

    /// Picks the cards for one section. Near-duplicates collapse to one card, the better scored
    /// or, when close, the newer. Then maximal marginal relevance spreads the picks, so a
    /// handful of near-identical items from one project can't push out a strong item from
    /// elsewhere. Cards already on screen keep their place.
    static func select(_ passing: [(Candidate, Double, Double?)], limit: Int, keep: Set<Int64>, reranked: Bool) -> [(Candidate, Double, Double?)] {
        guard !passing.isEmpty else { return [] }
        let maxFused = passing.map { $0.0.fused }.max() ?? 1
        // With the reranker, many items score close to 1. Retrieval's own agreement breaks the tie.
        func relevance(_ e: (Candidate, Double, Double?)) -> Double {
            guard reranked else { return e.1 }
            // The reranker plus how strongly the retrievers agree on the item.
            let fusedNorm = maxFused > 0 ? e.0.fused / maxFused : 0
            return e.1 + fusedWeight * fusedNorm
        }
        // Collapse near-duplicates first. With the reranker, an item the retrievers barely
        // agree on doesn't show on the cross-encoder's word alone.
        var pool: [(Candidate, Double, Double?, Double)] = []
        let agreed = passing.filter { !reranked || maxFused <= 0 || $0.0.fused / maxFused >= fusedFloor || keep.contains($0.0.doc.id) }
        for e in agreed.sorted(by: { relevance($0) != relevance($1) ? relevance($0) > relevance($1) : $0.0.doc.id < $1.0.doc.id }) {
            let r = relevance(e)
            if let i = pool.firstIndex(where: { isNearDuplicate($0.0, e.0) }) {
                let old = pool[i]
                let newer = max(e.0.doc.lastSeen, e.0.doc.mtime) > max(old.0.doc.lastSeen, old.0.doc.mtime)
                if keep.contains(e.0.doc.id) || (!keep.contains(old.0.doc.id) && newer && r >= old.3 - 0.05) {
                    pool[i] = (e.0, e.1, e.2, r)
                }
                continue
            }
            pool.append((e.0, e.1, e.2, r))
        }
        var chosen: [(Candidate, Double, Double?, Double)] = pool.filter { keep.contains($0.0.doc.id) }
        var rest = pool.filter { !keep.contains($0.0.doc.id) }
        while chosen.count < limit, !rest.isEmpty {
            var bestI = 0, bestV = -Double.infinity
            for (i, e) in rest.enumerated() {
                let maxSim = chosen.map { Double(similarity($0.0, e.0)) }.max() ?? 0
                // Only close neighbours are penalised: items about the same thing, not the same field.
                // With the reranker the order already reflects fit, and spreading made it worse in
                // the demo eval. Without it, spreading keeps clusters of near-twins apart.
                let v = e.3 - (reranked ? 0 : mmrWeight) * max(0, maxSim - 0.85)
                if v > bestV { bestV = v; bestI = i }
            }
            chosen.append(rest.remove(at: bestI))
        }
        if debugRank {
            let rows = chosen.map { String(format: "%@ rr %.2f rel %.2f", String($0.0.doc.title.prefix(26)), $0.1, $0.3) }
            let next = rest.prefix(3).map { String(format: "%@ rr %.2f rel %.2f", String($0.0.doc.title.prefix(26)), $0.1, $0.3) }
            FileHandle.standardError.write(Data("    chose: \(rows.joined(separator: " | "))   next: \(next.joined(separator: " | "))\n".utf8))
        }
        return chosen.map { ($0.0, $0.1, $0.2) }
    }

    /// The score without a reranker: keyword, meaning and names, with the round 2 evidence rules.
    static func fallbackScore(_ c: Candidate, norm: Double) -> Double {
        let shared = c.sharedTerms.count
        var k = min(1, c.keywordWeight / max(norm, 0.01))
        if !c.doc.hasText { k = min(1, c.keywordWeight / max(norm * 0.5, 0.01)) }
        if shared < 2 { k *= 0.5 }
        let s = c.meaning
        let e = min(1, Double(c.sharedEntities.count) / 2)
        var score: Double
        if c.doc.hasText {
            score = (1.0 * k + 0.7 * s + 0.3 * e) / 2.0
        } else {
            score = (1.0 * k + 0.3 * e) / 1.3
            if k < 0.35 { score *= 0.5 }
        }
        let enough = shared >= 2 || c.sharedEntities.count >= 2 || s >= 0.75
        if !enough { score *= 0.5 }
        if !c.doc.hasText && shared < 2 { score *= 0.5 }
        if c.penalized { score *= 0.7 }
        return score
    }

    static func match(_ c: Candidate, score: Double, rerank: Double?, norm: Double) -> Match {
        var m = Match(doc: c.doc, keyword: min(1, c.keywordWeight / max(norm, 0.01)), semantic: c.meaning,
                      entity: min(1, Double(c.sharedEntities.count) / 2), score: score, passage: c.passage,
                      sharedTerms: c.sharedTerms, sharedEntities: c.sharedEntities, topicTerms: c.topicTerms,
                      penalized: c.penalized, section: c.section)
        m.rerank = rerank
        m.fused = c.fused
        m.foundBy = c.foundBy
        return m
    }

    /// Applies a judgment to a card that cleared the bar. Strong cards always stay. Borderline
    /// cards go when the model is fairly sure they don't help.
    static func accept(_ m: Match, judgment: Judgment?, gate: Gate) -> Bool {
        if m.score >= gate.strong { return true }
        guard let j = judgment else { return true }
        // The model rarely says no with high confidence, so a moderately sure no is enough.
        return j.helpful || j.confidence < 0.4
    }
}
