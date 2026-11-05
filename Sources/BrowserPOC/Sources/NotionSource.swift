import Foundation

/// Reads the pages the Notion desktop app keeps on this Mac. Copies `notion.db` into the app's
/// tmp folder, reads the copy, and deletes it. Notion's own files are only opened read-only to
/// copy their bytes.
enum NotionSource {
    static var dbURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Notion/notion.db")
    }

    struct Page {
        let id: String
        let title: String
        let text: String
        let created: Double
        let edited: Double
        let accessed: Double?
        let space: String?
        var key: String { "notion:" + id.replacingOccurrences(of: "-", with: "").lowercased() }
        var url: String { "https://www.notion.so/" + id.replacingOccurrences(of: "-", with: "").lowercased() }
    }

    struct Stats {
        var blocks = 0
        var livePages = 0
        var pagesWithText = 0
        var withAccessTime = 0
        var columns: [String] = []
    }

    /// Text runs in Notion's record format: [["Hello ", [["b"]]], ["world"]].
    static func runs(_ any: Any?) -> String {
        guard let arr = any as? [Any] else { return "" }
        var out = ""
        for seg in arr {
            if let s = seg as? [Any], let t = s.first as? String {
                // Mentions of pages, users and dates show as "‣" with the id in the format list.
                out += t == "\u{2023}" ? "" : t
            } else if let t = seg as? String {
                out += t
            }
        }
        return out
    }

    static func ms(_ v: Double) -> Double { v > 100_000_000_000 ? v / 1000 : v }

    /// Reads every live page with its text rebuilt from its blocks.
    static func read(from src: URL = dbURL) throws -> (pages: [Page], stats: Stats) {
        let dir = try ForeignDB.snapshot(src, app: "Notion")
        defer { try? FileManager.default.removeItem(at: dir) }
        let copy = dir.appendingPathComponent(src.lastPathComponent)
        let db = try SQLiteDB(path: copy.path)
        var stats = Stats()
        stats.columns = try db.query("PRAGMA table_info(block)") { $0.text(1) }
        let hasAccess = stats.columns.contains("meta_last_access_timestamp")
        let hasTemplate = stats.columns.contains("is_template")
        struct B { let type: String; let props: String?; let content: String?; let collection: String? }
        var blocks: [String: B] = [:]
        var pageRows: [(String, Double, Double, Double?, String?)] = []
        let sql = """
            SELECT id, type, properties, content, collection_id, created_time, last_edited_time, space_id,
              \(hasAccess ? "meta_last_access_timestamp" : "NULL"), \(hasTemplate ? "coalesce(is_template, 0)" : "0")
            FROM block WHERE alive = 1
            """
        for (id, type, props, content, coll, created, edited, space, access, tmpl) in try db.query(sql, [], {
            ($0.text(0), $0.text(1), $0.optText(2), $0.optText(3), $0.optText(4), $0.double(5), $0.double(6), $0.optText(7),
             $0.isNull(8) ? nil : $0.double(8), $0.int(9))
        }) {
            stats.blocks += 1
            blocks[id] = B(type: type, props: props, content: content, collection: coll)
            if (type == "page" || type == "collection_view_page") && tmpl == 0 {
                pageRows.append((id, ms(created), ms(edited), access.map(ms), space))
            }
        }
        var collections: [String: String] = [:]
        if let rows = try? db.query("SELECT id, name FROM collection", [], { ($0.text(0), $0.optText(1)) }) {
            for (id, name) in rows {
                if let name, let data = name.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: data) {
                    collections[id] = runs(j)
                }
            }
        }
        var spaces: [String: String] = [:]
        if let rows = try? db.query("SELECT id, name FROM space", [], { ($0.text(0), $0.optText(1)) }) {
            for (id, name) in rows { if let name { spaces[id] = name } }
        }
        func json(_ s: String?) -> Any? {
            guard let s, let d = s.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: d)
        }
        func line(_ b: B) -> String {
            guard let props = json(b.props) as? [String: Any] else { return "" }
            if b.type == "table_row" {
                return props.values.map { runs($0) }.filter { !$0.isEmpty }.joined(separator: " | ")
            }
            return runs(props["title"])
        }
        func walk(_ id: String, depth: Int, into out: inout [String], budget: inout Int) {
            guard depth < 8, budget > 0, let b = blocks[id], let kids = json(b.content) as? [String] else { return }
            for k in kids {
                guard budget > 0, let child = blocks[k] else { continue }
                let l = line(child)
                if !l.isEmpty {
                    let prefix: String
                    switch child.type {
                    case "header": prefix = "# "
                    case "sub_header": prefix = "## "
                    case "sub_sub_header", "header_4": prefix = "### "
                    case "bulleted_list", "numbered_list", "to_do": prefix = "- "
                    default: prefix = ""
                    }
                    out.append(prefix + l)
                    budget -= l.count
                }
                // Child pages are their own items. Only their title shows here.
                if child.type != "page" && child.type != "collection_view_page" {
                    walk(k, depth: depth + 1, into: &out, budget: &budget)
                }
            }
        }
        var pages: [Page] = []
        for (id, created, edited, access, space) in pageRows {
            guard let b = blocks[id] else { continue }
            var title = line(b)
            if title.isEmpty, let c = b.collection { title = collections[c] ?? "" }
            var lines: [String] = []
            var budget = 40_000
            walk(id, depth: 0, into: &lines, budget: &budget)
            let text = lines.joined(separator: "\n")
            stats.livePages += 1
            if access != nil { stats.withAccessTime += 1 }
            guard !title.trimmingCharacters(in: .whitespaces).isEmpty || !text.isEmpty else { continue }
            if !text.isEmpty { stats.pagesWithText += 1 }
            pages.append(Page(id: id, title: title.isEmpty ? "Untitled" : title, text: text, created: created, edited: edited,
                              accessed: access, space: space.flatMap { spaces[$0] }))
        }
        return (pages, stats)
    }

    /// Prints counts and field names only. Never page titles or text.
    static func dryRun() -> Int32 {
        do {
            let (pages, stats) = try read()
            print("Notion dry run (read from a temp copy, which is now deleted)")
            print("  block columns: \(stats.columns.joined(separator: ", "))")
            print("  live blocks: \(stats.blocks)")
            print("  live pages: \(stats.livePages)")
            print("  pages with text: \(stats.pagesWithText)")
            print("  pages with a last-opened time: \(stats.withAccessTime)")
            print("  pages that would be indexed: \(pages.filter { !$0.text.isEmpty }.count)")
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: Paths.tmpDir.path))?.filter { $0.hasPrefix("notion-") } ?? []
            print("  temp copies left behind: \(leftovers.count)")
            return 0
        } catch {
            print("Could not read Notion's data: \(error)")
            return 1
        }
    }

    /// Brings changed pages into the index and removes pages that are gone. Returns a summary.
    static func sync(from src: URL = dbURL, store: IndexStore = IndexStore.shared, progress: ((Int, Int) -> Void)? = nil) throws -> String {
        let (pages, _) = try read(from: src)
        let known = store.sourceMtimes(.notion)
        let withText = pages.filter { !$0.text.isEmpty }
        var changed = 0
        for (i, p) in withText.enumerated() {
            if let m = known[p.key], abs(m - p.edited) < 0.5 { continue }
            let a = TextAnalysis.analyze(title: p.title, description: "", text: p.text)
            let seen = max(p.accessed ?? 0, p.edited)
            let d = DocUpsert(key: p.key, source: .notion, url: p.url, title: p.title, body: String(p.text.prefix(40000)),
                              project: p.space, firstSeen: p.created, lastSeen: seen, visitCount: 1, mtime: p.edited)
            if store.upsertSourceDoc(d, analysis: a, visitKind: "opened") { changed += 1 }
            if i % 20 == 0 { progress?(i, withText.count) }
        }
        let present = Set(withText.map { $0.key })
        let gone = known.keys.filter { !present.contains($0) }
        store.deleteDocs(keys: Array(gone))
        return "\(withText.count) pages, \(changed) updated" + (gone.isEmpty ? "" : ", \(gone.count) removed")
    }
}
