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
                                              options: GenerationOptions(temperature: 0))
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
        let top = counts.counts.sorted { $0.value > $1.value }.prefix(6).map { counts.display[$0.key] ?? $0.key }
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
                                              generating: Verdict.self, options: GenerationOptions(temperature: 0))
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

    static func gate(_ p: RankParams, reranker: Bool) -> Gate {
        if reranker {
            // The reranker's scores are close to 0 or 1, so the bar sits low and the judgment
            // handles the middle. The slider (0.1 to 0.9, default 0.4) moves it from 0.05 to 0.65.
            var bar = min(0.95, max(0.05, p.threshold - 0.25))
            if let o = ProcessInfo.processInfo.environment["BROWSERPOC_BAR"], let v = Double(o) { bar = v }
            return Gate(bar: bar, strong: max(bar + 0.2, 0.85), usesReranker: true)
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
        let summary = work ?? ContextReader.fallback(input, counts: counts, entities: ents)
        var entities: [String: String] = [:]
        for e in ents { entities[e.name] = e.display }
        for e in summary.entities {
            let folded = TextAnalysis.fold(Substring(e)).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if folded.count >= 3 && entities[folded] == nil { entities[folded] = e }
        }
        // Query texts for dense search: the context's own passages plus the search queries.
        var texts: [String] = []
        let chunks = TextAnalysis.chunk(ContextReader.window(input, limit: 3000), target: 600, maxChunks: 3)
        texts.append(contentsOf: chunks)
        if summary.fromModel {
            texts.append(summary.topic + ". " + summary.intent)
            texts.append(contentsOf: summary.queries)
        }
        if texts.isEmpty && !input.title.isEmpty { texts.append(input.title) }
        var qv: [EmbedderID: [[Float]]] = [:]
        let present = store.vectorCounts().filter { $0.value > 0 }.map { $0.key }
        for m in present {
            let vs = Intelligence.shared.embedQueries(texts, using: m).compactMap { $0 }
            if !vs.isEmpty { qv[m] = vs }
        }
        var rq = "Working on: \(input.title)."
        if summary.fromModel { rq += " Topic: \(summary.topic). Intent: \(summary.intent)." }
        rq += " Text: " + String(ContextReader.window(input, limit: 600).dropFirst(input.title.count + 12))
        return HybridQuery(input: input, counts: counts, entities: entities, nouns: nouns,
                           queries: summary.queries, queryVectors: qv, rerankQuery: String(rq.prefix(1200)), work: work)
    }

    /// Retrieves, reranks and gates. Synchronous; run it off the main thread.
    static func rank(_ q: HybridQuery, _ p: RankParams, store: IndexStore) -> Ranked {
        let cands = store.hybridCandidates(q, p, perSection: 24)
        let useReranker = Intelligence.shared.hasReranker
        var g = gate(p, reranker: useReranker)
        var out = Ranked(gate: g)
        out.terms = cands.terms
        for c in cands.all { out.candidates[c.doc.id] = c }

        var scored: [(Candidate, Double, Double?)] = []
        if useReranker {
            for list in [cands.sites, cands.docs] where !list.isEmpty {
                // The reranker reads the best passage of the top 20 by fusion, plus anything on screen.
                var pool = Array(list.prefix(20))
                for c in list.dropFirst(20) where p.keepIDs.contains(c.doc.id) { pool.append(c) }
                let docs = pool.map { "Title: \($0.doc.title)\n\($0.passage)" }
                if let scores = Intelligence.shared.rerank(query: q.rerankQuery, documents: docs) {
                    for (i, c) in pool.enumerated() {
                        var s = Double(scores[i])
                        if c.penalized { s *= 0.7 }
                        // A bare title can't carry a strong match on its own.
                        if !c.doc.hasText { s *= 0.8 }
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
        scored.sort { $0.1 > $1.1 }
        out.scored = scored.map { ($0.0.doc.title, $0.1) }
        for (c, s, rr) in scored {
            let m = match(c, score: s, rerank: rr, norm: cands.keywordNorm)
            if p.keepIDs.contains(c.doc.id) { out.kept[c.doc.id] = m }
            guard s >= g.bar else { continue }
            if c.section == .sites, out.sites.count < p.limit + 2 { out.sites.append(m) }
            if c.section == .docs, out.docs.count < p.limit + 2 { out.docs.append(m) }
        }
        return out
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
