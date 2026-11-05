import AppKit
import SwiftUI

/// Settings, AI clients: how to connect Claude, Codex and ChatGPT, what they can see, whether
/// they can edit notes, and what was served to them.
struct AIClientsSettings: View {
    enum Client: String, CaseIterable, Identifiable {
        case claudeCode = "Claude Code", claudeDesktop = "Claude Desktop", codex = "Codex", chatGPT = "ChatGPT"
        var id: String { rawValue }
    }

    @State private var mcp = MCPSettings.load(root: Paths.root)
    @State private var client: Client = .claudeCode
    @State private var log: [MCPLogEntry] = []
    @State private var counts: [String: Int] = [:]
    @State private var extraSources: [String] = []
    private let snippets = MCPInstall.snippets()
    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            connectSection
            visibilitySection
            editingSection
            logSection
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
        .onReceive(timer) { _ in log = MCPLog.read(root: Paths.root, limit: 60) }
        .onChange(of: mcp) { mcp.save(root: Paths.root) }
    }

    // MARK: Connect

    private var connectSection: some View {
        Section {
            Picker("Client", selection: $client) {
                ForEach(Client.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 10) {
                switch client {
                case .claudeCode:
                    if let plugin = snippets.claudePlugin {
                        Step("Install the plugin. It adds the server and a skill that teaches Claude when to search and how to cite your notes.")
                        CopyBlock(text: plugin)
                        Step("Or add only the server:")
                    } else {
                        Step("Add the server:")
                    }
                    CopyBlock(text: snippets.claudeCode)
                case .claudeDesktop:
                    Step("Open Claude, then Settings, then Developer, then Edit Config. Put this in the file (merge it with any servers already there), then quit and reopen Claude.")
                    CopyBlock(text: snippets.claudeDesktop)
                    Step("Or install the extension: run integrations/claude-desktop/pack.sh from the repo and double-click the .mcpb it makes.")
                case .codex:
                    Step("Add this to ~/.codex/config.toml. The ChatGPT Mac app reads the same file.")
                    CopyBlock(text: snippets.codexTOML)
                    Step("Or run:")
                    CopyBlock(text: snippets.codexCommand)
                    if let plugin = snippets.codexPlugin {
                        Step("Or install the plugin, which brings the skill along:")
                        CopyBlock(text: plugin)
                    }
                case .chatGPT:
                    Step("In ChatGPT for Mac, open Settings, then MCP servers, then Add server, and fill in:")
                    CopyBlock(text: snippets.chatGPTMac)
                    Step("Use it in a Codex or Work thread. ChatGPT on the web can only reach your Mac through OpenAI's Secure MCP Tunnel, which needs your own OpenAI Platform setup. The steps are in integrations/chatgpt/README.md.")
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Connect an AI client")
        } footer: {
            Text(MCPInstall.currentDataDir == nil
                 ? "The client starts this app's binary with --mcp. It reads your index without changing it, and only while the client is open."
                 : "This window runs on a separate profile, so these steps point the client at that profile.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Visibility

    private var visibilitySection: some View {
        Section {
            ForEach(MCPSources.builtIn, id: \.id) { s in
                sourceToggle(id: s.id, label: s.label, detail: s.detail)
            }
            ForEach(extraSources, id: \.self) { id in
                sourceToggle(id: id, label: MCPSources.label(id), detail: "Items from this source")
            }
            Toggle(isOn: $mcp.shareCurrentContext) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("What you're working on now")
                    Text("The focused page or note, its split, your space, its open tabs and the Related cards")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("What AI clients can see")
        } footer: {
            Text("Sites on your never-index list, sign-in links and links with tokens in them are always left out, and so is what you type.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func sourceToggle(id: String, label: String, detail: String) -> some View {
        Toggle(isOn: Binding(
            get: { !mcp.hiddenSources.contains(id) },
            set: { on in
                mcp.hiddenSources.removeAll { $0 == id }
                if !on { mcp.hiddenSources.append(id) }
            })) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let n = counts[id] {
                    Text(n.formatted()).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Editing

    private var editingSection: some View {
        Section {
            Toggle("Let AI clients edit notes", isOn: $mcp.allowWrites)
        } header: {
            Text("Note editing")
        } footer: {
            Text("Adds three tools: create a note, add to the end of a note, and add a link under a note's Related heading. They only touch .md files inside your notes folders, never replace or delete text, and refuse to write if the file changed since the client read it. Most clients ask you before each write.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Log

    private var logSection: some View {
        Section {
            Toggle("Keep a log of what's served", isOn: $mcp.keepLog)
            if log.isEmpty {
                Text("Nothing served yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(log.prefix(40)) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.detail.isEmpty ? e.name : "\(e.name)  \(e.detail)")
                            .lineLimit(1)
                        Text(logLine(e)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .help(e.titles.joined(separator: "\n"))
                }
            }
            HStack {
                Button("Clear log") { MCPLog.clear(root: Paths.root); log = [] }
                    .disabled(log.isEmpty)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([MCPLog.file(Paths.root)])
                }
                .disabled(log.isEmpty)
            }
        } header: {
            Text("Served to AI clients")
        } footer: {
            Text("Hover an entry to see the titles that went out.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func logLine(_ e: MCPLogEntry) -> String {
        var parts = [e.client, e.at.formatted(date: .abbreviated, time: .shortened)]
        parts.append(e.served == 1 ? "1 item" : "\(e.served) items")
        if e.hidden > 0 { parts.append("\(e.hidden) left out") }
        return parts.joined(separator: "  |  ")
    }

    private func reload() {
        mcp = MCPSettings.load(root: Paths.root)
        log = MCPLog.read(root: Paths.root, limit: 60)
        let reader = KnowledgeReader(root: Paths.root)
        counts = reader.switchCounts()
        let known = Set(MCPSources.builtIn.map { $0.id })
        extraSources = counts.keys.filter { !known.contains($0) }.sorted()
        reader.close()
    }
}

private struct Step: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
    }
}

/// Raw text to paste somewhere else, with a copy button. Monospace, since it's code.
private struct CopyBlock: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}
