import Foundation
import SQLite3

// Seams for the Graph and Engine agents' work. Each protocol has a fallback built on today's
// index, and one factory in `MCPSeams` picks the implementation. After the merge:
// - Graph: `makeGraph` returns an adapter over `GraphStore(indexURL:readOnly: true)`, mapping
//   `neighbours(itemID:depth:types:limit:)` and `edges(itemID:types:)` onto `MCPGraphSource`.
// - Engine: `makeSearch` and `makeSemantic` call the Engine's search, `semanticNeighbours` and
//   entities. The ranking snapshot keeps calling `IndexStore.retrieve`, whatever it becomes.

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

protocol MCPSearchSource {
    func search(_ query: String, limit: Int, filter: (KItem) -> Bool) -> [(item: KItem, score: Double, passage: String)]
}

enum MCPSeams {
    static func makeGraph(_ ctx: MCPContext) -> MCPGraphSource { IndexGraphSource(ctx: ctx) }
    static func makeSearch(_ ctx: MCPContext) -> MCPSearchSource { IndexSearchSource(reader: ctx.reader) }
}

// MARK: - Search on today's index

/// FTS5 with bm25, a title bonus and a little recency, then a rerank by meaning with the
/// passage vectors already in the index.
struct IndexSearchSource: MCPSearchSource {
    let reader: KnowledgeReader

    func search(_ query: String, limit: Int, filter: (KItem) -> Bool) -> [(item: KItem, score: Double, passage: String)] {
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
            let vecs = reader.vectors(ids: head.map { $0.0.id })
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
        return scored.prefix(limit).map { (item: $0.0, score: $0.1, passage: $0.2) }
    }
}

// MARK: - Graph on today's index

/// Edges from what the index already knows:
/// - link: Markdown links, bare URLs and [[wikilinks]] in a note, both directions.
/// - research: links under a note's "## Related" heading, which is where Add to research puts them.
/// - similar and topic: the Related panel's own ranking with the item as context.
struct IndexGraphSource: MCPGraphSource {
    let ctx: MCPContext
    var name: String { "index" }

    func edges(itemID: Int64, types: Set<String>?, limit: Int) -> [MCPEdge] {
        guard let it = ctx.reader.item(id: itemID) else { return [] }
        func wanted(_ t: String) -> Bool { types == nil || types!.contains(t) }
        var out: [MCPEdge] = []
        var seen = Set<String>()
        func add(_ e: MCPEdge) {
            let k = "\(min(e.from, e.to))-\(max(e.from, e.to))-\(e.type)"
            if seen.insert(k).inserted { out.append(e) }
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
        if wanted("similar") || wanted("topic") {
            for m in ctx.ranking.related(to: it, ctx: ctx, minScore: 0.25, perSection: 6) {
                if wanted("topic") && !m.sharedEntities.isEmpty {
                    let names = m.sharedEntities.prefix(4).joined(separator: ", ")
                    add(MCPEdge(from: it.id, to: m.doc.id, type: "topic", directed: false, weight: J.round3(m.entity),
                                detail: names, why: "Both mention \(names)"))
                }
                if wanted("similar") && (m.semantic >= 0.35 || m.keyword >= 0.35) {
                    let terms = (m.topicTerms.isEmpty ? m.sharedTerms : m.topicTerms).prefix(4).joined(separator: ", ")
                    add(MCPEdge(from: it.id, to: m.doc.id, type: "similar", directed: false, weight: J.round3(m.score),
                                detail: terms, why: terms.isEmpty ? "Close in meaning" : "Close in meaning, both cover \(terms)"))
                }
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

/// `IndexStore.retrieve` is the Related panel's ranking. `IndexStore` writes to its database when
/// it opens and keeps its connection private, and the brief says not to edit it. So this copies the
/// index with SQLite's online backup into a private temp folder, opens an `IndexStore` on the copy
/// and calls the real `retrieve`. The copy is rebuilt when the index changes, at most every 30
/// seconds, and removed when the server exits.
final class RankingSnapshot {
    private var store: IndexStore?
    private var builtVersion: Int64 = .min
    private var builtAt = Date.distantPast
    private let dir: URL
    var refreshInterval: TimeInterval = 30

    init() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("BrowserPOC-mcp-\(getpid())", isDirectory: true)
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

    /// The panel's matches for an item, both sections together, best first.
    func related(to it: KItem, ctx: MCPContext, minScore: Double, perSection: Int) -> [Match] {
        let input = ContextInput(key: it.key, title: it.title, text: ctx.reader.body(id: it.id),
                                 kind: it.isNote ? .note : .page)
        return related(input, ctx: ctx, minScore: minScore, perSection: perSection)
    }

    func related(_ input: ContextInput, ctx: MCPContext, minScore: Double, perSection: Int) -> [Match] {
        guard let store = storeFor(ctx.reader) else { return [] }
        let s = ctx.app
        var p = RankParams.fromSettings(s)
        p.threshold = minScore
        p.limit = perSection
        // The panel hides what was opened in the last ten minutes. An assistant wants those too.
        p.recentWindow = 0
        let r = store.retrieve(ContextAnalysis.make(input), p)
        return r.matches.sorted { $0.score > $1.score }
    }
}
