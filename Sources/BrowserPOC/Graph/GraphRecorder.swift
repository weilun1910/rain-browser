import Combine
import Foundation

/// Records the connections only the browser sees: link clicks, research adds, splits and
/// items used close together. Everything is stored by index key in `GraphStore`.
@MainActor
final class GraphRecorder {
    static let shared = GraphRecorder()

    /// An item must stay focused this long to count toward a session pair.
    static var minDwell: TimeInterval = 20
    /// Items focused within this window of each other count as used together.
    static var sessionWindow: TimeInterval = 600

    private weak var model: BrowserModel?
    private var bag: Set<AnyCancellable> = []
    private var focusKey: String?
    private var focusSince: Date?
    /// Recently used items, newest last: key and when focus on it ended.
    private(set) var recent: [(key: String, at: Date)] = []
    private var recordedSplits = Set<String>()
    /// Lets tests run the clock forward.
    var now: () -> Date = { Date() }

    // MARK: Link clicks

    /// Called by the WebKit navigation delegate when a link is followed, in place or into a new tab.
    nonisolated static func linkFollowed(from: URL?, to: URL?) {
        guard let from, let to, URLKey.isIndexableWeb(from), URLKey.isIndexableWeb(to) else { return }
        let s = Settings.shared.value
        if s.isExcluded(host: from.host) || s.isExcluded(host: to.host) { return }
        let a = URLKey.key(for: from), b = URLKey.key(for: to)
        guard a != b else { return }
        GraphStore.shared.recordNavigation(fromKey: a, toKey: b)
    }

    // MARK: Research

    /// Called when Add to research runs on a card. The edge starts at the note it went into,
    /// or at the item that was focused.
    func researchAdded(addedKey: String, model: BrowserModel) {
        let context: String?
        if let note = model.researchNote { context = URLKey.fileKey(note.url) } else { context = model.currentTab.flatMap(Self.key) }
        guard let context else { return }
        GraphStore.shared.recordResearch(contextKey: context, addedKey: addedKey)
    }

    // MARK: Splits and sessions

    func attach(_ model: BrowserModel) {
        guard self.model !== model else { return }
        self.model = model
        bag = []
        model.$selection
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.focusChanged() } }
            .store(in: &bag)
        model.$splits
            .receive(on: DispatchQueue.main)
            .sink { [weak self] splits in MainActor.assumeIsolated { self?.splitsChanged(splits) } }
            .store(in: &bag)
        GraphStore.shared.startWatching()
    }

    /// The index key for an item: a note's file key or a page's URL key. Nil for anything else.
    static func key(_ tab: Tab) -> String? {
        guard let u = tab.url else { return nil }
        if tab.kind == .note || tab.kind == .file { return URLKey.fileKey(u) }
        if tab.kind == .web { return URLKey.isIndexableWeb(u) ? URLKey.key(for: u) : nil }
        return nil
    }

    /// Focus moved. The item that had it counts toward session pairs if it stayed long enough.
    func focusChanged() {
        let key = model?.currentTab.flatMap(Self.key)
        guard key != focusKey else { return }
        endFocus()
        focusKey = key
        focusSince = key == nil ? nil : now()
    }

    /// Ends the current focus, as if the app lost it. Also used by tests.
    func endFocus() {
        guard let k = focusKey, let since = focusSince else { return }
        let t = now()
        focusKey = nil
        focusSince = nil
        guard t.timeIntervalSince(since) >= Self.minDwell else { return }
        recent.removeAll { t.timeIntervalSince($0.at) > Self.sessionWindow || $0.key == k }
        for r in recent { GraphStore.shared.recordTogether(r.key, k, detail: "session", at: t) }
        recent.append((k, t))
        if recent.count > 6 { recent.removeFirst(recent.count - 6) }
    }

    func splitsChanged(_ splits: [SplitRecord]) {
        guard let model else { return }
        for sp in splits {
            guard let l = model.tab(sp.left).flatMap(Self.key), let r = model.tab(sp.right).flatMap(Self.key) else { continue }
            let pair = l < r ? l + "\n" + r : r + "\n" + l
            if recordedSplits.contains(pair) { continue }
            recordedSplits.insert(pair)
            GraphStore.shared.recordTogether(l, r, detail: "split")
        }
    }
}
