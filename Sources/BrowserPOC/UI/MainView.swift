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

    static let sidebarWidth: CGFloat = Theme.Space.sidebarWidth
    static let panelWidth: CGFloat = Theme.Space.panelWidth

    @MainActor static func host(_ model: BrowserModel) -> NSView {
        NSHostingView(rootView: MainView().environmentObject(model))
    }

    var hidden: Bool { prefs.value.sidebarHidden }
    var right: Bool { prefs.value.sidebarOnRight }

    var body: some View {
        HStack(spacing: 0) {
            if right { panel(leading: true) } else { sidebarSlot }
            ContentArea()
                .padding(.vertical, Theme.Space.windowMargin)
                .padding(.top, right && !hidden ? 22 : 0)
                .padding(.leading, (hidden && !right) || (right && !settings.published.rightPanelOpen) ? Theme.Space.windowMargin : 0)
                .padding(.trailing, (hidden && right) || (!right && !settings.published.rightPanelOpen) ? Theme.Space.windowMargin : 0)
            if right { sidebarSlot } else { panel(leading: false) }
        }
        // The frame: neutral grey with the space's colour on the sidebar's side, fading across.
        // It follows the sidebar's space strip, so a swipe carries the colour with it.
        .background(StripTintBackground(strip: SpaceStrip.of(model),
                                        sidebarWidth: hidden ? 0 : Self.sidebarWidth, fromTrailing: right))
        .overlay(alignment: right ? .trailing : .leading) { compactSidebar }
        .overlay {
            CommandBarOverlay(bar: model.bar,
                              leadingClear: hidden || right ? 0 : Self.sidebarWidth,
                              trailingClear: hidden || !right ? 0 : Self.sidebarWidth)
        }
        .overlay { if let s = model.switcher { SwitcherOverlay(state: s) } }
        .overlay { StartupOverlayHost() }
        .background(TrafficLights(hidden: hidden && !peeking))
        .spaceTint(model.currentSpace?.color)
        .ignoresSafeArea()
        .frame(minWidth: 900, minHeight: 560)
        .motion(Motion.panel, value: hidden)
        .motion(Motion.panel, value: right)
        .motion(Motion.panel, value: settings.published.rightPanelOpen)
    }

    @ViewBuilder var sidebarSlot: some View {
        if !hidden {
            LeftSidebar().frame(width: Self.sidebarWidth)
                .transition(Motion.Transitions.panel(edge: right ? .trailing : .leading))
        }
    }

    @ViewBuilder func panel(leading: Bool) -> some View {
        if settings.published.rightPanelOpen {
            // On the left it starts below the window buttons.
            RightPanel().frame(width: Self.panelWidth).padding(.top, leading ? 24 : 0)
                .transition(Motion.Transitions.panel(edge: leading ? .leading : .trailing))
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
                    // The sidebar floats over the page on the space's colour, like Zen's compact mode.
                    LeftSidebar()
                        .frame(width: Self.sidebarWidth)
                        .background(
                            ZStack {
                                Theme.Palette.sidebarColor(model.currentSpace?.color)
                                GrainOverlay()
                            }
                            .clipShape(Theme.Radius.shape(Theme.Radius.card))
                            .themeShadow(.floating)
                        )
                        .overlay(Theme.Radius.shape(Theme.Radius.card).strokeBorder(Theme.Palette.hairline, lineWidth: 0.5))
                        .clipShape(Theme.Radius.shape(Theme.Radius.card))
                        .padding(Theme.Space.windowMargin)
                        .onHover { inside in if inside { show() } else { scheduleHide() } }
                        .transition(Motion.Transitions.panel(edge: right ? .trailing : .leading))
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    func show() {
        hideWork?.cancel()
        if !peeking { Motion.run(Motion.panel) { peeking = true } }
    }

    func scheduleHide() {
        hideWork?.cancel()
        let w = DispatchWorkItem { Motion.run(Motion.remove) { peeking = false } }
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
            // The quiet dots go with them.
            if let w = v.window { WindowChrome.setTrafficLightsHidden(w, hidden) }
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
        // Always present: the backdrop and the panel come and go inside it on their own timings.
        CommandBarView(bar: bar, leadingClear: leadingClear, trailingClear: trailingClear)
    }
}

struct ContentArea: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var settings = Settings.shared

    @State private var dropTarget: DropTarget?
    @State private var frames: [UUID: CGRect] = [:]
    @Environment(\.spaceAccent) private var spaceAccent
    @ObservedObject private var peekMotion = PeekMotion.shared

    /// A Peek is up and not on its way out.
    var underPeek: Bool { model.peek != nil && peekMotion.phase != .closing }

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
                .relatedShelf(frame: RelatedShelf.paneFrame(model, frames: frames, size: g.size))
                // Under Peek the page settles back a touch and dims, like Zen's Glance. It comes back
                // as soon as the Peek starts to close.
                .scaleEffect(!underPeek || Motion.reduceMotion ? 1 : 0.985)
                .opacity(underPeek ? 0.7 : 1)
                .motion(peekMotion.phase == .closing ? Motion.peekOut : Motion.peek, value: underPeek)
                if let t = dropTarget {
                    Theme.Radius.shape(Theme.Radius.card)
                        .fill(spaceAccent.opacity(0.12))
                        .overlay(Theme.Radius.shape(Theme.Radius.card).strokeBorder(spaceAccent.opacity(0.5), lineWidth: 1))
                        .frame(width: t.preview.width, height: t.preview.height)
                        .position(x: t.preview.midX, y: t.preview.midY)
                        .allowsHitTesting(false)
                        .motion(Motion.hover, value: t)
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
                        .padding(.bottom, 18 + RelatedShelf.toastLift(model))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .id(t.id)
                }
                if !settings.published.firstRunDone {
                    FirstRunPanel().clipShape(Theme.Radius.shape(Theme.Radius.card))
                }
            }
            .motion(Motion.toast, value: model.toastState)
            // Where the last click landed, so a Peek opened by it can grow from there.
            .background(ClickRecorder())
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
    /// Whether this is Peek's copy of the page or a pane's.
    var role: WebHostRole = .pane
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        ZStack(alignment: .top) {
            WebContainer(tab: tab, role: role)
            TintedProgressLine(progress: tab.progress, visible: tab.isLoading && tab.progress < 1)
            if let err = tab.loadError {
                VStack(spacing: Theme.Space.m) {
                    Text("Couldn't open this page")
                        .font(Theme.Font.display(22))
                        .displayTracking()
                    Text(err)
                        .font(Theme.Font.row)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .frame(maxWidth: 420)
                    Button("Try again") { model.reload() }
                        .controlSize(.large)
                        .padding(.top, Theme.Space.m)
                }
                .padding(Theme.Space.x4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.Palette.card)
                .transition(.opacity)
            }
        }
    }
}

/// Hosts one page's web view in a pane, Peek or Little Arc.
///
/// A web view can only be in one place. Hosts come and go as splits change, as Peek becomes a tab
/// or a split, and as panes switch pages, and SwiftUI may still update a host that's on its way
/// out, or make one that never reaches the screen. So no host simply grabs its web view. Each
/// says which web view it wants, and of the hosts on screen that want it, the newest gets it. When
/// a host leaves the screen, its web view goes to the next one in line. Before this, an old host
/// could pull a web view back and take it away when it went, which left panes blank.
final class WebHostView: NSView {
    private weak var current: WKWebView?
    /// The web view this host was last asked to show.
    private(set) weak var wanted: WKWebView?
    private let serial: Int
    private static var made = 0
    private static let hosts = NSHashTable<WebHostView>.weakObjects()

    override init(frame: NSRect) {
        Self.made += 1
        serial = Self.made
        super.init(frame: frame)
        Self.hosts.add(self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ wv: WKWebView) {
        let before = wanted
        wanted = wv
        if let before, before !== wv { Self.place(before) }
        Self.place(wv)
    }

    /// This host no longer wants its web view, so the next host in line can have it.
    func letGo() {
        guard let wv = wanted else { return }
        wanted = nil
        Self.place(wv)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Moving a web view while AppKit is still moving this host in or out of the window leaves
        // WebKit thinking the page isn't on screen, and it stops drawing. So wait a turn.
        guard let wv = wanted else { return }
        DispatchQueue.main.async { Self.place(wv) }
    }

    /// Puts `wv` in the newest on-screen host that wants it. With none, it stays where it is.
    private static func place(_ wv: WKWebView) {
        let best = hosts.allObjects.filter { $0.wanted === wv && $0.window != nil }.max { $0.serial < $1.serial }
        best?.adopt(wv)
    }

    private func adopt(_ wv: WKWebView) {
        guard current !== wv || wv.superview !== self else { return }
        if let c = current, c !== wv, c.superview === self { c.removeFromSuperview() }
        wv.frame = bounds
        wv.autoresizingMask = [.width, .height]
        addSubview(wv)
        current = wv
    }
}

/// Where a page's web view is drawn. A tab's web view can only sit in one place, so Peek and the
/// panes each take it only while the model says it's theirs. Otherwise a Peek on its way out,
/// which SwiftUI still updates once or twice, would pull the web view back from the pane that
/// now shows it, and take it away when it goes.
enum WebHostRole { case pane, peek }

struct WebContainer: NSViewRepresentable {
    let tab: Tab
    var role: WebHostRole = .pane

    func makeNSView(context: Context) -> WebHostView { WebHostView() }

    func updateNSView(_ v: WebHostView, context: Context) {
        let inPeek = tab.model?.peek?.tab === tab
        guard (role == .peek) == inPeek else { v.letGo(); return }
        v.show(tab.ensureWebView())
    }
}

struct StartView: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Text("Search or enter an address")
                .font(Theme.Font.display(22))
                .displayTracking()
                .foregroundStyle(.secondary)
            HStack(spacing: Theme.Space.x3) {
                StartAction(title: "New tab", keys: "\u{2318}T") { model.newTabCommand() }
                StartAction(title: "New note", keys: "\u{21E7}\u{2318}N") { model.newNote() }
            }
        }
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StartAction: View {
    let title: String
    let keys: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                Text(title)
                Text(keys).foregroundStyle(.tertiary)
            }
            .font(Theme.Font.row)
        }
        .buttonStyle(QuietActionStyle())
    }
}

struct FirstRunPanel: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var chrome = ChromeImporter.shared
    @ObservedObject var settings = Settings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.x3) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.m) {
                    BrandMark(weight: 0.08, color: .primary, opacity: 0.85)
                        .frame(width: 24, height: 24)
                    Wordmark(size: 17)
                }
                .padding(.bottom, Theme.Space.s)
                Text("Start with what you've already seen")
                    .font(Theme.Font.display(26))
                    .displayTracking()
                Text("Cards on the right come from pages and notes you've looked at before. Pick the folders that hold your notes and bring in your Chrome history now, or later in Settings.")
                    .font(Theme.Font.row)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                FirstRunStep(title: "Import Chrome history", disabled: chrome.isRunning,
                             detail: "Reads a copy of your Chrome history from the last 90 days. Text is fetched without cookies, only for pages you opened at least twice.",
                             action: { chrome.start() }) {
                    if chrome.phase == .needsPermission {
                        ChromePermissionHelp()
                    } else if chrome.phase != .idle {
                        Text(ChromeStatus.text(chrome.phase)).font(Theme.Font.secondary).foregroundStyle(.secondary)
                    }
                }
                FirstRunStep(title: "Choose notes folders...", disabled: false,
                             detail: "The .md files in these folders become your notes here. You can open and edit them like any note, and new notes go in the first folder.",
                             action: { SourcesActions.addNotesFolders() }) {
                    if !Settings.shared.value.usesFallbackNotes {
                        Text(Settings.shared.value.notesFolders.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))
                            .font(Theme.Font.secondary).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { Settings.shared.update { $0.firstRunDone = true } }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(Theme.Space.x4)
        .frame(width: 500)
        .floatingSheet()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.card)
    }
}

/// One step on the first run panel: a button, what it does, and its status.
private struct FirstRunStep<Status: View>: View {
    let title: String
    let disabled: Bool
    let detail: String
    let action: () -> Void
    @ViewBuilder var status: () -> Status

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Button(title, action: action)
                .disabled(disabled)
            Text(detail)
                .font(Theme.Font.secondary)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            status()
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Radius.shape(Theme.Radius.card).fill(Theme.Palette.field))
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
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Browser POC needs your OK to read Chrome's history")
                .font(Theme.Font.rowEmphasis)
            Text("macOS asks before one app reads another app's data. If a prompt came up, click Allow, then try again. If you clicked Don't Allow or no prompt came up, open System Settings, go to Privacy & Security, then Files & Folders, find Browser POC and turn on Google Chrome.")
                .font(Theme.Font.secondary)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
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
        .padding(Theme.Space.l)
        .background(Theme.Radius.shape(Theme.Radius.row).fill(Theme.Palette.sheet))
        .overlay(Theme.Radius.shape(Theme.Radius.row).strokeBorder(Theme.Palette.hairline, lineWidth: 0.5))
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
