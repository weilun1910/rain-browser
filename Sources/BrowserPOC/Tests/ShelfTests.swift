import AppKit
import Foundation
import SwiftUI

/// The Related shelf: the setting and its default, the toggles, which cards show, hiding while
/// typing, and the hover timing.
enum ShelfTests {
    static func check(_ ok: Bool, _ label: String, _ detail: String = "") { SelfTest.check(ok, label, detail) }

    static func run(dir: URL) {
        MainActor.assumeIsolated {
            setting()
            entries()
            presence()
            typing()
            hover()
            textAndMetrics()
            motion()
            // Leave the defaults behind for anything that runs later.
            try? FileManager.default.removeItem(at: RelatedPrefs.file)
            RelatedPrefs.shared.reload()
            ShelfState.shared.reset()
        }
    }

    static func card(_ id: Int64, _ title: String, section: CardSection = .sites, passage: String = "") -> Card {
        let doc = DocMeta(id: id, key: "https://example.com/\(id)", source: section == .sites ? .web : .note,
                          url: "https://example.com/\(id)", title: title, description: "", project: nil, root: nil,
                          firstSeen: 0, lastSeen: 0, visitCount: 1, dwell: 0, lastOpened: 0, hasText: true, mtime: 0)
        var m = Match(doc: doc, keyword: 0, semantic: 0, entity: 0, score: 1, passage: passage, sharedTerms: [], sharedEntities: [],
                      topicTerms: [], penalized: false)
        m.section = section
        return Card(match: m, reason: "You read this on 1 Nov.")
    }

    static func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    // MARK: Setting

    @MainActor static func setting() {
        let prefs = RelatedPrefs.shared
        Settings.shared.update { $0.rightPanelOpen = true }
        try? FileManager.default.removeItem(at: RelatedPrefs.file)
        prefs.reload()
        check(prefs.mode == .shelf && !prefs.value.shelfHidden, "Related shows as a shelf by default")
        check(!Settings.shared.value.rightPanelOpen, "the first launch with the shelf closes the right panel")
        check(FileManager.default.fileExists(atPath: RelatedPrefs.file.path), "the shelf setting is saved in related.json")

        prefs.setMode(.sidebar)
        check(prefs.mode == .sidebar && Settings.shared.value.rightPanelOpen, "switching to Sidebar opens the right panel")
        prefs.reload()
        check(prefs.mode == .sidebar, "the Sidebar setting survives a reload")

        prefs.toggleVisible()
        check(prefs.mode == .sidebar && !Settings.shared.value.rightPanelOpen, "Shift-Cmd-R hides the sidebar in sidebar mode")
        prefs.toggleVisible()
        check(Settings.shared.value.rightPanelOpen, "and shows it again")

        prefs.toggleMode()
        check(prefs.mode == .shelf && !Settings.shared.value.rightPanelOpen && !prefs.value.shelfHidden,
              "Ctrl-Cmd-R switches back to the shelf and closes the right panel")
        prefs.toggleVisible()
        check(prefs.value.shelfHidden && prefs.mode == .shelf && !Settings.shared.value.rightPanelOpen, "Shift-Cmd-R hides the shelf in shelf mode")
        prefs.toggleVisible()
        check(!prefs.value.shelfHidden, "and shows it again")

        // Anything that opens the right panel, like an older shortcut, switches to the sidebar.
        Settings.shared.update { $0.rightPanelOpen = true }
        check(prefs.mode == .sidebar, "opening the right panel while in shelf mode switches to Sidebar")
        prefs.setMode(.shelf)
        check(prefs.mode == .shelf && !Settings.shared.value.rightPanelOpen, "and setting Shelf turns the panel off again")

        // A broken file falls back to the defaults.
        try? Data("{\"mode\": \"floating\"}".utf8).write(to: RelatedPrefs.file)
        prefs.reload()
        check(prefs.mode == .shelf, "an unknown mode in related.json falls back to Shelf")
    }

    // MARK: Entries

    @MainActor static func entries() {
        let a = card(1, "WKWebExtension"), b = card(2, "Nook ExtensionManager"), c = card(3, "Browser engine notes", section: .docs)
        let both = ShelfLayout.entries(sites: [a, b], docs: [c], progress: nil).map(\.id)
        check(both == ["card-1", "card-2", "divider", "card-3"], "the shelf shows Sites, a divider, then Notes / Docs", both.joined(separator: " "))
        let sitesOnly = ShelfLayout.entries(sites: [a, b], docs: [], progress: nil).map(\.id)
        check(sitesOnly == ["card-1", "card-2"], "no divider when only Sites has cards")
        let docsOnly = ShelfLayout.entries(sites: [], docs: [c], progress: nil).map(\.id)
        check(docsOnly == ["card-3"], "no divider when only Notes / Docs has cards")
        let withProgress = ShelfLayout.entries(sites: [a], docs: [], progress: 0.4).map(\.id)
        check(withProgress == ["card-1", "progress"], "the model download sits at the end of the row")
        check(ShelfLayout.entries(sites: [], docs: [], progress: nil).isEmpty, "no cards means nothing in the row")
    }

    // MARK: Presence

    @MainActor static func presence() {
        typealias I = ShelfLayout.Inputs
        func p(_ i: I) -> ShelfLayout.Presence { ShelfLayout.presence(i) }
        check(p(I(hasCards: false)) == .gone, "no cards, no shelf")
        check(p(I(hasCards: true)) == .shown, "cards bring the shelf")
        check(p(I(hasCards: true, typing: true)) == .sunk, "typing in a note sinks the shelf")
        check(p(I(mode: .sidebar, hasCards: true)) == .gone, "sidebar mode has no shelf")
        check(p(I(hidden: true, hasCards: true)) == .gone, "a hidden shelf stays hidden")
        check(p(I(hasCards: true, peekOpen: true)) == .gone, "Peek hides the shelf")
        check(p(I(hasCards: true, firstRunDone: false)) == .gone, "the first run panel hides the shelf")
        let alone = p(I(hasCards: false, downloading: true))
        check(alone == .shown && !ShelfLayout.coversPage(alone, hasCards: false),
              "the model download shows alone, without the fade or the page inset")
        check(ShelfLayout.coversPage(.shown, hasCards: true) && !ShelfLayout.coversPage(.sunk, hasCards: true),
              "the fade shows with cards and goes while typing")
    }

    // MARK: Typing

    @MainActor static func typing() {
        let s = ShelfState.shared
        s.reset()
        s.noteTyped()
        check(s.typing, "a keystroke in a note marks typing")
        spin(ShelfStyle.typingPause * 0.5)
        s.noteTyped()
        spin(ShelfStyle.typingPause * 0.7)
        check(s.typing, "steady typing keeps the shelf down")
        spin(ShelfStyle.typingPause * 0.6)
        check(!s.typing, "a pause brings the shelf back")

        // Only an editable text view in the main window counts, never a field like the command bar.
        _ = NSApplication.shared
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        tv.isEditable = true
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        box.addSubview(tv)
        box.addSubview(field)
        w.contentView = box
        w.makeFirstResponder(tv)
        check(ShelfState.isNoteTyping(window: w, modifiers: [], mainWindow: w), "typing in a note's text view counts")
        check(ShelfState.isNoteTyping(window: w, modifiers: [.shift], mainWindow: w), "and so do capitals")
        check(!ShelfState.isNoteTyping(window: w, modifiers: [.command], mainWindow: w), "Cmd shortcuts don't count as typing")
        check(!ShelfState.isNoteTyping(window: w, modifiers: [], mainWindow: nil), "typing in another window doesn't count")
        w.makeFirstResponder(field)
        check(!ShelfState.isNoteTyping(window: w, modifiers: [], mainWindow: w), "typing in a field like the command bar doesn't count")
        tv.isEditable = false
        w.makeFirstResponder(tv)
        check(!ShelfState.isNoteTyping(window: w, modifiers: [], mainWindow: w), "a read-only note doesn't count")
        w.close()
    }

    // MARK: Hover

    @MainActor static func hover() {
        let s = ShelfState.shared
        s.reset()
        s.enter(.card(1))
        check(s.open == nil, "the popover waits before opening")
        spin(ShelfStyle.openDelay + 0.15)
        check(s.open == .card(1), "it opens after the pointer rests on a pill")
        s.leave(.card(1))
        s.enter(.card(2))
        check(s.open == .card(2), "moving to a neighbouring pill switches at once")
        s.leave(.card(2))
        check(s.open == .card(2), "leaving a pill doesn't close it straight away")
        s.enterPopover()
        spin(ShelfStyle.closeDelay + 0.15)
        check(s.open == .card(2), "the pointer can move into the popover")
        s.leavePopover()
        spin(ShelfStyle.closeDelay + 0.15)
        check(s.open == nil, "leaving the pill and the popover closes it")
        s.enter(.card(3))
        check(s.open == .card(3), "a quick re-hover opens at once")
        s.noteTyped()
        check(s.open == nil, "typing closes the popover")
        s.reset()

        s.focus(.card(4))
        check(s.open == .card(4), "keyboard focus on a pill opens its popover at once")
        s.focus(nil)
        check(s.open == nil, "and moving focus away closes it")

        s.toggleGraph()
        check(s.open == .graph && s.pinned, "the graph button opens the graph and keeps it open")
        s.enter(.card(1))
        s.leave(.card(1))
        spin(ShelfStyle.closeDelay + 0.15)
        check(s.open == .graph, "hovering pills doesn't close the graph")
        s.toggleGraph()
        check(s.open == nil && !s.pinned, "a second click closes it")
        s.reset()
    }

    // MARK: Text and sizes

    @MainActor static func textAndMetrics() {
        let plain = ShelfText.plain("## Feeding **schedule**\n- [ ] try [rye flour](https://x.y) and `levain`")
        check(plain == "Feeding schedule try rye flour and levain", "popover passages read as plain text", plain)
        let long = card(9, String(repeating: "A very long page title ", count: 8))
        let short = card(10, "Go")
        let wl = ShelfMetrics.width(.card(long)), ws = ShelfMetrics.width(.card(short))
        check(wl == ShelfStyle.pillMaxWidth && ws == ShelfStyle.pillMinWidth, "pills stay between their narrowest and widest",
              "\(Int(ws)) to \(Int(wl))")
        check(ShelfStyle.pillHeight <= 32 && ShelfStyle.clearance < 60, "the shelf stays thin", "\(Int(ShelfStyle.clearance)) pt")
    }

    // MARK: Motion

    @MainActor static func motion() {
        ShelfStyle.forceReduce = true
        let reduced = ShelfStyle.motion(ShelfStyle.popIn) == ShelfStyle.reducedFade && ShelfStyle.motion(ShelfStyle.glide) == ShelfStyle.reducedFade
        ShelfStyle.forceReduce = false
        let full = ShelfStyle.motion(ShelfStyle.popIn) == ShelfStyle.popIn
        ShelfStyle.forceReduce = nil
        check(reduced && full, "Reduce Motion turns the shelf's springs into a short fade")
    }
}
