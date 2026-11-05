import Foundation

/// Where topic nodes come from. Today: names shared by several items, from the index's entity
/// table. The Engine agent's entities and topics can replace it in `GraphStore.makeTopicSource`.
protocol TopicSource: AnyObject {
    func sharedTopics() -> [IndexReader.TopicRow]
}

final class IndexEntityTopics: TopicSource {
    private let reader: IndexReader
    init(reader: IndexReader) { self.reader = reader }
    func sharedTopics() -> [IndexReader.TopicRow] { reader.sharedTopics() }
}

extension Notification.Name {
    /// Posted on the main queue after the graph's edges change.
    static let graphChanged = Notification.Name("local.browserpoc.graphChanged")
}

/// The graph's own tables in `index.sqlite`, the sync that keeps them in step with the index,
/// and the read calls the UI and the MCP server use.
///
/// Edges are stored by index key (`docs.key`), not by row id, so they survive re-indexing and
/// can be recorded before a page is indexed. They're resolved to items when the graph is read.
final class GraphStore: @unchecked Sendable {
    private nonisolated(unsafe) static var _shared: GraphStore?
    private static let sharedLock = NSLock()

    /// The store for the app's index, opened on first use. `--data-dir` and the tests set the
    /// support folder before anything touches this.
    static var shared: GraphStore {
        sharedLock.lock(); defer { sharedLock.unlock() }
        if let s = _shared { return s }
        let s = (try? GraphStore(indexURL: Paths.indexFile)) ?? GraphStore(failedAt: Paths.indexFile)
        _shared = s
        return s
    }

    /// Points the shared store at another index. Used by the tests.
    @discardableResult
    static func reset(indexURL: URL) -> GraphStore {
        sharedLock.lock(); defer { sharedLock.unlock() }
        let s = (try? GraphStore(indexURL: indexURL)) ?? GraphStore(failedAt: indexURL)
        _shared = s
        return s
    }

    let url: URL
    let readOnly: Bool
    private let queue = DispatchQueue(label: "local.browserpoc.graph")
    private let db: SQLiteDB?
    private let reader: IndexReader?
    private var semantic: SemanticNeighbourSource?
    private var topics: TopicSource?
    private var semanticLoaded = false
    private var cached: GraphSnapshot?
    /// Bumped on every write.
    private(set) var version = 0
    private var notifyWork: DispatchWorkItem?

    /// How many "similar meaning" neighbours each item keeps.
    static let similarK = 5
    /// Session pairs need this many occurrences before they show. Splits show at once.
    static let sessionMinCount = 2

    init(indexURL: URL, readOnly: Bool = false) throws {
        url = indexURL
        self.readOnly = readOnly
        Paths.ensure(indexURL.deletingLastPathComponent())
        let db = try SQLiteDB(path: indexURL.path, readOnly: readOnly)
        self.db = db
        let reader = IndexReader(db: db)
        self.reader = reader
        try queue.sync {
            if !readOnly {
                try db.exec("PRAGMA journal_mode=WAL")
                try db.exec("""
                CREATE TABLE IF NOT EXISTS g_edges(
                  a TEXT NOT NULL,
                  b TEXT NOT NULL,
                  type TEXT NOT NULL,
                  weight REAL NOT NULL DEFAULT 1,
                  count INTEGER NOT NULL DEFAULT 1,
                  first REAL NOT NULL DEFAULT 0,
                  last REAL NOT NULL DEFAULT 0,
                  detail TEXT NOT NULL DEFAULT '',
                  PRIMARY KEY(a, b, type)
                );
                CREATE INDEX IF NOT EXISTS g_edges_b ON g_edges(b);
                CREATE INDEX IF NOT EXISTS g_edges_type ON g_edges(type);
                CREATE TABLE IF NOT EXISTS g_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS g_positions(
                  scope TEXT NOT NULL,
                  id TEXT NOT NULL,
                  x REAL NOT NULL,
                  y REAL NOT NULL,
                  PRIMARY KEY(scope, id)
                );
                """)
            }
        }
        semantic = Self.makeSemanticSource(reader: reader)
        topics = Self.makeTopicSource(reader: reader)
    }

    private init(failedAt url: URL) {
        self.url = url
        readOnly = true
        db = nil
        reader = nil
    }

    /// The one line to change when the Engine agent's `semanticNeighbours(itemID, k)` lands.
    static func makeSemanticSource(reader: IndexReader) -> SemanticNeighbourSource {
        IndexVectorNeighbours(reader: reader)
    }

    static func makeTopicSource(reader: IndexReader) -> TopicSource {
        IndexEntityTopics(reader: reader)
    }

    var isOpen: Bool { db != nil }

    // MARK: - Meta

    private func meta(_ key: String) -> String? {
        (try? db?.query("SELECT value FROM g_meta WHERE key = ?", [key]) { $0.text(0) })?.first
    }

    private func setMeta(_ key: String, _ value: String) {
        _ = try? db?.run("INSERT OR REPLACE INTO g_meta(key, value) VALUES(?, ?)", [key, value])
    }

    private func didWrite() {
        version += 1
        cached = nil
        notifyWork?.cancel()
        let w = DispatchWorkItem { NotificationCenter.default.post(name: .graphChanged, object: nil) }
        notifyWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    // MARK: - Layout positions

    /// Where each node sat when the layout last came to rest, so a relaunch starts there.
    func savePositions(scope: String, _ positions: [String: SIMD2<Float>]) {
        guard !readOnly, !positions.isEmpty else { return }
        queue.async { [self] in
            guard let db else { return }
            try? db.transaction {
                try db.run("DELETE FROM g_positions WHERE scope = ?", [scope])
                for (id, p) in positions where p.x.isFinite && p.y.isFinite {
                    try db.run("INSERT INTO g_positions(scope, id, x, y) VALUES(?, ?, ?, ?)", [scope, id, Double(p.x), Double(p.y)])
                }
            }
        }
    }

    func savePositionsNow(scope: String, _ positions: [String: SIMD2<Float>]) {
        savePositions(scope: scope, positions)
        queue.sync {}
    }

    func loadPositions(scope: String) -> [String: SIMD2<Float>] {
        queue.sync {
            guard let db else { return [:] }
            let rows = (try? db.query("SELECT id, x, y FROM g_positions WHERE scope = ?", [scope]) {
                ($0.text(0), SIMD2(Float($0.double(1)), Float($0.double(2))))
            }) ?? []
            return Dictionary(rows, uniquingKeysWith: { a, _ in a })
        }
    }

    // MARK: - Recording

    /// Page `from` led to page `to` through a link.
    func recordNavigation(fromKey: String, toKey: String, at: Date = Date()) {
        guard fromKey != toKey else { return }
        queue.async { self.upsert(fromKey, toKey, .navigation, weight: 1, detail: "", at: at.timeIntervalSince1970) }
    }

    /// `added` went into research while `context` was being worked on.
    func recordResearch(contextKey: String, addedKey: String, at: Date = Date()) {
        guard contextKey != addedKey else { return }
        queue.async { self.upsert(contextKey, addedKey, .research, weight: 1, detail: "", at: at.timeIntervalSince1970) }
    }

    /// Two items used together. `detail` is "split" or "session".
    func recordTogether(_ a: String, _ b: String, detail: String, at: Date = Date()) {
        guard a != b else { return }
        let (x, y) = a < b ? (a, b) : (b, a)
        queue.async { self.upsert(x, y, .together, weight: detail == "split" ? 1 : 0.5, detail: detail, at: at.timeIntervalSince1970) }
    }

    private func upsert(_ a: String, _ b: String, _ type: GraphEdgeType, weight: Double, detail: String, at: Double) {
        guard let db, !readOnly else { return }
        // A split outranks a session for the same pair.
        let detailSQL = type == .together
            ? "CASE WHEN detail = 'split' OR excluded.detail = 'split' THEN 'split' ELSE excluded.detail END"
            : "CASE WHEN excluded.detail != '' THEN excluded.detail ELSE detail END"
        _ = try? db.run("""
            INSERT INTO g_edges(a, b, type, weight, count, first, last, detail) VALUES(?, ?, ?, ?, 1, ?, ?, ?)
            ON CONFLICT(a, b, type) DO UPDATE SET count = count + 1, last = excluded.last,
              weight = max(weight, excluded.weight), detail = \(detailSQL)
            """, [a, b, type.rawValue, weight, at, at, detail])
        didWrite()
    }

    // MARK: - Sync

    /// Brings links and similarity edges up to date with the index. Returns how many docs were looked at.
    @discardableResult
    func sync() -> Int {
        queue.sync { syncLocked() }
    }

    func syncAsync(_ done: (@Sendable (Int) -> Void)? = nil) {
        queue.async { let n = self.syncLocked(); done?(n) }
    }

    private func syncLocked() -> Int {
        guard let db, let reader, !readOnly, reader.hasIndexTables() else { return 0 }
        // Version 2 stopped reading [[wikilinks]] out of web pages, so links are read again once.
        if meta("links_version") != "2" {
            setMeta("synced_at", "0")
            setMeta("links_version", "2")
        }
        let watermark = Double(meta("synced_at") ?? "") ?? 0
        let sig = semantic?.signature ?? ""
        let fullSimilarity = meta("vector_sig") != sig
        if !semanticLoaded || fullSimilarity {
            semantic?.refresh(nil)
            semanticLoaded = true
        }
        var processed = 0
        var since = watermark - 0.5
        var newMark = watermark
        var changedIDs: [Int64] = []
        while true {
            let batch = reader.changedDocs(since: since, limit: 2000)
            if batch.isEmpty { break }
            try? db.transaction {
                for d in batch {
                    try db.run("DELETE FROM g_edges WHERE a = ? AND type = 'link'", [d.key])
                    let now = d.indexedAt
                    let isNote = d.source == "note" || d.source == "markdown"
                    for ref in LinkExtractor.extract(body: d.body, ownKey: d.key, ownURL: d.url, wikilinks: isNote) {
                        try db.run("""
                            INSERT OR REPLACE INTO g_edges(a, b, type, weight, count, first, last, detail) VALUES(?, ?, 'link', 1, 1, ?, ?, ?)
                            """, [d.key, ref.target, now, now, ref.detail])
                    }
                }
            }
            processed += batch.count
            changedIDs.append(contentsOf: batch.map { $0.id })
            newMark = max(newMark, batch.last!.indexedAt)
            if batch.count < 2000 { break }
            since = batch.last!.indexedAt
        }

        if fullSimilarity {
            rebuildSimilarity()
            setMeta("vector_sig", sig)
        } else if !changedIDs.isEmpty {
            semantic?.refresh(changedIDs)
            refreshSimilarity(for: changedIDs)
        }

        // Edges of items that left the index.
        let count = reader.docCount()
        if Int(meta("doc_count") ?? "") ?? 0 > count || processed > 0 {
            _ = try? db.run("DELETE FROM g_edges WHERE type IN ('link', 'similar') AND a NOT IN (SELECT key FROM docs)")
            _ = try? db.run("DELETE FROM g_edges WHERE type = 'similar' AND b NOT IN (SELECT key FROM docs)")
        }
        setMeta("doc_count", String(count))
        setMeta("synced_at", String(newMark))
        if processed > 0 || fullSimilarity { didWrite() }
        return processed
    }

    private func keyMap() -> [Int64: String] {
        guard let reader else { return [:] }
        var out: [Int64: String] = [:]
        for d in reader.allDocs() { out[d.id] = d.key }
        return out
    }

    private func rebuildSimilarity() {
        guard let db, let semantic else { return }
        let keys = keyMap()
        try? db.transaction {
            try db.run("DELETE FROM g_edges WHERE type = 'similar'")
            for id in semantic.docIDs {
                guard let ka = keys[id] else { continue }
                for n in similarNeighbours(of: id) {
                    guard let kb = keys[n.docID] else { continue }
                    try insertSimilar(ka, kb, n.score)
                }
            }
        }
    }

    private func refreshSimilarity(for ids: [Int64]) {
        guard let db, let semantic else { return }
        let keys = keyMap()
        try? db.transaction {
            for id in ids {
                guard let ka = keys[id] else { continue }
                try db.run("DELETE FROM g_edges WHERE type = 'similar' AND (a = ? OR b = ?)", [ka, ka])
                for n in similarNeighbours(of: id) {
                    guard let kb = keys[n.docID] else { continue }
                    try insertSimilar(ka, kb, n.score)
                }
            }
        }
    }

    /// Above this, a pair counts as similar on its own.
    static let strongSimilarity = 0.88

    /// An item's top neighbours by meaning, kept only when the pair is mutual (each in the other's
    /// top k) or very close. Short notes in one style tend to look alike to a sentence model, and
    /// a one-sided match is usually that.
    private func similarNeighbours(of id: Int64) -> [(docID: Int64, score: Double)] {
        guard let semantic else { return [] }
        return semantic.neighbours(of: id, k: Self.similarK).filter { n in
            n.score >= Self.strongSimilarity || semantic.neighbours(of: n.docID, k: Self.similarK).contains { $0.docID == id }
        }
    }

    private func insertSimilar(_ a: String, _ b: String, _ score: Double) throws {
        let (x, y) = a < b ? (a, b) : (b, a)
        let now = Date().timeIntervalSince1970
        try db?.run("""
            INSERT INTO g_edges(a, b, type, weight, count, first, last, detail) VALUES(?, ?, 'similar', ?, 1, ?, ?, '')
            ON CONFLICT(a, b, type) DO UPDATE SET weight = max(weight, excluded.weight)
            """, [x, y, score, now, now])
    }

    // MARK: - Snapshot

    /// Every item and connection, resolved. Cached until the next write.
    func snapshot() -> GraphSnapshot {
        queue.sync {
            if let c = cached { return c }
            let s = buildSnapshot()
            cached = s
            return s
        }
    }

    private func buildSnapshot() -> GraphSnapshot {
        var snap = GraphSnapshot()
        guard let db, let reader, reader.hasIndexTables() else { snap.finish(); return snap }
        let (typed, overrides) = reader.sectionInputs()
        let writingSites = Settings.shared.value.writingSites
        var nameIndex: [String: Int] = [:]
        var titleIndex: [String: Int] = [:]
        var keyIndex: [String: Int] = [:]
        for d in reader.allDocs() {
            let kind = IndexReader.kind(source: d.source, url: d.url, key: d.key, typed: typed[d.key] ?? 0,
                                        override: overrides[d.key], writingSites: writingSites)
            let host = URL(string: d.url).flatMap { $0.host }.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? ""
            let title = d.title.isEmpty ? (host.isEmpty ? d.key : Snippet.prettyURL(d.url)) : d.title
            let i = snap.nodes.count
            snap.nodes.append(GraphNode(id: "d:\(d.id)", docID: d.id, kind: kind, title: title, key: d.key, url: d.url,
                                        host: host, project: d.project, source: d.source, firstSeen: d.firstSeen,
                                        lastSeen: d.lastSeen, visits: d.visits, hasText: d.hasText))
            keyIndex[d.key] = i
            if kind == .note {
                if let n = LinkExtractor.noteName(url: d.url), nameIndex[n] == nil { nameIndex[n] = i }
                let t = LinkExtractor.wikiName(d.title)
                if !t.isEmpty, titleIndex[t] == nil { titleIndex[t] = i }
            }
        }
        var unresolved: [String: Int] = [:]
        let rows = (try? db.query("SELECT a, b, type, weight, count, detail, last FROM g_edges") { s in
            (s.text(0), s.text(1), s.text(2), s.double(3), Int(s.int(4)), s.text(5), s.double(6))
        }) ?? []
        var seenPairs = Set<String>()
        for (a, b, t, w, c, detail, last) in rows {
            guard let type = GraphEdgeType(rawValue: t), let ai = keyIndex[a] else { continue }
            if type == .together && detail != "split" && c < Self.sessionMinCount { continue }
            var bi: Int?
            if b.hasPrefix(LinkExtractor.wikiPrefix) {
                let raw = String(b.dropFirst(LinkExtractor.wikiPrefix.count))
                let name = LinkExtractor.wikiName(raw)
                bi = nameIndex[name] ?? titleIndex[name]
                if bi == nil {
                    if let u = unresolved[name] { bi = u } else {
                        let u = snap.nodes.count
                        snap.nodes.append(GraphNode(id: "u:\(name)", docID: nil, kind: .unresolved, title: raw, key: "", url: "",
                                                    host: "", project: nil, source: "", firstSeen: last, lastSeen: last,
                                                    visits: 0, hasText: false))
                        unresolved[name] = u
                        bi = u
                    }
                }
            } else {
                bi = keyIndex[b]
            }
            guard let bi, bi != ai else { continue }
            // A wikilink and a Markdown link to the same note count once.
            let pairKey = "\(ai)>\(bi)>\(t)"
            if seenPairs.contains(pairKey) { continue }
            seenPairs.insert(pairKey)
            snap.links.append(GraphLink(a: ai, b: bi, type: type, weight: w, count: c, detail: detail, last: last))
        }
        // Topic nodes, like Obsidian's tag nodes.
        let docIndex = Dictionary(uniqueKeysWithValues: snap.nodes.enumerated().compactMap { i, n in n.docID.map { ($0, i) } })
        for t in topics?.sharedTopics() ?? [] {
            let members = t.docIDs.compactMap { docIndex[$0] }
            guard members.count >= 2 else { continue }
            let ti = snap.nodes.count
            let first = members.map { snap.nodes[$0].firstSeen }.min() ?? 0
            snap.nodes.append(GraphNode(id: "t:\(t.name)", docID: nil, kind: .topic, title: t.display, key: "", url: "",
                                        host: "", project: nil, source: t.kind, firstSeen: first, lastSeen: first,
                                        visits: 0, hasText: false))
            for m in members {
                snap.links.append(GraphLink(a: m, b: ti, type: .topic, weight: 0.5, count: 1, detail: t.display, last: first))
            }
        }
        snap.finish()
        return snap
    }

    // MARK: - Read calls for the MCP server and the UI

    func item(id: Int64) -> GraphItem? {
        let s = snapshot()
        guard let i = s.indexByDoc[id] else { return nil }
        return Self.item(s.nodes[i])
    }

    func itemID(forKey key: String) -> Int64? {
        let s = snapshot()
        return s.indexByKey[key].flatMap { s.nodes[$0].docID }
    }

    func itemID(forURL url: URL) -> Int64? {
        itemID(forKey: url.isFileURL ? URLKey.fileKey(url) : URLKey.key(for: url))
    }

    static func item(_ n: GraphNode) -> GraphItem? {
        guard let id = n.docID else { return nil }
        return GraphItem(itemID: id, key: n.key, title: n.title, url: n.url, kind: n.kind.rawValue, project: n.project,
                         firstSeen: n.firstSeen, lastSeen: n.lastSeen)
    }

    /// Item-to-item connections of one node. Topic nodes are folded into item-to-item edges that
    /// name the shared topic, so callers only ever see items.
    static func itemEdges(_ s: GraphSnapshot, _ i: Int, types: Set<GraphEdgeType>?, topicLimit: Int = 30) -> [(other: Int, edge: GraphLink)] {
        var out: [(Int, GraphLink)] = []
        for li in s.adjacency[i] {
            let l = s.links[li]
            if let types, !types.contains(l.type) { continue }
            let other = l.a == i ? l.b : l.a
            let on = s.nodes[other]
            if on.kind == .topic {
                for lj in s.adjacency[other].prefix(topicLimit) {
                    let l2 = s.links[lj]
                    let m = l2.a == other ? l2.b : l2.a
                    if m == i || s.nodes[m].docID == nil { continue }
                    out.append((m, GraphLink(a: i, b: m, type: .topic, weight: l.weight, count: 1, detail: on.title, last: l.last)))
                }
            } else if on.docID != nil {
                out.append((other, l))
            }
        }
        return out
    }

    static func why(_ l: GraphLink, _ s: GraphSnapshot) -> String {
        let a = s.nodes[l.a].title, b = s.nodes[l.b].title
        switch l.type {
        case .link:
            return l.detail.isEmpty || l.detail == b ? "\(a) links to \(b)" : "\(a) links to \(b) as \"\(l.detail)\""
        case .navigation:
            return l.count > 1 ? "You went from \(a) to \(b) \(l.count) times" : "You went from \(a) to \(b)"
        case .research:
            return "You added \(b) to research from \(a)"
        case .together:
            return l.detail == "split" ? "You had them side by side in a split" : "You used them together in \(l.count) sessions"
        case .similar:
            return "They're close in meaning (\(Int((l.weight * 100).rounded()))% similar)"
        case .topic:
            return "Both mention \(l.detail)"
        }
    }

    static func info(_ l: GraphLink, _ s: GraphSnapshot) -> GraphEdgeInfo? {
        guard let a = s.nodes[l.a].docID, let b = s.nodes[l.b].docID else { return nil }
        return GraphEdgeInfo(from: a, to: b, type: l.type, directed: l.type.directed, weight: l.weight, count: l.count,
                             detail: l.detail, why: why(l, s))
    }

    /// Everything within `depth` steps of an item, nearest first.
    func neighbours(itemID: Int64, depth: Int = 1, types: Set<GraphEdgeType>? = nil, limit: Int = 200) -> [GraphNeighbour] {
        let s = snapshot()
        guard let start = s.indexByDoc[itemID] else { return [] }
        var dist: [Int: Int] = [start: 0]
        var via: [Int: [GraphLink]] = [:]
        var frontier = [start]
        var order: [Int] = []
        for d in 1...max(1, min(depth, 4)) {
            var next: [Int] = []
            for i in frontier {
                for (o, l) in Self.itemEdges(s, i, types: types) {
                    if let od = dist[o] {
                        if od == d { via[o, default: []].append(l) }
                        continue
                    }
                    dist[o] = d
                    via[o] = [l]
                    next.append(o)
                    order.append(o)
                }
            }
            frontier = next
            if order.count >= limit { break }
        }
        return order.prefix(limit).compactMap { o in
            guard let item = Self.item(s.nodes[o]) else { return nil }
            return GraphNeighbour(item: item, depth: dist[o] ?? 0, via: (via[o] ?? []).compactMap { Self.info($0, s) })
        }
    }

    /// Every connection of one item.
    func edges(itemID: Int64, types: Set<GraphEdgeType>? = nil) -> [GraphEdgeInfo] {
        let s = snapshot()
        guard let i = s.indexByDoc[itemID] else { return [] }
        return Self.itemEdges(s, i, types: types).compactMap { Self.info($0.edge, s) }
    }

    /// The shortest chain of connections between two items, or nil if none within `maxDepth`.
    func path(from: Int64, to: Int64, maxDepth: Int = 4, types: Set<GraphEdgeType>? = nil) -> [GraphEdgeInfo]? {
        let s = snapshot()
        guard let a = s.indexByDoc[from], let b = s.indexByDoc[to] else { return nil }
        if a == b { return [] }
        var parent: [Int: (Int, GraphLink)] = [:]
        var seen: Set<Int> = [a]
        var frontier = [a]
        for _ in 0..<max(1, min(maxDepth, 6)) {
            var next: [Int] = []
            for i in frontier {
                for (o, l) in Self.itemEdges(s, i, types: types) where !seen.contains(o) {
                    seen.insert(o)
                    parent[o] = (i, l)
                    if o == b {
                        var chain: [GraphLink] = []
                        var cur = b
                        while let (p, l) = parent[cur] { chain.append(l); cur = p; if cur == a { break } }
                        return chain.reversed().compactMap { Self.info($0, s) }
                    }
                    next.append(o)
                }
            }
            frontier = next
            if frontier.isEmpty { break }
        }
        return nil
    }

    func stats() -> GraphStats {
        let s = snapshot()
        var edges: [String: Int] = [:]
        for l in s.links { edges[l.type.rawValue, default: 0] += 1 }
        return GraphStats(items: s.nodes.filter { $0.docID != nil }.count, topics: s.nodes.filter { $0.kind == .topic }.count, edges: edges)
    }

    // MARK: - Keeping up with the index

    private var watchTimer: DispatchSourceTimer?
    private var lastGeneration = -1
    private var indexObserver: NSObjectProtocol?

    /// Syncs when the index changes: on `.indexChanged`, and when `IndexStore`'s generation moves.
    func startWatching() {
        guard watchTimer == nil, !readOnly else { return }
        indexObserver = NotificationCenter.default.addObserver(forName: .indexChanged, object: nil, queue: nil) { [weak self] _ in
            self?.syncAsync()
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 4)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let g = IndexStore.shared?.generation ?? 0
            if g != self.lastGeneration {
                self.lastGeneration = g
                _ = self.syncLocked()
            }
        }
        t.resume()
        watchTimer = t
    }
}
