import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            SourcesSettings().tabItem { Label("Sources", systemImage: "tray.full") }
            TuningSettings().tabItem { Label("Tuning", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 580, height: 620)
    }
}

struct GeneralSettings: View {
    @ObservedObject var settings = Settings.shared
    @State private var excludeText = ""
    @State private var excludeSaved = false

    var body: some View {
        Form {
            Section("Notes") {
                LabeledContent("Folder") {
                    Text(settings.published.notesDir.path)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Change...") { pickNotesFolder() }
                    Button("Use default") { setNotesFolder(nil) }
                        .disabled(settings.published.notesFolder == nil)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([settings.published.notesDir]) }
                }
            }
            Section("Search") {
                LabeledContent("Default search", value: "Google")
            }
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
            Section("On-device model") {
                LabeledContent("Apple Foundation Models", value: ReasonWriter.availabilityText)
                LabeledContent("Sentence embeddings", value: Embedder.shared.isAvailable ? "available" : "not available")
            }
        }
        .formStyle(.grouped)
        .onAppear { excludeText = settings.published.excludedDomains.joined(separator: "\n") }
        .onChange(of: excludeText) { excludeSaved = false }
    }

    func pickNotesFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Use folder"
        guard p.runModal() == .OK, let u = p.url else { return }
        setNotesFolder(u.path)
    }

    func setNotesFolder(_ path: String?) {
        Settings.shared.update { $0.notesFolder = path }
        AppDelegate.shared?.model.notes.reload()
        Indexer.syncNotes(dir: Settings.shared.value.notesDir)
    }
}

struct SourcesSettings: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var chrome = ChromeImporter.shared
    @ObservedObject var md = MarkdownIndexer.shared
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
                if chrome.phase != .idle {
                    Text(ChromeStatus.text(chrome.phase)).font(.caption).foregroundStyle(.secondary)
                } else if let s = settings.published.chromeSummary, let at = settings.published.chromeImportedAt {
                    Text("Last import \(Fmt.day(at)): \(s)").font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Chrome history")
            } footer: {
                Text("Reads a copy of Chrome's Default profile history from the last 90 days, up to 2,000 pages. Page text is fetched without cookies for the 300 most visited pages you opened at least twice, skipping sign-in, unsubscribe and similar links and logged-in apps.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if settings.published.markdownRoots.isEmpty {
                    Text("No folders added").foregroundStyle(.secondary)
                }
                ForEach(settings.published.markdownRoots, id: \.self) { root in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(URL(fileURLWithPath: root).lastPathComponent)
                            Text(root).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text("\(rootCounts[root] ?? 0) files").font(.caption).foregroundStyle(.secondary)
                        Button("Remove") { md.removeRoot(root) }
                    }
                }
                HStack {
                    Button("Add folders...") { SourcesActions.addMarkdownFolders() }
                    Button("Rescan") { md.rescanAll() }
                        .disabled(settings.published.markdownRoots.isEmpty || md.running)
                }
                if !md.status.isEmpty { Text(md.status).font(.caption).foregroundStyle(.secondary) }
            } header: {
                Text("Markdown folders")
            } footer: {
                Text("Files are only read, never changed. Skips .git, node_modules, .build and any .nosync folder. Rescans on launch.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Index") {
                ForEach(SourceType.allCases, id: \.self) { s in
                    let c = counts.first { $0.source == s }
                    LabeledContent(Self.name(s)) {
                        Text(Self.countText(s, c)).foregroundStyle(.secondary)
                    }
                }
                Button("Clear index...") {
                    if Prompt.confirm(title: "Clear the index?",
                                      message: "This removes every captured page, note entry, Markdown entry and Chrome entry from the index. Your notes and Markdown files stay as they are.",
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

    static func name(_ s: SourceType) -> String {
        switch s {
        case .web: return "Pages read here"
        case .note: return "Notes"
        case .markdown: return "Markdown files"
        case .chrome: return "Chrome history"
        }
    }

    static func countText(_ s: SourceType, _ c: SourceCount?) -> String {
        guard let c else { return "0" }
        if s == .chrome { return "\(c.total), \(c.withText) with text" }
        return "\(c.total)"
    }

    func refresh() {
        let roots = settings.published.markdownRoots
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
                Text("Higher means fewer, stronger cards.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Signal weights") {
                SliderRow(title: "Keywords", value: binding(\.keywordWeight), range: 0...2)
                SliderRow(title: "Meaning", value: binding(\.semanticWeight), range: 0...2)
                SliderRow(title: "People, orgs, places", value: binding(\.entityWeight), range: 0...2)
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
