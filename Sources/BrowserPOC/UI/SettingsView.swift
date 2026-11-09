import AppKit
import SwiftUI

struct SettingsView: View {
    enum Pane: Hashable { case general, browsing, sources, models, tuning, aiClients }
    /// The tab the window opens on. The README screenshot tour opens it on AI clients.
    nonisolated(unsafe) static var initialTab: Pane = .general
    @State private var pane: Pane = SettingsView.initialTab

    var body: some View {
        TabView(selection: $pane) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag(Pane.general)
            BrowsingSettings().tabItem { Label("Browsing", systemImage: "sidebar.left") }.tag(Pane.browsing)
            SourcesSettings().tabItem { Label("Sources", systemImage: "tray.full") }.tag(Pane.sources)
            ModelsSettings().tabItem { Label("Models", systemImage: "cpu") }.tag(Pane.models)
            TuningSettings().tabItem { Label("Tuning", systemImage: "slider.horizontal.3") }.tag(Pane.tuning)
            AIClientsSettings().tabItem { Label("AI clients", systemImage: "point.3.connected.trianglepath.dotted") }.tag(Pane.aiClients)
        }
        .frame(width: 580, height: 620)
    }
}

struct GeneralSettings: View {
    @ObservedObject var settings = Settings.shared
    @State private var excludeText = ""
    @State private var excludeSaved = false
    @State private var writingText = ""
    @State private var writingSaved = false

    var body: some View {
        Form {
            Section("Search") {
                LabeledContent("Default search", value: "Google")
            }
            RelatedLayoutSection()
            Section {
                TextEditor(text: $excludeText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 120)
                HStack {
                    Button("Save list") {
                        let list = excludeText.split(whereSeparator: { $0.isNewline || $0 == "," })
                            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                            .filter { !$0.isEmpty }
                        Settings.shared.update { $0.excludedDomains = list }
                        let s = Settings.shared.value
                        Task.detached { IndexStore.shared.deleteExcluded { s.isExcluded(host: $0) } }
                        excludeSaved = true
                    }
                    Button("Restore defaults") { excludeText = AppSettings.defaultExcluded.joined(separator: "\n") }
                    if excludeSaved { Text("Saved").font(.caption).foregroundStyle(.secondary) }
                }
            } header: {
                Text("Never index these sites")
            } footer: {
                Text("One domain per line. Subdomains count too. Saving also removes matching pages already in the index.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                TextEditor(text: $writingText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 100)
                HStack {
                    Button("Save list") {
                        let list = writingText.split(whereSeparator: { $0.isNewline || $0 == "," })
                            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                            .filter { !$0.isEmpty }
                        Settings.shared.update { $0.writingSites = list }
                        AppDelegate.shared?.model.resurfacer.settingsChanged()
                        writingSaved = true
                    }
                    Button("Restore defaults") { writingText = AppSettings.defaultWritingSites.joined(separator: "\n") }
                    if writingSaved { Text("Saved").font(.caption).foregroundStyle(.secondary) }
                }
            } header: {
                Text("Sites you write on")
            } footer: {
                Text("Related shows these under Notes / Docs instead of Sites. Notion and Google Docs, Sheets and Slides always count, and so does any page where you've typed about 200 characters. One per line, like coda.io or *.atlassian.net/wiki. You can also move a single card from its right-click menu.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("On-device models") {
                LabeledContent("Apple Foundation Models", value: ReasonWriter.availabilityText)
                LabeledContent("Embedding", value: Intelligence.shared.documentEmbedder.label)
                LabeledContent("Reranker", value: Intelligence.shared.hasReranker ? ModelCatalog.reranker.name : "Not downloaded yet. See Models.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            excludeText = settings.published.excludedDomains.joined(separator: "\n")
            writingText = settings.published.writingSites.joined(separator: "\n")
        }
        .onChange(of: excludeText) { excludeSaved = false }
        .onChange(of: writingText) { writingSaved = false }
    }

}

struct SourcesSettings: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var chrome = ChromeImporter.shared
    @ObservedObject var notes: NotesStore = AppDelegate.shared?.model.notes ?? NotesStore()
    @State private var counts: [SourceCount] = []
    @State private var rootCounts: [String: Int] = [:]
    let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                HStack {
                    Button(chrome.isRunning ? "Importing..." : "Import Chrome history") { chrome.start() }
                        .disabled(chrome.isRunning)
                    if chrome.isRunning { Button("Stop") { chrome.cancel() } }
                }
                if case .fetching(let done, let total) = chrome.phase, total > 0 {
                    ProgressView(value: Double(done), total: Double(total))
                }
                if chrome.phase == .needsPermission {
                    ChromePermissionHelp()
                } else if chrome.phase != .idle {
                    Text(ChromeStatus.text(chrome.phase)).font(.caption).foregroundStyle(.secondary)
                } else if let s = settings.published.chromeSummary, let at = settings.published.chromeImportedAt {
                    Text("Last import \(Fmt.day(at)): \(s)").font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Chrome history")
            } footer: {
                Text("Reads a copy of Chrome's Default profile history from the last 90 days, up to 2,000 pages, plus your past searches. Page text is fetched without cookies for the 300 most visited pages you opened at least twice, skipping sign-in, unsubscribe and similar links and logged-in apps. macOS asks once before this app can read Chrome's data, and may ask again after the app is rebuilt.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            NewSourcesSettings()

            Section {
                if settings.published.notesFolders.isEmpty {
                    Text("No folders chosen. Notes go in the app's own folder for now.")
                        .foregroundStyle(.secondary)
                }
                ForEach(settings.published.notesFolders, id: \.self) { root in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(URL(fileURLWithPath: root).lastPathComponent)
                            Text(root).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text("\(rootCounts[root] ?? 0) notes").font(.caption).foregroundStyle(.secondary)
                        Button("Remove") { SourcesActions.removeNotesFolder(root) }
                    }
                }
                HStack {
                    Button("Add folder...") { SourcesActions.addNotesFolders() }
                    Button("Link folder...") { SourcesActions.linkFolder() }
                        .disabled(SpaceFolders.root == nil)
                        .help("Puts a link to a Markdown folder in the current space's folder. Nothing is copied.")
                    Button("Rescan") { notes.reload() }
                }
                LabeledContent("New notes go in") {
                    HStack {
                        Text(settings.published.defaultNewNotesFolder.lastPathComponent)
                            .foregroundStyle(.secondary)
                            .help(settings.published.defaultNewNotesFolder.path)
                        Button("Change...") { pickNewNotesFolder() }
                    }
                }
                if !notes.status.isEmpty { Text(notes.status).font(.caption).foregroundStyle(.secondary) }
            } header: {
                Text("Notes folders")
            } footer: {
                Text("Every .md file in these folders is one of your notes, and you can edit them here. Hidden folders, node_modules, .build and .nosync folders are left out. Notes save as you type, but never over a file that changed on disk since you opened it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Index") {
                ForEach([SourceType.web, .note, .chrome, .notion, .gdocs, .granola], id: \.self) { s in
                    let c = counts.first { $0.source == s }
                    LabeledContent(Self.name(s)) {
                        Text(Self.countText(s, c)).foregroundStyle(.secondary)
                    }
                }
                Button("Clear search history...") {
                    if Prompt.confirm(title: "Clear search history?", message: "This removes past searches from the command bar, including ones brought in from Chrome.", ok: "Clear") {
                        Task.detached { IndexStore.shared.clearSearches() }
                    }
                }
                Button("Clear index...") {
                    if Prompt.confirm(title: "Clear the index?",
                                      message: "This removes every page, note and Chrome entry from the index. Your note files stay exactly as they are.",
                                      ok: "Clear") {
                        Task.detached {
                            IndexStore.shared.clearAll()
                            await MainActor.run {
                                Settings.shared.update { $0.chromeSummary = nil; $0.chromeImportedAt = nil }
                                refresh()
                                AppDelegate.shared?.model.resurfacer.refresh(replace: true)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    func pickNewNotesFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Use folder"
        p.directoryURL = settings.published.defaultNewNotesFolder
        guard p.runModal() == .OK, let u = p.url else { return }
        let roots = Settings.shared.value.notesRoots
        guard roots.contains(where: { FileSafety.isInside(u, $0) || $0.standardizedFileURL.path == u.standardizedFileURL.path }) else {
            Prompt.info(title: "Pick a folder inside your notes folders", message: "New notes have to go somewhere the app shows as notes.")
            return
        }
        Settings.shared.update { $0.newNotesFolder = u.standardizedFileURL.path }
    }

    static func name(_ s: SourceType) -> String {
        switch s {
        case .web: return "Pages read here"
        case .note: return "Notes"
        case .markdown: return "Notes (older entries)"
        case .chrome: return "Chrome history"
        case .notion: return "Notion pages"
        case .gdocs: return "Google Docs"
        case .granola: return "Granola meetings"
        }
    }

    static func countText(_ s: SourceType, _ c: SourceCount?) -> String {
        guard let c else { return "0" }
        if s == .chrome { return "\(c.total), \(c.withText) with text" }
        return "\(c.total)"
    }

    func refresh() {
        let roots = settings.published.notesFolders
        Task.detached {
            let c = IndexStore.shared.counts()
            var rc: [String: Int] = [:]
            for r in roots { rc[r] = IndexStore.shared.count(root: r) }
            let snapshot = rc
            await MainActor.run { counts = c; rootCounts = snapshot }
        }
    }
}

struct TuningSettings: View {
    @ObservedObject var settings = Settings.shared

    func binding(_ kp: WritableKeyPath<AppSettings, Double>) -> Binding<Double> {
        Binding(get: { settings.published[keyPath: kp] },
                set: { v in
                    Settings.shared.update { $0[keyPath: kp] = v }
                    AppDelegate.shared?.model.resurfacer.settingsChanged()
                })
    }

    var body: some View {
        Form {
            Section {
                SliderRow(title: "Relevance threshold", value: binding(\.threshold), range: 0.1...0.9)
            } footer: {
                Text("Higher means fewer, stronger cards. Candidates come from keywords, meaning and shared names together. With the models downloaded, a reranker reads each one next to what you have open and this slider sets the score it must reach. Apple's on-device model then checks the borderline ones.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Show scores on cards", isOn: Binding(get: { settings.published.showScores },
                                                             set: { v in Settings.shared.update { $0.showScores = v } }))
                Button("Reset to defaults") {
                    let d = AppSettings()
                    Settings.shared.update {
                        $0.threshold = d.threshold
                        $0.keywordWeight = d.keywordWeight
                        $0.semanticWeight = d.semanticWeight
                        $0.entityWeight = d.entityWeight
                    }
                    AppDelegate.shared?.model.resurfacer.settingsChanged()
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack {
            Text(title).frame(width: 150, alignment: .leading)
            Slider(value: $value, in: range)
            Text(String(format: "%.2f", value))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }
}
