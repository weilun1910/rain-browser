import Foundation

/// Resources and prompts. Resources mirror the read tools, so a client that attaches context
/// with @-mentions (Claude Code) or resource pickers gets the same privacy rules.
enum MCPResources {
    static let templates: [JSON] = [
        ["uriTemplate": "browser://item/{id}", "name": "item", "title": "Item",
         "description": "One page, doc or note from the knowledge base, as Markdown with its details", "mimeType": "text/markdown"],
        ["uriTemplate": "browser://note/{+path}", "name": "note", "title": "Note",
         "description": "A note's current Markdown from disk, by its absolute path", "mimeType": "text/markdown"],
    ]

    static let fixed: [JSON] = [
        ["uri": "browser://overview", "name": "overview", "title": "Knowledge base overview",
         "description": "What's in the knowledge base and what AI clients can see", "mimeType": "application/json"],
        ["uri": "browser://context/current", "name": "current-context", "title": "What I'm working on now",
         "description": "The focused page or note, the space, open tabs and the Related cards on screen", "mimeType": "application/json"],
        ["uri": "browser://spaces", "name": "spaces", "title": "Spaces, pins and folders",
         "description": "How the browser's sidebar is organised", "mimeType": "application/json"],
    ]

    static let pageSize = 100

    static func list(_ ctx: MCPContext, cursor: String?) throws -> JSON {
        ctx.refresh()
        let offset: Int
        if let cursor {
            guard let d = Data(base64Encoded: cursor), let n = Int(String(decoding: d, as: UTF8.self)) else {
                throw RPCError.invalidParams("Invalid cursor")
            }
            offset = n
        } else {
            offset = 0
        }
        var all: [JSON] = fixed
        if !ctx.mcp.isHidden(MCPSources.notes) {
            var files: [NoteFile] = []
            for r in ctx.notesRoots { files.append(contentsOf: NotesScan.scan(r).allFiles) }
            files.sort { $0.mtime > $1.mtime }
            for f in files {
                let path = f.url.standardizedFileURL.path
                all.append(["uri": noteURI(path), "name": f.name, "title": f.name, "mimeType": "text/markdown",
                            "description": "Note, changed \(J.date(f.mtime))"])
            }
        }
        let page = Array(all.dropFirst(offset).prefix(pageSize))
        var out: JSON = ["resources": page]
        if offset + page.count < all.count { out["nextCursor"] = Data(String(offset + page.count).utf8).base64EncodedString() }
        return out
    }

    static func noteURI(_ path: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))
        return "browser://note" + (path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path)
    }

    static func notFound(_ ctx: MCPContext, _ uri: String) -> RPCError {
        // 2026-07-28 uses -32602; earlier versions used -32002.
        RPCError(code: ctx.modern ? -32602 : -32002, message: "Resource not found", data: ["uri": uri])
    }

    static func read(_ box: MCPToolbox, uri: String) throws -> JSON {
        let ctx = box.context
        ctx.refresh()
        func json(_ v: JSON) -> JSON { ["contents": [["uri": uri, "mimeType": "application/json", "text": J.string(v, pretty: true)]]] }
        func structured(_ tool: String, _ args: JSON = [:]) throws -> JSON {
            let r = try box.call(name: tool, arguments: args)
            if r["isError"] as? Bool == true { throw notFound(ctx, uri) }
            return r["structuredContent"] as? JSON ?? [:]
        }
        switch uri {
        case "browser://overview": return json(try structured("overview"))
        case "browser://context/current": return json(try structured("current_context"))
        case "browser://spaces": return json(try structured("list_spaces"))
        default: break
        }
        if uri.hasPrefix("browser://item/") {
            let id = String(uri.dropFirst("browser://item/".count))
            guard Int64(id) != nil, let it = ctx.reader.resolve(id), ctx.visible(it) else { throw notFound(ctx, uri) }
            let body = ctx.reader.body(id: it.id)
            var md = "# \(ctx.title(it))\n\n"
            md += "- Link: \(it.url)\n- Source: \(MCPSources.normalized(it.source))\n"
            md += "- Trust: \(MCPExternalText.trust(source: it.source))\n"
            if let p = it.project { md += "- Project: \(p)\n" }
            md += "- Last active: \(J.date(it.lastActive))\n\n"
            md += body.isEmpty ? (it.description.isEmpty ? "(Only the title and address are indexed.)" : it.description)
                : MCPExternalText.wrap(body, source: it.source, url: it.url)
            ctx.log("resource", "item", ctx.title(it), served: [ctx.title(it)])
            return ["contents": [["uri": uri, "mimeType": "text/markdown", "text": md]]]
        }
        if uri.hasPrefix("browser://note/") {
            let raw = String(uri.dropFirst("browser://note".count))
            let path = raw.removingPercentEncoding ?? raw
            let url: URL
            do { url = try box.noteURL(["note": path], "note") } catch { throw notFound(ctx, uri) }
            guard let data = NotesScan.read(url) else { throw notFound(ctx, uri) }
            ctx.log("resource", "note", url.lastPathComponent, served: [url.deletingPathExtension().lastPathComponent])
            return ["contents": [["uri": uri, "mimeType": "text/markdown", "text": NotesScan.decode(data)]]]
        }
        throw notFound(ctx, uri)
    }

    // MARK: Prompts

    static let prompts: [JSON] = [
        ["name": "what_do_i_know", "title": "What do I know about...",
         "description": "Pulls together everything the user has read and written about a topic, with citations",
         "arguments": [["name": "topic", "description": "The topic, person, project or question", "required": true]]],
        ["name": "catch_me_up", "title": "Catch me up",
         "description": "What the user is working on now and what they've been doing lately"],
        ["name": "tidy_my_notes", "title": "Tidy my notes",
         "description": "Finds notes that should link to each other, duplicates and loose ends, and proposes changes",
         "arguments": [["name": "topic", "description": "Limit it to a topic or project", "required": false]]],
    ]

    static func prompt(name: String, arguments: JSON, context ctx: MCPContext) throws -> JSON {
        ctx.refresh()
        let text: String
        let description: String
        switch name {
        case "what_do_i_know":
            guard let topic = (arguments["topic"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !topic.isEmpty else {
                throw RPCError.invalidParams("Missing required argument: topic")
            }
            description = "What I know about \(topic)"
            text = """
            What do I know about \(topic)?

            Use my Browser knowledge base to answer:
            1. search for it, and try related with the topic as text to catch items that use other words.
            2. Read the most relevant items with get_item (notes with read_note), and check connections on the best one or two.
            3. Write a short summary of what I know, what I concluded, and what I read, in plain sentences.
            4. Cite every item you use with its cite link. Mark which points come from my own notes and which from pages I read.
            5. End with gaps or contradictions you noticed, and one or two things worth reading again.
            """
        case "catch_me_up":
            description = "Catch me up"
            text = """
            Catch me up on what I'm doing.

            Use my Browser knowledge base: call current_context for what I have open now, then recent_activity for the last few days. \
            Group what you find into the two or three threads I seem to be working on, say where each one stands, and list what I \
            opened but probably haven't finished. Cite items with their cite links. Keep it short.
            """
        case "tidy_my_notes":
            let topic = (arguments["topic"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            description = topic.isEmpty ? "Tidy my notes" : "Tidy my notes on \(topic)"
            text = """
            Help me keep my notes in good shape\(topic.isEmpty ? "" : " for \(topic)").

            Use my Browser knowledge base. Find notes \(topic.isEmpty ? "I changed recently (list_notes, recent_activity)" : "about this (search, list_notes)"), \
            then use connections and related to spot:
            - notes that should link to each other but don't,
            - pages I read that belong in a note's Related list,
            - near-duplicate notes, and loose ends like unanswered questions or TODOs.
            Propose the changes as a short list first. Only write after I say yes, and only with the maintenance tools \
            (add_link, append_to_note, create_note) if they're available. Keep my wording, add rather than rewrite, and if a write is \
            refused because a note changed, read it again before trying anything else.
            """
        default:
            throw RPCError.invalidParams("Unknown prompt: \(name)")
        }
        ctx.log("prompt", name, (arguments["topic"] as? String) ?? "", served: [])
        return ["description": description, "messages": [["role": "user", "content": ["type": "text", "text": text]]]]
    }
}
