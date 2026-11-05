import Foundation
import CryptoKit

/// State shared by the tools for one server process. Settings files are read again on every
/// call, so a switch flipped in the app takes effect without restarting the AI client.
final class MCPContext {
    let root: URL
    let reader: KnowledgeReader
    let ranking = RankingSnapshot()
    var clientName = "unknown client"
    var modern = false
    var protocolVersion: String?
    private(set) var app = AppSettings()
    private(set) var mcp = MCPSettings()
    private var namesVersion: Int64 = .min
    private var namesCache: [String: Int64] = [:]

    init(root: URL) {
        self.root = root
        reader = KnowledgeReader(root: root)
    }

    var privacy: MCPPrivacy { MCPPrivacy(settings: mcp, app: app) }

    /// Called before every request.
    func refresh() {
        reader.reopenIfNeeded()
        app = reader.appSettings()
        mcp = reader.mcpSettings()
    }

    var noteNames: [String: Int64] {
        let v = reader.dataVersion()
        if v != namesVersion { namesCache = reader.noteNames(); namesVersion = v }
        return namesCache
    }

    var notesRoots: [URL] { reader.notesRoots(app) }

    func visible(_ it: KItem) -> Bool { privacy.allows(source: it.source, url: it.url) }

    func log(_ kind: String, _ name: String, _ detail: String, served: [String], hidden: Int = 0) {
        guard mcp.keepLog else { return }
        MCPLog.append(MCPLogEntry(at: Date(), client: clientName, kind: kind, name: name, detail: String(detail.prefix(160)),
                                  served: served.count, titles: Array(served.prefix(12)), hidden: hidden,
                                  protocolVersion: protocolVersion), root: root)
    }

    func close() {
        ranking.cleanup()
        reader.close()
    }

    /// Whether the app is running, from the pid in current-context.json.
    func appRunning(_ cc: CurrentContextFile?) -> Bool {
        guard let pid = cc?.pid, pid > 0 else { return false }
        return kill(pid_t(pid), 0) == 0
    }

    // MARK: Rendering

    func title(_ it: KItem) -> String {
        let t = it.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? Snippet.prettyURL(it.url) : t
    }

    func cite(title: String, url: String) -> String {
        let safe = title.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
        return "[\(safe)](\(url))"
    }

    /// The fields every item carries. `full` adds counts and dates.
    func itemJSON(_ it: KItem, full: Bool = false) -> JSON {
        let t = title(it)
        var j: JSON = [
            "id": it.id,
            "title": t,
            "url": it.url,
            "source": MCPSources.normalized(it.source),
            "kind": it.kind(writingSites: app.writingSites),
            "cite": cite(title: t, url: it.url),
            "uri": "browser://item/\(it.id)",
            "last_active": J.date(it.lastActive),
        ]
        if let p = it.project { j["project"] = p }
        if let f = it.fileURL { j["path"] = f.path }
        if full {
            j["key"] = it.key
            j["first_seen"] = J.date(it.firstSeen)
            j["last_seen"] = J.date(it.lastSeen)
            j["last_opened"] = J.date(it.lastOpened)
            j["visits"] = it.visitCount
            j["minutes_open"] = J.round3(it.dwell / 60)
            j["has_text"] = it.hasText
            j["section"] = reader.section(it, writingSites: app.writingSites) == .docs ? "docs" : "sites"
            if !it.description.isEmpty { j["description"] = it.description }
            if it.mtime > 0 { j["modified"] = J.date(it.mtime) }
        }
        return j
    }
}

struct ToolError: Error { let message: String }

struct MCPTool {
    let name: String
    let title: String
    let description: String
    let input: JSON
    let output: JSON
    let writes: Bool
    let run: (JSON) throws -> JSON

    var definition: JSON {
        var annotations: JSON = ["title": title, "readOnlyHint": !writes, "openWorldHint": false]
        if writes {
            annotations["destructiveHint"] = false
            annotations["idempotentHint"] = false
        } else {
            annotations["idempotentHint"] = true
        }
        return ["name": name, "title": title, "description": description, "inputSchema": input, "outputSchema": output,
                "annotations": annotations]
    }
}

/// JSON Schema helpers.
enum S {
    static func obj(_ props: [String: JSON], required: [String] = [], extra: Bool = true) -> JSON {
        var o: JSON = ["type": "object", "properties": props]
        if !required.isEmpty { o["required"] = required }
        if !extra { o["additionalProperties"] = false }
        return o
    }
    static func str(_ d: String, _ options: [String]? = nil) -> JSON {
        var o: JSON = ["type": "string", "description": d]
        if let options { o["enum"] = options }
        return o
    }
    static func int(_ d: String, min: Int? = nil, max: Int? = nil) -> JSON {
        var o: JSON = ["type": "integer", "description": d]
        if let min { o["minimum"] = min }
        if let max { o["maximum"] = max }
        return o
    }
    static func num(_ d: String) -> JSON { ["type": "number", "description": d] }
    static func bool(_ d: String) -> JSON { ["type": "boolean", "description": d] }
    static func arr(_ items: JSON, _ d: String = "") -> JSON { d.isEmpty ? ["type": "array", "items": items] : ["type": "array", "items": items, "description": d] }
    static let anyObj: JSON = ["type": "object"]
    static let nullableStr: JSON = ["type": ["string", "null"]]

    static let item: JSON = obj([
        "id": int("Item id. Pass it to get_item, related or connections."),
        "title": str("Title"),
        "url": str("Web address, or a file URL for a note"),
        "source": str("note, web, chrome, or a newer source"),
        "kind": str("note, doc (Google Docs, Notion, sites the user writes on) or page"),
        "cite": str("A Markdown link to use when citing this item"),
        "uri": str("MCP resource URI for this item"),
        "path": str("File path, for notes"),
        "project": str("Top folder of a note"),
        "last_active": nullableStr,
    ], required: ["id", "title", "url", "source", "cite"])

    static func withItem(_ extra: [String: JSON]) -> JSON {
        var props = (item["properties"] as? [String: JSON]) ?? [:]
        for (k, v) in extra { props[k] = v }
        return obj(props, required: ["id", "title", "url", "source", "cite"])
    }
}

final class MCPToolbox {
    let context: MCPContext
    private(set) var tools: [MCPTool] = []
    lazy var graph: MCPGraphSource = MCPSeams.makeGraph(context)
    lazy var searcher: MCPSearchSource = MCPSeams.makeSearch(context)
    lazy var writer = MCPNoteWriter(context: context)

    init(context: MCPContext) {
        self.context = context
        tools = readTools() + MCPNoteWriter.tools(self)
    }

    func listTools() -> [JSON] {
        context.refresh()
        return tools.filter { !$0.writes || context.mcp.allowWrites }.map { $0.definition }
    }

    func call(name: String, arguments: JSON) throws -> JSON {
        context.refresh()
        guard let tool = tools.first(where: { $0.name == name }) else { throw RPCError.invalidParams("Unknown tool: \(name)") }
        if tool.writes && !context.mcp.allowWrites {
            return errorResult("Maintenance tools are off. The user can turn them on in Rain, Settings, AI clients, \"Let AI clients edit notes\".")
        }
        do {
            let out = try tool.run(arguments)
            return ["content": [["type": "text", "text": J.string(out)]], "structuredContent": out, "isError": false]
        } catch let e as ToolError {
            return errorResult(e.message)
        }
    }

    private func errorResult(_ message: String) -> JSON {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    // MARK: Arguments

    static func str(_ a: JSON, _ k: String) -> String? {
        if let s = a[k] as? String { let t = s.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t }
        if let n = a[k] as? NSNumber { return n.stringValue }
        return nil
    }
    static func int(_ a: JSON, _ k: String, _ d: Int, min lo: Int = 0, max hi: Int = .max) -> Int {
        var v = d
        if let n = a[k] as? NSNumber { v = n.intValue } else if let s = a[k] as? String, let n = Int(s) { v = n }
        return Swift.max(lo, Swift.min(hi, v))
    }
    static func num(_ a: JSON, _ k: String, _ d: Double) -> Double {
        if let n = a[k] as? NSNumber { return n.doubleValue }
        if let s = a[k] as? String, let n = Double(s) { return n }
        return d
    }
    static func bool(_ a: JSON, _ k: String, _ d: Bool) -> Bool {
        if let b = a[k] as? Bool { return b }
        if let s = a[k] as? String { return ["true", "yes", "1"].contains(s.lowercased()) }
        return d
    }
    static func strings(_ a: JSON, _ k: String) -> [String]? {
        if let arr = a[k] as? [Any] { let s = arr.compactMap { ($0 as? String)?.lowercased() }; return s.isEmpty ? nil : s }
        if let s = a[k] as? String { let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }; return parts.isEmpty ? nil : parts }
        return nil
    }

    /// Resolves an item and checks Felix lets AI clients see it.
    func item(_ a: JSON, _ key: String = "item") throws -> KItem {
        guard let ref = Self.str(a, key) else { throw ToolError(message: "Pass \(key): an item id, URL, note path or note title.") }
        // A hidden item answers the same as a missing one, so its existence doesn't leak.
        guard let it = context.reader.resolve(ref), context.visible(it) else {
            throw ToolError(message: "No item matches \"\(ref)\". Use search to find it, then pass its id.")
        }
        return it
    }

    /// A passage cut around the query words, as plain text: no note heading in front, no heading
    /// marks, bullets or link syntax.
    static func snippet(_ passage: String, words: [String], title: String) -> String {
        var lines: [String] = []
        for raw in passage.components(separatedBy: "\n") {
            var l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("#") {
                l = String(l.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                if lines.isEmpty && l == title.trimmingCharacters(in: .whitespaces) { continue }
                if !l.isEmpty && !".:!?".contains(l.last!) { l += "." }
            }
            for bullet in ["- ", "* ", "+ "] where l.hasPrefix(bullet) { l = String(l.dropFirst(2)) }
            if !l.isEmpty { lines.append(l) }
        }
        var p = lines.joined(separator: " ")
        // Passages can arrive with their lines already joined, so headings and bullets sit mid-text.
        p = p.replacingOccurrences(of: #"(^|\s)#{1,6}\s+"#, with: "$1", options: .regularExpression)
        p = p.replacingOccurrences(of: #"(^|\s)[-*+]\s+(?=\[)"#, with: "$1", options: .regularExpression)
        p = p.replacingOccurrences(of: #"\[\[([^\]\|]+)\|([^\]]+)\]\]"#, with: "$2", options: .regularExpression)
        p = p.replacingOccurrences(of: #"\[\[([^\]]+)\]\]"#, with: "$1", options: .regularExpression)
        p = p.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        return Snippet.make(p, terms: words, title: title)
    }

    static func slice(_ text: String, offset: Int, max: Int) -> (String, Int?) {
        let chars = Array(text)
        guard offset < chars.count else { return ("", nil) }
        let end = Swift.min(chars.count, offset + max)
        return (String(chars[offset..<end]), end < chars.count ? end : nil)
    }

    static func version(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Read tools

    private func readTools() -> [MCPTool] {
        [overviewTool(), searchTool(), getItemTool(), relatedTool(), connectionsTool(), currentContextTool(),
         recentTool(), spacesTool(), listNotesTool(), readNoteTool()]
    }

    private func overviewTool() -> MCPTool {
        MCPTool(name: "overview", title: "Knowledge base overview",
                description: "What's in the user's Rain knowledge base: how many notes, pages and docs, which notes folders and spaces exist, whether the app is running, what the user has hidden from AI clients, and whether note editing is on. Call it once to orient yourself.",
                input: S.obj([:], extra: false),
                output: S.obj([
                    "app_running": S.bool("The app is open right now"),
                    "data_folder": S.str("The app's support folder"),
                    "sources": S.arr(S.obj(["id": S.str("Source id"), "label": S.str("Name"), "items": S.int("Items"), "visible": S.bool("AI clients can see it")])),
                    "notes_folders": S.arr(S.str("Folder path")),
                    "spaces": S.arr(S.str("Space name")),
                    "maintenance_tools": S.bool("create_note, append_to_note and add_link are on"),
                ], required: ["app_running", "sources"]),
                writes: false) { [unowned self] _ in
            let ctx = context
            let p = ctx.privacy
            let counts = ctx.reader.switchCounts()
            var sources: [JSON] = []
            var seen = Set<String>()
            for b in MCPSources.builtIn {
                seen.insert(b.id)
                sources.append(["id": b.id, "label": b.label, "items": counts[b.id] ?? 0, "visible": !ctx.mcp.isHidden(b.id)])
            }
            for (id, n) in counts.sorted(by: { $0.key < $1.key }) where !seen.contains(id) {
                sources.append(["id": id, "label": MCPSources.label(id), "items": n, "visible": !ctx.mcp.isHidden(id)])
            }
            let cc = ctx.reader.currentContext()
            let state = ctx.reader.savedState()
            let out: JSON = [
                "app_running": ctx.appRunning(cc),
                "data_folder": ctx.root.path,
                "index_found": ctx.reader.indexExists,
                "last_indexed": J.date(ctx.reader.lastIndexed()),
                "sources": sources,
                "notes_folders": p.allows(source: MCPSources.notes, url: "file:///") ? ctx.notesRoots.map { $0.path } : [],
                "spaces": (state?.spaces ?? []).map { $0.name },
                "current_context_shared": ctx.mcp.shareCurrentContext,
                "maintenance_tools": ctx.mcp.allowWrites,
                "connections_from": graph.name,
                "search_by": searcher.name,
                "reranker_ready": Intelligence.shared.hasReranker,
            ]
            ctx.log("tool", "overview", "", served: [])
            return out
        }
    }

    private func searchTool() -> MCPTool {
        MCPTool(name: "search", title: "Search the knowledge base",
                description: "Search across everything the user has read, written and met about: their notes, pages read in the browser, Chrome history, Google Docs, Notion pages and Granola meeting notes. The browser's own hybrid search: keywords, meaning and names, then an on-device reranker when it's downloaded. Each result says when and in what context the user saw it. Use it whenever the user asks about their own notes, projects, meetings, past reading or research. For a fuzzy topic or a whole paragraph, related often finds more.",
                input: S.obj([
                    "query": S.str("Words or a question to look for"),
                    "sources": S.arr(S.str("note, web, chrome, gdocs, notion, granola"),
                                     "Only these sources. gdocs and notion also match those docs read in the browser."),
                    "kind": S.str("Only notes, docs, meetings or pages", ["note", "doc", "meeting", "page"]),
                    "project": S.str("Only notes in this top folder"),
                    "since": S.str("Only items active on or after this date (YYYY-MM-DD or ISO 8601)"),
                    "until": S.str("Only items active on or before this date"),
                    "limit": S.int("How many results, 10 by default", min: 1, max: 50),
                ], required: ["query"]),
                output: S.obj([
                    "query": S.str("The query"),
                    "results": S.arr(S.withItem(["score": S.num("Relevance, higher is better"), "snippet": S.str("The matching passage"),
                                                 "history": S.str("When and in what context the user saw it")])),
                    "hidden": S.int("Matches left out because the user hid them from AI clients"),
                    "ranked_by": S.str("engine for the browser's hybrid search, index for keyword search"),
                ], required: ["query", "results"]),
                writes: false) { [unowned self] a in
            guard let q = Self.str(a, "query") else { throw ToolError(message: "Pass a query.") }
            let ctx = context
            let limit = Self.int(a, "limit", 10, min: 1, max: 50)
            let sources = Self.strings(a, "sources")
            let kind = Self.str(a, "kind")?.lowercased()
            let project = Self.str(a, "project")?.lowercased()
            let since = Self.str(a, "since").flatMap(J.parseDate)?.timeIntervalSince1970
            let until = Self.str(a, "until").flatMap(J.parseDate).map { $0.timeIntervalSince1970 + 86399 }
            var hidden = 0
            let results = searcher.search(q, limit: limit, sources: sources.map(Set.init),
                                          since: since.map { Date(timeIntervalSince1970: $0) },
                                          until: until.map { Date(timeIntervalSince1970: $0) }) { it in
                if !ctx.visible(it) { hidden += 1; return false }
                if let sources, !sources.contains(where: { MCPSources.matches($0, source: it.source, url: it.url) }) { return false }
                if let kind, it.kind(writingSites: ctx.app.writingSites) != kind { return false }
                if let project, !(it.project?.lowercased().contains(project) ?? false) { return false }
                if let since, it.lastActive < since { return false }
                if let until, it.lastActive > until { return false }
                return true
            }
            let words = TextAnalysis.rawWords(q).map(String.init)
            let rows: [JSON] = results.map { r in
                var j = ctx.itemJSON(r.item)
                j["score"] = J.round3(r.score)
                j["snippet"] = r.item.hasText ? Self.snippet(r.passage, words: words, title: r.item.title) : Snippet.prettyURL(r.item.url)
                if let h = r.history, !h.isEmpty { j["history"] = Fmt.clean(h) }
                return j
            }
            ctx.log("tool", "search", q, served: results.map { ctx.title($0.item) }, hidden: hidden)
            return ["query": q, "results": rows, "hidden": hidden, "ranked_by": searcher.name]
        }
    }

    private func getItemTool() -> MCPTool {
        MCPTool(name: "get_item", title: "Read an item",
                description: "Reads one item from the knowledge base: its details, its text (paged with offset and max_chars), the names in it and the links in it. Pass an id from search, or a URL, note path or note title. For a note's exact current Markdown on disk, use read_note.",
                input: S.obj([
                    "item": S.str("Item id, URL, note path or note title"),
                    "offset": S.int("Character to start from, for paging", min: 0),
                    "max_chars": S.int("Most characters of text to return, 12000 by default", min: 200, max: 40000),
                    "include_passages": S.bool("Also return the indexed passages, 700 characters each"),
                ], required: ["item"]),
                output: S.obj([
                    "item": S.item,
                    "text": S.str("The text, or this page of it"),
                    "offset": S.int("Where this page starts"),
                    "next_offset": ["type": ["integer", "null"], "description": "Pass as offset for the next page, null at the end"],
                    "total_chars": S.int("Length of the whole text"),
                    "names": S.arr(S.obj(["name": S.str(""), "kind": S.str(""), "count": S.int("")])),
                    "topics": S.arr(S.str("A topic, from the on-device tagging model or the item's most distinctive words")),
                    "history": S.str("When and in what context the user saw it"),
                    "links": S.arr(S.obj(["text": S.str(""), "url": S.str(""), "id": ["type": ["integer", "null"]]])),
                    "passages": S.arr(S.obj(["index": S.int(""), "text": S.str("")])),
                ], required: ["item", "text", "offset", "total_chars"]),
                writes: false) { [unowned self] a in
            let ctx = context
            let it = try item(a)
            let body = ctx.reader.body(id: it.id)
            let offset = Self.int(a, "offset", 0, min: 0)
            let maxChars = Self.int(a, "max_chars", 12000, min: 200, max: 40000)
            let (text, next) = Self.slice(body, offset: offset, max: maxChars)
            var out: JSON = [
                "item": ctx.itemJSON(it, full: true),
                "text": text,
                "offset": offset,
                "next_offset": next.map { $0 as Any } ?? NSNull(),
                "total_chars": body.count,
                "names": ctx.reader.entities(id: it.id).prefix(20).map { ["name": $0.name, "kind": $0.kind, "count": $0.count] as JSON },
                "topics": topics(it.id),
                "links": links(in: body, noteURL: it.fileURL),
            ]
            if let h = ctx.ranking.history(itemID: it.id, reader: ctx.reader) { out["history"] = h }
            if Self.bool(a, "include_passages", false) {
                var budget = 20000
                var ps: [JSON] = []
                for p in ctx.reader.passages(id: it.id) where budget > 0 {
                    ps.append(["index": p.idx, "text": p.text])
                    budget -= p.text.count
                }
                out["passages"] = ps
            }
            ctx.log("tool", "get_item", ctx.title(it), served: [ctx.title(it)])
            return out
        }
    }

    /// The tagging model's topics from the live index, or the Engine's fallback from the ranking copy.
    func topics(_ id: Int64) -> [String] {
        let live = context.reader.modelTopics(itemID: id)
        return Array((live.isEmpty ? context.ranking.topics(itemID: id, reader: context.reader) : live).prefix(8))
    }

    /// Links in a body, resolved to items where they're indexed. Hidden targets are left out.
    func links(in body: String, noteURL: URL?) -> [JSON] {
        var out: [JSON] = []
        var seen = Set<String>()
        for l in LinkScan.links(in: body, noteURL: noteURL).prefix(80) {
            var url = ""
            var target: KItem?
            switch l.target {
            case .url(let u):
                guard context.privacy.urlDecision(u) == .allowed else { continue }
                url = u.absoluteString
                target = context.reader.item(key: URLKey.key(for: u))
            case .file(let f):
                url = f.absoluteString
                target = context.reader.item(key: URLKey.fileKey(f))
            case .wiki(let name):
                target = context.noteNames[name.lowercased()].flatMap { context.reader.item(id: $0) }
                url = target?.url ?? "[[\(name)]]"
            }
            if let t = target, !context.visible(t) { continue }
            if !seen.insert(url).inserted { continue }
            out.append(["text": l.text, "url": url, "id": target.map { $0.id as Any } ?? NSNull(), "in_related_list": l.underRelated])
        }
        return out
    }

    private func relatedTool() -> MCPTool {
        let match = S.withItem([
            "score": S.num("The Related panel's score: the reranker's 0 to 1 when it's downloaded, otherwise words, meaning and names"),
            "signals": S.obj(["words": S.num(""), "meaning": S.num(""), "names": S.num(""), "reranker": ["type": ["number", "null"]]]),
            "found_by": S.arr(S.str("Which searches found it: keywords, queries, meaning, names")),
            "shared_terms": S.arr(S.str("")),
            "shared_names": S.arr(S.str("")),
            "passage": S.str("The passage that matched best"),
            "reason": S.str("When the user saw it and what it covers, like the Related cards"),
        ])
        return MCPTool(name: "related", title: "Related items",
                description: "What the user has seen before that relates to an item or to a piece of text, using the browser's Related panel ranking: keyword, meaning and name searches fused together, then an on-device reranker when it's downloaded, against the panel's own bar. Results come in two groups: sites they read, and notes, docs and meetings they wrote or took part in. Use it to bring back earlier reading while helping with a draft, or to find everything near a topic.",
                input: S.obj([
                    "item": S.str("An item id, URL, note path or title. Give this or text."),
                    "text": S.str("Free text to find related items for, like a paragraph the user is writing"),
                    "limit": S.int("Most results per group, 5 by default", min: 1, max: 15),
                    "min_score": S.num("Lowest score to include. By default the panel's own bar, which ranking.bar reports."),
                ]),
                output: S.obj([
                    "for": S.anyObj,
                    "sites": S.arr(match),
                    "docs": S.arr(match),
                    "ranking": S.obj(["bar": S.num("Lowest score shown"), "reranker": S.bool("The reranker scored these")]),
                    "hidden": S.int("Matches left out because the user hid them"),
                ], required: ["sites", "docs"]),
                writes: false) { [unowned self] a in
            let ctx = context
            let limit = Self.int(a, "limit", 5, min: 1, max: 15)
            let minScore = a["min_score"] == nil ? nil : Swift.max(0.05, Swift.min(0.95, Self.num(a, "min_score", 0.3)))
            var related: RankingSnapshot.Related
            var forJSON: JSON
            if Self.str(a, "item") != nil {
                let it = try item(a)
                related = ctx.ranking.related(to: it, ctx: ctx, minScore: minScore, perSection: limit + 3)
                forJSON = ctx.itemJSON(it)
            } else if let text = Self.str(a, "text") {
                let key = "mcp:text:" + Self.version(Data(text.utf8))
                related = ctx.ranking.related(ContextInput(key: key, title: "", text: text, kind: .page), ctx: ctx,
                                              minScore: minScore, perSection: limit + 3)
                forJSON = ["text": String(text.prefix(200))]
            } else {
                throw ToolError(message: "Pass item or text.")
            }
            var hidden = 0
            var sites: [JSON] = [], docs: [JSON] = []
            var served: [String] = []
            for m in related.matches {
                guard let it = ctx.reader.item(id: m.doc.id) else { continue }
                if !ctx.visible(it) { hidden += 1; continue }
                var j = ctx.itemJSON(it)
                j["score"] = J.round3(m.score)
                j["signals"] = ["words": J.round3(m.keyword), "meaning": J.round3(m.semantic), "names": J.round3(m.entity),
                                "reranker": m.rerank.map { J.round3($0) as Any } ?? NSNull()]
                j["found_by"] = m.foundBy
                j["shared_terms"] = Array(m.sharedTerms.prefix(8))
                j["shared_names"] = Array(m.sharedEntities.prefix(8))
                j["passage"] = it.isNote ? Self.snippet(m.passage, words: m.sharedTerms, title: it.title) : m.passage
                j["reason"] = Fmt.clean(Reasons.template(m, visits: related.visits[m.doc.id] ?? []))
                if m.section == .docs { if docs.count < limit { docs.append(j); served.append(ctx.title(it)) } }
                else if sites.count < limit { sites.append(j); served.append(ctx.title(it)) }
            }
            var out: JSON = ["for": forJSON, "sites": sites, "docs": docs, "hidden": hidden]
            if let g = related.gate { out["ranking"] = ["bar": J.round3(minScore ?? g.bar), "reranker": g.usesReranker] }
            ctx.log("tool", "related", (forJSON["title"] as? String) ?? (forJSON["text"] as? String) ?? "", served: served, hidden: hidden)
            return out
        }
    }

    private func connectionsTool() -> MCPTool {
        MCPTool(name: "connections", title: "Graph connections",
                description: "The item's neighbours in the user's knowledge graph, with the type of each connection and why it exists. Types: link (one links to the other), research (added from the Related panel), navigation (clicked from one to the other), together (open side by side or one after the other), similar (close in meaning) and topic (mention the same names). Depth 2 also returns neighbours of neighbours.",
                input: S.obj([
                    "item": S.str("Item id, URL, note path or title"),
                    "depth": S.int("1 or 2, 1 by default", min: 1, max: 2),
                    "types": S.arr(S.str("", ["link", "research", "navigation", "together", "similar", "topic"]), "Only these connection types"),
                    "limit": S.int("Most connections, 40 by default", min: 1, max: 150),
                ], required: ["item"]),
                output: S.obj([
                    "center": S.item,
                    "nodes": S.arr(S.withItem(["depth": S.int("Steps from the center")])),
                    "edges": S.arr(S.obj([
                        "from": S.int("Item id"), "to": S.int("Item id"), "type": S.str("Connection type"),
                        "directed": S.bool(""), "weight": S.num(""), "why": S.str("Why they're connected"), "detail": S.str(""),
                    ], required: ["from", "to", "type", "why"])),
                    "source": S.str("graph when the app's graph store answered, index when built from the index"),
                    "hidden": S.int("Connections left out because the user hid one end"),
                ], required: ["center", "nodes", "edges"]),
                writes: false) { [unowned self] a in
            let ctx = context
            let it = try item(a)
            let depth = Self.int(a, "depth", 1, min: 1, max: 2)
            let limit = Self.int(a, "limit", 40, min: 1, max: 150)
            let types = Self.strings(a, "types").map(Set.init)
            var edges = graph.edges(itemID: it.id, types: types, limit: limit)
            var depthOf: [Int64: Int] = [it.id: 0]
            for e in edges { for n in [e.from, e.to] where depthOf[n] == nil { depthOf[n] = 1 } }
            if depth == 2 {
                let firstRing = edges.map { $0.from == it.id ? $0.to : $0.from }
                for n in Array(NSOrderedSet(array: firstRing)).compactMap({ $0 as? Int64 }).prefix(6) {
                    for e in graph.edges(itemID: n, types: types, limit: 8) where edges.count < limit * 2 {
                        if (e.from == it.id || e.to == it.id) { continue }
                        edges.append(e)
                        for m in [e.from, e.to] where depthOf[m] == nil { depthOf[m] = 2 }
                    }
                }
            }
            let metas = ctx.reader.items(ids: Array(depthOf.keys))
            let visibleIDs = Set(metas.values.filter(ctx.visible).map { $0.id })
            var hidden = 0
            let kept = edges.filter { e in
                let ok = visibleIDs.contains(e.from) && visibleIDs.contains(e.to)
                if !ok { hidden += 1 }
                return ok
            }
            let used = Set(kept.flatMap { [$0.from, $0.to] }).union([it.id])
            let nodes: [JSON] = used.compactMap { id in
                guard let m = metas[id], id != it.id else { return nil }
                var j = ctx.itemJSON(m)
                j["depth"] = depthOf[id] ?? 1
                return j
            }.sorted { ($0["depth"] as? Int ?? 0) < ($1["depth"] as? Int ?? 0) }
            let edgeJSON: [JSON] = kept.map {
                ["from": $0.from, "to": $0.to, "type": $0.type, "directed": $0.directed, "weight": J.round3($0.weight),
                 "why": $0.why, "detail": $0.detail]
            }
            ctx.log("tool", "connections", ctx.title(it), served: nodes.compactMap { $0["title"] as? String }, hidden: hidden)
            return ["center": ctx.itemJSON(it), "nodes": nodes, "edges": edgeJSON, "source": graph.name, "hidden": hidden]
        }
    }

    private func currentContextTool() -> MCPTool {
        let ref = S.obj(["title": S.str(""), "url": S.str(""), "kind": S.str(""), "id": ["type": ["integer", "null"]], "cite": S.str("")])
        return MCPTool(name: "current_context", title: "What the user is working on now",
                description: "What the user has in front of them in the browser right now: the focused page or note (with a short excerpt), the other side of a split, the space they're in and its open tabs, the Related cards on screen, and the last things they focused. Use it when the user says \"this\", \"what I'm working on\" or \"the page I have open\".",
                input: S.obj([:], extra: false),
                output: S.obj([
                    "shared": S.bool("False when the user turned this off"),
                    "app_running": S.bool(""),
                    "updated_at": S.nullableStr,
                    "space": S.anyObj,
                    "focused": S.anyObj,
                    "split_with": S.anyObj,
                    "split_panes": S.arr(ref, "Every other pane of the split, up to three"),
                    "open_tabs": S.arr(ref),
                    "related_on_screen": S.arr(ref),
                    "recently_focused": S.arr(ref),
                    "message": S.str(""),
                ], required: ["shared"]),
                writes: false) { [unowned self] _ in
            let ctx = context
            guard ctx.mcp.shareCurrentContext else {
                ctx.log("tool", "current_context", "not shared", served: [])
                return ["shared": false, "message": "The user doesn't share what they're working on with AI clients."]
            }
            guard let cc = ctx.reader.currentContext() else {
                return ["shared": true, "app_running": false,
                        "message": "The app hasn't recorded what's open yet. It does that while it runs."]
            }
            var served: [String] = []
            func ref(_ r: CurrentContextFile.Ref?) -> JSON? {
                guard let r else { return nil }
                let source = r.kind == "note" ? MCPSources.notes : MCPSources.web
                guard ctx.privacy.allows(source: source, url: r.url) else { return nil }
                let hit = ctx.reader.resolve(r.key ?? r.url)
                var j: JSON = ["title": r.title, "url": r.url, "kind": r.kind, "cite": ctx.cite(title: r.title, url: r.url),
                               "id": hit.map { $0.id as Any } ?? NSNull()]
                if let at = r.at { j["at"] = J.iso.string(from: at) }
                served.append(r.title)
                return j
            }
            var out: JSON = ["shared": true, "app_running": ctx.appRunning(cc), "updated_at": J.iso.string(from: cc.updatedAt)]
            if let s = cc.space { out["space"] = ["name": s.name, "id": s.id] }
            if var f = ref(cc.focused) {
                if let id = f["id"] as? Int64, let it = ctx.reader.item(id: id) {
                    let body = ctx.reader.body(id: id)
                    f["excerpt"] = String(body.prefix(600))
                    f["uri"] = "browser://item/\(it.id)"
                }
                out["focused"] = f
            }
            // Every other pane of the split, up to three. Older files only have the one.
            let panes = (cc.splitPanes ?? cc.splitWith.map { [$0] } ?? []).compactMap(ref)
            if let first = panes.first {
                out["split_with"] = first
                out["split_panes"] = panes
            }
            out["open_tabs"] = cc.openTabs.compactMap(ref)
            out["related_on_screen"] = cc.related.compactMap(ref)
            out["recently_focused"] = cc.trail.prefix(15).compactMap(ref)
            ctx.log("tool", "current_context", "", served: served)
            return out
        }
    }

    private func recentTool() -> MCPTool {
        MCPTool(name: "recent_activity", title: "Recent activity",
                description: "What the user opened, read and edited over the last few days, newest first, plus what they focused in the browser and, if they allow it, what they searched for. Use it to catch up on what they've been doing or to find something they saw recently but can't name.",
                input: S.obj([
                    "days": S.int("How far back, 3 by default", min: 1, max: 90),
                    "limit": S.int("Most items, 30 by default", min: 1, max: 100),
                    "kind": S.str("Only notes, docs, meetings or pages", ["note", "doc", "meeting", "page"]),
                ]),
                output: S.obj([
                    "since": S.str(""),
                    "items": S.arr(S.withItem(["activity": S.str("opened, edited or visited"), "at": S.str("")])),
                    "searches": ["type": ["array", "null"], "items": S.obj(["query": S.str(""), "at": S.str("")])],
                    "searches_hidden": S.bool("True when the user hid past searches"),
                ], required: ["since", "items"]),
                writes: false) { [unowned self] a in
            let ctx = context
            let days = Self.int(a, "days", 3, min: 1, max: 90)
            let limit = Self.int(a, "limit", 30, min: 1, max: 100)
            let kind = Self.str(a, "kind")?.lowercased()
            let since = Date().timeIntervalSince1970 - Double(days) * 86400
            let candidates = ctx.reader.items(where: "max(last_opened, last_seen, mtime) >= ? ORDER BY max(last_opened, last_seen, mtime) DESC LIMIT ?",
                                              [since, limit * 4])
            var rows: [JSON] = []
            var served: [String] = []
            var hidden = 0
            for it in candidates {
                if rows.count >= limit { break }
                if !ctx.visible(it) { hidden += 1; continue }
                if let kind, it.kind(writingSites: ctx.app.writingSites) != kind { continue }
                var j = ctx.itemJSON(it)
                let activity = it.lastOpened > 0 && it.lastOpened >= it.lastActive ? "opened" : (it.isNote ? "edited" : "visited")
                j["activity"] = activity
                j["at"] = J.date(it.lastActive)
                rows.append(j)
                served.append(ctx.title(it))
            }
            var out: JSON = ["since": J.iso.string(from: Date(timeIntervalSince1970: since)), "items": rows, "hidden": hidden]
            if ctx.privacy.allowsSearches() {
                out["searches"] = ctx.reader.recentSearches(since: since, limit: 40).map {
                    ["query": $0.query, "at": J.date($0.at), "where": $0.source] as JSON
                }
                out["searches_hidden"] = false
            } else {
                out["searches"] = NSNull()
                out["searches_hidden"] = true
            }
            ctx.log("tool", "recent_activity", "\(days) days", served: served, hidden: hidden)
            return out
        }
    }

    private func spacesTool() -> MCPTool {
        let tab = S.obj(["title": S.str(""), "url": S.str(""), "kind": S.str("page or note"), "id": ["type": ["integer", "null"]], "cite": S.str("")])
        return MCPTool(name: "list_spaces", title: "Spaces, pins and folders",
                description: "The user's browser spaces (like projects or areas of life), each with its pinned items, sidebar folders and what's in them, open tabs and side-by-side splits of up to four panes, plus the Essentials shared by every space. Use it to learn how the user organises their work, or to see what belongs to a project.",
                input: S.obj(["space": S.str("Only the space with this name")]),
                output: S.obj([
                    "current_space": S.nullableStr,
                    "spaces": S.arr(S.obj([
                        "name": S.str(""), "id": S.str(""), "is_current": S.bool(""),
                        "pinned": S.arr(tab),
                        "folders": S.arr(S.obj(["name": S.str(""), "items": S.arr(tab)])),
                        "open_tabs": S.arr(tab),
                        "splits": S.arr(S.obj(["panes": S.arr(tab, "Two to four items side by side, in reading order"),
                                               "focused": S.nullableStr])),
                    ])),
                    "essentials": S.arr(tab, "Items pinned for every space"),
                    "hidden": S.int("Tabs left out because the user hid them"),
                ], required: ["spaces"]),
                writes: false) { [unowned self] a in
            let ctx = context
            guard let state = ctx.reader.savedState() else {
                return ["spaces": [], "current_space": NSNull(), "hidden": 0, "message": "No saved browser state yet."]
            }
            let only = Self.str(a, "space")?.lowercased()
            var hidden = 0
            var served: [String] = []
            func tabJSON(_ t: TabRecord) -> JSON? {
                guard let url = t.url, !url.isEmpty, t.kind == .web || t.kind == .note || t.kind == .file else { return nil }
                let isNote = t.kind != .web
                guard ctx.privacy.allows(source: isNote ? MCPSources.notes : MCPSources.web, url: url) else { hidden += 1; return nil }
                let hit = ctx.reader.resolve(url)
                let named = (t.customTitle?.isEmpty == false ? t.customTitle! : t.title)
                let title = named.isEmpty ? (hit.map(ctx.title) ?? url) : named
                served.append(title)
                return ["title": title, "url": url, "kind": isNote ? "note" : "page", "id": hit.map { $0.id as Any } ?? NSNull(),
                        "cite": ctx.cite(title: title, url: url)]
            }
            let spaces = state.spaces ?? []
            let homeID = spaces.first?.id
            let byID = Dictionary(state.tabs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            // Sidebar order where the app recorded one, otherwise the order they were made.
            let ordered = state.tabs.enumerated().sorted { ($0.element.order ?? Double($0.offset)) < ($1.element.order ?? Double($1.offset)) }
                .map { $0.element }
            let essentials = ordered.filter { $0.isEssential == true }
            var out: [JSON] = []
            for sp in spaces {
                if let only, sp.name.lowercased() != only { continue }
                let tabs = ordered.filter { ($0.spaceID ?? homeID) == sp.id && $0.isEssential != true }
                let splits = (state.splits ?? []).filter { ($0.spaceID ?? homeID) == sp.id }
                let inSplit = Set(splits.flatMap { $0.items })
                let folders = state.folders.filter { ($0.spaceID ?? homeID) == sp.id }
                let folderIDs = Set(folders.map { $0.id })
                var j: JSON = ["name": sp.name, "id": sp.id.uuidString, "is_current": sp.id == (state.currentSpace ?? homeID)]
                j["pinned"] = tabs.filter { $0.isPinned && $0.folderID == nil && !inSplit.contains($0.id) }.compactMap(tabJSON)
                j["folders"] = folders.map { f in
                    ["name": f.name, "items": tabs.filter { $0.folderID == f.id }.compactMap(tabJSON)] as JSON
                }
                j["open_tabs"] = tabs.filter { !$0.isPinned && !folderIDs.contains($0.folderID ?? UUID()) && !inSplit.contains($0.id) }.compactMap(tabJSON)
                // Splits hold up to four panes, in reading order.
                j["splits"] = splits.compactMap { s -> JSON? in
                    let panes = s.items.compactMap { byID[$0] }.compactMap(tabJSON)
                    guard panes.count >= 2 else { return nil }
                    let focused = byID[s.focused].flatMap(tabJSON)?["title"] as? String
                    return ["panes": panes, "focused": focused.map { $0 as Any } ?? NSNull()]
                }
                out.append(j)
            }
            let current = spaces.first { $0.id == (state.currentSpace ?? homeID) }?.name
            ctx.log("tool", "list_spaces", only ?? "", served: served, hidden: hidden)
            return ["spaces": out, "essentials": essentials.compactMap(tabJSON),
                    "current_space": current.map { $0 as Any } ?? NSNull(), "hidden": hidden]
        }
    }

    private func listNotesTool() -> MCPTool {
        MCPTool(name: "list_notes", title: "List notes",
                description: "Lists the user's Markdown notes in their notes folders, newest first by default, with path, title, project (top folder) and when each changed. Filter by folder, project, words in the name or how recently it changed. Pages with cursor.",
                input: S.obj([
                    "folder": S.str("Only notes inside this folder path"),
                    "project": S.str("Only notes in this top folder"),
                    "query": S.str("Only notes whose name or title contains this"),
                    "modified_within_days": S.int("Only notes changed in the last N days", min: 1, max: 3650),
                    "sort": S.str("recent (default) or name", ["recent", "name"]),
                    "limit": S.int("Notes per page, 50 by default", min: 1, max: 200),
                    "cursor": S.str("next_cursor from the last page"),
                ]),
                output: S.obj([
                    "folders": S.arr(S.str("Notes folder")),
                    "total": S.int("Notes matching the filters"),
                    "notes": S.arr(S.obj([
                        "path": S.str(""), "title": S.str(""), "name": S.str("File name without .md"), "project": S.str(""),
                        "modified": S.str(""), "id": ["type": ["integer", "null"]], "cite": S.str(""),
                        "downloaded": S.bool("False while the file is still only in iCloud"),
                    ], required: ["path", "title"])),
                    "next_cursor": S.nullableStr,
                ], required: ["notes", "total"]),
                writes: false) { [unowned self] a in
            let ctx = context
            guard !ctx.mcp.isHidden(MCPSources.notes) else { throw ToolError(message: "The user hid their notes from AI clients.") }
            let limit = Self.int(a, "limit", 50, min: 1, max: 200)
            let offset = Self.str(a, "cursor").flatMap { Data(base64Encoded: $0) }.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
            let folder = Self.str(a, "folder").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            let project = Self.str(a, "project")?.lowercased()
            let query = Self.str(a, "query")?.lowercased()
            let within = (a["modified_within_days"] != nil) ? Self.int(a, "modified_within_days", 30, min: 1, max: 3650) : nil
            let cutoff = within.map { Date().timeIntervalSince1970 - Double($0) * 86400 }
            var files: [(NoteFile, URL)] = []
            for r in ctx.notesRoots { for f in NotesScan.scan(r).allFiles { files.append((f, r)) } }
            var rows: [(JSON, Double, String)] = []
            for (f, r) in files {
                if let folder, !(FileSafety.isInside(f.url, folder)) { continue }
                let proj = NotesScan.project(for: f.url, root: r)
                if let project, proj.lowercased() != project { continue }
                if let cutoff, f.mtime < cutoff { continue }
                let hit = ctx.reader.item(key: URLKey.fileKey(f.url))
                let title = hit.map(ctx.title) ?? f.name
                if let query, !(f.name.lowercased().contains(query) || title.lowercased().contains(query)) { continue }
                let url = f.url.standardizedFileURL.absoluteString
                rows.append((["path": f.url.path, "title": title, "name": f.name, "project": proj, "modified": J.date(f.mtime),
                              "id": hit.map { $0.id as Any } ?? NSNull(), "cite": ctx.cite(title: title, url: url),
                              "downloaded": f.isLocal], f.mtime, f.name))
            }
            if Self.str(a, "sort") == "name" { rows.sort { $0.2.localizedStandardCompare($1.2) == .orderedAscending } }
            else { rows.sort { $0.1 > $1.1 } }
            let page = rows.dropFirst(offset).prefix(limit)
            let next = offset + page.count < rows.count ? Data(String(offset + page.count).utf8).base64EncodedString() : nil
            ctx.log("tool", "list_notes", query ?? project ?? "", served: page.compactMap { $0.0["title"] as? String })
            return ["folders": ctx.notesRoots.map { $0.path }, "total": rows.count, "notes": page.map { $0.0 },
                    "next_cursor": next.map { $0 as Any } ?? NSNull()]
        }
    }

    private func readNoteTool() -> MCPTool {
        MCPTool(name: "read_note", title: "Read a note from disk",
                description: "Reads a note's exact current Markdown from disk, paged with offset and max_chars. Returns a version string; pass it to append_to_note so a write is refused if the note changed in between. Only notes inside the user's notes folders can be read.",
                input: S.obj([
                    "note": S.str("Note path, file URL, item id or note title"),
                    "offset": S.int("Character to start from", min: 0),
                    "max_chars": S.int("Most characters to return, 20000 by default", min: 200, max: 60000),
                ], required: ["note"]),
                output: S.obj([
                    "path": S.str(""), "title": S.str(""), "project": S.str(""), "modified": S.str(""),
                    "version": S.str("Changes whenever the file's bytes change"),
                    "text": S.str(""), "offset": S.int(""),
                    "next_offset": ["type": ["integer", "null"]],
                    "total_chars": S.int(""),
                    "id": ["type": ["integer", "null"]],
                    "cite": S.str(""),
                    "links": S.arr(S.anyObj),
                ], required: ["path", "version", "text", "total_chars"]),
                writes: false) { [unowned self] a in
            let ctx = context
            let url = try noteURL(a, "note")
            guard let data = NotesScan.read(url) else {
                throw ToolError(message: "Couldn't read that note. It may still be downloading from iCloud.")
            }
            let text = NotesScan.decode(data)
            let offset = Self.int(a, "offset", 0, min: 0)
            let maxChars = Self.int(a, "max_chars", 20000, min: 200, max: 60000)
            let (page, next) = Self.slice(text, offset: offset, max: maxChars)
            let hit = ctx.reader.item(key: URLKey.fileKey(url))
            let title = Indexer.noteTitle(text: text, url: url)
            let root = FileSafety.notesRoot(for: url, roots: ctx.notesRoots)
            ctx.log("tool", "read_note", url.lastPathComponent, served: [title])
            return [
                "path": url.path, "title": title,
                "project": root.map { NotesScan.project(for: url, root: $0) } ?? "",
                "modified": J.date(NotesScan.mtime(url) ?? 0),
                "version": Self.version(data),
                "text": page, "offset": offset, "next_offset": next.map { $0 as Any } ?? NSNull(),
                "total_chars": text.count,
                "id": hit.map { $0.id as Any } ?? NSNull(),
                "cite": ctx.cite(title: title, url: url.standardizedFileURL.absoluteString),
                "links": links(in: text, noteURL: url),
            ]
        }
    }

    /// A note's file URL from a path, file URL, item id, key or title. Only `.md` files inside
    /// the notes folders, and only when notes aren't hidden.
    func noteURL(_ a: JSON, _ key: String) throws -> URL {
        let ctx = context
        guard !ctx.mcp.isHidden(MCPSources.notes) else { throw ToolError(message: "The user hid their notes from AI clients.") }
        guard let ref = Self.str(a, key) else { throw ToolError(message: "Pass \(key): a note path, item id or title.") }
        var url: URL?
        if ref.hasPrefix("/") || ref.hasPrefix("~") {
            url = URL(fileURLWithPath: (ref as NSString).expandingTildeInPath)
        } else if let u = URL(string: ref), u.isFileURL {
            url = u
        } else if let it = ctx.reader.resolve(ref) {
            url = it.fileURL
        }
        guard let u = url?.standardizedFileURL else { throw ToolError(message: "No note matches \"\(ref)\". Use list_notes or search to find it.") }
        guard u.pathExtension.lowercased() == "md", FileSafety.notesRoot(for: u, roots: ctx.notesRoots) != nil else {
            throw ToolError(message: "Only .md notes inside the user's notes folders are available.")
        }
        return u
    }
}
