import AppKit
import WebKit

/// `demo://<source>/<id>`: the demo profile's Google Docs, Sheets, Slides, Notion pages and
/// Granola meetings, drawn as read-only local pages. They aren't real documents, so nothing
/// here ever loads a Google or Notion address. The seeder copies each item's Markdown into
/// `demo-items/` in the profile, and this reads it back from there.
@MainActor
final class DemoScheme: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "demo"
    static let shared = DemoScheme()

    static func install(on c: WKWebViewConfiguration) {
        guard c.urlSchemeHandler(forURLScheme: scheme) == nil else { return }
        c.setURLSchemeHandler(shared, forURLScheme: scheme)
    }

    nonisolated static func handles(_ url: URL?) -> Bool { url?.scheme?.lowercased() == scheme }

    static var itemsDir: URL { Paths.root.appendingPathComponent("demo-items", isDirectory: true) }

    /// The item id in a demo address, if it's a safe file name.
    nonisolated static func itemID(_ url: URL) -> String? {
        guard handles(url) else { return nil }
        let id = url.lastPathComponent
        guard !id.isEmpty, id.count < 120, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        return id
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let (status, mime, body) = Self.response(for: url)
        let headers = ["Content-Type": mime, "Content-Length": String(body.count), "Cache-Control": "no-store"]
        let r = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(r)
        task.didReceive(body)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    /// Status, MIME type and bytes for a demo address. Anything other than a known item is a
    /// plain not-found page, so a bad address never falls through to the network.
    static func response(for url: URL) -> (Int, String, Data) {
        guard let id = itemID(url), url.pathComponents.count == 2 else {
            return (404, "text/plain; charset=utf-8", Data("Not found".utf8))
        }
        let file = itemsDir.appendingPathComponent(id + ".md")
        guard let text = try? String(contentsOf: file, encoding: .utf8), let item = DemoContent.parseItem(text) else {
            return (404, "text/html; charset=utf-8", Data(missingPage(id).utf8))
        }
        return (200, "text/html; charset=utf-8", Data(DemoPage.html(item).utf8))
    }

    static func missingPage(_ id: String) -> String {
        DemoPage.shell(title: "Not in this profile", icon: nil, body: """
            <header><div class="meta">Demo item</div><h1>Not in this profile</h1></header>
            <article><p>There's no demo item called \(Markdown.escape(id)) here. Demo items only exist in a profile made with <code>--seed-demo</code>.</p></article>
            """)
    }
}

/// The read-only page for one demo item, in the app's own look: the card's neutral background,
/// SF Pro for text, New York for the title, thin rules and quiet grey metadata.
enum DemoPage {
    static func html(_ item: DemoContent.Item) -> String {
        var meta: [String] = [item.sourceLabel]
        let day = DateFormatter()
        day.dateFormat = "EEE d MMM yyyy"
        day.timeZone = TimeZone(identifier: "America/New_York")
        let time = DateFormatter()
        time.dateFormat = "h:mm a"
        time.timeZone = day.timeZone
        if item.isMeeting {
            meta.append(day.string(from: item.edited) + ", " + time.string(from: item.edited))
            if let m = item.durationMin { meta.append("\(m) min") }
        } else {
            meta.append("Edited " + day.string(from: item.edited))
            if let o = item.owner { meta.append(o) }
        }
        var people = ""
        if item.isMeeting, !item.attendees.isEmpty {
            people = "<div class=\"people\">" + item.attendees.map { a in
                let detail = [a.role, a.org].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
                return "<span>\(Markdown.escape(a.name))" + (detail.isEmpty ? "" : " <em>\(Markdown.escape(detail))</em>") + "</span>"
            }.joined() + "</div>"
        } else if !item.sharedWith.isEmpty {
            people = "<div class=\"people\"><span><em>Shared with</em> " + Markdown.escape(item.sharedWith.joined(separator: ", ")) + "</span></div>"
        }
        // The title sits in the header, so a first heading that repeats it goes.
        var body = item.body
        let lines = body.components(separatedBy: "\n")
        if let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           lines[first].trimmingCharacters(in: .whitespaces) == "# " + item.title {
            body = lines[(first + 1)...].joined(separator: "\n")
        }
        let header = """
            <header>
              <div class="meta">\(meta.map(Markdown.escape).joined(separator: "<i></i>"))<span class="ro">Demo copy, read-only</span></div>
              <h1>\(Markdown.escape(item.title))</h1>
              \(people)
            </header>
            """
        return shell(title: item.title, icon: item.source, body: header + "<article>" + blocks(body) + "</article>")
    }

    /// Headings, paragraphs, lists with checkboxes, tables, quotes and rules. Inline styles come
    /// from the notes preview's own `Markdown.inline`.
    static func blocks(_ md: String) -> String {
        var out: [String] = []
        var para: [String] = []
        var list: String?
        var table: [[String]] = []

        func cells(_ line: String) -> [String] {
            var t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("|") { t.removeFirst() }
            if t.hasSuffix("|") { t.removeLast() }
            return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        func flushPara() { if !para.isEmpty { out.append("<p>" + para.map(Markdown.inline).joined(separator: " ") + "</p>"); para = [] } }
        func closeList() { if let l = list { out.append("</\(l)>"); list = nil } }
        func flushTable() {
            guard !table.isEmpty else { return }
            var rows = table
            table = []
            let head = rows.removeFirst()
            if let sep = rows.first, sep.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } && !$0.isEmpty }) { rows.removeFirst() }
            let numeric: (String) -> Bool = { s in !s.isEmpty && s.allSatisfy { $0.isNumber || ",.%$-".contains($0) } }
            var h = "<div class=\"table\"><table><thead><tr>" + head.map { "<th>\(Markdown.inline($0))</th>" }.joined() + "</tr></thead><tbody>"
            for r in rows {
                h += "<tr>" + r.map { "<td\(numeric($0) ? " class=\"n\"" : "")>\(Markdown.inline($0))</td>" }.joined() + "</tr>"
            }
            out.append(h + "</tbody></table></div>")
        }
        func flushAll() { flushPara(); closeList(); flushTable() }

        for line in md.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("|") { flushPara(); closeList(); table.append(cells(t)); continue }
            flushTable()
            if t.isEmpty { flushPara(); closeList(); continue }
            if t.hasPrefix("#") {
                let level = t.prefix(while: { $0 == "#" }).count
                if level <= 4, t.dropFirst(level).first == " " {
                    flushAll()
                    let lv = min(4, level + 1)
                    out.append("<h\(lv)>" + Markdown.inline(String(t.dropFirst(level + 1))) + "</h\(lv)>")
                    continue
                }
            }
            if t == "---" || t == "***" { flushAll(); out.append("<hr>"); continue }
            if t.hasPrefix("> ") { flushAll(); out.append("<blockquote>" + Markdown.inline(String(t.dropFirst(2))) + "</blockquote>"); continue }
            var item: String?
            var type = "ul"
            if t.hasPrefix("- ") || t.hasPrefix("* ") { item = String(t.dropFirst(2)) }
            else if let dot = t.firstIndex(of: "."), !t[..<dot].isEmpty, t[..<dot].allSatisfy(\.isNumber), t[t.index(after: dot)...].hasPrefix(" ") {
                item = String(t[t.index(dot, offsetBy: 2)...]); type = "ol"
            }
            if var it = item {
                flushPara()
                if list != type { closeList(); out.append("<\(type)>"); list = type }
                var check = ""
                if it.hasPrefix("[ ] ") { check = "<span class=\"box\"></span>"; it = String(it.dropFirst(4)) }
                else if it.hasPrefix("[x] ") || it.hasPrefix("[X] ") { check = "<span class=\"box done\"></span>"; it = String(it.dropFirst(4)) }
                out.append("<li\(check.isEmpty ? "" : " class=\"task\"")>" + check + Markdown.inline(it) + "</li>")
                continue
            }
            // A transcript line: [12:04] Name: words
            if let r = t.range(of: #"^\[(\d{1,2}:\d{2})\] ([^:]{1,40}): "#, options: .regularExpression) {
                flushAll()
                let head = String(t[r])
                let stamp = head.dropFirst().prefix(while: { $0 != "]" })
                let who = head.split(separator: "]", maxSplits: 1).last.map { $0.dropFirst().dropLast(2) } ?? ""
                out.append("<p class=\"line\"><span class=\"t\">\(stamp)</span><span class=\"who\">\(Markdown.escape(String(who)))</span>"
                           + Markdown.inline(String(t[r.upperBound...])) + "</p>")
                continue
            }
            closeList()
            para.append(t)
        }
        flushAll()
        return out.joined(separator: "\n")
    }

    static func shell(title: String, icon source: String?, body: String) -> String {
        let iconLink = source.flatMap { DemoIcons.png($0) }.map { "<link rel=\"icon\" type=\"image/png\" sizes=\"64x64\" href=\"data:image/png;base64,\($0.base64EncodedString())\">" } ?? ""
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(Markdown.escape(title))</title>
        <meta name="color-scheme" content="light dark">\(iconLink)
        <style>
        :root { color-scheme: light dark; --bg: #ffffff; --fg: #1d1d1f; --muted: #86868b; --rule: rgba(0,0,0,0.08); --soft: rgba(0,0,0,0.035); --link: #2f6fd6; }
        @media (prefers-color-scheme: dark) { :root { --bg: #202020; --fg: #e8e8ea; --muted: #8e8e93; --rule: rgba(255,255,255,0.10); --soft: rgba(255,255,255,0.045); --link: #7aaeff; } }
        html { background: var(--bg); }
        body { margin: 0; padding: 56px 40px 140px; color: var(--fg); font: 15px/1.6 -apple-system, "SF Pro Text", system-ui, sans-serif; -webkit-font-smoothing: antialiased; }
        header, article { max-width: 760px; margin: 0 auto; }
        header { padding-bottom: 22px; margin-bottom: 28px; border-bottom: 1px solid var(--rule); }
        .meta { font-size: 12px; color: var(--muted); display: flex; align-items: center; flex-wrap: wrap; gap: 0; }
        .meta i { display: inline-block; width: 18px; }
        .meta .ro { margin-left: auto; }
        h1 { font: 400 32px/1.2 "New York", ui-serif, Georgia, serif; letter-spacing: -0.2px; margin: 14px 0 10px; }
        .people { font-size: 13px; color: var(--muted); display: flex; flex-wrap: wrap; gap: 4px 18px; }
        .people span { color: var(--fg); } .people em { font-style: normal; color: var(--muted); }
        h2 { font-size: 19px; font-weight: 600; margin: 34px 0 10px; letter-spacing: -0.1px; }
        h3 { font-size: 16px; font-weight: 600; margin: 26px 0 8px; }
        h4 { font-size: 14px; font-weight: 600; margin: 20px 0 6px; color: var(--muted); }
        p { margin: 0 0 12px; } ul, ol { margin: 0 0 14px; padding-left: 22px; } li { margin: 4px 0; }
        li.task { list-style: none; margin-left: -22px; padding-left: 26px; position: relative; }
        .box { position: absolute; left: 2px; top: 5px; width: 12px; height: 12px; border: 1px solid var(--muted); border-radius: 3px; }
        .box.done { background: var(--muted); box-shadow: inset 0 0 0 2px var(--bg); }
        a { color: var(--link); text-decoration: none; } a:hover { text-decoration: underline; }
        strong { font-weight: 600; } hr { border: none; border-top: 1px solid var(--rule); margin: 24px 0; }
        blockquote { margin: 12px 0; padding-left: 14px; border-left: 2px solid var(--rule); color: var(--muted); }
        code { font: 13px ui-monospace, Menlo, monospace; background: var(--soft); padding: 1px 4px; border-radius: 4px; }
        .table { overflow-x: auto; margin: 6px 0 20px; }
        table { border-collapse: collapse; width: 100%; font-size: 13.5px; }
        th { text-align: left; font-weight: 600; color: var(--muted); font-size: 12px; padding: 7px 12px 7px 0; border-bottom: 1px solid var(--rule); white-space: nowrap; }
        td { padding: 8px 12px 8px 0; border-bottom: 1px solid var(--rule); vertical-align: top; }
        td.n { font-variant-numeric: tabular-nums; }
        p.line { display: grid; grid-template-columns: 52px 128px 1fr; gap: 0 10px; margin: 0 0 10px; }
        p.line .t { color: var(--muted); font-variant-numeric: tabular-nums; font-size: 12.5px; padding-top: 1px; }
        p.line .who { font-weight: 600; font-size: 13.5px; }
        </style></head><body>
        \(body)
        </body></html>
        """
    }
}

/// Small icons for the demo sources, drawn in code. Cached in the profile's favicons folder by
/// the seeder, and linked from each demo page so the sidebar keeps them.
enum DemoIcons {
    static let hosts = ["google-docs", "google-sheets", "google-slides", "notion", "granola"]

    nonisolated(unsafe) private static var cache: [String: Data] = [:]

    static func png(_ source: String, size: Int = 64) -> Data? {
        if let d = cache[source] { return d }
        let (hex, symbol, letter): (String, String?, String?) = {
            switch source {
            case "google-docs": return ("#4C8DF6", "text.alignleft", nil)
            case "google-sheets": return ("#3E9E6B", "tablecells", nil)
            case "google-slides": return ("#E0A030", "rectangle.inset.filled", nil)
            case "notion": return ("#2B2B2B", nil, "N")
            case "granola": return ("#6A9A52", "waveform", nil)
            default: return ("#7A8CA8", "doc", nil)
            }
        }()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let s = CGFloat(size)
        let rect = NSRect(x: 0, y: 0, width: s, height: s)
        Theme.Palette.RGB(hex: hex).ns.setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: s * 0.04, dy: s * 0.04), xRadius: s * 0.22, yRadius: s * 0.22).fill()
        if let letter {
            let font = NSFont(name: "NewYorkLarge-Semibold", size: s * 0.6) ?? NSFont.systemFont(ofSize: s * 0.58, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let str = NSAttributedString(string: letter, attributes: attrs)
            let sz = str.size()
            str.draw(at: NSPoint(x: (s - sz.width) / 2, y: (s - sz.height) / 2 + s * 0.01))
        } else if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: s * 0.42, weight: .semibold).applying(.init(paletteColors: [.white]))) {
            let isz = img.size
            img.draw(in: NSRect(x: (s - isz.width) / 2, y: (s - isz.height) / 2, width: isz.width, height: isz.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        let d = rep.representation(using: .png, properties: [:])
        if let d { cache[source] = d }
        return d
    }
}
