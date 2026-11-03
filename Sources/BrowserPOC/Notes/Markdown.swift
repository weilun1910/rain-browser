import Foundation

enum Markdown {
    /// Appends a link under a "## Related" heading at the end of the note.
    /// Returns nil when the link is already there.
    static func appendRelated(to text: String, title: String, url: String) -> String? {
        if text.contains("](\(url))") || text.contains("<\(url)>") { return nil }
        let safeTitle = title
            .replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
            .replacingOccurrences(of: "\n", with: " ")
        let line = "- [\(safeTitle)](\(url))"
        var lines = text.components(separatedBy: "\n")
        // Find the last "## Related" heading.
        var headingIdx: Int?
        for (i, l) in lines.enumerated() {
            let t = l.trimmingCharacters(in: .whitespaces).lowercased()
            if t == "## related" { headingIdx = i }
        }
        if let h = headingIdx {
            var insertAt = lines.count
            for j in (h + 1)..<lines.count where lines[j].trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                insertAt = j
                break
            }
            // Insert after the last non-empty line of the section.
            var k = insertAt
            while k > h + 1 && lines[k - 1].trimmingCharacters(in: .whitespaces).isEmpty { k -= 1 }
            lines.insert(line, at: k)
            var out = lines.joined(separator: "\n")
            if !out.hasSuffix("\n") { out += "\n" }
            return out
        }
        var out = text
        while out.hasSuffix("\n\n") { out.removeLast() }
        if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
        out += (out.isEmpty ? "" : "\n") + "## Related\n\n" + line + "\n"
        return out
    }

    // MARK: - Preview

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    private static let codeRE = re("`([^`]+)`")
    private static let imageRE = re("!\\[([^\\]]*)\\]\\(([^)\\s]+)\\)")
    private static let linkRE = re("\\[([^\\]]+)\\]\\(([^)\\s]+)\\)")
    private static let boldRE = re("\\*\\*([^*]+)\\*\\*")
    private static let italicRE = re("(?<![*\\w])\\*([^*]+)\\*(?![*\\w])")
    private static let autoRE = re("(?<![\"'(=>])(https?://[^\\s<]+)")

    static func inline(_ raw: String) -> String {
        // Protect code spans first.
        var codes: [String] = []
        let ns = raw as NSString
        var s = ""
        var last = 0
        for m in codeRE.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            s += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            codes.append(ns.substring(with: m.range(at: 1)))
            s += "\u{0}\(codes.count - 1)\u{0}"
            last = m.range.location + m.range.length
        }
        s += ns.substring(from: last)
        var h = escape(s)
        func sub(_ r: NSRegularExpression, _ t: String) {
            h = r.stringByReplacingMatches(in: h, range: NSRange(location: 0, length: (h as NSString).length), withTemplate: t)
        }
        sub(imageRE, "<img alt=\"$1\" src=\"$2\">")
        sub(linkRE, "<a href=\"$2\">$1</a>")
        sub(autoRE, "<a href=\"$1\">$1</a>")
        sub(boldRE, "<strong>$1</strong>")
        sub(italicRE, "<em>$1</em>")
        for (i, c) in codes.enumerated() {
            h = h.replacingOccurrences(of: "\u{0}\(i)\u{0}", with: "<code>\(escape(c))</code>")
        }
        return h
    }

    static func html(_ md: String, title: String) -> String {
        var out: [String] = []
        var para: [String] = []
        var listType: String?
        var inCode = false
        var code: [String] = []
        var quote: [String] = []

        func flushPara() {
            if !para.isEmpty { out.append("<p>" + para.map(inline).joined(separator: " ") + "</p>"); para = [] }
        }
        func closeList() { if let t = listType { out.append("</\(t)>"); listType = nil } }
        func flushQuote() {
            if !quote.isEmpty { out.append("<blockquote>" + quote.map(inline).joined(separator: "<br>") + "</blockquote>"); quote = [] }
        }

        for line in md.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                if inCode {
                    out.append("<pre><code>" + escape(code.joined(separator: "\n")) + "</code></pre>")
                    code = []; inCode = false
                } else {
                    flushPara(); closeList(); flushQuote(); inCode = true
                }
                continue
            }
            if inCode { code.append(line); continue }
            if t.isEmpty { flushPara(); closeList(); flushQuote(); continue }
            if t.hasPrefix("#") {
                let level = t.prefix(while: { $0 == "#" }).count
                if level <= 6, t.dropFirst(level).first == " " {
                    flushPara(); closeList(); flushQuote()
                    out.append("<h\(level)>" + inline(String(t.dropFirst(level + 1))) + "</h\(level)>")
                    continue
                }
            }
            if t == "---" || t == "***" || t == "___" { flushPara(); closeList(); flushQuote(); out.append("<hr>"); continue }
            if t.hasPrefix(">") {
                flushPara(); closeList()
                quote.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            var item: String?
            var type = "ul"
            if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") {
                item = String(t.dropFirst(2))
            } else if let dot = t.firstIndex(of: "."), t[..<dot].allSatisfy({ $0.isNumber }), !t[..<dot].isEmpty,
                      t[t.index(after: dot)...].hasPrefix(" ") {
                item = String(t[t.index(dot, offsetBy: 2)...]); type = "ol"
            }
            if var item {
                flushPara(); flushQuote()
                if listType != type { closeList(); out.append("<\(type)>"); listType = type }
                var check = ""
                if item.hasPrefix("[ ] ") { check = "<input type=checkbox disabled> "; item = String(item.dropFirst(4)) }
                if item.hasPrefix("[x] ") || item.hasPrefix("[X] ") { check = "<input type=checkbox checked disabled> "; item = String(item.dropFirst(4)) }
                out.append("<li>" + check + inline(item) + "</li>")
                continue
            }
            closeList(); flushQuote()
            para.append(t)
        }
        if inCode { out.append("<pre><code>" + escape(code.joined(separator: "\n")) + "</code></pre>") }
        flushPara(); closeList(); flushQuote()

        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(escape(title))</title>
        <style>
        :root { color-scheme: light dark; }
        body { font: 15px/1.6 -apple-system, system-ui, sans-serif; max-width: 720px; margin: 36px auto; padding: 0 32px; color: #1d1d1f; background: transparent; }
        @media (prefers-color-scheme: dark) { body { color: #e8e8ea; } a { color: #7ab7ff; } code, pre { background: rgba(255,255,255,0.08) !important; } }
        h1, h2, h3 { line-height: 1.25; margin: 1.4em 0 0.5em; }
        h1 { font-size: 1.7em; } h2 { font-size: 1.3em; } h3 { font-size: 1.1em; }
        a { color: #0a66d8; text-decoration: none; } a:hover { text-decoration: underline; }
        code { font: 13px ui-monospace, SFMono-Regular, Menlo, monospace; background: rgba(0,0,0,0.05); padding: 1px 4px; border-radius: 4px; }
        pre { background: rgba(0,0,0,0.05); padding: 12px 14px; border-radius: 8px; overflow-x: auto; }
        pre code { background: none; padding: 0; }
        blockquote { margin: 1em 0; padding-left: 14px; border-left: 3px solid rgba(128,128,128,0.35); color: gray; }
        li { margin: 0.25em 0; } img { max-width: 100%; } hr { border: none; border-top: 1px solid rgba(128,128,128,0.3); }
        </style></head><body>
        \(out.joined(separator: "\n"))
        </body></html>
        """
    }
}
