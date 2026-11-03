import AppKit
import SwiftUI
import WebKit

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

struct MainView: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var settings = Settings.shared

    @MainActor static func host(_ model: BrowserModel) -> NSView {
        NSHostingView(rootView: MainView().environmentObject(model))
    }

    var body: some View {
        HStack(spacing: 0) {
            LeftSidebar()
                .frame(width: 252)
            ContentArea()
                .padding(.vertical, 8)
                .padding(.trailing, settings.published.rightPanelOpen ? 0 : 8)
            if settings.published.rightPanelOpen {
                RightPanel()
                    .frame(width: 300)
            }
        }
        .background(VisualEffect().ignoresSafeArea())
        .overlay { CommandBarOverlay(bar: model.bar) }
        .ignoresSafeArea()
        .frame(minWidth: 900, minHeight: 560)
    }
}

/// Empty space that drags the window, like a title bar.
struct WindowDragArea: View {
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
    }
}

struct CommandBarOverlay: View {
    @ObservedObject var bar: CommandBar
    var body: some View {
        if bar.isOpen { CommandBarView(bar: bar) }
    }
}

struct ContentArea: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var settings = Settings.shared

    @State private var dropSide: PaneSide?

    var body: some View {
        GeometryReader { g in
            ZStack {
                if let sp = model.currentSplit, let l = model.tab(sp.left), let r = model.tab(sp.right) {
                    SplitPanes(split: sp, left: l, right: r, width: g.size.width)
                } else {
                    PaneView(tab: model.currentTab).paneCard()
                }
                if let side = dropSide {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 9).fill(Color.accentColor.opacity(side == .left ? 0.12 : 0))
                        RoundedRectangle(cornerRadius: 9).fill(Color.accentColor.opacity(side == .right ? 0.12 : 0))
                    }
                    .allowsHitTesting(false)
                }
                if !settings.published.firstRunDone {
                    FirstRunPanel().clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
            }
            .onDrop(of: [ItemDrag.type], delegate: PaneDropDelegate(width: g.size.width, side: $dropSide, model: model))
        }
    }
}

/// A note item: the editor, or the missing-file view.
struct NotePane: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        if tab.isMissing && (tab.url.map { model.docs[$0.standardizedFileURL.path] == nil } ?? true) {
            MissingNoteView(tab: tab)
        } else if let u = tab.url {
            NoteEditorView(doc: model.doc(for: u))
                .id(u.standardizedFileURL.path)
        }
    }
}

/// Watches the tab itself, so a blank tab switches to the page as soon as it gets a URL.
struct TabContent: View {
    @ObservedObject var tab: Tab
    var body: some View {
        if tab.url == nil && !tab.isLoaded { StartView() } else { WebArea(tab: tab) }
    }
}

struct WebArea: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        ZStack(alignment: .top) {
            WebContainer(tab: tab)
            if tab.isLoading && tab.progress < 1 {
                GeometryReader { g in
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.7))
                        .frame(width: max(8, g.size.width * tab.progress), height: 2)
                }
                .frame(height: 2)
                .allowsHitTesting(false)
            }
            if let err = tab.loadError {
                VStack(spacing: 10) {
                    Text("Couldn't open this page").font(.title3.weight(.semibold))
                    Text(err).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                    Button("Try again") { model.reload() }
                }
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }
}

final class WebHostView: NSView {
    private weak var current: WKWebView?

    func show(_ wv: WKWebView) {
        guard current !== wv else { return }
        current?.removeFromSuperview()
        wv.frame = bounds
        wv.autoresizingMask = [.width, .height]
        addSubview(wv)
        current = wv
    }
}

struct WebContainer: NSViewRepresentable {
    let tab: Tab

    func makeNSView(context: Context) -> WebHostView { WebHostView() }

    func updateNSView(_ v: WebHostView, context: Context) {
        v.show(tab.ensureWebView())
    }
}

struct StartView: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        VStack(spacing: 14) {
            Text("Search or enter an address")
                .font(.title3)
                .foregroundStyle(.tertiary)
            HStack(spacing: 18) {
                Button("New tab") { model.newTabCommand() }
                Button("New note") { model.newNote() }
            }
            .buttonStyle(.link)
            .font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FirstRunPanel: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var chrome = ChromeImporter.shared
    @ObservedObject var settings = Settings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Start with what you've already seen")
                .font(.title2.weight(.semibold))
            Text("Cards on the right come from pages and notes you've looked at before. Pick the folders that hold your notes and bring in your Chrome history now, or later in Settings.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Button("Import Chrome history") { chrome.start() }
                    .disabled(chrome.isRunning)
                Text("Reads a copy of your Chrome history from the last 90 days. Text is fetched without cookies, only for pages you opened at least twice.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if chrome.phase == .needsPermission {
                    ChromePermissionHelp()
                } else if chrome.phase != .idle {
                    Text(ChromeStatus.text(chrome.phase)).font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Button("Choose notes folders...") { SourcesActions.addNotesFolders() }
                Text("The .md files in these folders become your notes here. You can open and edit them like any note, and new notes go in the first folder.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !Settings.shared.value.usesFallbackNotes {
                    Text(Settings.shared.value.notesFolders.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Done") { Settings.shared.update { $0.firstRunDone = true } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.15), radius: 20, y: 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.04))
    }
}

enum ChromeStatus {
    static func text(_ p: ChromeImporter.Phase) -> String {
        switch p {
        case .idle: return ""
        case .reading: return "Reading Chrome history..."
        case .fetching(let done, let total): return "Reading page text: \(done) of \(total)"
        case .finished(let s): return s
        case .needsPermission: return ""
        case .failed(let e): return "Couldn't import: \(e)"
        }
    }
}

/// Explains the one macOS permission Chrome import needs, with a way to fix it.
struct ChromePermissionHelp: View {
    @ObservedObject var chrome = ChromeImporter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Browser POC needs your OK to read Chrome's history")
                .font(.system(size: 12, weight: .semibold))
            Text("macOS asks before one app reads another app's data. If a prompt came up, click Allow, then try again. If you clicked Don't Allow or no prompt came up, open System Settings, go to Privacy & Security, then Files & Folders, find Browser POC and turn on Google Chrome.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open System Settings") {
                    for s in ChromeHistory.settingsURLs {
                        if let u = URL(string: s), NSWorkspace.shared.open(u) { break }
                    }
                }
                Button("Try again") { chrome.start() }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

@MainActor
enum SourcesActions {
    static func addNotesFolders() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = true
        p.prompt = "Use as notes"
        p.message = "Pick the folders that hold your Markdown notes."
        let desk = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Desktop")
        if FileManager.default.fileExists(atPath: desk.path) { p.directoryURL = desk }
        guard p.runModal() == .OK else { return }
        let paths = p.urls.map { $0.standardizedFileURL.path }
        Settings.shared.update { s in
            for path in paths where !s.notesFolders.contains(path) { s.notesFolders.append(path) }
        }
        AppDelegate.shared?.model.notes.reload()
    }

    static func removeNotesFolder(_ path: String) {
        Settings.shared.update { s in
            s.notesFolders.removeAll { $0 == path }
            if s.newNotesFolder.map({ FileSafety.isInside(URL(fileURLWithPath: $0), URL(fileURLWithPath: path)) || $0 == path }) == true {
                s.newNotesFolder = nil
            }
        }
        Task.detached { IndexStore.shared.deleteRoot(path) }
        AppDelegate.shared?.model.notes.reload()
        AppDelegate.shared?.model.checkNotesOnDisk()
    }
}
