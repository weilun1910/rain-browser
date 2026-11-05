import AppKit
import SwiftUI

/// The MCP server: spawns `--mcp --data-dir` on a fixture profile and drives a legacy and a
/// modern session through every tool, resource and prompt. Also checks the privacy switches,
/// the served log, the disk rules for the maintenance tools, and the pieces that run in the app.
enum MCPTests {
    static func check(_ ok: Bool, _ label: String, _ detail: String = "") { SelfTest.check(ok, "mcp: " + label, detail) }

    static func run(dir: URL) {
        unitTests()
        contextWriterTest(dir: dir)
        guard let bin = Bundle.main.executablePath else { check(false, "binary path"); return }
        let root = dir.appendingPathComponent("mcp-profile", isDirectory: true)
        let fx: MCPFixture.Built
        do { fx = try MCPFixture.build(at: root, pid: getpid()) } catch { check(false, "fixture profile", "\(error)"); return }
        legacySession(bin: bin, fx: fx)
        modernSession(bin: bin, fx: fx)
        launcherSession(bin: bin, fx: fx)
        copyCleanup(bin: bin, fx: fx)
        privacySession(bin: bin, fx: fx)
        writeSession(bin: bin, fx: fx)
        check(!FileManager.default.fileExists(atPath: fx.root.appendingPathComponent("index.sqlite-journal").path), "index was only read")
    }

    // MARK: A tiny MCP client

    final class Client {
        let process = Process()
        private let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        private var buffer = Data()
        private var lines: [Data] = []
        private let lock = NSLock()
        private let ready = DispatchSemaphore(value: 0)
        private var nextID = 0
        var modern = false
        var clientName = "selftest"

        convenience init(bin: String, root: URL) throws {
            try self.init(executable: bin, arguments: ["--mcp", "--data-dir", root.path])
        }

        init(executable: String, arguments: [String], environment: [String: String]? = nil) throws {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let environment { process.environment = environment }
            process.standardInput = inPipe
            process.standardOutput = outPipe
            process.standardError = errPipe
            outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
                let d = h.availableData
                guard let self, !d.isEmpty else { return }
                self.lock.lock()
                self.buffer.append(d)
                while let nl = self.buffer.firstIndex(of: 0x0A) {
                    self.lines.append(self.buffer[self.buffer.startIndex..<nl])
                    self.buffer.removeSubrange(self.buffer.startIndex...nl)
                    self.ready.signal()
                }
                self.lock.unlock()
            }
            errPipe.fileHandleForReading.readabilityHandler = { h in _ = h.availableData }
            try process.run()
        }

        var meta: JSON {
            [MCPProtocol.metaVersion: MCPProtocol.modern, MCPProtocol.metaCapabilities: [:] as JSON,
             MCPProtocol.metaClientInfo: ["name": clientName, "version": "1"] as JSON]
        }

        func write(_ obj: JSON) {
            var d = try! JSONSerialization.data(withJSONObject: obj)
            d.append(0x0A)
            inPipe.fileHandleForWriting.write(d)
        }

        /// Sends a request and waits for its reply. Returns the whole reply object.
        @discardableResult
        func request(_ method: String, _ params: JSON = [:], meta extra: JSON? = nil, timeout: Double = 60) -> JSON {
            nextID += 1
            var p = params
            if let extra { p["_meta"] = extra } else if modern { p["_meta"] = meta }
            write(["jsonrpc": "2.0", "id": nextID, "method": method, "params": p])
            guard ready.wait(timeout: .now() + timeout) == .success else { return ["error": ["message": "timeout"]] }
            lock.lock()
            let line = lines.removeFirst()
            lock.unlock()
            return (try? JSONSerialization.jsonObject(with: line)) as? JSON ?? ["error": ["message": "bad json"]]
        }

        func result(_ method: String, _ params: JSON = [:]) -> JSON { request(method, params)["result"] as? JSON ?? [:] }

        /// A tools/call. Returns (structuredContent, isError, text).
        func tool(_ name: String, _ args: JSON = [:]) -> (JSON, Bool, String) {
            let r = result("tools/call", ["name": name, "arguments": args])
            let text = ((r["content"] as? [JSON])?.first?["text"] as? String) ?? ""
            return (r["structuredContent"] as? JSON ?? [:], r["isError"] as? Bool ?? true, text)
        }

        func notify(_ method: String) { write(["jsonrpc": "2.0", "method": method]) }

        func close() {
            try? inPipe.fileHandleForWriting.close()
            let deadline = Date().addingTimeInterval(10)
            while process.isRunning && Date() < deadline { usleep(50_000) }
            if process.isRunning { process.terminate() }
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
        }
    }

    static func titles(_ v: Any?) -> [String] { (v as? [JSON] ?? []).compactMap { $0["title"] as? String } }
    static func setSettings(_ fx: MCPFixture.Built, _ change: (inout MCPSettings) -> Void) {
        var s = MCPSettings.load(root: fx.root)
        change(&s)
        s.save(root: fx.root)
    }

    // MARK: Legacy session, every tool

    static func legacySession(bin: String, fx: MCPFixture.Built) {
        guard let c = try? Client(bin: bin, root: fx.root) else { check(false, "server starts"); return }
        defer { c.close() }
        let ini = c.result("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:] as JSON,
                                          "clientInfo": ["name": "selftest", "version": "1"] as JSON])
        check(ini["protocolVersion"] as? String == "2025-06-18", "initialize echoes a supported version")
        let info = ini["serverInfo"] as? JSON
        let instructions = ini["instructions"] as? String ?? ""
        check(info?["name"] as? String == "browser-poc-knowledge" && instructions.count < 4096
              && String(instructions.prefix(512)).contains("search"), "server info and instructions fit the client limits")
        check((ini["capabilities"] as? JSON)?.keys.sorted() == ["prompts", "resources", "tools"], "advertises tools, resources and prompts")
        c.notify("notifications/initialized")
        let other = c.result("initialize", ["protocolVersion": "1999-01-01", "capabilities": [:] as JSON])
        check(other["protocolVersion"] as? String == "2025-11-25", "an unknown version gets the latest legacy one")
        check(c.request("ping")["result"] != nil, "ping")

        let tools = c.result("tools/list")["tools"] as? [JSON] ?? []
        let names = tools.compactMap { $0["name"] as? String }
        check(names == ["overview", "search", "get_item", "related", "connections", "current_context", "recent_activity",
                        "list_spaces", "list_notes", "read_note"], "ten read tools, in a fixed order, no write tools", names.joined(separator: ","))
        check(tools.allSatisfy { t in
            let a = t["annotations"] as? JSON ?? [:]
            return a["readOnlyHint"] as? Bool == true && a["openWorldHint"] as? Bool == false
                && (t["inputSchema"] as? JSON)?["type"] as? String == "object" && (t["outputSchema"] as? JSON)?["type"] as? String == "object"
                && !((t["description"] as? String) ?? "").isEmpty
        }, "every read tool is read-only, closed-world and has input and output schemas")

        // overview
        let (ov, ovErr, ovText) = c.tool("overview")
        let sources = ov["sources"] as? [JSON] ?? []
        check(!ovErr && sources.first { $0["id"] as? String == "note" }?["items"] as? Int == 4
              && sources.first { $0["id"] as? String == "searches" }?["visible"] as? Bool == false
              && ov["maintenance_tools"] as? Bool == false && ov["app_running"] as? Bool == true, "overview")
        let mirrored = (try? JSONSerialization.jsonObject(with: Data(ovText.utf8))) as? JSON
        check(mirrored.map { NSDictionary(dictionary: $0).isEqual(to: ov) } ?? false, "text content mirrors structured content")

        // search
        let (s1, s1Err, _) = c.tool("search", ["query": "sourdough starter"])
        let s1Titles = titles(s1["results"])
        check(!s1Err && s1Titles.contains("How to feed and maintain a sourdough starter") && s1Titles.contains("Sourdough plan"),
              "search finds pages and notes", s1Titles.joined(separator: "; "))
        // With the reranker, those two drop out as unrelated before the privacy filter counts them.
        check(!s1Titles.contains("Sign in to Example") && !s1Titles.contains("Chase checking account")
              && (s1["hidden"] as? Int ?? 0) >= (Intelligence.shared.hasReranker ? 0 : 2),
              "search leaves out sign-in links and excluded sites", "hidden \(s1["hidden"] ?? "?")")
        check((s1["results"] as? [JSON] ?? []).allSatisfy { ($0["cite"] as? String)?.hasPrefix("[") == true && $0["id"] is Int },
              "search results carry an id and a cite link")
        let snippets = (s1["results"] as? [JSON] ?? []).compactMap { $0["snippet"] as? String }
        check(!snippets.isEmpty && !snippets.contains { $0.hasPrefix("#") }, "snippets don't start with the note's heading",
              snippets.map { String($0.prefix(40)) }.joined(separator: " | "))
        let s2 = titles(c.tool("search", ["query": "sourdough", "sources": ["note"]]).0["results"])
        check(!s2.isEmpty && s2.allSatisfy { ["Sourdough plan", "Bread bake log"].contains($0) }, "search filters by source", s2.joined(separator: "; "))
        let s3 = titles(c.tool("search", ["query": "plan", "kind": "doc"]).0["results"])
        check(s3.contains("Bread pop-up plan") && !s3.contains("Sourdough plan"), "search filters by kind", s3.joined(separator: "; "))
        check(c.tool("search", [:]).1, "search without a query is a tool error, not a crash")

        // The Engine's search and sources.
        func source(_ id: String) -> JSON? { sources.first { $0["id"] as? String == id } }
        check(source("granola")?["items"] as? Int == 1 && source("granola")?["label"] as? String == "Granola meetings"
              && source("gdocs")?["items"] as? Int == 2 && source("notion")?["items"] as? Int == 2 && ov["search_by"] as? String == "engine",
              "overview counts the Notion, Google Docs and Granola switches",
              ["gdocs", "notion", "granola"].map { "\($0)=\(source($0)?["items"] ?? "?")" }.joined(separator: " "))
        check(s1["ranked_by"] as? String == "engine" && (s1["results"] as? [JSON] ?? []).contains { !(($0["history"] as? String) ?? "").isEmpty },
              "search runs the Engine's hybrid search and says when each item was seen")
        let meet = c.tool("search", ["query": "Meera loaves", "sources": ["granola"]]).0["results"] as? [JSON] ?? []
        check(titles(meet) == ["Call with Meera about the market pop-up"] && meet.first?["kind"] as? String == "meeting",
              "search filters to Granola meetings", titles(meet).joined(separator: "; "))
        let gd = titles(c.tool("search", ["query": "starter feeding schedule pop-up plan", "sources": ["gdocs"]]).0["results"])
        check(Set(gd) == ["Starter feeding schedule", "Bread pop-up plan"], "the Google Docs filter covers synced docs and docs read in the browser",
              gd.joined(separator: "; "))

        // get_item
        let (g1, g1Err, _) = c.tool("get_item", ["item": fx.googleDoc + "/edit"])
        check(!g1Err && (g1["text"] as? String ?? "").contains("Meera") && titles(g1["names"]).isEmpty
              && ((g1["names"] as? [JSON]) ?? []).contains { $0["name"] as? String == "Meera" }
              && (g1["item"] as? JSON)?["section"] as? String == "docs", "get_item by URL with text, names and section")
        let (g2, _, _) = c.tool("get_item", ["item": fx.sourdough.path])
        let links = g2["links"] as? [JSON] ?? []
        check(links.contains { $0["text"] as? String == "Bread bake log" && $0["id"] is Int }
              && links.contains { ($0["url"] as? String ?? "").contains("kingarthur") && $0["in_related_list"] as? Bool == true },
              "get_item resolves wikilinks and Related links", links.map { "\($0["text"] ?? "")" }.joined(separator: "; "))
        let (g3, _, _) = c.tool("get_item", ["item": "Bread bake log", "max_chars": 200, "include_passages": true])
        check(g3["next_offset"] as? Int == 200 && !(g3["passages"] as? [JSON] ?? []).isEmpty, "get_item pages long text and returns passages")
        check(c.tool("get_item", ["item": fx.privatePage]).1 && c.tool("get_item", ["item": fx.excludedPage]).1,
              "get_item refuses hidden items")
        check(c.tool("get_item", ["item": "999999"]).1, "get_item with an unknown id is a tool error")
        let (g4, _, _) = c.tool("get_item", ["item": "How to feed and maintain a sourdough starter"])
        check(!(g4["topics"] as? [String] ?? []).isEmpty && ((g4["history"] as? String) ?? "").hasPrefix("You "),
              "get_item adds the item's topics and when it was seen", "\(g4["topics"] ?? "") | \(g4["history"] ?? "")")

        // related
        let (r1, r1Err, _) = c.tool("related", ["item": "Sourdough plan"])
        let r1Sites = titles(r1["sites"]), r1Docs = titles(r1["docs"])
        check(!r1Err && r1Sites.contains("How to feed and maintain a sourdough starter") && (r1Docs.contains("Bread bake log") || r1Docs.contains("Bread pop-up plan")),
              "related uses the panel's ranking for an item", "sites \(r1Sites) docs \(r1Docs)")
        check(!(r1Sites + r1Docs).contains("Sourdough plan") && !(r1Sites + r1Docs).contains("Chase checking account"),
              "related leaves out the item itself and hidden items")
        check(((r1["sites"] as? [JSON])?.first?["reason"] as? String ?? "").count > 10, "related gives a reason line")
        let ranking = r1["ranking"] as? JSON
        check(ranking?["bar"] is NSNumber && ranking?["reranker"] as? Bool == Intelligence.shared.hasReranker
              && ((r1["sites"] as? [JSON])?.first?["found_by"] as? [String] ?? []).count > 0,
              "related reports the panel's bar, the reranker and which searches found each item", "\(ranking ?? [:])")
        let r2 = titles(c.tool("related", ["text": "Marathon training: tempo runs, long slow distance and a two week taper before race day."]).0["sites"])
        check(r2.contains("A 16 week marathon training plan for beginners"), "related works for free text", r2.joined(separator: "; "))

        // connections
        let (cn, cnErr, _) = c.tool("connections", ["item": "Sourdough plan"])
        let edges = cn["edges"] as? [JSON] ?? []
        let nodesByID = Dictionary((cn["nodes"] as? [JSON] ?? []).compactMap { n -> (Int, String)? in
            guard let id = n["id"] as? Int, let t = n["title"] as? String else { return nil }
            return (id, t)
        }, uniquingKeysWith: { a, _ in a })
        func has(_ type: String, _ title: String) -> Bool {
            edges.contains { $0["type"] as? String == type && nodesByID[$0["to"] as? Int ?? -1] == title }
        }
        check(!cnErr && has("link", "Bread bake log") && has("research", "How to feed and maintain a sourdough starter") && has("similar", "Bread pop-up plan"),
              "connections has link, research and similar edges with reasons", edges.map { "\($0["type"] ?? "")" }.joined(separator: ","))
        check(edges.allSatisfy { !(($0["why"] as? String) ?? "").isEmpty } && cn["source"] as? String == "index", "every edge says why")
        let back = c.tool("connections", ["item": "Bread bake log", "types": ["link"]]).0
        check((back["edges"] as? [JSON] ?? []).contains { $0["type"] as? String == "link" && $0["to"] as? Int == (back["center"] as? JSON)?["id"] as? Int },
              "connections finds notes that link here")
        let met = c.tool("connections", ["item": "Call with Meera about the market pop-up", "types": ["topic"]]).0
        let metNodes = Dictionary(((met["nodes"] as? [JSON]) ?? []).compactMap { n -> (Int, String)? in
            guard let id = n["id"] as? Int, let t = n["title"] as? String else { return nil }
            return (id, t)
        }, uniquingKeysWith: { a, _ in a })
        check(((met["edges"] as? [JSON]) ?? []).contains { ($0["why"] as? String ?? "").contains("Meera")
                && ["Bread pop-up plan", "Pop-up stall checklist"].contains(metNodes[$0["to"] as? Int ?? -1] ?? "") },
              "connections links a meeting to docs that name the same person",
              ((met["edges"] as? [JSON]) ?? []).map { "\($0["why"] ?? "")" }.joined(separator: "; "))
        let deep = c.tool("connections", ["item": "MCP ideas", "depth": 2]).0
        check(((deep["nodes"] as? [JSON]) ?? []).contains { $0["depth"] as? Int == 2 } || !((deep["edges"] as? [JSON]) ?? []).isEmpty,
              "connections at depth 2")

        // current_context
        let (cc, ccErr, _) = c.tool("current_context")
        let focused = cc["focused"] as? JSON
        check(!ccErr && focused?["title"] as? String == "Sourdough plan" && (focused?["excerpt"] as? String ?? "").contains("rye")
              && (cc["split_with"] as? JSON)?["title"] as? String == "How to feed and maintain a sourdough starter"
              && cc["app_running"] as? Bool == true && (cc["space"] as? JSON)?["name"] as? String == "Baking",
              "current_context shows the focused note, the split and the space")
        check(!titles(cc["open_tabs"]).contains("Chase") && !titles(cc["recently_focused"]).contains("Chase")
              && titles(cc["related_on_screen"]).contains("Bread bake log"), "current_context filters hidden tabs")

        // recent_activity
        let (ra, raErr, _) = c.tool("recent_activity", ["days": 3])
        let raTitles = titles(ra["items"])
        check(!raErr && raTitles.contains("How to feed and maintain a sourdough starter") && raTitles.contains("Sourdough plan")
              && !raTitles.contains("Chase checking account") && !raTitles.contains("A 16 week marathon training plan for beginners"),
              "recent_activity covers the last days only, without hidden items", raTitles.joined(separator: "; "))
        check(ra["searches"] is NSNull && ra["searches_hidden"] as? Bool == true, "past searches stay hidden by default")

        // list_spaces
        let (sp, spErr, _) = c.tool("list_spaces")
        let spaces = sp["spaces"] as? [JSON] ?? []
        let home = spaces.first { $0["name"] as? String == "Home" }
        let baking = spaces.first { $0["name"] as? String == "Baking" }
        check(!spErr && spaces.count == 2 && sp["current_space"] as? String == "Baking"
              && titles((home?["folders"] as? [JSON])?.first?["items"]) == ["WKWebExtension", "Browser engine notes"]
              && titles(home?["pinned"]) == ["Nook ExtensionManager"] && (baking?["splits"] as? [JSON])?.count == 1,
              "list_spaces returns pins, folders, tabs and splits")
        check(!titles(baking?["open_tabs"]).contains("Chase") && (sp["hidden"] as? Int ?? 0) >= 1, "list_spaces hides excluded tabs")

        // list_notes and read_note
        let (ln, lnErr, _) = c.tool("list_notes")
        let lnPaths = (ln["notes"] as? [JSON] ?? []).compactMap { $0["path"] as? String }
        check(!lnErr && ln["total"] as? Int == 4 && !lnPaths.contains { $0.contains(".hidden") }, "list_notes skips hidden folders")
        let page1 = c.tool("list_notes", ["limit": 3, "sort": "name"]).0
        let cursor = page1["next_cursor"] as? String
        let page2 = cursor.map { c.tool("list_notes", ["limit": 3, "sort": "name", "cursor": $0]).0 }
        check((page1["notes"] as? [JSON])?.count == 3 && (page2?["notes"] as? [JSON])?.count == 1, "list_notes pages with a cursor")
        check(titles(c.tool("list_notes", ["project": "Browser"]).0["notes"]).sorted() == ["Browser engine notes", "MCP ideas"], "list_notes filters by project")
        let (rn, rnErr, _) = c.tool("read_note", ["note": "Bread bake log"])
        check(!rnErr && (rn["text"] as? String ?? "").contains("Saturday loaf") && (rn["version"] as? String)?.count == 16, "read_note returns the text and a version")
        check(c.tool("read_note", ["note": fx.outside.path]).1, "read_note refuses files outside the notes folders")
        check(c.tool("read_note", ["note": fx.hiddenNote.path]).1, "read_note refuses notes in hidden folders")
        check(c.tool("read_note", ["note": "/etc/hosts"]).1, "read_note refuses system files")
        check(c.tool("create_note", ["title": "x"]).1, "maintenance tools refuse while they're off")

        // resources and prompts
        let res = c.result("resources/list")["resources"] as? [JSON] ?? []
        let uris = res.compactMap { $0["uri"] as? String }
        check(uris.contains("browser://overview") && uris.contains("browser://context/current") && uris.filter { $0.hasPrefix("browser://note/") }.count == 4,
              "resources/list has the fixed resources and the notes")
        if let noteURI = uris.first(where: { $0.contains("Bread") }) {
            let txt = ((c.result("resources/read", ["uri": noteURI])["contents"] as? [JSON])?.first?["text"] as? String) ?? ""
            check(txt.contains("Saturday loaf"), "resources/read reads a note")
        }
        let itemID = (s1["results"] as? [JSON])?.first?["id"] as? Int ?? 0
        let itemText = ((c.result("resources/read", ["uri": "browser://item/\(itemID)"])["contents"] as? [JSON])?.first?["text"] as? String) ?? ""
        check(itemText.hasPrefix("# "), "resources/read reads an item as Markdown")
        let ccRes = ((c.result("resources/read", ["uri": "browser://context/current"])["contents"] as? [JSON])?.first?["text"] as? String) ?? ""
        check(ccRes.contains("Sourdough plan"), "resources/read serves the current context")
        let missing = c.request("resources/read", ["uri": "browser://item/999999"])["error"] as? JSON
        check(missing?["code"] as? Int == -32002, "a missing resource is -32002 in the legacy era")
        check(((c.result("resources/templates/list")["resourceTemplates"] as? [JSON]) ?? []).count == 2, "resource templates")
        let prompts = (c.result("prompts/list")["prompts"] as? [JSON] ?? []).compactMap { $0["name"] as? String }
        check(prompts == ["what_do_i_know", "catch_me_up", "tidy_my_notes"], "prompts/list")
        let pg = c.result("prompts/get", ["name": "what_do_i_know", "arguments": ["topic": "sourdough"]])
        let pgText = (((pg["messages"] as? [JSON])?.first?["content"] as? JSON)?["text"] as? String) ?? ""
        check(pgText.contains("sourdough") && pgText.contains("search"), "prompts/get fills in the topic")
        check((c.request("prompts/get", ["name": "what_do_i_know"])["error"] as? JSON)?["code"] as? Int == -32602, "a missing prompt argument is -32602")
        check((c.request("tools/call", ["name": "nope"])["error"] as? JSON)?["code"] as? Int == -32602, "an unknown tool is -32602")
        check((c.request("bogus/method")["error"] as? JSON)?["code"] as? Int == -32601, "an unknown method is -32601")

        let log = MCPLog.read(root: fx.root)
        check(log.contains { $0.name == "search" && $0.client == "selftest" && $0.served > 0 && $0.detail == "sourdough starter" }
              && log.contains { $0.name == "related" && $0.hidden >= 0 }, "the served log records client, tool, query and titles")
    }

    // MARK: Modern session (2026-07-28)

    static func modernSession(bin: String, fx: MCPFixture.Built) {
        guard let c = try? Client(bin: bin, root: fx.root) else { check(false, "modern server starts"); return }
        defer { c.close() }
        c.modern = true
        c.clientName = "selftest-modern"
        let d = c.result("server/discover")
        check(d["resultType"] as? String == "complete" && (d["supportedVersions"] as? [String])?.contains("2026-07-28") == true
              && d["ttlMs"] is Int && d["cacheScope"] as? String == "private"
              && ((d["_meta"] as? JSON)?[MCPProtocol.metaServerInfo] as? JSON)?["name"] as? String == "browser-poc-knowledge",
              "server/discover answers the modern way")
        let tl = c.result("tools/list")
        check(tl["resultType"] as? String == "complete" && tl["ttlMs"] is Int && (tl["tools"] as? [JSON])?.count == 10, "tools/list carries resultType and cache fields")
        let call = c.result("tools/call", ["name": "search", "arguments": ["query": "WebKit extensions"]])
        check(call["resultType"] as? String == "complete" && call["isError"] as? Bool == false
              && titles((call["structuredContent"] as? JSON)?["results"]).contains { $0.contains("WKWebExtension") || $0.contains("Nook") },
              "a modern tools/call works without initialize")
        let bad = c.request("tools/list", meta: [MCPProtocol.metaVersion: "1999-01-01", MCPProtocol.metaCapabilities: [:] as JSON])["error"] as? JSON
        check(bad?["code"] as? Int == -32022 && ((bad?["data"] as? JSON)?["supported"] as? [String])?.contains("2026-07-28") == true,
              "an unsupported version is -32022 with the supported list")
        let noCaps = c.request("tools/list", meta: [MCPProtocol.metaVersion: "2026-07-28"])["error"] as? JSON
        check(noCaps?["code"] as? Int == -32602, "missing client capabilities is -32602")
        check((c.request("resources/read", ["uri": "browser://item/999999"])["error"] as? JSON)?["code"] as? Int == -32602,
              "a missing resource is -32602 in the modern era")
        let rl = c.result("resources/list")
        check(rl["ttlMs"] is Int && rl["cacheScope"] as? String == "private", "resources/list carries cache fields")

        // The app keeps writing while the server runs. Play the app: write a page with a second connection.
        if let writer = try? IndexStore(url: fx.root.appendingPathComponent("index.sqlite")) {
            let text = "Zebra crossings slow traffic near schools. Painted stripes and a beacon."
            let now = Date().timeIntervalSince1970
            writer.recordCapture(DocUpsert(key: "https://example.org/zebra-crossings", source: .web, url: "https://example.org/zebra-crossings",
                                           title: "Zebra crossings", body: text, firstSeen: now, lastSeen: now),
                                 analysis: TextAnalysis.analyze(title: "Zebra crossings", description: "", text: text))
        }
        let fresh = titles((c.result("tools/call", ["name": "search", "arguments": ["query": "zebra crossings"]])["structuredContent"] as? JSON)?["results"])
        check(fresh == ["Zebra crossings"], "the server sees pages the app indexes while it runs", fresh.joined(separator: "; "))
        check(MCPLog.read(root: fx.root).contains { $0.client == "selftest-modern" && $0.protocolVersion == "2026-07-28" },
              "the log takes the client name and version from _meta")
    }

    // MARK: The private copy of the index

    /// The ranking copy goes when a client ends the server with a signal, and copies left by a
    /// killed server are swept when the next one starts.
    static func copyCleanup(bin: String, fx: MCPFixture.Built) {
        let stale = FileManager.default.temporaryDirectory.appendingPathComponent(RankingSnapshot.prefix + "99999999")
        try? FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        guard let c = try? Client(bin: bin, root: fx.root) else { check(false, "cleanup server starts"); return }
        _ = c.result("initialize", ["protocolVersion": "2025-11-25", "capabilities": [:] as JSON])
        _ = c.tool("related", ["item": "Sourdough plan"])
        let copy = RankingSnapshot.directory(pid: c.process.processIdentifier)
        let made = FileManager.default.fileExists(atPath: copy.path)
        check(made && !FileManager.default.fileExists(atPath: stale.path), "a killed server's copy is swept at the next start")
        c.process.terminate()
        c.process.waitUntilExit()
        c.close()
        check(made && !FileManager.default.fileExists(atPath: copy.path), "SIGTERM removes the server's copy of the index")
    }

    // MARK: The packaged launcher

    /// The launcher every package ships finds the app from BROWSER_POC_APP, and without it from
    /// the path the app noted in the profile's current-context.json.
    static func launcherSession(bin: String, fx: MCPFixture.Built) {
        guard let dir = MCPInstall.integrationsFolder() else { return }
        let launcher = dir.appendingPathComponent("launcher/browser-mcp").path
        let base = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        for (label, extra) in [("from BROWSER_POC_APP", ["BROWSER_POC_APP": bin, "BROWSER_POC_DATA_DIR": fx.root.path]),
                               ("from the path the app noted", ["BROWSER_POC_DATA_DIR": fx.root.path])] {
            guard let c = try? Client(executable: launcher, arguments: [], environment: base.merging(extra) { $1 }) else {
                check(false, "launcher starts \(label)"); continue
            }
            let ini = c.result("initialize", ["protocolVersion": "2025-11-25", "capabilities": [:] as JSON])
            let ov = c.tool("overview").0
            check(ini["protocolVersion"] as? String == "2025-11-25" && ov["data_folder"] as? String == fx.root.path,
                  "the launcher finds the app \(label) and keeps the profile")
            c.close()
        }
    }

    // MARK: Privacy switches

    static func privacySession(bin: String, fx: MCPFixture.Built) {
        guard let c = try? Client(bin: bin, root: fx.root) else { check(false, "privacy server starts"); return }
        defer {
            c.close()
            MCPSettings().save(root: fx.root)
        }
        _ = c.result("initialize", ["protocolVersion": "2025-11-25", "capabilities": [:] as JSON])
        setSettings(fx) { $0.hiddenSources = [MCPSources.searches, MCPSources.notes] }
        let s = c.tool("search", ["query": "sourdough"]).0
        check(!(s["results"] as? [JSON] ?? []).contains { $0["source"] as? String == "note" }, "hiding notes takes them out of search")
        check(c.tool("list_notes").1 && c.tool("read_note", ["note": fx.breadLog.path]).1, "hiding notes blocks list_notes and read_note")
        check(!titles(c.tool("current_context").0["open_tabs"]).contains("Sourdough plan"), "hiding notes takes note tabs out of the current context")

        setSettings(fx) { $0.hiddenSources = [MCPSources.searches, MCPSources.gdocs] }
        let docs = titles(c.tool("search", ["query": "pop-up plan loaves starter feeding schedule"]).0["results"])
        check(!docs.contains("Bread pop-up plan") && !docs.contains("Starter feeding schedule") && docs.contains("Pop-up stall checklist"),
              "hiding Google Docs takes out synced docs and docs read in the browser, and leaves Notion", docs.joined(separator: "; "))
        check(!titles(c.tool("related", ["item": "Sourdough plan"]).0["docs"]).contains("Bread pop-up plan"), "hidden docs stay out of related")

        setSettings(fx) { $0.hiddenSources = [MCPSources.searches, MCPSources.notion, MCPSources.granola] }
        let rest = titles(c.tool("search", ["query": "Meera market pop-up"]).0["results"])
        check(!rest.contains("Pop-up stall checklist") && !rest.contains("Call with Meera about the market pop-up") && rest.contains("Bread pop-up plan"),
              "the Notion and Granola switches hide their items", rest.joined(separator: "; "))
        check(c.tool("get_item", ["item": "Call with Meera about the market pop-up"]).1, "a hidden meeting can't be read")

        setSettings(fx) { $0.hiddenSources = []; $0.shareCurrentContext = false }
        check(c.tool("current_context").0["shared"] as? Bool == false, "turning off the current context hides it")
        let ra = c.tool("recent_activity").0
        check((ra["searches"] as? [JSON] ?? []).contains { $0["query"] as? String == "sourdough hydration" }, "past searches show once allowed")
        check(c.tool("overview").0["current_context_shared"] as? Bool == false, "overview reports the switches")

        setSettings(fx) { $0.keepLog = false }
        let before = MCPLog.read(root: fx.root, limit: 100000).count
        _ = c.tool("search", ["query": "webkit"])
        check(MCPLog.read(root: fx.root, limit: 100000).count == before, "turning off the log stops it")
    }

    // MARK: Maintenance tools and disk rules

    static func writeSession(bin: String, fx: MCPFixture.Built) {
        guard let c = try? Client(bin: bin, root: fx.root) else { check(false, "write server starts"); return }
        defer {
            c.close()
            MCPSettings().save(root: fx.root)
        }
        _ = c.result("initialize", ["protocolVersion": "2025-11-25", "capabilities": [:] as JSON])
        setSettings(fx) { $0.allowWrites = true }
        let tools = c.result("tools/list")["tools"] as? [JSON] ?? []
        let writes = tools.filter { ["create_note", "append_to_note", "add_link"].contains($0["name"] as? String ?? "") }
        check(writes.count == 3 && writes.allSatisfy {
            let a = $0["annotations"] as? JSON ?? [:]
            return a["readOnlyHint"] as? Bool == false && a["destructiveHint"] as? Bool == false
        }, "maintenance tools appear when allowed, marked as non-destructive writes")

        let (cr, crErr, crText) = c.tool("create_note", ["title": "MCP test note", "text": "First line."])
        let path = cr["path"] as? String ?? ""
        let created = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        check(!crErr && path.hasPrefix(fx.notes.path) && created.hasPrefix("# MCP test note\n\nFirst line."), "create_note writes into the space's notes folder", crText)
        let again = c.tool("create_note", ["title": "MCP test note"]).0["path"] as? String ?? ""
        check(again.hasSuffix("MCP test note 2.md") && created == ((try? String(contentsOfFile: path, encoding: .utf8)) ?? ""),
              "create_note never replaces an existing note")
        check(c.tool("create_note", ["title": "x", "folder": "/tmp"]).1 && c.tool("create_note", ["title": "x", "folder": "../escape"]).1,
              "create_note stays inside the notes folders")

        let v1 = c.tool("read_note", ["note": path]).0["version"] as? String ?? ""
        let (ap, apErr, apText) = c.tool("append_to_note", ["note": path, "text": "Second line.", "expected_version": v1])
        let afterAppend = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        check(!apErr && ap["changed"] as? Bool == true && afterAppend.hasSuffix("First line.\n\nSecond line.\n"), "append_to_note adds at the end", apText)
        let stale = c.tool("append_to_note", ["note": path, "text": "Third line.", "expected_version": v1])
        check(stale.1 && stale.2.contains("changed") && ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "") == afterAppend,
              "append_to_note refuses when the note changed since it was read")
        _ = c.tool("append_to_note", ["note": path, "text": "- Try rye", "under_heading": "Next steps"])
        _ = c.tool("append_to_note", ["note": path, "text": "- Bake Saturday", "under_heading": "## Next steps"])
        let withHeading = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        check(withHeading.hasSuffix("## Next steps\n\n- Try rye\n- Bake Saturday\n"), "append_to_note adds under a heading", withHeading)

        let kaID = c.tool("search", ["query": "feed maintain sourdough starter"]).0["results"].flatMap { ($0 as? [JSON])?.first?["id"] as? Int } ?? 0
        let (lk, lkErr, lkText) = c.tool("add_link", ["note": path, "target": "\(kaID)"])
        let linked = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        check(!lkErr && lk["changed"] as? Bool == true && linked.contains("## Related\n\n- [How to feed and maintain a sourdough starter](https://www.kingarthurbaking.com/sourdough-starter-guide)"),
              "add_link puts the link under Related", lkText)
        check(c.tool("add_link", ["note": path, "target": "\(kaID)"]).0["changed"] as? Bool == false, "add_link doesn't add a link twice")
        check(c.tool("add_link", ["note": path, "target": fx.privatePage]).1, "add_link won't write a private URL into a note")
        let byTitle = c.tool("add_link", ["note": again, "target": "Bread pop-up plan"])
        check(!byTitle.1 && ((try? String(contentsOfFile: again, encoding: .utf8)) ?? "").contains("[Bread pop-up plan](https://docs.google.com/"),
              "add_link finds a page by its exact title", byTitle.2)

        check(c.tool("append_to_note", ["note": fx.outside.path, "text": "x"]).1, "append_to_note refuses files outside the notes folders")
        let txt = fx.notes.appendingPathComponent("plain.txt")
        try? Data("plain".utf8).write(to: txt)
        check(c.tool("append_to_note", ["note": txt.path, "text": "x"]).1 && ((try? String(contentsOf: txt, encoding: .utf8)) ?? "") == "plain",
              "append_to_note refuses files that aren't .md")
        check(c.tool("append_to_note", ["note": fx.hiddenNote.path, "text": "x"]).1, "append_to_note refuses notes in hidden folders")
        setSettings(fx) { $0.allowWrites = false }
        check((c.result("tools/list")["tools"] as? [JSON] ?? []).count == 10 && c.tool("append_to_note", ["note": path, "text": "x"]).1,
              "turning maintenance off hides and blocks the tools again")
    }

    // MARK: In-process pieces

    static func unitTests() {
        let note = URL(fileURLWithPath: "/notes/Project/Plan.md")
        let links = LinkScan.links(in: """
            # Plan
            See [the guide](https://example.com/guide) and [[Bread log|my log]] and [[Other#Heading]].
            Also https://example.org/page. and [sibling](Sibling%20note.md) and [up](../Top.md) and [mail](mailto:a@b.c).
            ## Related
            - [Saved](https://example.com/saved)
            """, noteURL: note)
        check(links.count == 7, "link scan finds Markdown links, wikilinks, bare URLs and relative notes", "\(links.count)")
        check(links.contains { $0.target == .wiki("Bread log") && $0.text == "my log" } && links.contains { $0.target == .wiki("Other") },
              "wikilinks keep the name and alias")
        check(links.contains { $0.target == .file(URL(fileURLWithPath: "/notes/Project/Sibling note.md")) }
              && links.contains { $0.target == .file(URL(fileURLWithPath: "/notes/Top.md")) }, "relative note links resolve against the note")
        check(links.contains { $0.target == .url(URL(string: "https://example.org/page")!) }, "bare URLs lose trailing punctuation")
        check(links.filter { $0.underRelated }.count == 1, "links under Related are marked")

        let p = MCPPrivacy(settings: MCPSettings(), app: AppSettings())
        check(p.check(source: "web", url: "https://docs.google.com/document/d/1AbCdEfGhIjKlMnOpQrStUvWxYz0123456789") == .allowed
              && p.check(source: "web", url: "https://www.notion.so/Roadmap-0123456789abcdef0123456789abcdef") == .allowed,
              "Google Docs and Notion URLs pass the token check")
        let blocked = ["https://example.com/magic-link/abc", "https://example.com/x?token=1", "https://chase.com/accounts",
                       "https://example.com/oauth/callback?code=1", "https://example.com/p?u=9f8e7d6c5b4a39281706f5e4d3c2b1a0aabbccdd1234"]
        check(blocked.allSatisfy { p.check(source: "web", url: $0) != .allowed }, "sign-in links, tokens and excluded sites are hidden",
              blocked.filter { p.check(source: "web", url: $0) == .allowed }.joined(separator: ", "))
        check(p.check(source: "markdown", url: "file:///notes/a.md") == .allowed, "notes pass the URL check")
        var hideDocs = MCPSettings(); hideDocs.hiddenSources = [MCPSources.gdocs]
        let hd = MCPPrivacy(settings: hideDocs, app: AppSettings())
        check(hd.check(source: "chrome", url: "https://docs.google.com/document/d/1AbCdEfGhIjKlMnOpQrStUvWxYz0123456789") != .allowed
              && hd.check(source: "gdocs", url: "https://docs.google.com/document/d/1AbCdEfGhIjKlMnOpQrStUvWxYz0123456789") != .allowed
              && hd.check(source: "notion", url: "https://www.notion.so/0123456789abcdef0123456789abcdef") == .allowed,
              "the Google Docs switch covers Chrome history and the sync, and not Notion")
        check(p.check(source: "granola", url: "https://notes.granola.ai/d/mtg-0451") == .allowed, "Granola links pass the URL check")
        let oldSettings = try? JSONDecoder().decode(MCPSettings.self, from: Data(#"{"hiddenSources":["searches","docs"]}"#.utf8))
        check(oldSettings.map { Set($0.hiddenSources) == ["searches", "gdocs", "notion"] } ?? false,
              "an older docs switch becomes the Google Docs and Notion switches")

        let appended = MCPNoteWriter.appending("- c", to: "# T\n\n## A\n\n- a\n\n## B\n\n- b\n", under: "A")
        check(appended == "# T\n\n## A\n\n- a\n- c\n\n## B\n\n- b\n", "appending under a heading lands at the end of its section", appended)
        check(MCPNoteWriter.appending("x", to: "", under: nil) == "x\n" && MCPNoteWriter.appending("x", to: "a\n\n\n", under: nil) == "a\n\nx\n",
              "appending at the end keeps one blank line")

        let snippets = MCPInstall.snippets(binary: "/Apps/My App.app/Contents/MacOS/BrowserPOC", dataDir: "/Users/me/it's here")
        let desktop = (try? JSONSerialization.jsonObject(with: Data(snippets.claudeDesktop.utf8))) as? JSON
        let server = (desktop?["mcpServers"] as? JSON)?["browser"] as? JSON
        check(server?["command"] as? String == "/Apps/My App.app/Contents/MacOS/BrowserPOC"
              && server?["args"] as? [String] == ["--mcp", "--data-dir", "/Users/me/it's here"], "the Claude Desktop snippet is valid JSON")
        check(snippets.codexTOML.contains("command = \"/Apps/My App.app/Contents/MacOS/BrowserPOC\"")
              && snippets.codexTOML.contains("args = [\"--mcp\", \"--data-dir\", \"/Users/me/it's here\"]"), "the Codex snippet is valid TOML", snippets.codexTOML)
        check(snippets.claudeCode.contains("'/Users/me/it'\\''s here'"), "shell commands quote paths", snippets.claudeCode)
        check(MCPInstall.integrationsFolder() == nil || FileManager.default.fileExists(atPath: MCPInstall.integrationsFolder()!.appendingPathComponent("claude-code/.claude-plugin/marketplace.json").path),
              "the Claude Code marketplace is where the install steps point")
        integrationFiles()
    }

    /// The packaged plugins parse, and every copy of the launcher is the same.
    static func integrationFiles() {
        guard let dir = MCPInstall.integrationsFolder() else { return }
        let jsonFiles = ["claude-code/.claude-plugin/marketplace.json", "claude-code/plugins/browser-knowledge/.claude-plugin/plugin.json",
                         "claude-code/plugins/browser-knowledge/.mcp.json", "claude-desktop/mcpb/manifest.json",
                         "claude-desktop/claude_desktop_config.example.json", "codex/plugin/plugin.json", "codex/plugin/mcp.json",
                         "codex/.agents/plugins/marketplace.json"]
        let bad = jsonFiles.filter { f in
            guard let d = try? Data(contentsOf: dir.appendingPathComponent(f)) else { return true }
            return (try? JSONSerialization.jsonObject(with: d)) == nil
        }
        check(bad.isEmpty, "integration manifests parse", bad.joined(separator: ", "))
        let launcher = try? Data(contentsOf: dir.appendingPathComponent("launcher/browser-mcp"))
        let copies = ["claude-code/plugins/browser-knowledge/scripts/browser-mcp", "claude-desktop/mcpb/server/browser-mcp", "codex/plugin/scripts/browser-mcp"]
        check(launcher != nil && copies.allSatisfy { (try? Data(contentsOf: dir.appendingPathComponent($0))) == launcher },
              "every launcher copy matches integrations/launcher")
        let skills = ["claude-code/plugins/browser-knowledge/skills/browser-knowledge/SKILL.md", "codex/plugin/skills/browser-knowledge/SKILL.md"]
        check(skills.allSatisfy { (try? String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8))?.hasPrefix("---\nname: browser-knowledge\ndescription: ") == true },
              "skills have name and description frontmatter")
    }

    /// Smoke test: the context writer on the real model, and the AI clients pane drawn offscreen.
    @MainActor
    static func smoke(model: BrowserModel, snaps: URL) {
        let w = CurrentContextWriter.shared
        w.start(model: model)
        w.stop()
        let wrote = w.writeNow()
        let f = try? JSONDecoder.iso.decode(CurrentContextFile.self, from: Data(contentsOf: CurrentContextFile.url(Paths.root)))
        check(wrote && f?.focused != nil && f?.binary == Bundle.main.executablePath && !(f?.openTabs.isEmpty ?? true),
              "the running model writes what's on screen", f?.focused?.title ?? "nothing focused")
        for (i, name) in ["search", "related", "current_context"].enumerated() {
            MCPLog.append(MCPLogEntry(at: Date().addingTimeInterval(Double(-60 * i)), client: "claude-code", kind: "tool", name: name,
                                      detail: i == 0 ? "sourdough starter" : "", served: 3 - i, titles: ["Bread bake log"], hidden: i), root: Paths.root)
        }
        let view = NSHostingView(rootView: AIClientsSettings())
        let win = SmokeTest.offscreenWindow(view, size: NSSize(width: 580, height: 1100))
        SmokeTest.snapshot(win.contentView!, snaps.appendingPathComponent("20-ai-clients.png"))
        check(view.fittingSize.height > 100, "the AI clients pane lays out")
    }

    /// The app side: the writer records the focused note and the trail.
    static func contextWriterTest(dir: URL) {
        MainActor.assumeIsolated {
            BrowserModel.useEphemeralStore = true
            let notes = dir.appendingPathComponent("ctx-notes", isDirectory: true)
            Paths.ensure(notes)
            let a = notes.appendingPathComponent("Context note.md")
            try? Data("# Context note\n\nHello.\n".utf8).write(to: a)
            let m = BrowserModel()
            let w = CurrentContextWriter.shared
            w.start(model: m)
            w.stop()
            _ = m.openNote(a)
            let wrote = w.writeNow()
            let f = try? JSONDecoder.iso.decode(CurrentContextFile.self, from: Data(contentsOf: CurrentContextFile.url(Paths.root)))
            check(wrote && f?.focused?.kind == "note" && f?.focused?.url.hasSuffix("Context%20note.md") == true && f?.pid == getpid()
                  && f?.trail.first?.url == f?.focused?.url && f?.space?.name == m.currentSpace?.name,
                  "the app writes current-context.json with the focused note, space and trail")
            check(!w.writeNow(), "the context file is only rewritten when something changed")
            try? FileManager.default.removeItem(at: CurrentContextFile.url(Paths.root))
        }
    }
}
