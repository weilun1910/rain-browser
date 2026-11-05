import Foundation

/// Granola meeting notes through Granola's official MCP server. Granola encrypts its files on
/// the Mac and only its own app can read them, so this never touches them. Felix signs in once
/// in his default browser; there's no key to paste.
enum GranolaSource {
    static let endpoint = URL(string: "https://mcp.granola.ai/mcp")!
    static var tokenFile: URL { Paths.root.appendingPathComponent("granola-auth.json") }
    static var auth: OAuthClient { OAuthClient(resource: endpoint, tokenFile: tokenFile) }

    static var supportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Granola")
    }

    struct Meeting: Equatable {
        let id: String
        var title: String
        var date: Date?
        var text: String
        var key: String { "granola:" + id }
        var url: String { "https://notes.granola.ai/d/" + id }
    }

    // MARK: Parsing

    static let uuidPattern = try! NSRegularExpression(pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

    static func parseDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd", "MMM d, yyyy h:mm a", "MMM d, yyyy"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\(name)=\"([^\"]*)\""
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let r = Range(m.range(at: 1), in: tag) else { return nil }
        return String(tag[r])
    }

    static func element(_ name: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "<\(name)[^>]*>([\\s\\S]*?)</\(name)>"),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    static func stripTags(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<[^>]+>", with: "\n", options: .regularExpression)
        for (a, b) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] { t = t.replacingOccurrences(of: a, with: b) }
        return t.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Reads meetings out of tool output, which is XML-like or JSON text meant for a model.
    static func parseMeetings(_ text: String) -> [Meeting] {
        // JSON: an array, or an object holding one.
        if let d = text.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) {
            var arr: [[String: Any]] = []
            if let a = j as? [[String: Any]] { arr = a }
            else if let o = j as? [String: Any] {
                for k in ["meetings", "notes", "documents", "results", "data"] { if let a = o[k] as? [[String: Any]] { arr = a; break } }
            }
            if !arr.isEmpty {
                return arr.compactMap { o in
                    guard let id = (o["id"] ?? o["meeting_id"] ?? o["note_id"]) as? String else { return nil }
                    let title = (o["title"] as? String) ?? "Meeting"
                    let date = parseDate((o["meeting_at"] ?? o["date"] ?? o["created_at"] ?? o["start"]) as? String)
                    var parts: [String] = []
                    for k in ["summary", "ai_summary", "notes", "private_notes", "private_notes_markdown", "notes_markdown", "content", "transcript"] {
                        if let s = o[k] as? String, !s.isEmpty { parts.append(s) }
                    }
                    if let attendees = o["attendees"] as? [Any] {
                        let names = attendees.compactMap { ($0 as? String) ?? (($0 as? [String: Any])?["name"] as? String) }
                        if !names.isEmpty { parts.append("Attendees: " + names.joined(separator: ", ")) }
                    }
                    return Meeting(id: id, title: title, date: date, text: parts.joined(separator: "\n\n"))
                }
            }
        }
        // XML-like: <meeting id="..." title="..." date="..."> ... </meeting>
        var out: [Meeting] = []
        if let re = try? NSRegularExpression(pattern: "<(meeting|note|document)\\b([^>]*)>([\\s\\S]*?)</\\1>") {
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let attrsR = Range(m.range(at: 2), in: text), let bodyR = Range(m.range(at: 3), in: text) else { continue }
                let attrs = String(text[attrsR]), body = String(text[bodyR])
                let idText = attribute("id", in: attrs) ?? attribute("meeting_id", in: attrs) ?? element("id", in: body) ?? ""
                guard let idM = uuidPattern.firstMatch(in: idText.isEmpty ? attrs + body : idText, range: NSRange((idText.isEmpty ? attrs + body : idText).startIndex..., in: idText.isEmpty ? attrs + body : idText)) else { continue }
                let src = idText.isEmpty ? attrs + body : idText
                let id = String(src[Range(idM.range, in: src)!])
                let title = attribute("title", in: attrs) ?? element("title", in: body).map(stripTags) ?? "Meeting"
                let date = parseDate(attribute("meeting_at", in: attrs) ?? attribute("date", in: attrs) ?? attribute("created_at", in: attrs)
                                     ?? element("meeting_at", in: body) ?? element("date", in: body))
                var b = body
                if let t = element("title", in: body) { b = b.replacingOccurrences(of: t, with: "") }
                out.append(Meeting(id: id, title: title, date: date, text: stripTags(b)))
            }
        }
        if !out.isEmpty { return out }
        // Last resort: any meeting ids in plain text, so get_meetings can fetch them.
        var seen = Set<String>()
        return uuidPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            let id = String(text[Range(m.range, in: text)!])
            guard seen.insert(id).inserted else { return nil }
            return Meeting(id: id, title: "Meeting", date: nil, text: "")
        }
    }

    // MARK: Sync

    /// Signs in with Granola in the default browser.
    static func connect(open: @escaping @Sendable (URL) -> Void) async throws {
        _ = try await auth.signIn(open: open)
    }

    static func disconnect() { auth.signOut() }

    static var isConnected: Bool { auth.isConnected }

    /// Lists recent meetings and fetches their notes. Slow on purpose: Granola allows about 100
    /// requests a minute.
    static func sync(store: IndexStore = IndexStore.shared, days: Int = 90) async throws -> String {
        let client = MCPClient(endpoint: endpoint, auth: auth)
        let tools = try await client.listTools()
        guard let list = tools.first(where: { $0.name == "list_meetings" }) else { throw MCPClient.Failure.tool("Granola didn't offer list_meetings.") }
        var args: [String: Any] = [:]
        let since = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-Double(days) * 86400))
        for k in ["from_date", "start_date", "since", "after"] where list.properties.contains(k) { args[k] = since; break }
        if list.properties.contains("limit") { args["limit"] = 100 }
        let listed = parseMeetings(try await client.call("list_meetings", args))
        let known = store.sourceMtimes(.granola)
        let fresh = listed.filter { known[$0.key] == nil }
        var meetings: [Meeting] = []
        let hasGet = tools.contains { $0.name == "get_meetings" }
        for start in stride(from: 0, to: fresh.count, by: 10) where hasGet {
            let ids = fresh[start..<min(fresh.count, start + 10)].map { $0.id }
            let detail = parseMeetings(try await client.call("get_meetings", ["meeting_ids": ids]))
            for var m in detail {
                if let base = listed.first(where: { $0.id == m.id }) {
                    if m.title == "Meeting" { m.title = base.title }
                    if m.date == nil { m.date = base.date }
                }
                meetings.append(m)
            }
            try await Task.sleep(nanoseconds: 1_500_000_000)
        }
        var added = 0
        for m in meetings where !m.text.isEmpty {
            let at = (m.date ?? Date()).timeIntervalSince1970
            let a = TextAnalysis.analyze(title: m.title, description: "", text: m.text)
            let d = DocUpsert(key: m.key, source: .granola, url: m.url, title: m.title, body: String(m.text.prefix(40000)),
                              firstSeen: at, lastSeen: at, visitCount: 1, mtime: at)
            if store.upsertSourceDoc(d, analysis: a, visitKind: "met") { added += 1 }
        }
        return "\(listed.count) meetings listed, \(added) new"
    }

    // MARK: Dry run

    /// Reports what's on disk (names, sizes, whether files are encrypted) and the public sign-in
    /// metadata. Reads no notes and signs in to nothing.
    static func dryRun() -> Int32 {
        print("Granola dry run")
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(atPath: supportDir.path) {
            for name in items.sorted() where name.hasSuffix(".db") || name.hasSuffix(".json") || name.hasSuffix(".enc") {
                let u = supportDir.appendingPathComponent(name)
                let size = ((try? fm.attributesOfItem(atPath: u.path))?[.size] as? NSNumber)?.intValue ?? 0
                var note = ""
                if name.hasSuffix(".db"), let h = FileHandle(forReadingAtPath: u.path) {
                    let head = (try? h.read(upToCount: 16)) ?? Data()
                    try? h.close()
                    note = head.starts(with: Data("SQLite format 3".utf8)) ? "plain SQLite" : "not plain SQLite (encrypted)"
                } else if name.hasSuffix(".enc") {
                    note = "encrypted"
                }
                print("  \(name)  \(size) bytes  \(note)")
            }
        } else {
            print("  Granola's folder isn't there or isn't readable.")
        }
        print("  Local files are not read. Notes come from Granola's MCP server after you sign in.")
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var meta: OAuthClient.Metadata?
        nonisolated(unsafe) var failure: Error?
        Task.detached {
            do { meta = try await auth.discover() } catch { failure = error }
            sem.signal()
        }
        sem.wait()
        if let meta {
            print("  sign-in server: \(meta.issuer)")
            print("  registration endpoint: \(meta.registrationEndpoint ?? "none")")
            print("  connected in this profile: \(isConnected ? "yes" : "no")")
            return 0
        }
        print("  couldn't read the public sign-in metadata: \(failure.map { "\($0)" } ?? "unknown")")
        return 1
    }
}
