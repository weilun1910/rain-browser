import AppKit
import SwiftUI

/// The named sequences for `--motion-tour <name>`, one per area of the motion plan
/// (notes/plans/2026-11-05-motion.md), so before and after recordings play the same actions.
/// Like the default tour, they only run with `--data-dir` and quit the app at the end.
@MainActor
enum MotionTours {
    static let names = ["spaces", "rows", "peek", "split", "compact", "toasts"]

    /// The tour named on the command line, if it's one of these.
    static var requested: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--motion-tour"), i + 1 < args.count, names.contains(args[i + 1]) else { return nil }
        return args[i + 1]
    }

    static func start(_ name: String, _ model: BrowserModel) {
        // Copying a link in a tour must never reach the real clipboard.
        BrowserModel.pasteboard = NSPasteboard(name: NSPasteboard.Name("local.browserpoc.motion-tour"))
        // Keep the window above everything for the length of the tour. WebKit stops drawing pages in
        // a window that's covered, so a recording of a covered window shows blank panes.
        if let w = NSApp.windows.first(where: { $0.contentView is NSHostingView<ModifiedContent<MainView, _EnvironmentKeyWritingModifier<BrowserModel?>>> }) {
            w.level = .floating
            w.orderFrontRegardless()
        }
        let s = MotionTour.Steps()
        switch name {
        case "spaces": spaces(s, model)
        case "rows": rows(s, model)
        case "peek": peek(s, model)
        case "split": split(s, model)
        case "compact": compact(s, model)
        case "toasts": toasts(s, model)
        default: break
        }
        s.step(1.4, "quit") { NSApp.terminate(nil) }
    }

    /// Web tabs in the current space that have an address, Tabs first.
    static func webTabs(_ model: BrowserModel) -> [Tab] {
        let today = model.refs(in: .today).compactMap { r -> Tab? in if case .tab(let id) = r { return model.tab(id) }; return nil }
        let rest = model.spaceTabs.filter { t in !today.contains { $0 === t } }
        return (today + rest).filter { $0.isWeb && $0.url != nil }
    }

    // MARK: Spaces

    static func spaces(_ s: MotionTour.Steps, _ m: BrowserModel) {
        s.step(2.8, "start on the first space") { m.switchSpace(index: 0) }
        // Swipes, made of the same events a trackpad sends, 120 a second, fed to the sidebar's tracker.
        s.step(1.0, "swipe: slow drag past a third, then lift") { swipe(m, Array(repeating: -4, count: 32), hold: 0.12) }
        s.step(1.4, "swipe: short drag back, then lift") { swipe(m, Array(repeating: 3, count: 18), hold: 0.12) }
        s.step(1.4, "swipe: flick back") { swipe(m, Array(repeating: 10, count: 7)) }
        s.step(1.4, "swipe: pull past the first space") { swipe(m, Array(repeating: 6, count: 30), hold: 0.12) }
        s.step(1.4, "swipe: flick, then flick again mid-settle") {
            swipe(m, Array(repeating: -10, count: 7), then: (0.12, Array(repeating: -10, count: 7)))
        }
        s.step(1.4, "click: back") { m.switchSpace(by: -1) }
        s.step(1.2, "click: next") { m.switchSpace(by: 1) }
        s.step(1.2, "jump to the last") { m.switchSpace(index: m.spaces.count - 1) }
        s.step(1.2, "jump to the first") { m.switchSpace(index: 0) }
        s.step(1.2, "rapid 2") { m.switchSpace(index: 1) }
        s.step(0.1, "rapid 3") { m.switchSpace(index: 2) }
        s.step(0.1, "rapid 4") { m.switchSpace(index: 3) }
        s.step(1.4, "home") { m.switchSpace(index: 0) }
    }

    /// Plays a two-finger swipe over the sidebar: `moves` are the fingers' sideways travel per
    /// event, 120 events a second, then `hold` seconds still before they lift. `then` plays a
    /// second swipe that many seconds after the first lifts. Each event is sent a frame after the
    /// one before it, so a busy main thread delays the gesture instead of bunching its events.
    static func swipe(_ m: BrowserModel, _ moves: [CGFloat], hold: Double = 0, then: (Double, [CGFloat])? = nil) {
        let dt = 1.0 / 120
        var events: [(delay: Double, dx: CGFloat, phase: SwipeSample.Phase)] = []
        func add(_ moves: [CGFloat], hold: Double, after: Double) {
            events.append((after, 0, .mayBegin))
            for (i, dx) in moves.enumerated() { events.append((dt, dx, i == 0 ? .began : .changed)) }
            if hold > 0 { events.append((hold, 0, .changed)) }
            events.append((dt, 0, .ended))
        }
        add(moves, hold: hold, after: 0)
        if let then { add(then.1, hold: 0, after: then.0) }
        play(events[...], strip: SpaceStrip.of(m))
    }

    private static func play(_ events: ArraySlice<(delay: Double, dx: CGFloat, phase: SwipeSample.Phase)>, strip: SpaceStrip) {
        guard let e = events.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + e.delay) {
            MainActor.assumeIsolated {
                _ = strip.handle(SwipeSample(dx: e.dx, phase: e.phase, time: ProcessInfo.processInfo.systemUptime), inside: true)
                play(events.dropFirst(), strip: strip)
            }
        }
    }

    // MARK: Rows

    static func rows(_ s: MotionTour.Steps, _ m: BrowserModel) {
        var t: Tab?
        s.step(2.8, "pick a tab") { t = webTabs(m).first { !$0.isPinned && $0.folderID == nil }; if let t { m.select(t) } }
        s.step(1.2, "pin") { if let t { m.togglePin(t) } }
        s.step(1.2, "unpin") { if let t { m.togglePin(t) } }
        s.step(1.2, "into a folder") { if let t, let f = m.spaceFolders.first { m.move(t, to: f.id) } }
        s.step(1.2, "back to Tabs") { if let t { m.move(t, to: nil) } }
        s.step(1.2, "add to Essentials") { if let t { m.addToEssentials(t) } }
        s.step(1.2, "remove from Essentials") { if let t { m.removeFromEssentials(t) } }
        var opened: Tab?
        s.step(1.2, "new tab") { opened = m.newTab(url: URL(string: "https://en.wikipedia.org/wiki/Spring_(device)"), select: true) }
        s.step(1.4, "close it") { if let o = opened { m.remove(o) } }
        s.step(1.2, "folder close") { if let f = m.spaceFolders.first { m.toggleFolder(f) } }
        s.step(1.2, "folder open") { if let f = m.spaceFolders.first { m.toggleFolder(f) } }
        s.step(1.2, "clear today") { _ = m.clearToday() }
        s.step(1.6, "undo") { m.runToastAction() }
    }

    // MARK: Peek

    static func peek(_ s: MotionTour.Steps, _ m: BrowserModel) {
        var host: Tab?
        let links = { Array(webTabs(m).compactMap(\.url).dropFirst()) }
        s.step(2.8, "pick a page") { host = webTabs(m).first; if let host { m.select(host) } }
        // As if a link were clicked there: Peek grows from the click.
        s.step(1.6, "open peek from a link") { PeekMotion.shared.recordClick(CGPoint(x: 520, y: 300)); if let u = links().first { m.openPeek(u, from: host) } }
        s.step(1.6, "close peek") { m.closePeek() }
        s.step(1.2, "open from another link") { PeekMotion.shared.recordClick(CGPoint(x: 260, y: 560)); if links().count > 1 { m.openPeek(links()[1], from: host) } }
        s.step(1.6, "expand") { m.expandPeek() }
        s.step(1.4, "open with no click") { if links().count > 2 { m.openPeek(links()[2], from: m.currentTab) } }
        s.step(1.6, "into a split") { m.splitPeek() }
    }

    // MARK: Split

    static func split(_ s: MotionTour.Steps, _ m: BrowserModel) {
        var tabs: [Tab] = []
        func step(_ gap: Double, _ label: String, _ f: @escaping @MainActor () -> Void) {
            s.step(gap, label) { f(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { MainActor.assumeIsolated { report(label, m) } } }
        }
        step(2.8, "pick a page") { tabs = Array(webTabs(m).prefix(3)); if let a = tabs.first { m.select(a) } }
        step(1.4, "split") { if tabs.count > 1 { m.openInSplit(tabs[1], side: .right) } }
        step(1.4, "swap") { if let sp = m.currentSplit { m.swap(sp) } }
        step(1.4, "third pane") { if tabs.count > 2 { m.openInSplit(tabs[2], side: .right) } }
        step(1.4, "close a pane") { if tabs.count > 2 { m.focusPane(item: tabs[2].id); m.closeCurrent() } }
        step(1.4, "pop out") { if tabs.count > 1 { m.popOut(tabs[1].id) } }
        step(1.2, "split again") { if tabs.count > 1, let a = tabs.first { m.select(a); m.openInSplit(tabs[1], side: .right) } }
        step(1.4, "separate") { if let sp = m.currentSplit { m.separate(sp) } }
    }

    /// With RAIN_TOUR_DEBUG set, prints where each visible page's web view is, for checking that
    /// every pane on screen holds its page.
    static func report(_ label: String, _ m: BrowserModel) {
        guard ProcessInfo.processInfo.environment["RAIN_TOUR_DEBUG"] != nil else { return }
        let w = NSApp.windows.first { $0.contentView is NSHostingView<ModifiedContent<MainView, _EnvironmentKeyWritingModifier<BrowserModel?>>> }
        print("REPORT \(label): visible \(m.visibleTabs.count), window on screen \(w?.occlusionState.contains(.visible) ?? false)")
        for t in m.visibleTabs {
            let wv = t.webView
            print("REPORT   \(t.displayTitle.prefix(16)): in window \(wv?.window != nil), host \(wv?.superview.map { "\(type(of: $0))" } ?? "none"), \(wv.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "")")
        }
    }

    // MARK: Compact mode

    static func compact(_ s: MotionTour.Steps, _ m: BrowserModel) {
        s.step(2.8, "pick a page") { if let a = webTabs(m).first { m.select(a) } }
        s.step(1.2, "hide the sidebar") { BrowserPrefs.shared.update { $0.sidebarHidden = true } }
        s.step(1.4, "show it") { BrowserPrefs.shared.update { $0.sidebarHidden = false } }
        s.step(1.2, "hide again") { BrowserPrefs.shared.update { $0.sidebarHidden = true } }
        s.step(1.6, "show") { BrowserPrefs.shared.update { $0.sidebarHidden = false } }
    }

    // MARK: Toasts and find

    static func toasts(_ s: MotionTour.Steps, _ m: BrowserModel) {
        s.step(2.8, "pick a page") { if let a = webTabs(m).first { m.select(a) } }
        s.step(1.6, "copy link") { m.copyCurrentURL() }
        s.step(0.7, "copy as markdown") { m.copyCurrentURL(markdown: true) }
        s.step(3.2, "find") { m.openFind(); m.setFindQuery("the") }
        s.step(1.6, "find closes") { m.closeFind() }
    }
}
