import Foundation
import SwiftUI

struct Card: Identifiable {
    var id: Int64 { match.doc.id }
    var match: Match
    var reason: String
    var reasonFromModel = false
    var feedback: String?
}

/// Keeps the right panel's cards. Each context runs in two passes. The first uses the text on
/// screen and shows the cards the reranker is sure about within a second or two. The second
/// adds the on-device model's description of what Felix is doing, and its judgment on
/// borderline cards. Cards already on screen stay put while they still qualify.
@MainActor
final class Resurfacer: ObservableObject {
    @Published private(set) var siteCards: [Card] = []
    @Published private(set) var docCards: [Card] = []
    var cards: [Card] { siteCards + docCards }
    @Published private(set) var hasContext = false
    @Published private(set) var isWorking = false
    /// The model's reading of the current context, when it ran.
    @Published private(set) var work: WorkingContextSummary?

    weak var model: BrowserModel?
    private(set) var context: ContextInput?
    private var contextTerms: [String] = []
    private var lastTerms = Set<String>()
    private var lastKey: String?
    private var lastWords = Set<String>()
    private var generation = 0
    private var indexObserver: NSObjectProtocol?
    private var modelsObserver: NSObjectProtocol?
    private var settingsWork: DispatchWorkItem?
    private var typingWork: DispatchWorkItem?

    /// Cards per context, so switching focus back to a pane doesn't refetch.
    private struct Cached { let sites: [Card]; let docs: [Card]; let terms: [String]; let at: Date }
    private var cache: [String: Cached] = [:]
    /// The model's description per context, with the words it was made from.
    private var summaries: [String: (words: Set<String>, summary: WorkingContextSummary)] = [:]
    /// Judgments per context and item.
    private var judgments: [String: Judgment] = [:]
    /// Borderline cards waiting for a judgment, per section.
    private var pending: [CardSection: [Match]] = [:]
    private var visits: [Int64: [Visit]] = [:]
    private var gate = Pipeline.Gate(bar: 0.5, strong: 0.85, usesReranker: true)
    /// How many retrievals have run. The self test uses it to check the cache.
    private(set) var retrievalCount = 0

    init() {
        indexObserver = NotificationCenter.default.addObserver(forName: .indexChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.indexDidChange() }
        }
        modelsObserver = NotificationCenter.default.addObserver(forName: .modelsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.indexDidChange() }
        }
    }

    func contextFromTab(_ tab: Tab) {
        guard tab.kind == .web else { return }
        if let e = tab.lastExtract, e.url == tab.webView?.url {
            setContext(ContextInput(key: URLKey.key(for: e.url), title: e.title, text: e.description + "\n" + e.text, kind: .page))
        } else if let wv = tab.webView, !wv.isLoading, wv.url != nil {
            tab.extract { [weak self, weak tab] e in
                guard let self, let tab, let e else { return }
                tab.lastExtract = e
                if self.model?.isSelected(tab) == true { self.contextFromTab(tab) }
            }
        } else if tab.isBlank {
            setContext(nil)
        }
    }

    func contextFromDocument(_ doc: NoteDocument) {
        guard doc.state == .ready else { return }
        setContext(ContextInput(key: URLKey.fileKey(doc.url), title: doc.title, text: doc.text,
                                kind: doc.isReadOnly ? .file : .note))
    }

    static func words(_ input: ContextInput) -> Set<String> {
        Set(TextAnalysis.rawWords(input.title + " " + input.text.prefix(20000)).map(TextAnalysis.fold).filter(TextAnalysis.isContentWord))
    }

    private func noteActivity(_ input: ContextInput) {
        if let m = model { ActivityTracker.shared.noteSpace(m.currentSpace?.name, count: m.spaces.count) }
        var writing = input.kind == .note
        if input.kind == .page, let u = URL(string: input.key) {
            writing = WritingKey.isWritingSite(u, list: Settings.shared.value.writingSites)
        }
        if writing { ActivityTracker.shared.noteWriting(title: input.title, key: input.key) }
    }

    func setContext(_ input: ContextInput?) {
        guard let input, (input.title.count + input.text.count) >= 40 else {
            generation += 1
            context = input
            hasContext = input != nil
            if input == nil || input?.key != lastKey { siteCards = []; docCards = []; lastTerms = []; lastKey = input?.key; work = nil }
            return
        }
        noteActivity(input)
        let words = Self.words(input)
        if input.key == lastKey, context != nil {
            // Same item, text changed: skip tiny edits, and wait for a pause in typing.
            if Self.jaccard(words, lastWords) >= 0.97 { context = input; return }
            context = input
            typingWork?.cancel()
            let w = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let c = self.context, c.key == input.key else { return }
                    self.generation += 1
                    self.lastWords = Self.words(c)
                    self.run(c, replace: false)
                }
            }
            typingWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: w)
            return
        }
        generation += 1
        typingWork?.cancel()
        context = input
        hasContext = true
        lastWords = words
        if input.key != lastKey, let c = cache[input.key], Date().timeIntervalSince(c.at) < 180 {
            siteCards = c.sites
            docCards = c.docs
            contextTerms = c.terms
            lastTerms = Set(c.terms)
            lastKey = input.key
            work = summaries[input.key]?.summary
            return
        }
        run(input, replace: false)
    }

    private var indexWork: DispatchWorkItem?

    /// Index changes come in bursts (a rescan, an import), so they're coalesced.
    private func indexDidChange() {
        indexWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.cache = [:]
                self?.refresh(replace: false)
            }
        }
        indexWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
    }

    private func storeCache() {
        guard let k = lastKey else { return }
        cache[k] = Cached(sites: siteCards, docs: docCards, terms: contextTerms, at: Date())
        if cache.count > 40, let oldest = cache.min(by: { $0.value.at < $1.value.at })?.key { cache[oldest] = nil }
    }

    /// Re-runs the current context, for index changes and tuning.
    func refresh(replace: Bool) {
        guard let c = context, (c.title.count + c.text.count) >= 40 else { return }
        generation += 1
        run(c, replace: replace)
    }

    func settingsChanged() {
        cache = [:]
        settingsWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refresh(replace: true) } }
        settingsWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    private func run(_ input: ContextInput, replace: Bool) {
        let gen = generation
        var params = RankParams.fromSettings(Settings.shared.value)
        params.keepIDs = replace ? [] : Set(cards.map { $0.id })
        isWorking = true
        retrievalCount += 1
        let words = Self.words(input)
        let cachedSummary: WorkingContextSummary? = {
            guard let s = summaries[input.key], Self.jaccard(s.words, words) >= 0.85 else { return nil }
            return s.summary
        }()
        guard let store = IndexStore.shared else { return }
        Task.detached(priority: .userInitiated) {
            // Pass 1: what's on screen, plus the model's description if a recent one fits.
            let q1 = Pipeline.makeQuery(input, work: cachedSummary, store: store)
            let r1 = Pipeline.rank(q1, params, store: store)
            let v1 = Self.loadVisits(r1, store: store)
            await MainActor.run {
                guard gen == self.generation else { return }
                self.apply(r1, visits: v1, input: input, params: params, replace: replace)
                if cachedSummary != nil || !ContextReader.isAvailable { self.isWorking = false }
            }
            await self.judgePending(input: input, gen: gen, work: cachedSummary)
            // Pass 2: ask the model what Felix is doing, then retrieve again with its queries.
            guard cachedSummary == nil, ContextReader.isAvailable else { return }
            guard await MainActor.run(body: { gen == self.generation }) else { return }
            guard let summary = await ContextReader.describe(input) else {
                await MainActor.run { if gen == self.generation { self.isWorking = false } }
                return
            }
            var p2 = params
            p2.keepIDs = await MainActor.run { Set(self.cards.map { $0.id }) }
            let q2 = Pipeline.makeQuery(input, work: summary, store: store)
            let r2 = Pipeline.rank(q2, p2, store: store)
            let v2 = Self.loadVisits(r2, store: store)
            await MainActor.run {
                self.summaries[input.key] = (words, summary)
                if self.summaries.count > 60, let k = self.summaries.keys.first { self.summaries[k] = nil }
                guard gen == self.generation else { return }
                self.work = summary
                self.apply(r2, visits: v2, input: input, params: p2, replace: false)
                self.isWorking = false
            }
            await self.judgePending(input: input, gen: gen, work: summary)
        }
    }

    nonisolated static func loadVisits(_ r: Pipeline.Ranked, store: IndexStore) -> [Int64: [Visit]] {
        var out: [Int64: [Visit]] = [:]
        for m in r.matches + Array(r.kept.values) where out[m.doc.id] == nil {
            out[m.doc.id] = store.visits(docID: m.doc.id, limit: 10)
        }
        return out
    }

    private func judgmentKey(_ docID: Int64, _ contextKey: String) -> String { "\(contextKey)|\(docID)" }

    private func apply(_ r: Pipeline.Ranked, visits newVisits: [Int64: [Visit]], input: ContextInput, params: RankParams, replace: Bool) {
        for (k, v) in newVisits { visits[k] = v }
        gate = r.gate
        let newTerms = Set(r.terms)
        let sameItem = input.key == lastKey
        let overlap = Self.jaccard(newTerms, lastTerms)
        let bigChange = replace || (!sameItem && overlap < 0.3)
        let old = cards
        siteCards = merge(.sites, old: old, fresh: r.sites, kept: r.kept, input: input, params: params, bigChange: bigChange, sameItem: sameItem)
        docCards = merge(.docs, old: old, fresh: r.docs, kept: r.kept, input: input, params: params, bigChange: bigChange, sameItem: sameItem)
        contextTerms = r.terms
        lastTerms = newTerms
        lastKey = input.key
        storeCache()
    }

    /// Keeps cards that still qualify in place, then appends new ones, within one section.
    /// Borderline new cards wait for the model's judgment before they appear.
    private func merge(_ sec: CardSection, old: [Card], fresh: [Match], kept: [Int64: Match], input: ContextInput,
                       params: RankParams, bigChange: Bool, sameItem: Bool) -> [Card] {
        var next: [Card] = []
        if !bigChange {
            for c in old {
                let m = fresh.first { $0.doc.id == c.id } ?? kept[c.id]
                // Hysteresis: a card on screen stays until it falls well under the bar.
                guard let m, m.section == sec, m.score >= gate.bar * 0.75 else { continue }
                var k = c
                k.match = m
                if !sameItem {
                    k.reason = Reasons.template(m, visits: visits[m.doc.id] ?? [])
                    k.reasonFromModel = false
                    k.feedback = nil
                }
                next.append(k)
            }
        }
        var waiting: [Match] = []
        for m in fresh where !next.contains(where: { $0.id == m.doc.id }) {
            let j = judgments[judgmentKey(m.doc.id, input.key)]
            let showNow = m.score >= gate.strong || !Judge.isAvailable || j != nil
            if showNow {
                guard Pipeline.accept(m, judgment: j, gate: gate) else { continue }
                if next.count < params.limit { next.append(card(m, judgment: j)) }
            } else if next.count + waiting.count < params.limit {
                waiting.append(m)
            }
        }
        pending[sec] = waiting
        return Array(next.prefix(params.limit))
    }

    private func card(_ m: Match, judgment: Judgment?) -> Card {
        var m = m
        let v = visits[m.doc.id] ?? []
        if let j = judgment {
            m.judgedHelpful = j.helpful
            m.judgeConfidence = j.confidence
            m.judgeReason = j.reason
            return Card(match: m, reason: Reasons.withJudgment(m, visits: v, judgment: j), reasonFromModel: j.helpful && !j.reason.isEmpty)
        }
        return Card(match: m, reason: Reasons.template(m, visits: v))
    }

    /// Judges borderline cards (which then appear or don't) and writes reasons for the cards on
    /// screen. One at a time, newest context only.
    nonisolated private func judgePending(input: ContextInput, gen: Int, work: WorkingContextSummary?) async {
        guard Judge.isAvailable else { return }
        while true {
            let next: (Match, CardSection)? = await MainActor.run {
                guard gen == self.generation else { return nil }
                for sec in CardSection.allCases {
                    if let m = self.pending[sec]?.first(where: { self.judgments[self.judgmentKey($0.doc.id, input.key)] == nil }) { return (m, sec) }
                }
                for c in self.cards where !c.reasonFromModel && self.judgments[self.judgmentKey(c.id, input.key)] == nil {
                    return (c.match, c.match.section)
                }
                return nil
            }
            guard let (m, sec) = next else { return }
            let history = Reasons.history(m.doc, visits: await MainActor.run { self.visits[m.doc.id] ?? [] })
            let cand = Candidate(doc: m.doc, section: sec, passage: m.passage, fused: m.fused, keywordWeight: 0, dense: 0,
                                 meaning: m.semantic, sharedTerms: m.sharedTerms, sharedEntities: m.sharedEntities,
                                 topicTerms: m.topicTerms, foundBy: m.foundBy, penalized: m.penalized)
            let j = await Judge.judge(work: work, input: input, item: cand, history: history)
                ?? Judgment(helpful: true, confidence: 0, reason: "")
            await MainActor.run {
                self.judgments[self.judgmentKey(m.doc.id, input.key)] = j
                if self.judgments.count > 600 { self.judgments.removeAll() }
                guard gen == self.generation else { return }
                self.applyJudgment(j, to: m, section: sec, contextKey: input.key)
            }
        }
    }

    private func applyJudgment(_ j: Judgment, to m: Match, section sec: CardSection, contextKey: String) {
        let limit = RankParams.fromSettings(Settings.shared.value).limit
        if let i = pending[sec]?.firstIndex(where: { $0.doc.id == m.doc.id }) {
            pending[sec]?.remove(at: i)
            guard Pipeline.accept(m, judgment: j, gate: gate) else { return }
            if sec == .sites, siteCards.count < limit, !siteCards.contains(where: { $0.id == m.doc.id }) { siteCards.append(card(m, judgment: j)) }
            if sec == .docs, docCards.count < limit, !docCards.contains(where: { $0.id == m.doc.id }) { docCards.append(card(m, judgment: j)) }
        } else {
            // A card already on screen gets the model's reason. It stays even on a no, so
            // nothing disappears under Felix while he reads.
            let update: (inout [Card]) -> Void = { list in
                guard let i = list.firstIndex(where: { $0.id == m.doc.id }) else { return }
                var c = list[i]
                c.match.judgedHelpful = j.helpful
                c.match.judgeConfidence = j.confidence
                c.match.judgeReason = j.reason
                if j.helpful && !j.reason.isEmpty {
                    c.reason = Reasons.withJudgment(c.match, visits: self.visits[m.doc.id] ?? [], judgment: j)
                }
                c.reasonFromModel = true
                list[i] = c
            }
            update(&siteCards)
            update(&docCards)
        }
        storeCache()
    }

    func dismiss(_ card: Card) {
        guard let key = lastKey else { return }
        IndexStore.shared.dismiss(docID: card.id, contextKey: key, terms: contextTerms)
        siteCards.removeAll { $0.id == card.id }
        docCards.removeAll { $0.id == card.id }
        storeCache()
    }

    func setFeedback(_ text: String, for card: Card) {
        if let i = siteCards.firstIndex(where: { $0.id == card.id }) { siteCards[i].feedback = text }
        if let i = docCards.firstIndex(where: { $0.id == card.id }) { docCards[i].feedback = text }
        storeCache()
    }

    /// Felix's own call on which section a card belongs in. Remembered per item.
    func move(_ card: Card, to sec: CardSection) {
        let key = card.match.doc.key
        Task.detached {
            IndexStore.shared.setOverride(key: key, section: sec)
            await MainActor.run {
                self.cache = [:]
                self.refresh(replace: false)
            }
        }
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        let u = a.union(b).count
        return u == 0 ? 0 : Double(a.intersection(b).count) / Double(u)
    }
}
