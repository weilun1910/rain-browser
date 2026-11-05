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
    @ObservedObject var prefs = BrowserPrefs.shared
    /// Compact mode: the sidebar is showing because the pointer reached the edge.
    @State private var peeking = false
    @State private var hideWork: DispatchWorkItem?

    static let sidebarWidth: CGFloat = 252
    static let panelWidth: CGFloat = 300

    @MainActor static func host(_ model: BrowserModel) -> NSView {
        NSHostingView(rootView: MainView().environmentObject(model))
    }

    var hidden: Bool { prefs.value.sidebarHidden }
    var right: Bool { prefs.value.sidebarOnRight }

    var body: some View {
        HStack(spacing: 0) {
            if right { panel(leading: true) } else { sidebarSlot }
            ContentArea()
                .padding(.vertical, 8)
                .padding(.top, right && !hidden ? 22 : 0)
                .padding(.leading, (hidden && !right) || (right && !settings.published.rightPanelOpen) ? 8 : 0)
                .padding(.trailing, (hidden && right) || (!right && !settings.published.rightPanelOpen) ? 8 : 0)
            if right { sidebarSlot } else { panel(leading: false) }
        }
        .background(VisualEffect().ignoresSafeArea())
        .overlay(alignment: right ? .trailing : .leading) { compactSidebar }
        .overlay {
            CommandBarOverlay(bar: model.bar,
                              leadingClear: hidden || right ? 0 : Self.sidebarWidth,
                              trailingClear: hidden || !right ? 0 : Self.sidebarWidth)
        }
        .overlay { if let s = model.switcher { SwitcherOverlay(state: s) } }
        .background(TrafficLights(hidden: hidden && !peeking))
        .ignoresSafeArea()
        .frame(minWidth: 900, minHeight: 560)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: hidden)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: right)
    }

    @ViewBuilder var sidebarSlot: some View {
        if !hidden {
            LeftSidebar().frame(width: Self.sidebarWidth)
                .transition(.move(edge: right ? .trailing : .leading).combined(with: .opacity))
        }
    }

    @ViewBuilder func panel(leading: Bool) -> some View {
        if settings.published.rightPanelOpen {
            RightPanel().frame(width: Self.panelWidth)
        }
    }

    /// Compact mode: a thin edge that brings the sidebar back as an overlay. It hides one second
    /// after the pointer leaves, like Zen.
    @ViewBuilder var compactSidebar: some View {
        if hidden {
            ZStack(alignment: right ? .trailing : .leading) {
                Color.clear.frame(width: 6).contentShape(Rectangle())
                    .onHover { if $0 { show() } }
                if peeking {
                    LeftSidebar()
                        .frame(width: Self.sidebarWidth)
                        .background(VisualEffect(material: .sidebar).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous)))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: .black.opacity(0.2), radius: 18, x: right ? -4 : 4)
                        .padding(6)
                        .onHover { inside in if inside { show() } else { scheduleHide() } }
                        .transition(.move(edge: right ? .trailing : .leading).combined(with: .opacity))
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    func show() {
        hideWork?.cancel()
        if !peeking { withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) { peeking = true } }
    }

    func scheduleHide() {
        hideWork?.cancel()
        let w = DispatchWorkItem { withAnimation(.easeOut(duration: 0.2)) { peeking = false } }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: w)
    }
}

/// Hides the window buttons in compact mode, so they don't sit on top of the page.
struct TrafficLights: NSViewRepresentable {
    let hidden: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async {
            for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                v.window?.standardWindowButton(b)?.isHidden = hidden
            }
        }
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
    var leadingClear: CGFloat = 0
    var trailingClear: CGFloat = 0
    var body: some View {
        ZStack {
            if bar.isOpen { CommandBarView(bar: bar, leadingClear: leadingClear, trailingClear: trailingClear) }
        }
        .animation(.easeOut(duration: 0.14), value: bar.isOpen)
    }
}

struct ContentArea: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var settings = Settings.shared

    @State private var dropTarget: DropTarget?
    @State private var frames: [UUID: CGRect] = [:]

    var body: some View {
        GeometryReader { g in
            ZStack {
                Group {
                    if let sp = model.currentSplit, sp.items.allSatisfy({ model.tab($0) != nil }) {
                        SplitPanes(split: sp)
                    } else {
                        PaneView(tab: model.currentTab).paneCard()
                    }
                }
                .scaleEffect(model.peek == nil ? 1 : 0.985)
                .animation(.spring(response: 0.32, dampingFraction: 0.86), value: model.peek == nil)
                if let t = dropTarget {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1))
                        .frame(width: t.preview.width, height: t.preview.height)
                        .position(x: t.preview.midX, y: t.preview.midY)
                        .allowsHitTesting(false)
                        .animation(.easeOut(duration: 0.12), value: t)
                }
                if model.find.visible, model.currentWebTab != nil {
                    FindBar()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(.top, findTop)
                        .padding(.trailing, findTrailing(width: g.size.width))
                }
                if let p = model.peek {
                    PeekOverlay(peek: p).id(p.tab.id)
                }
                if let t = model.toastState {
                    ToastView(toast: t)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .id(t.id)
                }
                if !settings.published.firstRunDone {
                    FirstRunPanel().clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
            }
            .animation(.easeOut(duration: 0.18), value: model.toastState)
            .coordinateSpace(name: "content")
            .onPreferenceChange(PaneFramesKey.self) { frames = $0 }
            .onDrop(of: [ItemDrag.type], delegate: ContentDropDelegate(frames: model.currentSplit == nil ? [:] : frames,
                                                                      bounds: CGRect(origin: .zero, size: g.size),
                                                                      target: $dropTarget, model: model))
        }
    }

    /// The find bar sits at the top right of the focused pane.
    var findTop: CGFloat {
        if let id = model.currentTab?.id, let f = frames[id], model.currentSplit != nil { return f.minY + 10 }
        return 10
    }

    func findTrailing(width: CGFloat) -> CGFloat {
        if let id = model.currentTab?.id, let f = frames[id], model.currentSplit != nil { return width - f.maxX + 10 }
        return 10
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
