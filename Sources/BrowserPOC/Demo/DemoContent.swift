import CryptoKit
import Foundation

/// The demo profile's content as it sits in the repo's `Demo/` folder: Markdown notes, demo
/// Google Docs, Notion pages and Granola meetings, the browsing history, the layout and the
/// labelled resurfacing cases. See `Demo/SPEC.md` for the formats.
struct DemoContent {
    struct Note {
        let id: String
        let title: String
        let space: String
        let folder: String
        let created: Date
        let updated: Date
        let tags: [String]
        /// The text after the front matter, starting with the `# title` heading.
        let body: String
    }

    /// A demo Google Doc, Sheet, Slides deck, Notion page or Granola meeting.
    struct Item {
        struct Attendee { let name: String; let role: String; let org: String? }
        let id: String
        let title: String
        let source: String
        let space: String
        let created: Date
        let edited: Date
        let owner: String?
        let sharedWith: [String]
        let originURL: String?
        let demoURL: String
        let attendees: [Attendee]
        let durationMin: Int?
        let body: String
        /// The whole file, front matter included. The demo page reads this back.
        let raw: String

        var isMeeting: Bool { source == "granola" }
        var sourceType: SourceType {
            switch source {
            case "notion": return .notion
            case "granola": return .granola
            default: return .gdocs
            }
        }
        var sourceLabel: String { DemoContent.sourceLabel(source) }
    }

    struct History: Decodable {
        struct Page: Decodable {
            let id: String
            let url: String
            let title: String
            let site: String
            let space: String
            let query: String?
            let visitCount: Int
            let firstVisit: String
            let lastVisit: String
            let visits: [String]
            let dwellSeconds: Int
            let excerpt: String
            let excerptSource: String
        }
        struct Search: Decodable { let query: String; let at: String; let led_to: String? }
        let anchor: String
        let pages: [Page]
        let searches: [Search]
    }

    struct Layout: Decodable {
        struct Item: Decodable { let id: String; let kind: String; let ref: String }
        struct Folder: Decodable { let id: String; let name: String; let expanded: Bool; let items: [Item] }
        struct Split: Decodable { let id: String; let left: Item; let right: Item; let ratio: Double; let focus: String }
        struct Selected: Decodable { let split: String?; let item: String? }
        struct Space: Decodable {
            let id: String
            let name: String
            let icon: String
            let color: String
            let notesFolder: String
            let pinned: [Item]
            let folders: [Folder]
            let tabs: [Item]
            let splits: [Split]
            let selected: Selected
        }
        struct Focus: Decodable { let space: String; let split: String?; let pane: String?; let item: String }
        let anchor: String
        let currentSpace: String
        let focus: Focus
        let essentials: [Item]
        let spaces: [Space]
    }

    struct Expected: Decodable {
        struct Ref: Decodable { let ref: String; let section: String?; let why: String? }
        struct Context: Decodable { let kind: String; let ref: String; let space: String }
        struct Case: Decodable {
            let id: String
            let description: String
            let context: Context
            let onScreen: [String]
            let must: [Ref]
            let nice: [Ref]
            let acceptable: [String]
            let shouldNotSurface: [Ref]
            let atMostOneOf: [[String]]
        }
        let cases: [Case]
    }

    let dir: URL
    let notes: [Note]
    let items: [Item]
    let history: History
    let layout: Layout
    let expected: Expected?
    let anchor: Date

    var pages: [History.Page] { history.pages }
    func note(_ id: String) -> Note? { notes.first { $0.id == id } }
    func item(_ id: String) -> Item? { items.first { $0.id == id } }
    func page(_ id: String) -> History.Page? { history.pages.first { $0.id == id } }

    enum LoadError: Error, CustomStringConvertible {
        case notFound(String)
        case bad(String)
        var description: String {
            switch self {
            case .notFound(let s): return "Couldn't find the demo content: \(s)"
            case .bad(let s): return s
            }
        }
    }

    static func sourceLabel(_ source: String) -> String {
        switch source {
        case "google-docs": return "Google Docs"
        case "google-sheets": return "Google Sheets"
        case "google-slides": return "Google Slides"
        case "notion": return "Notion"
        case "granola": return "Granola"
        default: return source
        }
    }

    // MARK: Finding and loading

    /// The `Demo/` folder: the one given, else the first one found walking up from the binary
    /// or the working folder. Both `.build/debug/BrowserPOC` and `build/BrowserPOC.app` sit in the repo.
    static func locate(_ given: String?) -> URL? {
        let fm = FileManager.default
        if let given {
            let u = URL(fileURLWithPath: (given as NSString).expandingTildeInPath, isDirectory: true)
            return fm.fileExists(atPath: u.appendingPathComponent("spaces.json").path) ? u : nil
        }
        var starts: [URL] = [URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)]
        if let exe = Bundle.main.executableURL { starts.insert(exe.deletingLastPathComponent(), at: 0) }
        for start in starts {
            var d = start.standardizedFileURL
            for _ in 0..<10 {
                let c = d.appendingPathComponent("Demo", isDirectory: true)
                if fm.fileExists(atPath: c.appendingPathComponent("spaces.json").path) { return c }
                let up = d.deletingLastPathComponent()
                if up.path == d.path { break }
                d = up
            }
        }
        return nil
    }

    static func load(_ dir: URL) throws -> DemoContent {
        let fm = FileManager.default
        func json<T: Decodable>(_ name: String, _ type: T.Type) throws -> T {
            let u = dir.appendingPathComponent(name)
            guard let d = try? Data(contentsOf: u) else { throw LoadError.notFound(u.path) }
            do { return try JSONDecoder().decode(T.self, from: d) } catch { throw LoadError.bad("\(name) doesn't parse: \(error)") }
        }
        let history = try json("history.json", History.self)
        let layout = try json("spaces.json", Layout.self)
        let expected = try? json("expected.json", Expected.self)
        guard let anchor = parseDate(layout.anchor) else { throw LoadError.bad("spaces.json has no usable anchor") }

        var notes: [Note] = []
        let notesDir = dir.appendingPathComponent("notes", isDirectory: true)
        let folders = ((try? fm.contentsOfDirectory(at: notesDir, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
        for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let files = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "md" }
            for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let text = try String(contentsOf: f, encoding: .utf8)
                let (meta, body) = frontMatter(text)
                guard let id = meta["id"]?.string, let title = meta["title"]?.string, let space = meta["space"]?.string,
                      let c = meta["created"]?.string.flatMap(parseDate), let u = meta["updated"]?.string.flatMap(parseDate) else {
                    throw LoadError.bad("\(f.lastPathComponent) is missing front matter")
                }
                notes.append(Note(id: id, title: title, space: space, folder: folder.lastPathComponent, created: c, updated: u,
                                  tags: meta["tags"]?.list ?? [], body: body))
            }
        }

        var items: [Item] = []
        for sub in ["docs", "meetings"] {
            let d = dir.appendingPathComponent(sub, isDirectory: true)
            let files = ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "md" }
            for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let text = try String(contentsOf: f, encoding: .utf8)
                guard let item = parseItem(text) else { throw LoadError.bad("\(sub)/\(f.lastPathComponent) is missing front matter") }
                items.append(item)
            }
        }
        return DemoContent(dir: dir, notes: notes, items: items, history: history, layout: layout, expected: expected, anchor: anchor)
    }

    /// One demo doc or meeting from its file. Also used by the demo:// pages.
    static func parseItem(_ text: String) -> Item? {
        let (meta, body) = frontMatter(text)
        guard let id = meta["id"]?.string, let title = meta["title"]?.string, let source = meta["source"]?.string,
              let space = meta["space"]?.string, let demo = meta["demo_url"]?.string else { return nil }
        let isMeeting = source == "granola"
        let date = (isMeeting ? meta["date"]?.string : meta["created"]?.string).flatMap(parseDate)
        let edited = (isMeeting ? meta["date"]?.string : meta["edited"]?.string).flatMap(parseDate)
        guard let date, let edited else { return nil }
        let attendees = (meta["attendees"]?.maps ?? []).map { Item.Attendee(name: $0["name"] ?? "", role: $0["role"] ?? "", org: $0["org"]) }
        return Item(id: id, title: title, source: source, space: space, created: date, edited: edited,
                    owner: meta["owner"]?.string, sharedWith: meta["shared_with"]?.list ?? [], originURL: meta["origin_url"]?.string,
                    demoURL: demo, attendees: attendees, durationMin: meta["duration_min"]?.string.flatMap { Int($0) }, body: body, raw: text)
    }

    // MARK: Front matter

    enum Value {
        case string(String)
        case list([String])
        case maps([[String: String]])
        var string: String? { if case .string(let s) = self { return s }; return nil }
        var list: [String]? {
            switch self {
            case .list(let l): return l
            case .string(let s): return s.isEmpty ? [] : [s]
            case .maps: return nil
            }
        }
        var maps: [[String: String]]? { if case .maps(let m) = self { return m }; return nil }
    }

    /// The small YAML subset the demo files use: `key: value`, `key: [a, b]`, and a list of
    /// `{k: v, k: "v"}` maps under a key.
    static func frontMatter(_ text: String) -> ([String: Value], String) {
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) else {
            return ([:], text)
        }
        let head = text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound]
        let body = String(text[end.upperBound...])
        var out: [String: Value] = [:]
        var key: String?
        for line in head.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("  - "), let k = key {
                let item = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
                if item.hasPrefix("{") {
                    var maps = out[k]?.maps ?? []
                    maps.append(flowMap(item))
                    out[k] = .maps(maps)
                } else {
                    var l = out[k]?.list ?? []
                    l.append(scalar(item))
                    out[k] = .list(l)
                }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = line[..<colon].trimmingCharacters(in: .whitespaces)
            let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            key = k
            if v.hasPrefix("[") && v.hasSuffix("]") {
                out[k] = .list(splitTop(String(v.dropFirst().dropLast())).map(scalar).filter { !$0.isEmpty })
            } else if v.isEmpty {
                out[k] = .list([])
            } else {
                out[k] = .string(scalar(v))
            }
        }
        return (out, body)
    }

    static func scalar(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, let f = t.first, f == t.last, f == "\"" || f == "'" { return String(t.dropFirst().dropLast()) }
        return t
    }

    static func splitTop(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character?
        for c in s {
            if let q = quote {
                cur.append(c)
                if c == q { quote = nil }
            } else if (c == "\"" || c == "'"), cur.trimmingCharacters(in: .whitespaces).isEmpty || cur.trimmingCharacters(in: .whitespaces).hasSuffix(":") {
                // A quote opens a value at the start of an entry or right after a map key's colon.
                quote = c; cur.append(c)
            } else if c == "," {
                out.append(cur); cur = ""
            } else {
                cur.append(c)
            }
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty { out.append(cur) }
        return out
    }

    static func flowMap(_ s: String) -> [String: String] {
        var m: [String: String] = [:]
        for part in splitTop(String(s.dropFirst().dropLast())) {
            guard let c = part.firstIndex(of: ":") else { continue }
            m[part[..<c].trimmingCharacters(in: .whitespaces)] = scalar(String(part[part.index(after: c)...]))
        }
        return m
    }

    /// ISO 8601 with an offset, with or without seconds.
    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        // "2026-11-04T16:40-05:00" has no seconds.
        if let r = s.range(of: #"T\d{2}:\d{2}(?=[+-]\d{2}:\d{2}$|Z$)"#, options: .regularExpression) {
            return f.date(from: s.replacingCharacters(in: r, with: s[r] + ":00"))
        }
        return nil
    }

    // MARK: Stable ids

    /// A name-based UUID (version 5) from a demo id, so a reseed gives every space, folder,
    /// tab and split the same UUID.
    static func uuid(_ name: String) -> UUID {
        let namespace: [UInt8] = [0x6f, 0x1d, 0x2c, 0x44, 0x9a, 0x3b, 0x4e, 0x21, 0x8c, 0x55, 0x0b, 0x7e, 0x3f, 0x90, 0xd2, 0x18]
        var data = Data(namespace)
        data.append(Data(("rain-demo:" + name).utf8))
        var b = Array(Insecure.SHA1.hash(data: data).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
