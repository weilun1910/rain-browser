import AppKit
import SwiftUI

/// Settings for the on-device models: what's downloaded, progress, and what's in use.
struct ModelsSettings: View {
    @ObservedObject var store = ModelStore.shared
    @State private var counts: [EmbedderID: Int] = [:]
    @State private var passages = 0
    let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                ForEach(ModelCatalog.all) { spec in
                    ModelRow(spec: spec, state: store.state(spec))
                }
                HStack {
                    if !store.allReady {
                        Button(store.anyBusy ? "Downloading..." : "Download models") { store.downloadAll() }
                            .disabled(store.anyBusy)
                    }
                    if store.anyBusy { Button("Pause") { store.pause() } }
                    Spacer()
                    Text("\(ByteCountFormatter.string(fromByteCount: ModelCatalog.totalBytes, countStyle: .file)) in all")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("On-device models")
            } footer: {
                Text("Both models run on this Mac through llama.cpp. They're downloaded once from Hugging Face, checked against their published checksums, and kept in this profile's support folder. A paused download picks up where it stopped. Until they're ready, Related uses Apple's built-in embedding.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("In use") {
                LabeledContent("Embedding", value: Intelligence.shared.documentEmbedder.label)
                LabeledContent("Reranker", value: Intelligence.shared.hasReranker ? ModelCatalog.reranker.name : "Not ready")
                LabeledContent("Apple Foundation Models", value: ReasonWriter.availabilityText)
                LabeledContent("Passages") {
                    Text(vectorText).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    var vectorText: String {
        let parts = EmbedderID.allCases.compactMap { id -> String? in
            guard let n = counts[id], n > 0 else { return nil }
            return "\(n) by \(id == .gemma ? "EmbeddingGemma" : id == .contextual ? "Apple contextual" : "Apple sentence")"
        }
        return parts.isEmpty ? "\(passages)" : "\(passages) total, " + parts.joined(separator: ", ")
    }

    func refresh() {
        guard IndexStore.shared != nil else { return }
        Task.detached {
            let c = IndexStore.shared.vectorCounts()
            let p = IndexStore.shared.passageCount()
            await MainActor.run { counts = c; passages = p }
        }
    }
}

struct ModelRow: View {
    let spec: ModelSpec
    let state: ModelStore.State
    @ObservedObject var store = ModelStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(spec.name)
                    Text("\(spec.summary) \(spec.licence), \(ByteCountFormatter.string(fromByteCount: spec.bytes, countStyle: .file)).")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text(statusText).font(.caption).foregroundStyle(.secondary)
                if state == .ready {
                    Button("Remove") { store.remove(spec) }
                }
            }
            if case .downloading(let done, let total) = state, total > 0 {
                ProgressView(value: Double(done), total: Double(total))
            }
        }
    }

    var statusText: String {
        switch state {
        case .missing: return "Not downloaded"
        case .partial(let n): return "Paused at \(Int(Double(n) / Double(spec.bytes) * 100))%"
        case .downloading(let d, let t): return "\(Int(Double(d) / Double(max(t, 1)) * 100))%"
        case .verifying: return "Checking"
        case .ready: return "Ready"
        case .failed(let why): return why
        }
    }
}

/// The Notion, Google Docs and Granola sections of the Sources tab.
struct NewSourcesSettings: View {
    @ObservedObject var sources = SourceSettings.shared
    @ObservedObject var sync = SourceSync.shared

    func toggle(_ kp: WritableKeyPath<SourceConfig, Bool>, then: @escaping () -> Void) -> Binding<Bool> {
        Binding(get: { sources.published[keyPath: kp] }, set: { v in
            SourceSettings.shared.update { $0[keyPath: kp] = v }
            if v { then() }
        })
    }

    var body: some View {
        Section {
            Toggle("Read pages from the Notion app", isOn: toggle(\.notionEnabled) { sync.syncNotion() })
            statusLine(sources.published.notionStatus, at: sources.published.notionSyncedAt, running: sync.running.contains("notion"))
            if (sources.published.notionStatus ?? "").contains("Privacy & Security") { PermissionButton() }
            if sources.published.notionEnabled {
                Button("Sync now") { sync.syncNotion() }.disabled(sync.running.contains("notion"))
            }
        } header: {
            Text("Notion")
        } footer: {
            Text("Reads a copy of the Notion desktop app's local cache, which holds the pages you've opened in Notion on this Mac. The copy is deleted after reading. Nothing is sent anywhere, and Notion's files are never changed. macOS may ask once before this app can read Notion's data.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            Toggle("Refresh Google Docs I've opened", isOn: toggle(\.googleDocsEnabled) { sync.syncGoogleDocs() })
            statusLine(sources.published.googleDocsStatus, at: sources.published.googleDocsSyncedAt, running: sync.running.contains("gdocs"))
            if sources.published.googleDocsEnabled {
                Button("Sync now") { sync.syncGoogleDocs() }.disabled(sync.running.contains("gdocs"))
            }
        } header: {
            Text("Google Docs, Sheets and Slides")
        } footer: {
            Text("Takes the documents in your history here and in your Chrome import, and downloads each one's plain-text export with this browser's Google sign-in, the same as File > Download. Up to 40 documents per run, each at most once a day. It reads only, and only from Google.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            HStack {
                if GranolaSource.isConnected {
                    Toggle("Bring in my Granola meeting notes", isOn: toggle(\.granolaEnabled) { sync.syncGranola() })
                    Button("Disconnect") {
                        GranolaSource.disconnect()
                        SourceSettings.shared.update { $0.granolaEnabled = false; $0.granolaStatus = "Disconnected." }
                    }
                } else {
                    Button(sync.running.contains("granola") ? "Waiting for sign-in..." : "Connect Granola") { sync.connectGranola() }
                        .disabled(sync.running.contains("granola"))
                }
            }
            statusLine(sources.published.granolaStatus, at: sources.published.granolaSyncedAt, running: sync.running.contains("granola") && GranolaSource.isConnected)
            if GranolaSource.isConnected && sources.published.granolaEnabled {
                Button("Sync now") { sync.syncGranola() }.disabled(sync.running.contains("granola"))
            }
        } header: {
            Text("Granola")
        } footer: {
            Text("Granola encrypts its notes on your Mac, so this uses Granola's official connection instead. Connect opens Granola's sign-in in your browser; there's no key to paste. It then reads your recent meetings' notes and summaries, read-only, and keeps them in this browser's index. The sign-in stays in this profile's folder.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    func statusLine(_ status: String?, at: Date?, running: Bool) -> some View {
        if running {
            Text("Syncing...").font(.caption).foregroundStyle(.secondary)
        } else if let status {
            Text((at.map { "\(Fmt.day($0)): " } ?? "") + status).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PermissionButton: View {
    var body: some View {
        Button("Open System Settings") {
            for s in ChromeHistory.settingsURLs {
                if let u = URL(string: s), NSWorkspace.shared.open(u) { break }
            }
        }
    }
}

/// One quiet line in the Related panel while the models download.
struct ModelProgressLine: View {
    @ObservedObject var store = ModelStore.shared

    var body: some View {
        if let p = store.overallProgress {
            HStack(spacing: 6) {
                ProgressView(value: p).progressViewStyle(.linear).frame(width: 60).controlSize(.mini)
                Text("Getting on-device models ready, \(Int(p * 100))%")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
