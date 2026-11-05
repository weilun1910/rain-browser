import AppKit
import SwiftUI

/// The graph in the real model, headless: a richer fixture index, the Graph item, hover, the
/// settings panel and the right panel's local graph, each saved as an offscreen snapshot.
@MainActor
enum GraphSmoke {
    static func check(_ ok: Bool, _ label: String, _ detail: String = "") { SelfTest.check(ok, label, detail) }

    struct Item {
        let title: String
        let file: String?     // a note file name, or nil for a page
        let url: String?
        let text: String
    }

    /// Four projects' worth of notes and pages that link, lead to and resemble each other.
    static func items(notesRoot: URL) -> [Item] {
        func note(_ title: String, _ text: String) -> Item { Item(title: title, file: title + ".md", url: nil, text: "# \(title)\n\n" + text) }
        func page(_ title: String, _ url: String, _ text: String) -> Item { Item(title: title, file: nil, url: url, text: text) }
        let webkit = "WebKit WKWebView browser extensions WKWebExtension tabs spaces split view Swift macOS"
        let bread = "sourdough starter levain hydration rye flour bulk fermentation crumb loaf bake"
        let run = "marathon training plan long run tempo intervals pace taper race day fuel"
        let shop = "convenience store Gen Z interviews late night snacks checkout app deals opportunity"
        return [
            note("Browser plan", "Start from [[Engine choice]] and [[Extension research]]. Spaces come from [[Spaces design]] and the bar from [[Command bar]]. Read https://webkit.org/blog/web-extensions and https://developer.apple.com/documentation/webkit/wkwebview. Split view ideas live in [[Split view notes]]. Open question in [[Passkeys]]. \(webkit)"),
            note("Engine choice", "Picked WebKit over Chromium, see [[Browser plan]] and https://developer.apple.com/documentation/webkit/wkwebview. \(webkit)"),
            note("Extension research", "WKWebExtensionController loads extensions. Nook did it: https://github.com/nook-browser/Nook. Back to [[Browser plan]]. \(webkit)"),
            note("Spaces design", "Arc spaces with their own folders, like https://arc.net/spaces. Zen does it too: https://github.com/zen-browser/desktop. Linked from [[Browser plan]]. \(webkit)"),
            note("Command bar", "Cmd-T opens a centered bar like Arc. [[Spaces design]] decides what it searches. \(webkit)"),
            note("Split view notes", "Two items side by side, notes too. See [[Command bar]] and https://github.com/zen-browser/desktop. \(webkit)"),
            page("WKWebView | Apple Developer Documentation", "https://developer.apple.com/documentation/webkit/wkwebview", "An object that displays interactive web content in your app. \(webkit)"),
            page("WKWebExtension | Apple Developer Documentation", "https://developer.apple.com/documentation/webkit/wkwebextension", "Encapsulates a web extension's resources. \(webkit)"),
            page("Web extensions in WebKit apps", "https://webkit.org/blog/web-extensions", "WebKit apps can load web extensions now. \(webkit)"),
            page("nook-browser/Nook", "https://github.com/nook-browser/Nook", "An open source browser for macOS in Swift. \(webkit)"),
            page("zen-browser/desktop", "https://github.com/zen-browser/desktop", "Zen is a calm Firefox based browser with workspaces and split view. \(webkit)"),
            page("Spaces | Arc", "https://arc.net/spaces", "Spaces keep work and life apart in the sidebar. \(webkit)"),
            page("Show HN: a Mac browser on WebKit", "https://news.ycombinator.com/item?id=101", "Comments about extensions and password managers. \(webkit)"),
            page("Ask HN: Arc alternatives", "https://news.ycombinator.com/item?id=102", "People recommend Zen, Orion and Safari profiles. \(webkit)"),

            note("Bread log", "Saturday loaf at 75 percent hydration. Feed per [[Starter schedule]]. Guide: https://www.kingarthurbaking.com/sourdough-starter. \(bread)"),
            note("Starter schedule", "Feed twice a day with rye. Back to [[Bread log]]. \(bread)"),
            page("How to feed a sourdough starter", "https://www.kingarthurbaking.com/sourdough-starter", "A healthy starter rises after each feeding. \(bread)"),
            page("The Perfect Loaf: beginner sourdough", "https://www.theperfectloaf.com/beginners-sourdough", "A simple bread with a long cold proof. \(bread)"),
            page("The Perfect Loaf: levain", "https://www.theperfectloaf.com/levain", "Building a levain the night before. \(bread)"),
            page("Serious Eats: sourdough", "https://www.seriouseats.com/sourdough", "Why sourdough needs time. \(bread)"),

            note("Training log", "Long run on Sunday, see [[Race plan]]. Pace from https://www.calculator.net/pace-calculator.html. \(run)"),
            note("Race plan", "Taper two weeks out. [[Training log]] has the miles. \(run)"),
            page("16 week marathon plan", "https://www.runnersworld.com/marathon-plan", "Build mileage ten percent a week. \(run)"),
            page("Pace calculator", "https://www.calculator.net/pace-calculator.html", "Work out your race pace. \(run)"),
            page("Strava: Sunday long run", "https://www.strava.com/activities/1", "Twenty miles at easy pace. \(run)"),

            note("Interview synthesis", "Students want fast checkout late at night. Feeds [[Opportunity map]]. Deck: https://docs.google.com/document/d/1AbCdEfGhIjKlMnOp/edit. \(shop)"),
            note("Opportunity map", "Three opportunities from [[Interview synthesis]]. Plan in https://www.notion.so/Midpoint-plan-123abc. \(shop)"),
            page("Midpoint deck draft", "https://docs.google.com/document/d/1AbCdEfGhIjKlMnOp/edit", "Draft of the midpoint story for the client. \(shop)"),
            page("Midpoint plan", "https://www.notion.so/Midpoint-plan-123abc", "Who presents what at the midpoint. \(shop)"),
            page("Gen Z shopping habits", "https://www.mckinsey.com/gen-z-shopping", "How Gen Z shops at convenience stores. \(shop)"),
        ] + (1...24).map { i in
            let hosts = ["www.youtube.com", "twitter.com", "www.reddit.com", "en.wikipedia.org", "medium.com", "github.com"]
            return Item(title: "History page \(i)", file: nil, url: "https://\(hosts[i % hosts.count])/history-\(i)", text: "")
        }
    }

    static func seed(_ index: IndexStore, notesRoot: URL) -> [String: String] {
        var keys: [String: String] = [:]
        let now = Date().timeIntervalSince1970
        for (n, it) in items(notesRoot: notesRoot).enumerated() {
            let t = now - Double(60 - n) * 86400 * 0.8
            if let f = it.file {
                let u = notesRoot.appendingPathComponent(f)
                try? it.text.write(to: u, atomically: true, encoding: .utf8)
                let (d, a) = Indexer.fileDoc(url: u, text: it.text, root: notesRoot, mtime: t)
                index.upsertFile(d, analysis: a)
                keys[it.title] = d.key
            } else if let s = it.url, let u = URL(string: s) {
                let a = TextAnalysis.analyze(title: it.title, description: "", text: it.text)
                let d = DocUpsert(key: URLKey.key(for: u), source: it.text.isEmpty ? .chrome : .web, url: s, title: it.title,
                                  body: it.text, firstSeen: t, lastSeen: t, visitCount: 2)
                if it.text.isEmpty { _ = index.importChrome([(d, a)]) } else { index.recordCapture(d, analysis: a) }
                keys[it.title] = d.key
            }
        }
        return keys
    }

    static func distinctColors(_ png: URL, _ rect: CGRect) -> Int {
        guard let rep = NSImage(contentsOf: png)?.representations.first as? NSBitmapImageRep else { return 0 }
        var seen = Set<UInt32>()
        let sx = CGFloat(rep.pixelsWide) / (rep.size.width > 0 ? rep.size.width : 1)
        var y = rect.minY
        while y < rect.maxY {
            var x = rect.minX
            while x < rect.maxX {
                if let c = rep.colorAt(x: Int(x * sx), y: Int(y * sx)) {
                    let v = UInt32(c.redComponent * 31) << 10 | UInt32(c.greenComponent * 31) << 5 | UInt32(c.blueComponent * 31)
                    seen.insert(v)
                }
                x += 3
            }
            y += 3
        }
        return seen.count
    }

    static func run(model: BrowserModel, window: NSWindow, snaps: URL, dir: URL) {
        /// A window snapshot with the graphs' Metal views swapped for rendered stills.
        @discardableResult
        func shot(_ name: String) -> URL {
            let u = snaps.appendingPathComponent(name)
            let views = [GraphController.global.view, GraphController.local.view].compactMap { $0 }.filter { $0.window === window }
            func nest(_ i: Int) {
                if i == views.count { SmokeTest.snapshot(window.contentView!, u) } else { views[i].withStill { nest(i + 1) } }
            }
            nest(0)
            return u
        }
        let index = IndexStore.shared!
        let store = GraphStore.reset(indexURL: dir.appendingPathComponent("index.sqlite"))
        let notesRoot = dir.appendingPathComponent("notes-root", isDirectory: true)
        Paths.ensure(notesRoot)
        let keys = seed(index, notesRoot: notesRoot)
        func k(_ t: String) -> String { keys[t] ?? "" }
        store.recordNavigation(fromKey: k("Show HN: a Mac browser on WebKit"), toKey: k("nook-browser/Nook"))
        store.recordNavigation(fromKey: k("Ask HN: Arc alternatives"), toKey: k("zen-browser/desktop"))
        store.recordNavigation(fromKey: k("Ask HN: Arc alternatives"), toKey: k("Spaces | Arc"))
        store.recordNavigation(fromKey: k("The Perfect Loaf: beginner sourdough"), toKey: k("The Perfect Loaf: levain"))
        store.recordNavigation(fromKey: k("16 week marathon plan"), toKey: k("Pace calculator"))
        store.recordResearch(contextKey: k("Browser plan"), addedKey: k("Show HN: a Mac browser on WebKit"))
        store.recordResearch(contextKey: k("Opportunity map"), addedKey: k("Gen Z shopping habits"))
        store.recordTogether(k("Bread log"), k("Serious Eats: sourdough"), detail: "split")
        store.recordTogether(k("Training log"), k("Strava: Sunday long run"), detail: "split")
        store.sync()
        let stats = store.stats()
        print("      graph fixture: \(stats.items) items, edges \(stats.edges)")

        GraphRecorder.shared.attach(model)
        let graphTab = model.openGraph()
        let g = GraphController.global
        check(model.currentTab?.id == graphTab.id && graphTab.kind == .graph, "the Graph item opens in the content area")
        let loaded = SmokeTest.wait(15) { g.hasLoaded && g.layout.nodes.count > 20 }
        check(loaded && g.layout.edges.count >= 25, "the global graph loads the fixture items",
              "\(g.layout.nodes.count) nodes, \(g.layout.edges.count) lines")
        let size = g.view?.bounds.size ?? CGSize(width: 800, height: 760)
        check(g.view != nil && size.width > 300, "the graph's Metal view is in the window", "\(Int(size.width)) x \(Int(size.height))")
        g.settle(ticks: 400, size: size)
        let global = shot("9-graph-global.png")
        if let v = g.view {
            let r = v.convert(v.bounds, to: window.contentView!)
            let flipped = CGRect(x: r.minX, y: window.contentView!.bounds.height - r.maxY, width: r.width, height: r.height)
            let colors = distinctColors(global,(window.contentView!.isFlipped ? r : flipped).insetBy(dx: 40, dy: 60))
            check(colors > 12, "the snapshot shows the Metal graph, not a blank view", "\(colors) colours in the graph area")
        }
        func save(_ img: CGImage?, _ name: String) {
            guard let img else { return }
            try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: snaps.appendingPathComponent(name))
        }
        save(g.renderImage(size: size), "9b-graph-render.png")
        save(g.renderImage(size: size, appearance: NSAppearance(named: .aqua)), "9c-graph-light.png")
        g.themeChanged()

        // The timelapse brings items in one by one.
        g.startTimelapse()
        for _ in 0..<20 { _ = g.makeFrame(size: size, pixelRatio: 2, appearance: window.effectiveAppearance) }
        let shown = g.makeFrame(size: size, pixelRatio: 2, appearance: window.effectiveAppearance).styles.filter { $0.alpha > 0 }.count
        check(g.timelapse != nil && shown > 0 && shown < g.layout.nodes.count, "the timelapse starts with a few items and adds the rest",
              "\(shown) of \(g.layout.nodes.count) showing")
        g.stopTimelapse()
        g.settle(ticks: 200, size: size)

        // Hover the most connected node.
        if let hub = g.layout.nodes.indices.max(by: { g.layout.nodes[$0].degree < g.layout.nodes[$1].degree }) {
            let p = g.sim.positions()
            if hub < p.count {
                g.pointerMoved(g.screen(p[hub]))
                _ = SmokeTest.wait(1) { false }
                let h = g.hover
                check(h != nil && !(h?.reasons.isEmpty ?? true), "hovering a node shows why it's connected",
                      h.map { "\($0.title): " + $0.reasons.joined(separator: " | ") } ?? "no card")
                for _ in 0..<30 { _ = g.makeFrame(size: size, pixelRatio: 2, appearance: window.effectiveAppearance) }
                shot("10-graph-hover.png")
                g.pointerExited()
                for _ in 0..<30 { _ = g.makeFrame(size: size, pixelRatio: 2, appearance: window.effectiveAppearance) }
            }
        }

        // The settings panel, with topics on.
        GraphSettingsStore.shared.value.panelOpen = true
        GraphSettingsStore.shared.value.openSections = ["Filters", "Display", "Forces"]
        _ = SmokeTest.wait(1.5) { false }
        shot("11-graph-settings.png")
        GraphSettingsStore.shared.value.panelOpen = false

        // The local graph follows a note.
        let plan = notesRoot.appendingPathComponent("Browser plan.md")
        model.openNote(plan)
        let l = GraphController.local
        let localOK = SmokeTest.wait(10) { l.layout.center != nil && l.layout.nodes.count > 3 }
        check(localOK, "the right panel's local graph follows the focused note",
              "\(l.layout.nodes.count) nodes around \(l.layout.center.map { l.layout.nodes[$0].title } ?? "nothing")")
        let lsize = l.view?.bounds.size ?? CGSize(width: 280, height: LocalGraphSlot.canvasHeight)
        l.settle(ticks: 300, size: lsize)
        shot("12-graph-local.png")

        // The graph next to the note in a split.
        model.openInSplit(graphTab, side: .right)
        _ = SmokeTest.wait(2) { false }
        if let v = g.view { g.settle(ticks: 200, size: v.bounds.size) }
        check(g.youAreHereKey == URLKey.fileKey(plan), "in a split, the note next to the graph gets the you-are-here ring")
        _ = SmokeTest.wait(3) { l.layout.center != nil }
        check(l.centerKey == URLKey.fileKey(plan), "with the graph focused in a split, the local graph follows the note beside it")
        shot("13-graph-split.png")
        if let sp = model.currentSplit { model.separate(sp) }
    }
}
