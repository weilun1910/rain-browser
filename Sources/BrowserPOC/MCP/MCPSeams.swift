import Foundation
import SQLite3

// Seams for the Graph and Engine agents' work. One factory in `MCPSeams` picks each implementation.
// - Engine (merged): search goes through `IndexStore.search`, related through the panel's
//   `Pipeline`, similar edges through `semanticNeighbours`, and get_item adds `topics` and the
//   visit history. All of it runs on the ranking copy, since `IndexStore.init` writes.
// - Graph (next): `makeGraph` returns an adapter over `GraphStore(indexURL:readOnly: true)`, mapping
//   `edges(itemID:types:)` onto `MCPGraphSource`. Until then edges come from the index.

/// An edge between two items. Same shape as the Graph agent's `GraphEdgeInfo`.
struct MCPEdge {
    let from: Int64
    let to: Int64
    /// link, navigation, research, together, similar or topic
    let type: String
    let directed: Bool
    let weight: Double
    let detail: String
    let why: String
}

protocol MCPGraphSource {
    /// Where the edges come from, for the answer: "graph" once the Graph agent's store is in, "index" before.
    var name: String { get }
    func edges(itemID: Int64, types: Set<String>?, limit: Int) -> [MCPEdge]
}

struct MCPSearchResult {
    let item: KItem
    let score: Double
    let passage: String
    /// When and in what context Felix saw it, like the card reasons.
    var history: String? = nil
    /// Indexed after the ranking copy was made, so found by the live keyword search.
    var fresh = false
}

protocol MCPSearchSource {
    /// engine or index, for the answer.
    var name: String { get }
    /// `sources` narrows the search to index sources before ranking. `filter` runs the privacy rules
    /// and the rest of the tool's filters on every hit.
    func search(_ query: String, limit: Int, sources: Set<String>?, since: Date?, until: Date?,
                filter: (KItem) -> Bool) -> [MCPSearchResult]
}

enum MCPSeams {
    static func makeGraph(_ ctx: MCPContext) -> MCPGraphSource { IndexGraphSource(ctx: ctx) }
    static func makeSearch(_ ctx: MCPContext) -> MCPSearchSource { EngineSearchSource(ctx: ctx) }
}

// MARK: - Search

/// The Engine's hybrid search (keywords, meaning, names, rank fusion, then the reranker when it's
/// downloaded), on the ranking copy. Items indexed since the copy was made come from the live
/// keyword search, so nothing the app just captured is missing.
struct EngineSearchSource: MCPSearchSource {
    let ctx: MCPContext
    var name: String { "engine" }

    func search(_ query: String, limit: Int, sources: Set<String>?, since: Date?, until: Date?,
                filter: (KItem) -> Bool) -> [MCPSearchResult] {
        let live = IndexSearchSource(reader: ctx.reader)
        guard let store = ctx.ranking.storeFor(ctx.reader) else {
            return live.search(query, limit: limit, sources: sources, since: since, until: until, filter: filter)
        }
        var f = SearchFilters()
        if let sources { f.sources = Set(sources.flatMap(MCPSources.indexSources).compactMap(SourceType.init(rawValue:))) }
        f.since = since
        f.until = until
        f.writingSites = ctx.app.writingSites
        var hits = store.search(query, filters: f, limit: min(100, limit * 3 + 10))
        // Dense search always finds something. With the reranker, the Engine scores a hit 1 plus the
        // reranker's 0 to 1, and unrelated passages score under 0.1, so those go.
        if Intelligence.shared.hasReranker { hits = hits.filter { $0.score >= 1 + Self.rerankerFloor } }
        // Items the app indexed after the copy was made, from the live keyword search, go first:
        // they're the newest and they matched the words.
        var out: [MCPSearchResult] = []
        let fresh = ctx.reader.ids(indexedAfter: ctx.ranking.copiedThrough)
        if !fresh.isEmpty {
            for var r in live.search(query, limit: limit, sources: sources, since: since, until: until,
                                     filter: { fresh.contains($0.id) && filter($0) }) {
                r.fresh = true
                out.append(r)
            }
        }
        let have = Set(out.map { $0.item.id })
        // Details come from the live index, so an item deleted since the copy drops out.
        let metas = ctx.reader.items(ids: hits.map { $0.doc.id })
        for h in hits where out.count < limit && !have.contains(h.doc.id) {
            guard let it = metas[h.doc.id], filter(it) else { continue }
            out.append(MCPSearchResult(item: it, score: h.score, passage: h.passage, history: h.history))
        }
        return out
    }

    /// The Engine measured unrelated passages under 0.1 and relevant ones from 0.55.
    static let rerankerFloor = 0.1
}

/// FTS5 with bm25, a title bonus and a little recency, then a rerank by meaning with Apple's
/// sentence vectors. Reads the live index. Used for fresh items and when there's no ranking copy.
struct IndexSearchSource: MCPSearchSource {
    let reader: KnowledgeReader
    var name: String { "index" }

    func search(_ query: String, limit: Int, sources: Set<String>?, since: Date?, until: Date?,
                filter: (KItem) -> Bool) -> [MCPSearchResult] {
        let hits = reader.ftsSearch(query).filter { filter($0.item) }
        guard !hits.isEmpty else { return [] }
        let now = Date().timeIntervalSince1970
        let maxKW = max(hits.map { $0.bm25 }.max() ?? 1, 0.0001)
        let words = Set(TextAnalysis.rawWords(query).map { TextAnalysis.fold($0) }.filter(TextAnalysis.isContentWord))
        var scored: [(KItem, Double, String)] = hits.map { h in
            var s = h.bm25 / maxKW
            let titleWords = Set(TextAnalysis.rawWords(h.item.title).map { TextAnalysis.fold($0) })
            if !words.isEmpty { s += 0.3 * Double(words.intersection(titleWords).count) / Double(words.count) }
            let ageDays = max(0, now - h.item.lastActive) / 86400
            s += 0.1 * exp(-ageDays / 60)
            if !h.item.hasText { s *= 0.7 }
            return (h.item, s, h.passage)
        }
        scored.sort { $0.1 > $1.1 }
        // Rerank the head by meaning.
        let head = Array(scored.prefix(60))
        if let qv = Embedder.shared.vector(query) {
            let vecs = reader.vectors(ids: head.map { $0.0.id }, model: "nlsent")
            scored = head.map { (it, s, p) in
                var best: Float = -1
                for v in vecs[it.id] ?? [] where v.count == qv.count {
                    best = max(best, v.withUnsafeBufferPointer { Embedder.dot($0.baseAddress!, qv, qv.count) })
                }
                let sem = best > -1 ? IndexStore.calibrateSemantic(best) : 0
                return (it, 0.65 * min(1.3, s) + 0.35 * sem, p)
            } + scored.dropFirst(60)
            scored.sort { $0.1 > $1.1 }
        }
        return scored.prefix(limit).map { MCPSearchResult(item: $0.0, score: $0.1, passage: $0.2) }
    }
}

// MARK: - Graph on today's index

/// Edges from what the index already knows:
/// - link: Markdown links, bare URLs and [[wikilinks]] in a note, both directions.
/// - research: links under a note's "## Related" heading, which is where Add to research puts them.
/// - similar: the Engine's `semanticNeighbours`, above the embedding model's own floor.
/// - topic: the same people, organisations or places, or the same model-tagged topics.
struct IndexGraphSource: MCPGraphSource {
    let ctx: MCPContext
    var name: String { "index" }

    func edges(itemID: Int64, types: Set<String>?, limit: Int) -> [MCPEdge] {
        guard let it = ctx.reader.item(id: itemID) else { return [] }
        func wanted(_ t: String) -> Bool { types == nil || types!.contains(t) }
        var out: [MCPEdge] = []
        var seen = Set<String>()
        let canon = CanonicalID.of(url: it.url)
        func add(_ e: MCPEdge) {
            let k = "\(min(e.from, e.to))-\(max(e.from, e.to))-\(e.type)"
            guard seen.insert(k).inserted else { return }
            // A doc read in the browser and the same doc from its sync are one item, not neighbours.
            if let canon, let other = ctx.reader.item(id: e.from == it.id ? e.to : e.from), CanonicalID.of(url: other.url) == canon { return }
            out.append(e)
        }
        if wanted("link") || wanted("research") {
            for l in LinkScan.links(in: ctx.reader.body(id: it.id), noteURL: it.fileURL) {
                guard let target = resolve(l), target != it.id else { continue }
                let type = l.underRelated ? "research" : "link"
                if wanted(type) {
                    add(MCPEdge(from: it.id, to: target, type: type, directed: true, weight: 1, detail: l.text,
                                why: l.underRelated ? "Added to this note's Related list" : "This note links to it"))
                }
            }
            // Notes that link here.
            var needles = [it.url]
            if it.key != it.url { needles.append(it.key) }
            if let f = it.fileURL {
                let name = f.deletingPathExtension().lastPathComponent
                needles.append("[[\(name)]]"); needles.append("[[\(name)|"); needles.append("[[\(name)#")
                if let enc = f.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) { needles.append(enc) }
                needles.append(f.lastPathComponent)
            }
            for n in ctx.reader.notesMentioning(needles, excluding: it.id) {
                let links = LinkScan.links(in: ctx.reader.body(id: n.id), noteURL: n.fileURL)
                guard let l = links.first(where: { resolve($0) == it.id }) else { continue }
                let type = l.underRelated ? "research" : "link"
                if wanted(type) {
                    add(MCPEdge(from: n.id, to: it.id, type: type, directed: true, weight: 1, detail: l.text,
                                why: l.underRelated ? "That note added it to its Related list" : "That note links here"))
                }
            }
        }
        if wanted("similar") {
            for n in ctx.ranking.similar(itemID: it.id, k: 8, reader: ctx.reader) {
                add(MCPEdge(from: it.id, to: n.id, type: "similar", directed: false, weight: n.similarity,
                            detail: String(n.passage.prefix(160)),
                            why: "Close in meaning (\(String(format: "%.2f", n.similarity)) with \(n.model))"))
            }
        }
        if wanted("topic") {
            for s in ctx.reader.sharedNames(itemID: it.id) {
                let names = s.names.prefix(4).joined(separator: ", ")
                add(MCPEdge(from: it.id, to: s.id, type: "topic", directed: false, weight: min(1, Double(s.names.count) / 2),
                            detail: names, why: "Both mention \(names)"))
            }
            for s in ctx.reader.sharedTopics(itemID: it.id) {
                let names = s.names.prefix(4).joined(separator: ", ")
                add(MCPEdge(from: it.id, to: s.id, type: "topic", directed: false, weight: min(1, Double(s.names.count) / 3),
                            detail: names, why: "Both are about \(names)"))
            }
        }
        return Array(out.prefix(limit))
    }

    private func resolve(_ l: LinkScan.Link) -> Int64? {
        switch l.target {
        case .url(let u):
            return ctx.reader.item(key: URLKey.key(for: u))?.id ?? ctx.reader.items(where: "url = ?", [u.absoluteString]).first?.id
        case .file(let f):
            return ctx.reader.item(key: URLKey.fileKey(f))?.id
        case .wiki(let name):
            return ctx.noteNames[name.lowercased()]
        }
    }
}

/// Finds links in Markdown: [text](target), <url>, bare http(s) URLs and [[wikilinks]].
enum LinkScan {
    enum Target: Equatable {
        case url(URL)
        case file(URL)
        case wiki(String)
    }

    struct Link {
        let text: String
        let target: Target
        /// Under a "## Related" heading.
        let underRelated: Bool
    }

    static func links(in text: String, noteURL: URL?) -> [Link] {
        var out: [Link] = []
        var underRelated = false
        let mdLink = try! NSRegularExpression(pattern: #"\[([^\]\n]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)"#)
        let wiki = try! NSRegularExpression(pattern: #"\[\[([^\]\|#\n]+)(?:#[^\]\|\n]*)?(?:\|([^\]\n]*))?\]\]"#)
        let bare = try! NSRegularExpression(pattern: #"(?<![\(<\w])https?://[^\s\)\]>"']+"#)
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                let heading = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces).lowercased()
                underRelated = heading == "related"
                continue
            }
            let ns = line as NSString
            var taken: [NSRange] = []
            for m in mdLink.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                taken.append(m.range)
                let label = ns.substring(with: m.range(at: 1))
                var target = ns.substring(with: m.range(at: 2))
                if target.hasPrefix("<") && target.hasSuffix(">") { target = String(target.dropFirst().dropLast()) }
                if let t = classify(target, noteURL: noteURL) { out.append(Link(text: label, target: t, underRelated: underRelated)) }
            }
            for m in wiki.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let alias = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : name
                out.append(Link(text: alias, target: .wiki(name), underRelated: underRelated))
            }
            for m in bare.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                if taken.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) { continue }
                var s = ns.substring(with: m.range)
                while let last = s.last, ".,;:!?".contains(last) { s.removeLast() }
                if let u = URL(string: s) { out.append(Link(text: s, target: .url(u), underRelated: underRelated)) }
            }
        }
        return out
    }

    static func classify(_ target: String, noteURL: URL?) -> Target? {
        if target.hasPrefix("#") || target.hasPrefix("mailto:") { return nil }
        if let u = URL(string: target), let scheme = u.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" { return .url(u) }
            if scheme == "file" { return .file(u) }
            return nil
        }
        // A relative path to another note.
        guard let base = noteURL?.deletingLastPathComponent() else { return nil }
        let decoded = target.removingPercentEncoding ?? target
        let path = decoded.split(separator: "#").first.map(String.init) ?? decoded
        guard path.lowercased().hasSuffix(".md") else { return nil }
        return .file(URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL)
    }
}

// MARK: - The Related panel's ranking, read-only

/// The Engine's calls (`search`, `Pipeline`, `semanticNeighbours`, `topics`, `visits`) live on
/// `IndexStore`, and `IndexStore.init` writes to its database when it opens (a schema check, an
/// `ALTER TABLE` and a migration `UPDATE`). The real index must only be read. So this copies the
/// index with SQLite's online backup into a private temp folder, opens an `IndexStore` on the copy
/// and calls the Engine there. The copy keeps every row id, so ids match the live index. It's
/// rebuilt when the index changes, at most every 30 seconds, and removed when the server exits.
final class RankingSnapshot {
    private var store: IndexStore?
    private var builtVersion: Int64 = .min
    private var builtAt = Date.distantPast
    /// The newest `indexed_at` in the copy. Items indexed after this aren't in it.
    private(set) var copiedThrough: Double = 0
    private let dir: URL
    var refreshInterval: TimeInterval = 30

    static let prefix = "BrowserPOC-mcp-"
    static func directory(pid: pid_t) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(prefix + "\(pid)", isDirectory: true)
    }

    init() {
        dir = Self.directory(pid: getpid())
    }

    /// Removes copies left by servers that were killed before they could clean up.
    static func sweepStale() {
        let tmp = FileManager.default.temporaryDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [] where name.hasPrefix(prefix) {
            guard let pid = pid_t(name.dropFirst(prefix.count)), pid != getpid(), kill(pid, 0) != 0 else { continue }
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
        }
    }

    func storeFor(_ reader: KnowledgeReader) -> IndexStore? {
        guard let src = reader.db else { return nil }
        let v = reader.dataVersion()
        if store != nil && (v == builtVersion || Date().timeIntervalSince(builtAt) < refreshInterval) { return store }
        do {
            store = nil
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let dest = dir.appendingPathComponent("index.sqlite")
            let copy = try SQLiteDB(path: dest.path)
            guard let b = sqlite3_backup_init(copy.handle, "main", src.handle, "main") else {
                throw SQLiteError(message: copy.errorMessage)
            }
            sqlite3_backup_step(b, -1)
            sqlite3_backup_finish(b)
            copiedThrough = (try? copy.query("SELECT coalesce(max(indexed_at), 0) FROM docs") { $0.double(0) })?.first ?? 0
            store = try IndexStore(url: dest)
            builtVersion = v
            builtAt = Date()
        } catch {
            FileHandle.standardError.write(Data("ranking snapshot failed: \(error)\n".utf8))
            store = nil
        }
        return store
    }

    func cleanup() {
        store = nil
        try? FileManager.default.removeItem(at: dir)
    }

    struct Related {
        var matches: [Match] = []
        /// The bar the panel would use, and whether the reranker scored the cards.
        var gate: Pipeline.Gate?
        var visits: [Int64: [Visit]] = [:]
    }

    /// The panel's matches for an item, both sections together, best first.
    func related(to it: KItem, ctx: MCPContext, minScore: Double?, perSection: Int) -> Related {
        let input = ContextInput(key: it.key, title: it.title, text: ctx.reader.body(id: it.id),
                                 kind: it.isNote ? .note : .page)
        return related(input, ctx: ctx, minScore: minScore, perSection: perSection)
    }

    /// The Related panel's first pass: hybrid candidates, the reranker when it's downloaded, and the
    /// panel's bar. It skips the Foundation Models steps (describing the work, judging borderline
    /// cards), which take seconds and only refine what's already here.
    func related(_ input: ContextInput, ctx: MCPContext, minScore: Double?, perSection: Int) -> Related {
        guard let store = storeFor(ctx.reader) else { return Related() }
        var p = RankParams.fromSettings(ctx.app)
        p.limit = perSection
        // The panel hides what was opened in the last ten minutes. An assistant wants those too.
        p.recentWindow = 0
        if let minScore {
            // Pipeline.gate turns the slider value into the bar; this picks the slider value for a bar.
            p.threshold = Intelligence.shared.hasReranker ? minScore + 0.25 : minScore + 0.1
        }
        let q = Pipeline.makeQuery(input, work: nil, store: store)
        let r = Pipeline.rank(q, p, store: store)
        var out = Related(matches: r.matches.sorted { $0.score > $1.score }, gate: r.gate)
        for m in out.matches { out.visits[m.doc.id] = store.visits(docID: m.doc.id, limit: 10) }
        return out
    }

    struct Similar {
        let id: Int64
        let similarity: Double
        let passage: String
        let model: String
    }

    /// The Engine's nearest items by meaning, kept only above the embedding model's own floor.
    func similar(itemID: Int64, k: Int, reader: KnowledgeReader) -> [Similar] {
        guard let store = storeFor(reader) else { return [] }
        let order: [EmbedderID] = [.gemma, .contextual, .sentence]
        guard let model = order.first(where: { store.vectorSets[$0]?[itemID]?.isEmpty == false }) else { return [] }
        let floor = Double(IndexStore.denseFloor(model))
        return store.semanticNeighbours(itemID: itemID, k: k).filter { $0.similarity >= floor }.map {
            Similar(id: $0.doc.id, similarity: $0.similarity, passage: $0.passage, model: Self.modelName(model))
        }
    }

    static func modelName(_ m: EmbedderID) -> String {
        switch m {
        case .gemma: return "EmbeddingGemma"
        case .contextual: return "Apple's contextual embedding"
        case .sentence: return "Apple's sentence embedding"
        }
    }

    /// Topics from the content-tagging model, or the item's most distinctive words.
    func topics(itemID: Int64, reader: KnowledgeReader) -> [String] {
        storeFor(reader)?.topics(itemID: itemID) ?? []
    }

    /// "You read this on 12 Oct while writing ...", the same line the cards start with.
    func history(itemID: Int64, reader: KnowledgeReader) -> String? {
        guard let store = storeFor(reader), let meta = store.item(id: itemID) else { return nil }
        let line = Reasons.history(meta, visits: store.visits(docID: itemID, limit: 10))
        return line.isEmpty ? nil : Fmt.clean(line)
    }
}
