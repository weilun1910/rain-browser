import Foundation

/// The maintenance tools. They follow the app's disk rules for notes:
/// - only `.md` files inside a notes folder (`FileSafety.canWriteNote`),
/// - new notes are created without replacing anything,
/// - an append reads the file, and right before writing checks that its size and date haven't
///   moved. If the assistant passes the version it read, a different version refuses too.
/// The running app sees the change through its folder watcher, reloads an open note with no
/// unsaved edits, and shows its usual "changed on disk" bar if there are some.
final class MCPNoteWriter {
    let context: MCPContext

    init(context: MCPContext) { self.context = context }

    enum WriteError: Error { case changed, failed(String) }

    static func tools(_ box: MCPToolbox) -> [MCPTool] {
        let written = S.obj([
            "path": S.str("The note's file path"),
            "version": S.str("The note's version after the write"),
            "cite": S.str("A Markdown link to the note"),
            "created": S.bool(""),
            "changed": S.bool("False when nothing needed writing"),
            "message": S.str(""),
        ], required: ["path", "version", "changed"])

        let create = MCPTool(name: "create_note", title: "Create a note",
            description: "Creates a new Markdown note in the user's notes folders. It never replaces an existing file: if the name is taken, it adds a number. By default it goes where the user's current space saves new notes. Ask the user before creating notes, and write in their words.",
            input: S.obj([
                "title": S.str("The note's title. It becomes the file name and the first heading."),
                "text": S.str("Markdown body, without the title heading"),
                "folder": S.str("A folder inside the notes folders, as a path or a top folder name"),
            ], required: ["title"]),
            output: written, writes: true) { [unowned box] a in
            try box.writer.create(a)
        }

        let append = MCPTool(name: "append_to_note", title: "Append to a note",
            description: "Adds text to the end of a note, or to the end of a section under a heading. Pass the version from read_note: if the note changed since you read it, nothing is written and you should read it again. It never rewrites existing text.",
            input: S.obj([
                "note": S.str("Note path, item id or title"),
                "text": S.str("Markdown to add"),
                "under_heading": S.str("Add at the end of the section with this heading, creating the heading at the end if it's missing"),
                "expected_version": S.str("The version read_note returned"),
            ], required: ["note", "text"]),
            output: written, writes: true) { [unowned box] a in
            try box.writer.append(a, box: box)
        }

        let link = MCPTool(name: "add_link", title: "Link a note to an item",
            description: "Adds a Markdown link from a note to another item (a page, doc or note) under the note's \"## Related\" heading, the same way the browser's Add to research button does. Does nothing if the note already links there.",
            input: S.obj([
                "note": S.str("The note to add the link to: path, item id or title"),
                "target": S.str("The item to link to: item id, URL or note path"),
                "title": S.str("Link text. Defaults to the item's title."),
                "expected_version": S.str("The version read_note returned"),
            ], required: ["note", "target"]),
            output: written, writes: true) { [unowned box] a in
            try box.writer.link(a, box: box)
        }
        return [create, append, link]
    }

    // MARK: create_note

    func create(_ a: JSON) throws -> JSON {
        let ctx = context
        guard !ctx.mcp.isHidden(MCPSources.notes) else { throw ToolError(message: "The user hid their notes from AI clients.") }
        guard let title = MCPToolbox.str(a, "title") else { throw ToolError(message: "Pass a title.") }
        let text = (a["text"] as? String) ?? ""
        let folder = try targetFolder(MCPToolbox.str(a, "folder"))
        let base = Self.safeName(title)
        var url = folder.appendingPathComponent(base + ".md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n).md"); n += 1
        }
        guard FileSafety.canWriteNote(url, roots: ctx.notesRoots) else {
            throw ToolError(message: "That folder isn't inside the user's notes folders.")
        }
        var body = text.trimmingCharacters(in: .newlines)
        if !body.hasPrefix("# ") { body = "# \(title)\n\n" + body }
        if !body.hasSuffix("\n") { body += "\n" }
        let data = Data(body.utf8)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .withoutOverwriting)
        } catch {
            throw ToolError(message: "Couldn't create the note: \(error.localizedDescription)")
        }
        ctx.log("tool", "create_note", url.lastPathComponent, served: [])
        return ["path": url.path, "version": MCPToolbox.version(data), "cite": ctx.cite(title: title, url: url.absoluteString),
                "created": true, "changed": true,
                "message": "Created. The browser indexes it within a few seconds while it's running."]
    }

    /// The same file names the app's New note uses (`NotesStore.safeName`, which is main-actor bound).
    static func safeName(_ s: String) -> String {
        let cleaned = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = cleaned.hasPrefix(".") ? String(cleaned.drop(while: { $0 == "." })) : cleaned
        return trimmed.isEmpty ? "Untitled" : String(trimmed.prefix(120))
    }

    /// The folder new notes go in: the one asked for, else the current space's, else the app's default.
    func targetFolder(_ asked: String?) throws -> URL {
        let roots = context.notesRoots
        func inside(_ u: URL) -> Bool {
            roots.contains { FileSafety.isInside(u, $0) || $0.standardizedFileURL.path == u.standardizedFileURL.path }
        }
        if let asked {
            let expanded = (asked as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") {
                let u = URL(fileURLWithPath: expanded, isDirectory: true)
                guard inside(u), !u.pathComponents.contains(where: { FileSafety.isSkippedFolder($0) }) else {
                    throw ToolError(message: "That folder isn't inside the user's notes folders.")
                }
                return u
            }
            guard !asked.contains(".."), !asked.hasPrefix(".") else { throw ToolError(message: "Give a folder inside the notes folders.") }
            for r in roots {
                let u = r.appendingPathComponent(asked, isDirectory: true)
                if FileManager.default.fileExists(atPath: u.path) { return u }
            }
            return roots[0].appendingPathComponent(asked, isDirectory: true)
        }
        if let state = context.reader.savedState(), let sp = state.spaces?.first(where: { $0.id == state.currentSpace }) ?? state.spaces?.first,
           let p = sp.newNotesFolder {
            let u = URL(fileURLWithPath: p, isDirectory: true)
            if inside(u) { return u }
        }
        if let p = context.app.newNotesFolder {
            let u = URL(fileURLWithPath: p, isDirectory: true)
            if inside(u) { return u }
        }
        return roots[0]
    }

    // MARK: append_to_note and add_link

    func append(_ a: JSON, box: MCPToolbox) throws -> JSON {
        let ctx = context
        guard let text = a["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError(message: "Pass some text.")
        }
        let url = try box.noteURL(a, "note")
        let heading = MCPToolbox.str(a, "under_heading")
        let result = try edit(url, expected: MCPToolbox.str(a, "expected_version")) { old in
            Self.appending(text, to: old, under: heading)
        }
        ctx.log("tool", "append_to_note", url.lastPathComponent, served: [])
        return result
    }

    func link(_ a: JSON, box: MCPToolbox) throws -> JSON {
        let ctx = context
        let url = try box.noteURL(a, "note")
        guard let ref = MCPToolbox.str(a, "target") else { throw ToolError(message: "Pass target: an item id, URL or note path.") }
        var title = MCPToolbox.str(a, "title")
        var target: String
        if let it = ctx.reader.resolve(ref) {
            guard ctx.visible(it) else { throw ToolError(message: "That item is hidden from AI clients.") }
            target = it.url
            title = title ?? ctx.title(it)
        } else if let u = URL(string: ref), ["http", "https"].contains(u.scheme?.lowercased() ?? "") {
            guard ctx.privacy.urlDecision(u) == .allowed else { throw ToolError(message: "That URL looks private, so it won't be written into a note.") }
            target = u.absoluteString
        } else if ref.hasPrefix("/") || ref.hasPrefix("~") {
            target = URL(fileURLWithPath: (ref as NSString).expandingTildeInPath).standardizedFileURL.absoluteString
        } else {
            throw ToolError(message: "No item matches \"\(ref)\".")
        }
        let linkTitle = title ?? Snippet.prettyURL(target)
        let result = try edit(url, expected: MCPToolbox.str(a, "expected_version")) { old in
            Markdown.appendRelated(to: old, title: linkTitle, url: target)
        }
        ctx.log("tool", "add_link", "\(url.lastPathComponent) -> \(linkTitle)", served: [])
        return result
    }

    /// Text added at the end, or at the end of a heading's section.
    static func appending(_ add: String, to old: String, under heading: String?) -> String {
        let piece = add.trimmingCharacters(in: .newlines)
        guard let heading else {
            var out = old
            while out.hasSuffix("\n\n") { out.removeLast() }
            if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
            return out + (out.isEmpty ? "" : "\n") + piece + "\n"
        }
        let name = String(heading.drop(while: { $0 == "#" || $0 == " " }))
        let wanted = name.lowercased()
        var lines = old.components(separatedBy: "\n")
        var at: Int?
        var level = 0
        for (i, l) in lines.enumerated() {
            let t = l.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("#") else { continue }
            let hashes = t.prefix(while: { $0 == "#" }).count
            if t.dropFirst(hashes).trimmingCharacters(in: .whitespaces).lowercased() == wanted { at = i; level = hashes }
        }
        guard let h = at else {
            let base = appending("## \(name)", to: old, under: nil)
            return appending(piece, to: base, under: nil)
        }
        var end = lines.count
        for j in (h + 1)..<lines.count {
            let t = lines[j].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") && t.prefix(while: { $0 == "#" }).count <= level { end = j; break }
        }
        var k = end
        while k > h + 1 && lines[k - 1].trimmingCharacters(in: .whitespaces).isEmpty { k -= 1 }
        let insert = (k == h + 1 ? [""] : []) + piece.components(separatedBy: "\n") + (end < lines.count && k == end ? [""] : [])
        lines.insert(contentsOf: insert, at: k)
        var out = lines.joined(separator: "\n")
        if !out.hasSuffix("\n") { out += "\n" }
        return out
    }

    /// Reads, changes and writes a note, refusing if it changed since the assistant read it
    /// or while this ran. `change` returns nil when there's nothing to do.
    func edit(_ url: URL, expected: String?, change: (String) -> String?) throws -> JSON {
        let ctx = context
        guard FileSafety.canWriteNote(url, roots: ctx.notesRoots) else {
            throw ToolError(message: "Only .md notes inside the user's notes folders can be changed.")
        }
        guard let before = NotesScan.stat(url), let data = NotesScan.read(url) else {
            throw ToolError(message: "Couldn't read that note. It may have moved, or it's still downloading from iCloud.")
        }
        guard let old = String(data: data, encoding: .utf8) else {
            throw ToolError(message: "That note isn't UTF-8 text, so it won't be changed.")
        }
        let current = MCPToolbox.version(data)
        if let expected, expected != current {
            throw ToolError(message: "The note changed since you read it (version \(expected), now \(current)). Nothing was written. Read it again first.")
        }
        let title = Indexer.noteTitle(text: old, url: url)
        guard let new = change(old) else {
            return ["path": url.path, "version": current, "cite": ctx.cite(title: title, url: url.absoluteString),
                    "changed": false, "message": "Already there. Nothing written."]
        }
        let newData = Data(new.utf8)
        var coordError: NSError?
        var outcome: WriteError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { u in
            // Last check, right before the bytes go out.
            guard let now = NotesScan.stat(u), now.mtime == before.mtime, now.size == before.size else { outcome = .changed; return }
            do { try newData.write(to: u, options: .atomic) } catch { outcome = .failed(error.localizedDescription) }
        }
        if let coordError { throw ToolError(message: "Couldn't write the note: \(coordError.localizedDescription)") }
        switch outcome {
        case .changed:
            throw ToolError(message: "The note changed on disk while writing, so nothing was written. Read it again first.")
        case .failed(let m):
            throw ToolError(message: "Couldn't write the note: \(m)")
        case nil:
            return ["path": url.path, "version": MCPToolbox.version(newData), "cite": ctx.cite(title: title, url: url.absoluteString),
                    "changed": true, "message": "Written."]
        }
    }
}
