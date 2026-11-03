import Foundation

/// Pulls title, description and readable text out of raw HTML without running any scripts.
enum HTMLText {
    struct Extract {
        var title: String
        var description: String
        var text: String
    }

    private static func regex(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    private static let titleRE = regex("<title[^>]*>(.*?)</title>")
    private static let metaRE = regex("<meta\\s[^>]*>")
    private static let attrRE = regex("([a-zA-Z:_-]+)\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)")
    private static let dropBlocks = regex("<(script|style|noscript|svg|template|iframe|canvas|object)\\b[^>]*>.*?</\\1\\s*>")
    private static let comments = regex("<!--.*?-->")
    private static let chromeBlocks = regex("<(nav|header|footer|aside|form|button|select|dialog)\\b[^>]*>.*?</\\1\\s*>")
    private static let articleRE = regex("<article\\b[^>]*>(.*)</article\\s*>")
    private static let mainRE = regex("<main\\b[^>]*>(.*)</main\\s*>")
    private static let bodyRE = regex("<body\\b[^>]*>(.*)</body\\s*>")
    private static let blockEnd = regex("</?(p|div|br|li|ul|ol|h[1-6]|tr|table|section|article|blockquote|pre|dd|dt|figcaption)\\b[^>]*>")
    private static let tags = regex("<[^>]+>")

    private static func first(_ re: NSRegularExpression, in s: String, group: Int = 1) -> String? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > group else { return nil }
        let r = m.range(at: group)
        return r.location == NSNotFound ? nil : ns.substring(with: r)
    }

    private static func replace(_ re: NSRegularExpression, in s: String, with t: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: t)
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
                                       "mdash": "-", "ndash": "-", "hellip": "...", "rsquo": "'", "lsquo": "'",
                                       "rdquo": "\"", "ldquo": "\"", "middot": ",", "bull": ",", "copy": "(c)"]
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let name = String(s[s.index(after: i)..<semi])
                var rep: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X"), let v = UInt32(name.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) {
                    rep = String(Character(u))
                } else if name.hasPrefix("#"), let v = UInt32(name.dropFirst()), let u = Unicode.Scalar(v) {
                    rep = String(Character(u))
                } else {
                    rep = named[name.lowercased()]
                }
                if let rep {
                    out += rep
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }

    static func clean(_ s: String) -> String {
        let decoded = decodeEntities(s)
        var lines: [String] = []
        for line in decoded.components(separatedBy: .newlines) {
            let collapsed = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{00A0}" }).joined(separator: " ")
            if !collapsed.isEmpty { lines.append(collapsed) }
        }
        return Fmt.clean(lines.joined(separator: "\n"))
    }

    static func extract(_ html: String, maxChars: Int = 20000) -> Extract {
        let limited = String(html.prefix(3_000_000))
        let title = clean(first(titleRE, in: limited) ?? "").replacingOccurrences(of: "\n", with: " ")
        var description = ""
        let ns = limited as NSString
        for m in metaRE.matches(in: limited, range: NSRange(location: 0, length: min(ns.length, 200_000))) {
            let tag = ns.substring(with: m.range)
            var attrs: [String: String] = [:]
            let tns = tag as NSString
            for a in attrRE.matches(in: tag, range: NSRange(location: 0, length: tns.length)) {
                let k = tns.substring(with: a.range(at: 1)).lowercased()
                var v = tns.substring(with: a.range(at: 2))
                if v.hasPrefix("\"") || v.hasPrefix("'") { v = String(v.dropFirst().dropLast()) }
                attrs[k] = v
            }
            let name = (attrs["name"] ?? attrs["property"] ?? "").lowercased()
            if name == "description" || (description.isEmpty && name == "og:description") {
                description = clean(attrs["content"] ?? "")
            }
        }
        var doc = replace(comments, in: limited, with: " ")
        doc = replace(dropBlocks, in: doc, with: " ")
        func toText(_ fragment: String) -> String {
            var f = replace(chromeBlocks, in: fragment, with: " ")
            f = replace(blockEnd, in: f, with: "\n")
            f = replace(tags, in: f, with: " ")
            return clean(f)
        }
        var text = ""
        if let a = first(articleRE, in: doc) { text = toText(a) }
        if text.count < 500, let m = first(mainRE, in: doc) { text = toText(m) }
        if text.count < 500 { text = toText(first(bodyRE, in: doc) ?? doc) }
        return Extract(title: title, description: description, text: String(text.prefix(maxChars)))
    }

    static let wallPhrases = [
        "sign in to continue", "log in to continue", "login to continue", "please sign in", "please log in",
        "sign in to your account", "log in to your account", "you must be logged in", "you need to sign in",
        "create an account or sign in", "enable javascript", "javascript is required", "requires javascript",
        "verify you are human", "checking your browser", "access denied", "are you a robot", "just a moment",
        "subscribe to continue reading", "to continue, sign in",
    ]

    static func isLoginWall(_ e: Extract) -> Bool {
        let t = e.text
        if t.count < 300 { return true }
        let lower = t.lowercased()
        if t.count < 2000 {
            for p in wallPhrases where lower.contains(p) { return true }
        }
        return false
    }
}
