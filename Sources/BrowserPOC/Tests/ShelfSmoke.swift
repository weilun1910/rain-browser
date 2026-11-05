import AppKit
import SwiftUI
import WebKit

/// The Related shelf part of `--smoketest`: the shelf over a live page and a note, the page's
/// obscured inset, the hover popover, light and dark, the graph slot, a split, and sidebar mode.
@MainActor
enum ShelfSmoke {
    static func check(_ ok: Bool, _ label: String, _ detail: String = "") { SelfTest.check(ok, label, detail) }
    static func wait(_ s: Double, _ done: () -> Bool) -> Bool { SmokeTest.wait(s, until: done) }

    /// A page that looks like a real article, with a fixed cookie bar at the bottom.
    static let page = """
    <!doctype html><html><head><title>Shipping Chrome extensions in a WebKit browser</title>
    <meta name="description" content="WKWebExtensionController, manifests and native messaging">
    <style>
      body { margin: 0; font: 16px/1.6 -apple-system, sans-serif; color: #1d1d1f; background: #fbfbfa; }
      header { padding: 14px 48px; border-bottom: 1px solid #e6e6e3; font-weight: 600; letter-spacing: -0.01em; }
      header span { color: #8a8a86; font-weight: 400; margin-left: 10px; }
      article { max-width: 680px; margin: 0 auto; padding: 40px 48px 160px; }
      h1 { font: 600 34px/1.15 'New York', Georgia, serif; letter-spacing: -0.02em; margin: 0 0 12px; }
      .meta { color: #8a8a86; font-size: 14px; margin-bottom: 28px; }
      .hero { height: 180px; border-radius: 10px; margin: 0 0 28px; background: linear-gradient(135deg, #d9e4f5, #f3e3d3); }
      pre { background: #f0efec; border-radius: 8px; padding: 14px 16px; font: 13px/1.5 ui-monospace, monospace; }
      #cookie { position: fixed; left: 0; right: 0; bottom: 0; padding: 12px 48px; background: #1d1d1f; color: #f5f5f7;
                font-size: 13px; display: flex; justify-content: space-between; }
      #cookie b { color: #9ecbff; font-weight: 500; }
    </style></head>
    <body><header>Field Notes<span>Browsers</span></header><article>
    <h1>Shipping Chrome extensions in a WebKit browser</h1>
    <div class="meta">12 min read | Updated this week</div>
    <div class="hero"></div>
    <p>A Mac browser built on WKWebView loads Chrome and Safari extensions with WKWebExtensionController. Create a
    WKWebExtension from the unpacked folder with its manifest, wrap it in a WKWebExtensionContext and load it into the controller.</p>
    <p>The browser has to report tab events to the controller, opening, closing and activating tabs, so extensions see the
    same tab model you do. Password managers such as Bitwarden and 1Password need native messaging, and CRX packages from the
    Chrome Web Store have to be converted to ZIP before WebKit will read them.</p>
    <pre>let ext = try await WKWebExtension(resourceBaseURL: folder)
    let context = WKWebExtensionContext(for: ext)
    try controller.load(context)</pre>
    <p>Manifest version 3 service workers are supported. Blocking webRequest isn't, so content blockers use declarative rules.</p>
    </article><div id="cookie">This site uses cookies to remember your reading position. <b>OK</b></div></body></html>
    """

    static func pageImage(_ t: Tab) -> NSImage? {
        var img: NSImage?
        var done = false
        t.webView?.takeSnapshot(with: nil) { i, _ in img = i; done = true }
        _ = wait(6) { done }
        return img
    }

    static func js(_ t: Tab, _ script: String) -> Double? {
        var out: Double?
        var done = false
        t.webView?.evaluateJavaScript(script) { r, _ in out = (r as? NSNumber)?.doubleValue; done = true }
        _ = wait(5) { done }
        return out
    }

    static func run(model: BrowserModel, window: NSWindow, snaps: URL) {
        let shot = { (name: String) in SmokeTest.snapshot(window.contentView!, snaps.appendingPathComponent(name)) }
        let state = ShelfState.shared
        RelatedPrefs.shared.setMode(.shelf)
        state.reset()
        if let s = model.currentSplit { model.separate(s) }
        let dark = NSAppearance(named: .darkAqua), light = NSAppearance(named: .aqua)
        window.appearance = dark

        // 1. A page brings cards, and the shelf comes with them instead of the right panel.
        let tab = model.newTab(url: nil, select: true)
        let url = URL(string: "https://fieldnotes.smoke.test/chrome-extensions-in-webkit")!
        tab.ensureWebView().loadHTMLString(page, baseURL: url)
        let got = wait(20) { !model.resurfacer.cards.isEmpty }
        _ = wait(30) { !model.resurfacer.isWorking }
        _ = wait(1) { false }
        let titles = model.resurfacer.cards.map { $0.match.doc.title.prefix(28) }.joined(separator: " | ")
        check(got && RelatedShelf.presence(model) == .shown, "the shelf shows when cards arrive", titles)
        check(!Settings.shared.value.rightPanelOpen && RelatedPrefs.shared.mode == .shelf, "the right panel stays closed in shelf mode")

        // 2. The page is told its bottom is covered, so its fixed cookie bar sits above the shelf.
        let insetOK = wait(3) { tab.webView?.obscuredContentInsets.bottom == ShelfStyle.clearance }
        let height = Double(tab.webView?.frame.height ?? 0)
        let inner = js(tab, "innerHeight") ?? 0
        let bar = js(tab, "document.getElementById('cookie').getBoundingClientRect().bottom") ?? 0
        check(insetOK && abs(inner - (height - Double(ShelfStyle.clearance))) < 1.5,
              "WebKit shrinks the page's viewport by the shelf", "view \(Int(height)), innerHeight \(Int(inner))")
        check(bar > 0 && bar <= inner + 0.5, "the page's fixed cookie bar moves above the shelf", "bar bottom \(Int(bar))")

        // MCP's current context still lists the Related cards in shelf mode.
        CurrentContextWriter.shared.start(model: model)
        let reported = CurrentContextWriter.shared.snapshot()?.related.map(\.key) ?? []
        check(!reported.isEmpty && reported == model.resurfacer.cards.map(\.match.doc.key),
              "AI clients' current context lists the shelf's cards", "\(reported.count) cards")

        // 3. Snapshots: offscreen rendering can't draw WebKit, so the page's own snapshot is drawn under the shelf.
        state.backdrop = pageImage(tab)
        check(state.backdrop != nil, "the page's snapshot is there to draw under the shelf")
        if let img = state.backdrop, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: snaps.appendingPathComponent("21a-page-alone.png"))
            print("      page snapshot \(Int(img.size.width))x\(Int(img.size.height)), \(rep.pixelsWide)x\(rep.pixelsHigh) px")
        }
        shot("21-shelf-page-dark.png")
        if let first = model.resurfacer.cards.first {
            state.focus(.card(first.id))
            _ = wait(0.7) { false }
            check(state.open == .card(first.id), "focusing a pill opens its popover")
            shot("22-shelf-hover-dark.png")
            state.closeNow()
            window.appearance = light
            _ = wait(0.4) { false }
            shot("23-shelf-page-light.png")
            let last = model.resurfacer.cards.last ?? first
            state.focus(.card(last.id))
            _ = wait(0.7) { false }
            shot("24-shelf-hover-light.png")
            state.closeNow()
            window.appearance = dark
        }

        // 4. The model download, and the graph button at the end of the row. The graph itself is
        // checked after the Graph smoke test seeds its fixture, in `graphPopover`.
        state.progressOverride = 0.42
        _ = wait(0.6) { false }
        check(ShelfGraph.isAvailable, "the shelf has the local graph's button")
        shot("25-shelf-progress-and-graph.png")

        // A narrow window: the row runs off the trailing edge, fades there and scrolls.
        let wide = window.contentView?.frame.size ?? NSSize(width: 1380, height: 860)
        window.setContentSize(NSSize(width: 960, height: 640))
        _ = wait(0.8) { false }
        state.backdrop = pageImage(tab)
        shot("25b-shelf-narrow.png")
        window.setContentSize(wide)
        _ = wait(0.6) { false }
        state.progressOverride = nil
        state.backdrop = nil

        // 5. A note: the shelf floats over it, sinks while typing and comes back on a pause.
        let noteURL = model.notes.create(in: model.newNotesFolder, title: "Starter troubleshooting")
        if let noteURL {
            try? "# Starter troubleshooting\n\nThe sourdough starter is sluggish and the levain smells of acetone after feeding. Feed it rye flour twice a day, keep it warmer, and check the hydration before the next bake.\n".write(to: noteURL, atomically: true, encoding: .utf8)
            let note = model.openNote(noteURL)
            _ = wait(5) { model.document?.state == .ready }
            let breadKeys = Set([3, 4].map { SelfTest.fixtures[$0].key })
            let gotBread = wait(15) { model.resurfacer.cards.contains { breadKeys.contains($0.match.doc.key) } }
            _ = wait(30) { !model.resurfacer.isWorking }
            _ = wait(1) { false }
            check(gotBread && RelatedShelf.presence(model) == .shown, "the shelf floats over a note")
            check(tab.webView?.obscuredContentInsets.bottom == 0, "the page loses its inset when the shelf moves to a note")
            shot("27-shelf-note-dark.png")
            state.noteTyped()
            check(RelatedShelf.presence(model) == .sunk, "typing in the note sinks the shelf")
            _ = wait(0.6) { false }
            shot("28-shelf-note-typing.png")
            let back = wait(ShelfStyle.typingPause + 1) { RelatedShelf.presence(model) == .shown }
            check(back, "the shelf comes back when typing pauses")
            window.appearance = light
            _ = wait(0.6) { false }
            shot("29-shelf-note-light.png")
            window.appearance = dark

            // 6. A page and the note side by side: the shelf sits under the focused pane.
            _ = model.openInSplit(tab, side: .left)
            model.focusPane(item: tab.id)
            _ = wait(10) { model.resurfacer.context?.key == URLKey.key(for: url) && !model.resurfacer.isWorking && !model.resurfacer.cards.isEmpty }
            _ = wait(2) { tab.webView?.obscuredContentInsets.bottom == ShelfStyle.clearance }
            check(model.currentSplit != nil && tab.webView?.obscuredContentInsets.bottom == ShelfStyle.clearance,
                  "in a split the shelf sits under the focused page")
            state.backdrop = pageImage(tab)
            _ = wait(1.5) { false } // pills arriving one after another
            shot("30-shelf-split.png")
            state.backdrop = nil
            model.focusPane(item: note.id)
            _ = wait(3) { tab.webView?.obscuredContentInsets.bottom == 0 }
            check(tab.webView?.obscuredContentInsets.bottom == 0, "focusing the other pane moves the shelf off the page")
            if let sp = model.currentSplit { model.separate(sp) }
        } else {
            check(false, "could create a note for the shelf")
        }

        // 7. Sidebar mode still works, and the shelf leaves the page alone there.
        model.select(tab)
        RelatedPrefs.shared.setMode(.sidebar)
        _ = wait(1.5) { tab.webView?.obscuredContentInsets.bottom == 0 }
        check(Settings.shared.value.rightPanelOpen && RelatedShelf.presence(model) == .gone && tab.webView?.obscuredContentInsets.bottom == 0,
              "sidebar mode shows the right panel and no shelf")
        _ = wait(8) { !model.resurfacer.cards.isEmpty }
        shot("31-related-sidebar.png")
        RelatedPrefs.shared.setMode(.shelf)
        state.reset()
    }
}

extension ShelfSmoke {
    /// After the Graph smoke test has seeded its notes and edges: the shelf's graph button opens
    /// the real local graph above the shelf, centred on the focused note.
    static func graphPopover(model: BrowserModel, window: NSWindow, snaps: URL, dir: URL) {
        let state = ShelfState.shared
        let l = GraphController.local
        /// A window snapshot with the local graph's Metal view swapped for a rendered still.
        func shot(_ name: String) {
            let u = snaps.appendingPathComponent(name)
            if let v = l.view, v.window === window { v.withStill { SmokeTest.snapshot(window.contentView!, u) } }
            else { SmokeTest.snapshot(window.contentView!, u) }
        }
        RelatedPrefs.shared.setMode(.shelf)
        state.reset()
        if let sp = model.currentSplit { model.separate(sp) }
        window.appearance = NSAppearance(named: .darkAqua)
        let plan = dir.appendingPathComponent("notes-root", isDirectory: true).appendingPathComponent("Browser plan.md")
        model.openNote(plan)
        _ = wait(5) { model.document?.state == .ready }
        let gotCards = wait(20) { !model.resurfacer.cards.isEmpty }
        _ = wait(30) { !model.resurfacer.isWorking }
        _ = wait(1) { false }
        check(gotCards && RelatedShelf.presence(model) == .shown && !Settings.shared.value.rightPanelOpen,
              "the shelf shows over the graph fixture's note", model.resurfacer.cards.map { $0.match.doc.title.prefix(24) }.joined(separator: " | "))
        state.toggleGraph()
        _ = wait(0.7) { false } // the popover growing in
        let opened = wait(10) { l.view?.window === window && l.centerKey == URLKey.fileKey(plan) && l.layout.nodes.count > 3 }
        check(state.open == .graph && opened, "the shelf's graph button opens the real local graph around the note",
              "\(l.layout.nodes.count) nodes around \(l.layout.center.map { l.layout.nodes[$0].title } ?? "nothing")")
        if let v = l.view { l.settle(ticks: 300, size: v.bounds.size) }
        shot("26-shelf-graph.png")
        window.appearance = NSAppearance(named: .aqua)
        _ = wait(0.6) { false }
        if let v = l.view { l.settle(ticks: 60, size: v.bounds.size) }
        shot("26b-shelf-graph-light.png")
        window.appearance = NSAppearance(named: .darkAqua)
        state.toggleGraph()
        check(state.open == nil, "a second click closes the graph")
    }
}
