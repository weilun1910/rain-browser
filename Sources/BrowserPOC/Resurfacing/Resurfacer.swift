import Foundation
import SwiftUI

struct Card: Identifiable {
    var id: Int64 { match.doc.id }
    var match: Match
    var reason: String
    var reasonFromModel = false
    var feedback: String?
}

/// Keeps the right panel's cards. Recomputes on page load and note pauses, and keeps
/// cards in place while the context stays roughly the same.
@MainActor
final class Resurfacer: ObservableObject {
    @Published private(set) var siteCards: [Card] = []
    @Published private(set) var docCards: [Card] = []
    var cards: [Card] { siteCards + docCards }
    @Published private(set) var hasContext = false
    @Published private(set) var isWorking = false

    weak var model: BrowserModel?
    private(set) var context: ContextInput?
    private var contextTerms: [String] = []
    private var lastTerms = Set<String>()
    private var lastKey: String?
    private var generation = 0
    private var indexObserver: NSObjectProtocol?
    private var settingsWork: DispatchWorkItem?

    init() {
        indexObserver = NotificationCenter.default.addObserver(forName: .indexChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(replace: false) }
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

    func setContext(_ input: ContextInput?) {
        generation += 1
        guard let input, (input.title.count + input.text.count) >= 40 else {
            context = input
            hasContext = input != nil
            if input == nil || input?.key != lastKey { siteCards = []; docCards = []; lastTerms = []; lastKey = input?.key }
            return
        }
        context = input
        hasContext = true
        run(input, replace: false)
    }

    /// Re-runs the current context, for index changes and tuning.
    func refresh(replace: Bool) {
        guard let c = context, (c.title.count + c.text.count) >= 40 else { return }
        generation += 1
        run(c, replace: replace)
    }

    func settingsChanged() {
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
        Task.detached(priority: .userInitiated) {
            let ctx = ContextAnalysis.make(input)
            let result = IndexStore.shared.retrieve(ctx, params)
            await MainActor.run {
                guard gen == self.generation else { return }
                self.isWorking = false
                self.apply(result, input: input, params: params, replace: replace)
            }
        }
    }

    private func apply(_ result: RetrievalResult, input: ContextInput, params: RankParams, replace: Bool) {
        let newTerms = Set(result.terms)
        let sameItem = input.key == lastKey
        let overlap = Self.jaccard(newTerms, lastTerms)
        let bigChange = replace || (!sameItem && overlap < 0.3)
        let old = cards
        siteCards = merge(.sites, old: old, fresh: result.sites, result: result, params: params, bigChange: bigChange, sameItem: sameItem)
        docCards = merge(.docs, old: old, fresh: result.docs, result: result, params: params, bigChange: bigChange, sameItem: sameItem)
        contextTerms = result.terms
        lastTerms = newTerms
        lastKey = input.key
        ReasonWriter.shared.cancelAll(except: input.key)
        for c in cards where !c.reasonFromModel {
            requestReason(for: c, input: input)
        }
    }

    /// Keeps cards that still qualify in place, then appends new ones, within one section.
    private func merge(_ sec: CardSection, old: [Card], fresh: [Match], result: RetrievalResult,
                       params: RankParams, bigChange: Bool, sameItem: Bool) -> [Card] {
        var next: [Card] = []
        if !bigChange {
            for c in old {
                let m = fresh.first { $0.doc.id == c.id } ?? result.kept[c.id]
                guard let m, m.section == sec, m.score >= params.threshold * 0.85 else { continue }
                var kept = c
                kept.match = m
                if !sameItem {
                    kept.reason = Reasons.template(m)
                    kept.reasonFromModel = false
                    kept.feedback = nil
                }
                next.append(kept)
            }
        }
        for m in fresh where next.count < params.limit && !next.contains(where: { $0.id == m.doc.id }) {
            next.append(Card(match: m, reason: Reasons.template(m)))
        }
        return Array(next.prefix(params.limit))
    }

    private func requestReason(for card: Card, input: ContextInput) {
        let key = input.key
        let docID = card.id
        if let cached = IndexStore.shared.cachedReason(docID: docID, contextKey: key) {
            setReason(cached, docID: docID, key: key)
            return
        }
        guard ReasonWriter.isAvailable else { return }
        let passage = TextAnalysis.chunk(input.text, target: 600, maxChunks: 1).first ?? input.text
        let prompt = ReasonWriter.prompt(contextTitle: input.title, contextPassage: passage, match: card.match)
        ReasonWriter.shared.request(.init(docID: docID, contextKey: key, prompt: prompt) { [weak self] text in
            self?.setReason(text, docID: docID, key: key)
        })
    }

    private func setReason(_ text: String, docID: Int64, key: String) {
        guard key == lastKey else { return }
        if let i = siteCards.firstIndex(where: { $0.id == docID }) { siteCards[i].reason = text; siteCards[i].reasonFromModel = true }
        if let i = docCards.firstIndex(where: { $0.id == docID }) { docCards[i].reason = text; docCards[i].reasonFromModel = true }
    }

    func dismiss(_ card: Card) {
        guard let key = lastKey else { return }
        IndexStore.shared.dismiss(docID: card.id, contextKey: key, terms: contextTerms)
        siteCards.removeAll { $0.id == card.id }
        docCards.removeAll { $0.id == card.id }
    }

    func setFeedback(_ text: String, for card: Card) {
        if let i = siteCards.firstIndex(where: { $0.id == card.id }) { siteCards[i].feedback = text }
        if let i = docCards.firstIndex(where: { $0.id == card.id }) { docCards[i].feedback = text }
    }

    /// Felix's own call on which section a card belongs in. Remembered per item.
    func move(_ card: Card, to sec: CardSection) {
        let key = card.match.doc.key
        Task.detached {
            IndexStore.shared.setOverride(key: key, section: sec)
            await MainActor.run { self.refresh(replace: false) }
        }
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        let u = a.union(b).count
        return u == 0 ? 0 : Double(a.intersection(b).count) / Double(u)
    }
}
