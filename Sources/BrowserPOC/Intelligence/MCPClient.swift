import CryptoKit
import Foundation
import Network

/// OAuth for MCP servers: discovery, dynamic client registration as a public client, PKCE,
/// a one-shot loopback listener for the redirect, and token refresh. No secrets to paste.
final class OAuthClient: @unchecked Sendable {
    struct Metadata: Codable {
        var authorizationEndpoint: String
        var tokenEndpoint: String
        var registrationEndpoint: String?
        var issuer: String
    }

    struct Tokens: Codable {
        var clientID: String
        var redirectURI: String
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date
        var metadata: Metadata
        var resource: String
    }

    enum Failure: Error, CustomStringConvertible {
        case discovery(String), registration(String), denied(String), token(String), listener(String), notConnected
        var description: String {
            switch self {
            case .discovery(let s): return "Couldn't find the sign-in service: \(s)"
            case .registration(let s): return "Couldn't register the app: \(s)"
            case .denied(let s): return "Sign-in didn't finish: \(s)"
            case .token(let s): return "Couldn't get a sign-in token: \(s)"
            case .listener(let s): return "Couldn't listen for the sign-in redirect: \(s)"
            case .notConnected: return "Not connected."
            }
        }
    }

    let resource: URL
    let tokenFile: URL
    let clientName: String
    let scope: String
    static let loopbackPort: UInt16 = 47815

    init(resource: URL, tokenFile: URL, clientName: String = "Browser POC", scope: String = "mcp offline_access") {
        self.resource = resource
        self.tokenFile = tokenFile
        self.clientName = clientName
        self.scope = scope
    }

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }

    // MARK: Discovery

    /// RFC 9728 protected-resource metadata, then RFC 8414 authorization-server metadata.
    func discover() async throws -> Metadata {
        guard let host = resource.host, let scheme = resource.scheme else { throw Failure.discovery("bad URL") }
        let origin = "\(scheme)://\(host)"
        var authServer = origin
        for path in ["/.well-known/oauth-protected-resource\(resource.path)", "/.well-known/oauth-protected-resource"] {
            if let j = try? await getJSON(URL(string: origin + path)!), let list = j["authorization_servers"] as? [String], let first = list.first {
                authServer = first
                break
            }
        }
        guard let asURL = URL(string: authServer), let asHost = asURL.host else { throw Failure.discovery("bad authorization server") }
        let asOrigin = "\(asURL.scheme ?? "https")://\(asHost)"
        let candidates = [asOrigin + "/.well-known/oauth-authorization-server" + (asURL.path == "/" ? "" : asURL.path),
                          asOrigin + "/.well-known/oauth-authorization-server",
                          asOrigin + "/.well-known/openid-configuration"]
        for c in candidates {
            if let j = try? await getJSON(URL(string: c)!), let auth = j["authorization_endpoint"] as? String, let token = j["token_endpoint"] as? String {
                return Metadata(authorizationEndpoint: auth, tokenEndpoint: token,
                                registrationEndpoint: j["registration_endpoint"] as? String, issuer: (j["issuer"] as? String) ?? asOrigin)
            }
        }
        throw Failure.discovery("no authorization server metadata at \(asOrigin)")
    }

    func getJSON(_ url: URL) async throws -> [String: Any] {
        let (data, resp) = try await Self.session().data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.discovery("\(url.absoluteString) answered \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return j
    }

    // MARK: Sign-in

    static func base64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func randomString(_ bytes: Int = 32) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return base64url(Data(b))
    }

    static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// Runs the whole sign-in: registers if needed, opens the sign-in page with `open`, waits
    /// for the redirect on 127.0.0.1 and trades the code for tokens.
    func signIn(open: @escaping @Sendable (URL) -> Void) async throws -> Tokens {
        let meta = try await discover()
        let redirect = "http://127.0.0.1:\(Self.loopbackPort)/callback"
        let clientID = try await register(meta, redirect: redirect)
        let verifier = Self.randomString(48)
        let state = Self.randomString(16)
        var c = URLComponents(string: meta.authorizationEndpoint)!
        c.queryItems = (c.queryItems ?? []) + [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "code_challenge", value: Self.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "resource", value: resource.absoluteString),
        ]
        let listener = LoopbackListener(port: Self.loopbackPort)
        try listener.start()
        open(c.url!)
        let query = try await listener.waitForCallback(timeout: 300)
        if let err = query["error"] { throw Failure.denied(query["error_description"] ?? err) }
        guard query["state"] == state, let code = query["code"] else { throw Failure.denied("the redirect didn't match this sign-in") }
        let t = try await tokenRequest(meta, form: [
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirect,
            "client_id": clientID, "code_verifier": verifier, "resource": resource.absoluteString,
        ], clientID: clientID, redirect: redirect, previous: nil)
        try save(t)
        return t
    }

    func register(_ meta: Metadata, redirect: String) async throws -> String {
        if let saved = load(), saved.metadata.issuer == meta.issuer, saved.redirectURI == redirect { return saved.clientID }
        guard let reg = meta.registrationEndpoint, let url = URL(string: reg) else { throw Failure.registration("the server has no registration endpoint") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": clientName, "redirect_uris": [redirect], "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"], "token_endpoint_auth_method": "none", "scope": scope,
        ])
        let (data, resp) = try await Self.session().data(for: req)
        guard let code = (resp as? HTTPURLResponse)?.statusCode, (200..<300).contains(code),
              let j = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = j["client_id"] as? String else {
            throw Failure.registration(String(data: data, encoding: .utf8)?.prefix(200).description ?? "no answer")
        }
        return id
    }

    func tokenRequest(_ meta: Metadata, form: [String: String], clientID: String, redirect: String, previous: Tokens?) async throws -> Tokens {
        var req = URLRequest(url: URL(string: meta.tokenEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await Self.session().data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = j["access_token"] as? String else {
            throw Failure.token(String(data: data, encoding: .utf8)?.prefix(200).description ?? "no answer")
        }
        let expires = (j["expires_in"] as? Double) ?? Double((j["expires_in"] as? Int) ?? 3600)
        return Tokens(clientID: clientID, redirectURI: redirect, accessToken: access,
                      refreshToken: (j["refresh_token"] as? String) ?? previous?.refreshToken,
                      expiresAt: Date().addingTimeInterval(expires - 60), metadata: meta, resource: resource.absoluteString)
    }

    /// A valid access token, refreshing it when it has expired.
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard var t = load() else { throw Failure.notConnected }
        if !forceRefresh && t.expiresAt > Date() { return t.accessToken }
        guard let refresh = t.refreshToken else { throw Failure.notConnected }
        t = try await tokenRequest(t.metadata, form: ["grant_type": "refresh_token", "refresh_token": refresh,
                                                      "client_id": t.clientID, "resource": t.resource],
                                   clientID: t.clientID, redirect: t.redirectURI, previous: t)
        try save(t)
        return t.accessToken
    }

    // MARK: Storage

    /// Tokens stay in the app's own folder, readable only by Felix's account. The shipping app
    /// would keep them in the Keychain.
    func save(_ t: Tokens) throws {
        Paths.ensure(tokenFile.deletingLastPathComponent())
        let d = try JSONEncoder.pretty.encode(t)
        try d.write(to: tokenFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
    }

    func load() -> Tokens? {
        guard let d = try? Data(contentsOf: tokenFile) else { return nil }
        return try? JSONDecoder.iso.decode(Tokens.self, from: d)
    }

    var isConnected: Bool { load() != nil }

    func signOut() { try? FileManager.default.removeItem(at: tokenFile) }
}

/// Listens on 127.0.0.1 for one OAuth redirect and answers with a short page.
final class LoopbackListener: @unchecked Sendable {
    private let port: UInt16
    private var listener: NWListener?
    private var continuation: CheckedContinuation<[String: String], Error>?
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "local.browserpoc.oauth")

    init(port: UInt16) { self.port = port }

    func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        let l: NWListener
        do { l = try NWListener(using: params) } catch { throw OAuthClient.Failure.listener("\(error)") }
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        l.start(queue: queue)
        listener = l
    }

    static func parseQuery(_ requestLine: String) -> [String: String] {
        // "GET /callback?code=abc&state=xyz HTTP/1.1"
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, let c = URLComponents(string: "http://127.0.0.1" + parts[1]) else { return [:] }
        var out: [String: String] = [:]
        for i in c.queryItems ?? [] { out[i.name] = i.value ?? "" }
        return out
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let first = text.split(separator: "\r\n").first.map(String.init) ?? ""
            let query = Self.parseQuery(first)
            guard first.contains("/callback") else { conn.cancel(); return }
            let body = "<!doctype html><meta charset=utf-8><title>Signed in</title><body style=\"font: 15px -apple-system; margin: 4em; color: #333\">You're signed in. You can close this tab and go back to the browser.</body>"
            let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
            self.finish(.success(query))
        }
    }

    private func finish(_ r: Result<[String: String], Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        listener?.cancel()
        switch r {
        case .success(let q): c?.resume(returning: q)
        case .failure(let e): c?.resume(throwing: e)
        }
    }

    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { c in
            setContinuation(c)
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(OAuthClient.Failure.denied("timed out after \(Int(timeout / 60)) minutes")))
            }
        }
    }

    private func setContinuation(_ c: CheckedContinuation<[String: String], Error>) {
        lock.lock(); continuation = c; lock.unlock()
    }
}

/// A small MCP client over Streamable HTTP: initialize, tools/list and tools/call.
final class MCPClient: @unchecked Sendable {
    let endpoint: URL
    let auth: OAuthClient
    private var sessionID: String?
    private var nextID = 1
    private var initialized = false
    private let lock = NSLock()
    static let protocolVersion = "2025-06-18"

    enum Failure: Error, CustomStringConvertible {
        case http(Int, String), rpc(String), tool(String)
        var description: String {
            switch self {
            case .http(let c, let s): return "The server answered \(c). \(s)"
            case .rpc(let s): return s
            case .tool(let s): return s
            }
        }
    }

    init(endpoint: URL, auth: OAuthClient) {
        self.endpoint = endpoint
        self.auth = auth
    }

    private func takeID() -> Int {
        lock.lock(); defer { lock.unlock() }
        nextID += 1
        return nextID
    }

    /// Picks the JSON-RPC response with `id` out of a JSON body or an SSE stream.
    static func parseResponse(_ data: Data, contentType: String, id: Int) -> [String: Any]? {
        if contentType.contains("text/event-stream") {
            let text = String(decoding: data, as: UTF8.self)
            var buffer = ""
            for line in text.components(separatedBy: "\n") {
                if line.hasPrefix("data:") {
                    buffer += line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                } else if line.trimmingCharacters(in: .whitespaces).isEmpty, !buffer.isEmpty {
                    if let j = try? JSONSerialization.jsonObject(with: Data(buffer.utf8)) as? [String: Any], (j["id"] as? Int) == id { return j }
                    buffer = ""
                }
            }
            if !buffer.isEmpty, let j = try? JSONSerialization.jsonObject(with: Data(buffer.utf8)) as? [String: Any], (j["id"] as? Int) == id { return j }
            return nil
        }
        if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return j }
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] { return arr.first { ($0["id"] as? Int) == id } }
        return nil
    }

    private func post(_ body: [String: Any], expectResponse: Bool, retried: Bool = false) async throws -> [String: Any]? {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(Self.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        req.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
        if let sessionID { req.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 60
        let (data, resp) = try await OAuthClient.session().data(for: req)
        let http = resp as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        if code == 401 && !retried {
            _ = try await auth.accessToken(forceRefresh: true)
            return try await post(body, expectResponse: expectResponse, retried: true)
        }
        if code == 404 && sessionID != nil && !retried {
            // The server forgot the session; start a new one.
            sessionID = nil
            initialized = false
            try await initialize()
            return try await post(body, expectResponse: expectResponse, retried: true)
        }
        guard (200..<300).contains(code) else { throw Failure.http(code, String(decoding: data.prefix(300), as: UTF8.self)) }
        if let sid = http?.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = sid }
        guard expectResponse, let id = body["id"] as? Int else { return nil }
        guard let j = Self.parseResponse(data, contentType: http?.value(forHTTPHeaderField: "Content-Type") ?? "", id: id) else {
            throw Failure.rpc("No answer from the server.")
        }
        if let err = j["error"] as? [String: Any] { throw Failure.rpc((err["message"] as? String) ?? "Unknown error") }
        return j["result"] as? [String: Any]
    }

    func initialize() async throws {
        if initialized { return }
        _ = try await post(["jsonrpc": "2.0", "id": takeID(), "method": "initialize", "params": [
            "protocolVersion": Self.protocolVersion, "capabilities": [:],
            "clientInfo": ["name": "browser-poc", "version": "0.3"],
        ]], expectResponse: true)
        _ = try await post(["jsonrpc": "2.0", "method": "notifications/initialized"], expectResponse: false)
        initialized = true
    }

    struct ToolInfo { let name: String; let properties: [String] }

    func listTools() async throws -> [ToolInfo] {
        try await initialize()
        let r = try await post(["jsonrpc": "2.0", "id": takeID(), "method": "tools/list", "params": [:]], expectResponse: true)
        let tools = (r?["tools"] as? [[String: Any]]) ?? []
        return tools.compactMap { t in
            guard let name = t["name"] as? String else { return nil }
            let props = ((t["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])?.keys.map { $0 } ?? []
            return ToolInfo(name: name, properties: props)
        }
    }

    /// Calls a tool and returns its text content joined.
    func call(_ name: String, _ arguments: [String: Any] = [:]) async throws -> String {
        try await initialize()
        let r = try await post(["jsonrpc": "2.0", "id": takeID(), "method": "tools/call",
                                "params": ["name": name, "arguments": arguments]], expectResponse: true)
        let content = (r?["content"] as? [[String: Any]]) ?? []
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        if (r?["isError"] as? Bool) == true { throw Failure.tool(text.isEmpty ? "The tool failed." : String(text.prefix(300))) }
        if text.isEmpty, let structured = r?["structuredContent"], let d = try? JSONSerialization.data(withJSONObject: structured) {
            return String(decoding: d, as: UTF8.self)
        }
        return text
    }
}
