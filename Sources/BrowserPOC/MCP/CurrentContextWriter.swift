import Combine
import Foundation

/// What Felix has in front of him, written by the app for `--mcp` to read.
/// Lives at current-context.json in the support folder.
struct CurrentContextFile: Codable, Equatable {
    struct Ref: Codable, Equatable {
        var title: String
        var url: String
        /// page or note
        var kind: String
        var key: String?
        /// When it was focused, for the trail.
        var at: Date?
    }
    struct SpaceRef: Codable, Equatable {
        var id: String
        var name: String
    }

    var updatedAt: Date
    /// The app's process id, so the server can tell whether it's still running.
    var pid: Int32
    var space: SpaceRef?
    var focused: Ref?
    var splitWith: Ref?
    var openTabs: [Ref] = []
    var related: [Ref] = []
    /// The last things focused, newest first.
    var trail: [Ref] = []

    static func url(_ root: URL) -> URL { root.appendingPathComponent("current-context.json") }
}

/// Watches the browser and the Related panel and keeps current-context.json up to date, about a
/// second after things settle. Only writes when something changed.
@MainActor
final class CurrentContextWriter {
    static let shared = CurrentContextWriter()

    private weak var model: BrowserModel?
    private var subscriptions: Set<AnyCancellable> = []
    private var work: DispatchWorkItem?
    private var trail: [CurrentContextFile.Ref] = []
    private var lastWritten: CurrentContextFile?
    var delay: TimeInterval = 1.0
    static let trailLength = 30

    func start(model: BrowserModel) {
        self.model = model
        subscriptions.removeAll()
        if let old = try? JSONDecoder.iso.decode(CurrentContextFile.self, from: Data(contentsOf: CurrentContextFile.url(Paths.root))) {
            trail = old.trail
        }
        model.objectWillChange.sink { [weak self] _ in MainActor.assumeIsolated { self?.schedule() } }.store(in: &subscriptions)
        model.resurfacer.objectWillChange.sink { [weak self] _ in MainActor.assumeIsolated { self?.schedule() } }.store(in: &subscriptions)
        schedule()
    }

    func stop() {
        subscriptions.removeAll()
        work?.cancel()
    }

    private func schedule() {
        work?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { _ = self?.writeNow() } }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func ref(_ t: Tab) -> CurrentContextFile.Ref? {
        guard let u = t.url, !t.isBlank else { return nil }
        let isNote = t.kind != .web
        let key = isNote ? URLKey.fileKey(u) : URLKey.key(for: u)
        var title = t.title
        if isNote, let d = model?.document, d.url.standardizedFileURL == u.standardizedFileURL { title = d.title }
        if title.isEmpty { title = isNote ? u.deletingPathExtension().lastPathComponent : Snippet.prettyURL(u.absoluteString) }
        return CurrentContextFile.Ref(title: title, url: isNote ? u.standardizedFileURL.absoluteString : u.absoluteString,
                                      kind: isNote ? "note" : "page", key: key)
    }

    func snapshot() -> CurrentContextFile? {
        guard let m = model else { return nil }
        var f = CurrentContextFile(updatedAt: Date(), pid: getpid())
        if let s = m.currentSpace { f.space = .init(id: s.id.uuidString, name: s.name) }
        let focused = m.currentTab.flatMap(ref)
        f.focused = focused
        if let sp = m.currentSplit, let other = m.tab(sp.other) { f.splitWith = ref(other) }
        f.openTabs = m.spaceTabs.prefix(60).compactMap(ref)
        f.related = m.resurfacer.cards.map {
            CurrentContextFile.Ref(title: $0.match.doc.title, url: $0.match.doc.url,
                                   kind: ($0.match.doc.source == .note || $0.match.doc.source == .markdown) ? "note" : "page",
                                   key: $0.match.doc.key)
        }
        if var top = focused, trail.first?.url != top.url {
            top.at = Date()
            trail.removeAll { $0.url == top.url }
            trail.insert(top, at: 0)
            if trail.count > Self.trailLength { trail.removeLast(trail.count - Self.trailLength) }
        }
        f.trail = trail
        return f
    }

    /// Writes the file now if anything but the time changed.
    @discardableResult
    func writeNow() -> Bool {
        guard var f = snapshot() else { return false }
        if var last = lastWritten {
            last.updatedAt = f.updatedAt
            if last == f { return false }
        }
        f.updatedAt = Date()
        guard let data = try? JSONEncoder.pretty.encode(f) else { return false }
        Paths.ensure(Paths.root)
        do { try data.write(to: CurrentContextFile.url(Paths.root), options: .atomic) } catch { return false }
        lastWritten = f
        return true
    }
}
