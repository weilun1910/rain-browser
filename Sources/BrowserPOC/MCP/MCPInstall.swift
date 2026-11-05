import Foundation

/// Install steps for each AI client, filled in with this copy of the app and its profile.
/// Settings shows them with copy buttons. Nothing here touches a client's config.
enum MCPInstall {
    struct Snippets {
        /// `claude mcp add`, one line.
        let claudeCode: String
        /// Adding the local marketplace and installing the plugin. Nil when the integrations folder isn't next to the app.
        let claudePlugin: String?
        /// The `mcpServers` entry for claude_desktop_config.json.
        let claudeDesktop: String
        /// The `[mcp_servers.browser]` table for ~/.codex/config.toml.
        let codexTOML: String
        /// `codex mcp add`, one line.
        let codexCommand: String
        /// The local Codex plugin marketplace. Nil when the integrations folder isn't next to the app.
        let codexPlugin: String?
        /// What to type in ChatGPT's Settings, MCP servers.
        let chatGPTMac: String
    }

    static let serverName = "browser"

    static var currentBinary: String { Bundle.main.executablePath ?? "/Applications/BrowserPOC.app/Contents/MacOS/BrowserPOC" }
    static var currentDataDir: String? { Paths.overrideRoot?.standardizedFileURL.path }

    static func args(dataDir: String?) -> [String] {
        var a = ["--mcp"]
        if let dataDir { a += ["--data-dir", dataDir] }
        return a
    }

    static func shellQuote(_ s: String) -> String {
        if s.allSatisfy({ $0.isLetter || $0.isNumber || "/._-+=:@".contains($0) }) && s.allSatisfy({ $0.isASCII }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func tomlString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func snippets(binary: String = currentBinary, dataDir: String? = currentDataDir) -> Snippets {
        let a = args(dataDir: dataDir)
        let cmdLine = ([binary] + a).map(shellQuote).joined(separator: " ")
        let desktop: JSON = ["mcpServers": [serverName: ["command": binary, "args": a] as JSON] as JSON]
        let toml = """
        [mcp_servers.\(serverName)]
        command = \(tomlString(binary))
        args = [\(a.map(tomlString).joined(separator: ", "))]
        startup_timeout_sec = 30
        """
        var plugin: String?
        var codexPlugin: String?
        if let dir = integrationsFolder() {
            var install = "claude plugin install browser-knowledge@browser-poc --config app_path=\(shellQuote(binary))"
            if let dataDir { install += " --config data_dir=\(shellQuote(dataDir))" }
            plugin = "claude plugin marketplace add \(shellQuote(dir.appendingPathComponent("claude-code").path))\n" + install
            codexPlugin = "codex plugin marketplace add \(shellQuote(dir.appendingPathComponent("codex").path))\ncodex plugin add browser-knowledge@browser-poc"
        }
        let chatgpt = """
        Name: \(serverName)
        Type: STDIO
        Command: \(binary)
        Arguments: \(a.joined(separator: " "))
        """
        return Snippets(claudeCode: "claude mcp add --scope user --transport stdio \(serverName) -- \(cmdLine)",
                        claudePlugin: plugin,
                        claudeDesktop: J.string(desktop, pretty: true),
                        codexTOML: toml,
                        codexCommand: "codex mcp add \(serverName) -- \(cmdLine)",
                        codexPlugin: codexPlugin,
                        chatGPTMac: chatgpt)
    }

    /// The repo's `integrations/` folder: next to `build/BrowserPOC.app`, or found from this source file.
    static func integrationsFolder() -> URL? {
        var candidates: [URL] = []
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            candidates.append(bundle.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("integrations"))
        }
        // Sources/BrowserPOC/MCP/MCPInstall.swift -> repo root.
        let source = URL(fileURLWithPath: #filePath)
        candidates.append(source.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("integrations"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("launcher/browser-mcp").path) }
    }
}
