import Foundation

/// `--mcp`: serves the knowledge index to AI clients over MCP on stdio.
///
/// Hand-written JSON-RPC that answers both protocol eras:
/// - legacy (2025-11-25 and earlier): the client opens with `initialize`.
/// - modern (2026-07-28): no handshake, every request carries `_meta` with the protocol
///   version and client capabilities, and results carry `resultType`, `ttlMs` and `cacheScope`.
/// One request is handled at a time and every message goes out as one line through one writer.
typealias JSON = [String: Any]

struct RPCError: Error {
    let code: Int
    let message: String
    var data: Any? = nil

    static func invalidParams(_ m: String) -> RPCError { RPCError(code: -32602, message: m) }
    static func methodNotFound(_ m: String) -> RPCError { RPCError(code: -32601, message: "Method not found: \(m)") }
}

enum MCPProtocol {
    static let modern = "2026-07-28"
    static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static let metaVersion = "io.modelcontextprotocol/protocolVersion"
    static let metaCapabilities = "io.modelcontextprotocol/clientCapabilities"
    static let metaClientInfo = "io.modelcontextprotocol/clientInfo"
    static let metaServerInfo = "io.modelcontextprotocol/serverInfo"

    static let serverInfo: JSON = [
        "name": "browser-poc-knowledge",
        "title": "Rain knowledge",
        "version": "0.3.0",
        "description": "Pages, notes, docs and connections from Rain on this Mac.",
    ]

    /// The first 512 characters stand on their own (OpenAI's guidance); the whole text stays under 4,096 (Claude Code's cap).
    static let instructions = """
    This server is the user's personal knowledge base from their Rain app, kept on their Mac: web pages they read, \
    their Markdown notes, Google Docs, Notion pages, Granola meeting notes, and how these connect. Use it to understand \
    what the user knows, is working on and has read before. Call search first for a topic, get_item to read one item, \
    related and connections for what links to it, and current_context or recent_activity for what they're doing now. \
    Cite every item you use by its title and link.

    Good habits:
    - Search before answering questions about the user's own projects, notes, reading or past research, and when they say \
    "I read something about", "my notes", "what do I know about".
    - Prefer the user's own notes, docs and meetings over general knowledge when they disagree, and say so.
    - Results say when and in what context the user saw each item ("history"). Use it to tell old reading from current work.
    - Results carry a ready "cite" string. Use it. For notes, the link is a file path on their Mac.
    - get_item and read_note page long text with offset and max_chars. Read the passage you need, not everything.
    - Items the user hid from AI clients never appear. Don't guess at them.
    - Maintenance tools (create_note, append_to_note, add_link) only exist when the user turned them on in Settings. \
    Ask before writing, keep the user's wording, append rather than rewrite, and never retry a write that was refused \
    because the file changed. Read it again first.
    """
}

final class MCPServer {
    private let out: FileHandle
    private let toolbox: MCPToolbox
    /// Set by `initialize`. Requests without modern `_meta` are answered the legacy way.
    private var legacyVersion: String?
    private var clientName = "unknown client"

    init(toolbox: MCPToolbox, out: FileHandle) {
        self.toolbox = toolbox
        self.out = out
    }

    /// Runs `--mcp`. Keeps stdout for protocol messages only: anything else that prints goes to stderr.
    static func runStdio(root: URL) -> Int32 {
        let protocolFD = dup(STDOUT_FILENO)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        setvbuf(stdout, nil, _IOLBF, 0)
        signal(SIGPIPE, SIG_IGN)
        let out = FileHandle(fileDescriptor: protocolFD, closeOnDealloc: false)
        // Clients often end a server with a signal instead of closing stdin. Either way the private
        // copy of the index goes, and so do copies from servers that were killed outright.
        RankingSnapshot.sweepStale()
        let copyDir = RankingSnapshot.directory(pid: getpid())
        var signalSources: [DispatchSourceSignal] = []
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .userInitiated))
            s.setEventHandler {
                try? FileManager.default.removeItem(at: copyDir)
                exit(0)
            }
            s.resume()
            signalSources.append(s)
        }
        defer { signalSources.forEach { $0.cancel() } }
        let context = MCPContext(root: root)
        let server = MCPServer(toolbox: MCPToolbox(context: context), out: out)
        FileHandle.standardError.write(Data("Rain MCP server on \(root.path)\n".utf8))
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let reply = server.handle(line: trimmed) { server.send(reply) }
        }
        context.close()
        return 0
    }

    func send(_ message: JSON) {
        guard var data = try? JSONSerialization.data(withJSONObject: J.clean(message), options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        out.write(data)
    }

    // MARK: Dispatch

    /// Handles one line. Returns the reply, or nil for notifications.
    func handle(line: String) -> JSON? {
        guard let data = line.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) else {
            return ["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]]
        }
        guard let msg = obj as? JSON else {
            // Batches were removed in 2025-06-18.
            return ["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Batches are not supported"]]
        }
        let id = msg["id"]
        guard let method = msg["method"] as? String else {
            // A response to something we never sent, or junk.
            return id == nil ? nil : ["jsonrpc": "2.0", "id": id!, "error": ["code": -32600, "message": "Invalid request"]]
        }
        let params = msg["params"] as? JSON ?? [:]
        if id == nil || id is NSNull {
            // Notifications: initialized, cancelled. Nothing to answer.
            return nil
        }
        do {
            let result = try dispatch(method: method, params: params)
            return ["jsonrpc": "2.0", "id": id!, "result": result]
        } catch let e as RPCError {
            var err: JSON = ["code": e.code, "message": e.message]
            if let d = e.data { err["data"] = d }
            return ["jsonrpc": "2.0", "id": id!, "error": err]
        } catch {
            return ["jsonrpc": "2.0", "id": id!, "error": ["code": -32603, "message": "Internal error: \(error)"]]
        }
    }

    private func dispatch(method: String, params: JSON) throws -> JSON {
        if method == "initialize" { return initialize(params) }
        let meta = params["_meta"] as? JSON
        let modernVersion = meta?[MCPProtocol.metaVersion] as? String
        let modern = modernVersion != nil || (method == "server/discover" && legacyVersion == nil)
        if let v = modernVersion {
            guard v == MCPProtocol.modern else {
                throw RPCError(code: -32022, message: "Unsupported protocol version",
                               data: ["supported": [MCPProtocol.modern] + MCPProtocol.legacyVersions, "requested": v])
            }
            guard meta?[MCPProtocol.metaCapabilities] is JSON else {
                throw RPCError.invalidParams("Missing \(MCPProtocol.metaCapabilities) in _meta")
            }
            if let info = meta?[MCPProtocol.metaClientInfo] as? JSON, let name = info["name"] as? String { clientName = name }
        }
        toolbox.context.clientName = clientName
        toolbox.context.modern = modern
        toolbox.context.protocolVersion = modernVersion ?? legacyVersion

        var result: JSON
        var ttl: Int?
        switch method {
        case "ping":
            result = [:]
        case "server/discover":
            result = [
                "supportedVersions": [MCPProtocol.modern],
                "capabilities": capabilities,
                "instructions": MCPProtocol.instructions,
            ]
            ttl = 60_000
        case "tools/list":
            result = ["tools": toolbox.listTools()]
            // Short, because the maintenance tools come and go with a Settings switch.
            ttl = 30_000
        case "tools/call":
            guard let name = params["name"] as? String else { throw RPCError.invalidParams("Missing tool name") }
            result = try toolbox.call(name: name, arguments: params["arguments"] as? JSON ?? [:])
        case "resources/list":
            result = try MCPResources.list(toolbox.context, cursor: params["cursor"] as? String)
            ttl = 30_000
        case "resources/templates/list":
            result = ["resourceTemplates": MCPResources.templates]
            ttl = 3_600_000
        case "resources/read":
            guard let uri = params["uri"] as? String else { throw RPCError.invalidParams("Missing uri") }
            result = try MCPResources.read(toolbox, uri: uri)
            ttl = 5_000
        case "prompts/list":
            result = ["prompts": MCPResources.prompts]
            ttl = 3_600_000
        case "prompts/get":
            guard let name = params["name"] as? String else { throw RPCError.invalidParams("Missing prompt name") }
            result = try MCPResources.prompt(name: name, arguments: params["arguments"] as? JSON ?? [:], context: toolbox.context)
        default:
            throw RPCError.methodNotFound(method)
        }
        if modern {
            result["resultType"] = "complete"
            var m = result["_meta"] as? JSON ?? [:]
            m[MCPProtocol.metaServerInfo] = MCPProtocol.serverInfo
            result["_meta"] = m
            if let ttl {
                result["ttlMs"] = ttl
                result["cacheScope"] = "private"
            }
        }
        return result
    }

    private var capabilities: JSON {
        ["tools": ["listChanged": false], "resources": ["listChanged": false, "subscribe": false], "prompts": ["listChanged": false]]
    }

    private func initialize(_ params: JSON) -> JSON {
        let asked = params["protocolVersion"] as? String ?? MCPProtocol.legacyVersions[0]
        let version = MCPProtocol.legacyVersions.contains(asked) ? asked : MCPProtocol.legacyVersions[0]
        legacyVersion = version
        if let info = params["clientInfo"] as? JSON, let name = info["name"] as? String { clientName = name }
        return [
            "protocolVersion": version,
            "capabilities": capabilities,
            "serverInfo": MCPProtocol.serverInfo,
            "instructions": MCPProtocol.instructions,
        ]
    }
}

/// JSON helpers. JSONSerialization throws an Objective-C exception on NaN or infinity, so every
/// outgoing value goes through `clean`.
enum J {
    static func clean(_ v: Any) -> Any {
        switch v {
        case let n as NSDecimalNumber: return n
        case let d as Double: return d.isFinite ? d : 0
        case let f as Float: return f.isFinite ? Double(f) : 0
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (k, x) in dict { out[k] = clean(x) }
            return out
        case let arr as [Any]: return arr.map(clean)
        default: return v
        }
    }

    static func string(_ v: Any, pretty: Bool = false) -> String {
        var opts: JSONSerialization.WritingOptions = [.withoutEscapingSlashes, .sortedKeys]
        if pretty { opts.insert(.prettyPrinted) }
        guard let d = try? JSONSerialization.data(withJSONObject: clean(v), options: opts) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    /// Three decimals, written as 0.845 rather than 0.84499999999999997.
    static func round3(_ x: Double) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.3f", x.isFinite ? x : 0), locale: Locale(identifier: "en_US_POSIX"))
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone.current
        return f
    }()

    static func date(_ t: Double) -> Any { t > 0 ? iso.string(from: Date(timeIntervalSince1970: t)) : NSNull() }

    static func parseDate(_ s: String) -> Date? {
        if let d = iso.date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }
}
