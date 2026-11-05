import AppKit
import Combine
import SwiftUI
import WebKit

// The Related shelf's state and rules, kept apart from its views so the self test can check them.
// See notes/plans/2026-11-05-related-shelf.md.

// MARK: - The setting

/// How Related shows: a row of cards floating at the bottom of the page, or the right panel.
enum RelatedMode: String, Codable, CaseIterable {
    case shelf, sidebar
    var title: String { self == .shelf ? "Shelf" : "Sidebar" }
}

struct RelatedPrefsValue: Codable, Equatable {
    var mode: RelatedMode = .shelf
    /// Cmd-Shift-R in shelf mode. The sidebar keeps using `AppSettings.rightPanelOpen`.
    var shelfHidden = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RelatedPrefsValue()
        mode = (try? c.decodeIfPresent(RelatedMode.self, forKey: .mode)) ?? d.mode
        shelfHidden = try c.decodeIfPresent(Bool.self, forKey: .shelfHidden) ?? d.shelfHidden
    }
}

/// Kept in its own `related.json`, like `browser.json`, so it never collides with other settings.
/// `rightPanelOpen` keeps meaning "the right panel is open". Shelf mode keeps it off, and anything
/// that opens the right panel while in shelf mode switches to Sidebar, so the two never show at once.
@MainActor
final class RelatedPrefs: ObservableObject {
    static let shared = RelatedPrefs()
    @Published private(set) var value = RelatedPrefsValue()
    private var watch: AnyCancellable?
    private var panelWasOpen = false

    static var file: URL { Paths.root.appendingPathComponent("related.json") }

    private init() { reload() }

    /// Reads the file again. Tests call this after pointing Paths at a throwaway folder.
    func reload() {
        watch = nil
        if let data = try? Data(contentsOf: Self.file), let v = try? JSONDecoder.iso.decode(RelatedPrefsValue.self, from: data) {
            value = v
        } else {
            // First launch with the shelf: it becomes the default.
            value = RelatedPrefsValue()
            save()
        }
        if value.mode == .shelf && Settings.shared.value.rightPanelOpen { Settings.shared.update { $0.rightPanelOpen = false } }
        panelWasOpen = Settings.shared.value.rightPanelOpen
        watch = Settings.shared.$published.dropFirst().sink { [weak self] s in
            MainActor.assumeIsolated { self?.settingsChanged(s) }
        }
    }

    private func settingsChanged(_ s: AppSettings) {
        defer { panelWasOpen = s.rightPanelOpen }
        guard s.rightPanelOpen, !panelWasOpen, value.mode == .shelf else { return }
        update { $0.mode = .sidebar }
    }

    func update(_ change: (inout RelatedPrefsValue) -> Void) {
        var v = value
        change(&v)
        guard v != value else { return }
        value = v
        save()
    }

    private func save() {
        Paths.ensure(Paths.root)
        if let data = try? JSONEncoder.pretty.encode(value) { try? data.write(to: Self.file, options: .atomic) }
    }

    var mode: RelatedMode { value.mode }

    /// Switches between the shelf and the sidebar, showing whichever it switches to.
    func setMode(_ m: RelatedMode) {
        update {
            $0.mode = m
            if m == .shelf { $0.shelfHidden = false }
        }
        let open = m == .sidebar
        if Settings.shared.value.rightPanelOpen != open { Settings.shared.update { $0.rightPanelOpen = open } }
    }

    func toggleMode() { setMode(mode == .shelf ? .sidebar : .shelf) }

    /// Cmd-Shift-R: shows or hides Related in whichever mode is on.
    func toggleVisible() {
        if mode == .sidebar {
            Settings.shared.update { $0.rightPanelOpen.toggle() }
        } else {
            update { $0.shelfHidden.toggle() }
        }
    }

    var isVisible: Bool { mode == .sidebar ? Settings.shared.value.rightPanelOpen : !value.shelfHidden }
}

// MARK: - What shows

/// One thing in the shelf's row.
enum ShelfEntry: Identifiable {
    case card(Card)
    /// The hairline between Sites and Notes / Docs.
    case divider
    /// The model download, while it runs.
    case progress(Double)

    var id: String {
        switch self {
        case .card(let c): return "card-\(c.id)"
        case .divider: return "divider"
        case .progress: return "progress"
        }
    }

    var card: Card? { if case .card(let c) = self { return c }; return nil }
}

/// What the popover is showing.
enum ShelfTarget: Hashable {
    case card(Int64)
    case progress
    case graph
}

enum ShelfLayout {
    /// Sites first, then Notes / Docs, with a divider only when both have cards, then the model
    /// download if it's running.
    static func entries(sites: [Card], docs: [Card], progress: Double?) -> [ShelfEntry] {
        var out = sites.map(ShelfEntry.card)
        if !sites.isEmpty && !docs.isEmpty { out.append(.divider) }
        out += docs.map(ShelfEntry.card)
        if let p = progress { out.append(.progress(p)) }
        return out
    }

    enum Presence: Equatable {
        /// Nothing at all: no pills, no fade.
        case gone
        case shown
        /// Below the card's edge while Felix types in a note.
        case sunk
    }

    struct Inputs {
        var mode: RelatedMode = .shelf
        var hidden = false
        var hasCards = false
        var downloading = false
        var typing = false
        var peekOpen = false
        var firstRunDone = true
    }

    static func presence(_ i: Inputs) -> Presence {
        guard i.mode == .shelf, !i.hidden, i.firstRunDone, !i.peekOpen else { return .gone }
        guard i.hasCards || i.downloading else { return .gone }
        return i.typing ? .sunk : .shown
    }

    /// The fade and the page's inset only come with cards, not with the download pill alone.
    static func coversPage(_ p: Presence, hasCards: Bool) -> Bool { p == .shown && hasCards }
}

// MARK: - Live state

/// Typing, and which popover is open. One shelf per window, so one shared state.
@MainActor
final class ShelfState: ObservableObject {
    static let shared = ShelfState()

    /// True from a keystroke in a note until a pause.
    @Published private(set) var typing = false
    /// The popover on screen, if any.
    @Published private(set) var open: ShelfTarget?
    /// True when the popover was opened by a click (the graph) rather than hover.
    @Published private(set) var pinned = false
    /// Test hook: stands in for the model download's progress.
    @Published var progressOverride: Double?
    /// Test hook: a picture drawn where the page is, since offscreen snapshots can't draw WebKit.
    @Published var backdrop: NSImage?

    private var typingWork: DispatchWorkItem?
    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var lastClosed = Date.distantPast
    private var keyMonitor: Any?

    // MARK: Typing

    func noteTyped() {
        if !typing { typing = true }
        if !pinned { closeNow() }
        typingWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.typing = false } }
        typingWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + ShelfStyle.typingPause, execute: w)
    }

    /// Notices keystrokes in a note's text view in the main window. The text never leaves here.
    func installTypingMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            MainActor.assumeIsolated {
                if Self.isNoteTyping(e) { ShelfState.shared.noteTyped() }
                if e.keyCode == 53, ShelfState.shared.open != nil { ShelfState.shared.closeNow() }
            }
            return e
        }
    }

    static func isNoteTyping(_ e: NSEvent) -> Bool {
        isNoteTyping(window: e.window, modifiers: e.modifierFlags, mainWindow: AppDelegate.shared?.window)
    }

    /// A key without Cmd or Ctrl, in the main window, into an editable text view that isn't a
    /// field's editor (the command bar and the find field use field editors).
    static func isNoteTyping(window w: NSWindow?, modifiers: NSEvent.ModifierFlags, mainWindow: NSWindow?) -> Bool {
        guard modifiers.intersection([.command, .control]).isEmpty, let w, w === mainWindow,
              let tv = w.firstResponder as? NSTextView, tv.isEditable, !tv.isFieldEditor else { return false }
        return true
    }

    // MARK: Hover

    /// The pointer arrived on a pill or the download pill.
    func enter(_ t: ShelfTarget, now: Date = Date()) {
        closeWork?.cancel()
        openWork?.cancel()
        if pinned { return }
        if open != nil || now.timeIntervalSince(lastClosed) < ShelfStyle.warmWindow {
            // Already open, or only just closed: move at once, gliding.
            show(t)
            return
        }
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.show(t) } }
        openWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + ShelfStyle.openDelay, execute: w)
    }

    /// The pointer left a pill. The popover waits a moment in case it's heading there.
    func leave(_ t: ShelfTarget) {
        openWork?.cancel()
        guard !pinned else { return }
        scheduleClose()
    }

    func enterPopover() { closeWork?.cancel() }
    func leavePopover() { if !pinned { scheduleClose() } }

    /// Keyboard focus on a pill opens its popover at once.
    func focus(_ t: ShelfTarget?) {
        openWork?.cancel()
        closeWork?.cancel()
        if let t { show(t) } else if !pinned { closeNow() }
    }

    /// The graph button: click opens it and keeps it open, a second click closes it.
    func toggleGraph() {
        openWork?.cancel()
        closeWork?.cancel()
        if open == .graph { closeNow() } else { show(.graph) }
    }

    /// Opening grows the popover out of its pill. Moving to another pill glides it across.
    private func show(_ t: ShelfTarget) {
        pinned = t == .graph
        guard open != t else { return }
        withAnimation(ShelfStyle.motion(open == nil ? ShelfStyle.popIn : ShelfStyle.glide)) { open = t }
    }

    private func scheduleClose() {
        closeWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.closeNow() } }
        closeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + ShelfStyle.closeDelay, execute: w)
    }

    func closeNow() {
        openWork?.cancel()
        closeWork?.cancel()
        pinned = false
        guard open != nil else { return }
        lastClosed = Date()
        withAnimation(ShelfStyle.motion(ShelfStyle.popOut)) { open = nil }
    }

    /// Back to nothing open, for tests and new contexts.
    func reset() {
        closeNow()
        lastClosed = .distantPast
        typingWork?.cancel()
        typing = false
    }
}

// MARK: - The page underneath

/// Tells the web page under the shelf that its bottom is covered, with WebKit's
/// `obscuredContentInsets` (macOS 26). Fixed footers, chat boxes and cookie bars then sit above
/// the shelf, and the end of the page can scroll clear of it. Only one web view has it at a time.
@MainActor
enum ShelfInsets {
    private static weak var current: WKWebView?

    static func apply(_ wv: WKWebView?, bottom: CGFloat) {
        if let c = current, c !== wv { set(c, 0) }
        current = bottom > 0 ? wv : nil
        if let wv { set(wv, bottom) }
    }

    static func clear() { apply(nil, bottom: 0) }

    private static func set(_ wv: WKWebView, _ bottom: CGFloat) {
        var i = wv.obscuredContentInsets
        guard i.bottom != bottom else { return }
        i.bottom = bottom
        wv.obscuredContentInsets = i
    }
}

// MARK: - The graph slot

/// The local graph opens from a button at the end of the shelf: the same view as the right panel's
/// graph slot, always open. Tests can swap it, and with nothing set the button doesn't show.
@MainActor
enum ShelfGraph {
    static let localGraph: (Resurfacer) -> AnyView = { r in AnyView(LocalGraphSlot(resurfacer: r, alwaysOpen: true)) }
    static var provider: ((Resurfacer) -> AnyView)? = localGraph
    static var isAvailable: Bool { provider != nil }
}

// MARK: - Hooks for shared views

enum RelatedShelf {
    /// Called once at launch, before the window: settles the mode and starts noticing typing.
    @MainActor static func launch(_ model: BrowserModel) {
        _ = RelatedPrefs.shared
        ShelfState.shared.installTypingMonitor()
        ShelfDemo.start(model: model)
    }

    /// The focused pane's frame in the content area: the whole area, or the focused pane of a split.
    @MainActor static func paneFrame(_ model: BrowserModel, frames: [UUID: CGRect], size: CGSize) -> CGRect {
        if model.currentSplit != nil, let id = model.currentTab?.id, let f = frames[id] { return f }
        return CGRect(origin: .zero, size: size)
    }

    /// How far toasts move up while the shelf shows.
    @MainActor static func toastLift(_ model: BrowserModel) -> CGFloat {
        presence(model) == .shown ? ShelfStyle.toastLift : 0
    }

    @MainActor static func presence(_ model: BrowserModel) -> ShelfLayout.Presence {
        let r = model.resurfacer
        let p = RelatedPrefs.shared.value
        return ShelfLayout.presence(.init(mode: p.mode, hidden: p.shelfHidden, hasCards: !r.cards.isEmpty,
                                          downloading: (ShelfState.shared.progressOverride ?? ModelStore.shared.overallProgress) != nil,
                                          typing: ShelfState.shared.typing, peekOpen: model.peek != nil,
                                          firstRunDone: Settings.shared.published.firstRunDone))
    }

    /// Gives a note's scroll view room at the bottom, so its last lines can scroll above the shelf.
    @MainActor static func setNoteClearance(_ scroll: NSScrollView, _ bottom: CGFloat) {
        guard scroll.contentInsets.bottom != bottom else { return }
        scroll.automaticallyAdjustsContentInsets = false
        var i = scroll.contentInsets
        i.bottom = bottom
        scroll.contentInsets = i
    }
}

private struct ShelfClearanceKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// Extra room at the bottom of a note in shelf mode, so its last lines scroll above the shelf.
    var relatedShelfClearance: CGFloat {
        get { self[ShelfClearanceKey.self] }
        set { self[ShelfClearanceKey.self] = newValue }
    }
}
