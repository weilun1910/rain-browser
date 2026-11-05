import AppKit
import SwiftUI

/// `--motion-tour glass [light|dark]` (only with `--data-dir`): sets up each floating layer over
/// three kinds of page, a bright one, a busy one and a dark one, so the window can be captured and
/// the glass checked for legibility. For each page it shows the Related shelf at rest, a pill's
/// popover and the command bar, then the graph's hover card and settings panel. Each scene writes
/// `ready <name>` to `<data dir>/glass-tour.log` once it has settled, and holds for a second so a
/// script can capture it. The app quits at the end.
@MainActor
enum GlassTour {
    static let hold: Double = 1.1
    static var log: URL { Paths.root.appendingPathComponent("glass-tour.log") }

    static func pause(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    static func until(_ timeout: Double, _ ok: () -> Bool) async -> Bool {
        var t = 0.0
        while !ok() && t < timeout { await pause(0.1); t += 0.1 }
        return ok()
    }

    static func ready(_ name: String) async {
        let visible = NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) }
        note(visible ? "ready \(name)" : "ready \(name) (window not visible to WebKit)")
        await pause(hold)
    }

    static func note(_ s: String) {
        if let h = try? FileHandle(forWritingTo: log) { h.seekToEndOfFile(); h.write(Data((s + "\n").utf8)); try? h.close() }
    }

    static func start(_ model: BrowserModel) {
        let args = CommandLine.arguments
        if args.contains("dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if args.contains("light") { NSApp.appearance = NSAppearance(named: .aqua) }
        try? "".write(to: log, atomically: true, encoding: .utf8)
        if IndexStore.shared.doc(key: SelfTest.fixtures[0].key) == nil { SelfTest.seed(IndexStore.shared, now: Date()) }
        Settings.shared.update { $0.firstRunDone = true }
        RelatedPrefs.shared.setMode(.shelf)

        Task { @MainActor in
            await pause(2.6)
            let shelf = ShelfState.shared
            for (name, html) in pages {
                let tab = model.newTab(url: nil, select: true)
                let wv = tab.ensureWebView()
                // Keep painting even if the window is covered or the display sleeps.
                wv.configuration.preferences.inactiveSchedulingPolicy = .none
                wv.loadHTMLString(html, baseURL: URL(string: "https://fieldnotes.smoke.test/\(name)")!)
                await pause(1.0)
                guard await until(30, { !model.resurfacer.cards.isEmpty }) else { note("no cards on \(name)"); continue }
                await pause(1.4)
                await ready("\(name)-shelf")
                let ids = model.resurfacer.cards.map { ShelfTarget.card($0.id) }
                shelf.enter(ids[0])
                await pause(1.0)
                await ready("\(name)-popover")
                if ids.count > 1 {
                    shelf.leave(ids[0]); shelf.enter(ids[1])
                    await pause(0.9)
                    await ready("\(name)-popover-2")
                    shelf.leave(ids[1])
                } else {
                    shelf.leave(ids[0])
                }
                await pause(0.6)
                model.bar.open(.newTab)
                await pause(0.4)
                model.bar.query = ""
                for ch in "starter" { model.bar.lastEditWasInsertion = true; model.bar.query.append(ch); await pause(0.05) }
                await pause(0.5)
                model.bar.move(1)
                await pause(0.6)
                await ready("\(name)-bar")
                model.bar.close()
                await pause(0.5)
            }
            _ = model.openGraph()
            let g = GraphController.global
            if await until(20, { g.layout.nodes.count > 8 && g.liveCount > 8 }) {
                await pause(3.0)
                if let hub = g.layout.nodes.indices.max(by: { g.layout.nodes[$0].degree < g.layout.nodes[$1].degree }) {
                    let p = g.sim.positions()
                    if hub < p.count { g.pointerMoved(g.screen(p[hub])) }
                    await pause(0.8)
                    await ready("graph-hover")
                    g.pointerExited()
                }
                GraphSettingsStore.shared.value.panelOpen = true
                await pause(0.9)
                await ready("graph-panel")
                GraphSettingsStore.shared.value.panelOpen = false
            } else {
                note("no graph")
            }
            note("done")
            await pause(0.3)
            NSApp.terminate(nil)
        }
    }

    // MARK: Pages

    /// The fixture article three ways: as it is (bright), over a loud background (busy), and dark.
    static var pages: [(String, String)] {
        let base = ShelfSmoke.page
        func with(_ css: String) -> String { base.replacingOccurrences(of: "</style>", with: css + "\n</style>") }
        return [("bright", base), ("busy", with(busyCSS)), ("dark", with(darkCSS))]
    }

    static let busyCSS = """
    body { background: #f2ece2; }
    body::before { content: ""; position: fixed; inset: 0; z-index: -1;
      background:
        radial-gradient(circle at 16% 82%, #ff5a36 0 10%, transparent 10.4%),
        radial-gradient(circle at 70% 90%, #1c6cff 0 13%, transparent 13.4%),
        radial-gradient(circle at 44% 58%, #ffd23f 0 8%, transparent 8.4%),
        radial-gradient(circle at 90% 38%, #10b981 0 11%, transparent 11.4%),
        radial-gradient(circle at 30% 30%, #111 0 4%, transparent 4.4%),
        repeating-linear-gradient(115deg, rgba(0,0,0,0.85) 0 2px, transparent 2px 20px),
        conic-gradient(from 30deg at 35% 40%, #ff9a8b, #ffd1ff, #a1c4fd, #c2e9fb, #fbc2eb, #ff9a8b); }
    header { background: rgba(255,255,255,0.7); }
    .hero { height: 300px; background: repeating-conic-gradient(from 10deg at 60% 50%, #111 0 9deg, #ffd23f 9deg 18deg, #ff5a36 18deg 27deg, #fff 27deg 36deg); }
    p, pre, h1, .meta { background: rgba(255,255,255,0.55); }
    """

    static let darkCSS = """
    body { background: #0e0e10; color: #e6e6e6; }
    header { border-color: #26262a; }
    header span, .meta { color: #8d8d93; }
    .hero { background: linear-gradient(135deg, #1b2a4a, #3a1f2e); }
    pre { background: #1a1a1d; }
    #cookie { background: #f5f5f7; color: #1d1d1f; }
    #cookie b { color: #0a62d0; }
    """
}
