import Foundation

/// Finds explicit links in a note or doc: `[[wikilinks]]`, Markdown links and bare URLs.
/// Targets are index keys, or `wiki:<name>` for wikilinks, which are resolved when the graph is read.
enum LinkExtractor {
    struct Ref: Hashable {
        let target: String
        let detail: String
    }

    static let wikiPrefix = "wiki:"
    static let maxRefs = 300

    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    private static let wikiRE = re("!?\\[\\[([^\\]\\|#\\^\\n]+)(?:[#\\^][^\\]\\|\\n]*)?(?:\\|([^\\]\\n]*))?\\]\\]")
    private static let mdRE = re("(!?)\\[([^\\]\\n]*)\\]\\(<?([^)\\s>]+)>?(?:\\s+\"[^\"\\n]*\")?\\)")
    private static let urlRE = re("https?://[^\\s<>()\\[\\]\"'`]+")
    private static let attachmentExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "pdf", "mp3", "mp4", "mov", "wav", "m4a", "heic", "zip", "canvas", "excalidraw"]

    /// The note name a wikilink points at, as written: the last path part without `.md`.
    static func wikiTarget(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let slash = s.lastIndex(of: "/") { s = String(s[s.index(after: slash)...]) }
        if s.lowercased().hasSuffix(".md") { s = String(s.dropLast(3)) }
        return s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The name a wikilink matches: the target folded for case and accents.
    static func wikiName(_ raw: String) -> String {
        TextAnalysis.fold(Substring(wikiTarget(raw)))
    }

    /// The name a note answers to in wikilinks: its file name.
    static func noteName(url: String) -> String? {
        guard let u = URL(string: url), u.isFileURL else { return nil }
        return wikiName(u.deletingPathExtension().lastPathComponent)
    }

    static func extract(body: String, ownKey: String, ownURL: String) -> [Ref] {
        guard !body.isEmpty else { return [] }
        let ns = body as NSString
        let full = NSRange(location: 0, length: ns.length)
        var out: [Ref] = []
        var seen = Set<String>()
        func add(_ target: String, _ detail: String) {
            let dedupe = target.hasPrefix(wikiPrefix) ? TextAnalysis.fold(Substring(target)) : target
            guard !target.isEmpty, target != ownKey, !seen.contains(dedupe), out.count < maxRefs else { return }
            seen.insert(dedupe)
            out.append(Ref(target: target, detail: String(detail.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))))
        }
        var covered: [NSRange] = []

        for m in wikiRE.matches(in: body, range: full) {
            covered.append(m.range)
            let raw = ns.substring(with: m.range(at: 1))
            let ext = (raw as NSString).pathExtension.lowercased()
            if !ext.isEmpty && ext != "md" && attachmentExts.contains(ext) { continue }
            let name = wikiTarget(raw)
            guard !name.isEmpty else { continue }
            let alias = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : ""
            // A note linking to itself by name isn't a connection.
            if let own = noteName(url: ownURL), own == wikiName(raw) { continue }
            add(wikiPrefix + name, alias)
        }

        let base = URL(string: ownURL)
        for m in mdRE.matches(in: body, range: full) {
            covered.append(m.range)
            let isImage = ns.substring(with: m.range(at: 1)) == "!"
            let text = ns.substring(with: m.range(at: 2))
            let rawTarget = ns.substring(with: m.range(at: 3))
            if isImage { continue }
            if let key = key(forTarget: rawTarget, base: base) { add(key, text) }
        }

        for m in urlRE.matches(in: body, range: full) {
            if covered.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) { continue }
            var s = ns.substring(with: m.range)
            while let last = s.last, ".,;:!?*_".contains(last) { s.removeLast() }
            if let u = URL(string: s), URLKey.isIndexableWeb(u) { add(URLKey.key(for: u), "") }
        }
        return out
    }

    /// An index key for a Markdown link target: a web page, or another note by relative path.
    static func key(forTarget raw: String, base: URL?) -> String? {
        let lower = raw.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let u = URL(string: raw), URLKey.isIndexableWeb(u) else { return nil }
            return URLKey.key(for: u)
        }
        if lower.hasPrefix("file://") {
            guard let u = URL(string: raw), u.pathExtension.lowercased() == "md" else { return nil }
            return URLKey.fileKey(u)
        }
        if lower.contains(":") || raw.hasPrefix("#") { return nil }
        var path = raw
        if let hash = path.firstIndex(of: "#") { path = String(path[..<hash]) }
        path = path.removingPercentEncoding ?? path
        guard path.lowercased().hasSuffix(".md"), let base, base.isFileURL else { return nil }
        let dir = base.deletingLastPathComponent()
        let target = path.hasPrefix("/") ? URL(fileURLWithPath: path) : dir.appendingPathComponent(path)
        return URLKey.fileKey(target.standardizedFileURL)
    }
}
