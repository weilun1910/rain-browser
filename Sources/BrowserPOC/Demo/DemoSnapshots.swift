import AppKit
import SwiftUI
import WebKit

/// `--demo-snapshots <out> --profile <demo profile>`: renders a copy of a seeded demo profile
/// offscreen, with no window on screen: the opening moment with the Related shelf, the same
/// split with the article focused, the Swapshelf pilot plan, the Job hunt split and the graph.
/// Pages load cookie-free into a throwaway WebKit store. The profile isn't written to.
@MainActor
enum DemoSnapshots {
    static func commandLine(_ args: [String]) -> Int32 {
        func arg(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        guard let o = arg("--demo-snapshots"), let p = arg("--profile") else {
            print("Usage: --demo-snapshots <out folder> --profile <demo profile>")
            return 2
        }
        let out = URL(fileURLWithPath: (o as NSString).expandingTildeInPath, isDirectory: true)
        let profile = URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: profile.appendingPathComponent(DemoSeeder.marker).path) else {
            print("\(profile.path) isn't a demo profile.")
            return 1
        }
        return run(out: out, profile: profile)
    }

    static func run(out: URL, profile: URL) -> Int32 {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("BrowserPOC-demo-shots-\(UUID().uuidString)", isDirectory: true)
        Paths.ensure(tmp)
        Paths.ensure(out)
        defer { try? fm.removeItem(at: tmp) }
        for f in ["state.json", "settings.json", "sources.json", "browser.json", "index.sqlite", "index.sqlite-wal", "index.sqlite-shm",
                  "history.sqlite", "favicons", "demo-items", DemoSeeder.marker] + ShotProfile.folderFiles {
            try? fm.copyItem(at: profile.appendingPathComponent(f), to: tmp.appendingPathComponent(f))
        }
        Paths.overrideRoot = tmp
        ShotProfile.useSpaceFolders(in: tmp)
        ModelFiles.overrideDir = profile.appendingPathComponent("Models", isDirectory: true)
        ModelFiles.clearReadyCache()
        Settings.shared.reloadFromDisk()
        SourceSettings.shared.reload()
        RelatedPrefs.shared.reload()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        guard let store = try? IndexStore(url: tmp.appendingPathComponent("index.sqlite")) else { print("Couldn't open the index copy"); return 1 }
        IndexStore.shared = store
        GraphStore.reset(indexURL: tmp.appendingPathComponent("index.sqlite"), index: store)
        BrowserModel.useEphemeralStore = true
        SpaceTintBackground.forceActive = true
        Motion.forceReduce = true
        let model = BrowserModel()
        model.notes.reload()
        GraphRecorder.shared.attach(model)
        let window = SmokeTest.offscreenWindow(MainView.host(model), size: NSSize(width: 1440, height: 900))
        WindowChrome.configure(window)
        let shelf = ShelfState.shared
        let dark = NSAppearance(named: .darkAqua), light = NSAppearance(named: .aqua)
        func wait(_ s: Double, _ done: () -> Bool) -> Bool { SmokeTest.wait(s, until: done) }

        func cards(_ label: String) {
            let r = model.resurfacer
            print("  \(label)")
            print("    sites: " + (r.siteCards.map { String($0.match.doc.title.prefix(48)) }.joined(separator: " | ").nilIfEmpty ?? "(none)"))
            print("    docs:  " + (r.docCards.map { String($0.match.doc.title.prefix(48)) }.joined(separator: " | ").nilIfEmpty ?? "(none)"))
        }
        func settle(_ key: String?) {
            _ = wait(25) { !model.spaceTabs.contains { $0.isLoading } }
            _ = wait(20) { (key == nil || model.resurfacer.context?.key == key) && model.resurfacer.hasContext }
            _ = wait(45) { !model.resurfacer.isWorking && !model.resurfacer.cards.isEmpty }
            _ = wait(40) { !model.resurfacer.isWorking }
            _ = wait(1.5) { false }
        }
        /// Both appearances. With the shelf over a page, the page's own snapshot is drawn under
        /// the shelf and web views aren't laid over the top.
        func shoot(_ name: String, overPage tab: Tab? = nil) {
            for (suffix, a) in [("dark", dark), ("light", light)] {
                window.appearance = a
                _ = wait(0.5) { false }
                if let tab {
                    shelf.backdrop = ShelfSmoke.pageImage(tab)
                    LookRenders.skipWeb = true
                }
                LookRenders.snapshot(window, out.appendingPathComponent("\(name)-\(suffix).png"))
                shelf.backdrop = nil
                LookRenders.skipWeb = false
            }
            window.appearance = nil
        }
        func openFirstCard(_ name: String, docs: Bool, overPage tab: Tab? = nil) {
            guard let card = (docs ? model.resurfacer.docCards : model.resurfacer.siteCards).first ?? model.resurfacer.cards.first else { return }
            window.appearance = dark
            // Let the page repaint in the new appearance before taking its picture.
            _ = wait(0.8) { false }
            if let tab { shelf.backdrop = ShelfSmoke.pageImage(tab); LookRenders.skipWeb = true }
            shelf.focus(.card(card.id))
            _ = wait(1.2) { false }
            print("    open card: \(card.match.doc.title.prefix(60)): \(card.reason)")
            LookRenders.snapshot(window, out.appendingPathComponent("\(name)-dark.png"))
            shelf.closeNow()
            shelf.backdrop = nil
            LookRenders.skipWeb = false
            window.appearance = nil
        }

        print("Rendering the demo into \(out.path)")
        // 1. The opening moment: section 2 of the paper focused, next to the NFX article.
        settle(model.currentTab.flatMap { $0.url.map { $0.isFileURL ? URLKey.fileKey($0) : URLKey.key(for: $0) } })
        cards("Opening, \(model.currentTab?.title ?? "?") focused")
        shoot("1-opening-draft")
        openFirstCard("1b-opening-draft-card", docs: true)

        // 2. The article pane focused.
        if let sp = model.currentSplit, let article = sp.items.compactMap({ model.tab($0) }).first(where: { $0.kind == .web }) {
            model.focusPane(item: article.id)
            settle(article.url.map { URLKey.key(for: $0) })
            cards("Same split, \(article.title.prefix(40)) focused")
            shoot("2-opening-article", overPage: article)
            openFirstCard("2b-opening-article-card", docs: true, overPage: article)
        }

        // 3. Swapshelf: the pilot plan, a demo Google Doc.
        if let sw = model.spaces.first(where: { $0.name == "Swapshelf" }) {
            model.switchSpace(to: sw.id)
            let t = model.currentTab
            settle(t?.url.map { URLKey.key(for: $0) })
            cards("Swapshelf, \(t?.title ?? "?")")
            shoot("3-swapshelf-pilot-plan", overPage: t)
            openFirstCard("3b-swapshelf-pilot-plan-card", docs: false, overPage: t)
        }
        // 4. Job hunt: behavioral stories next to the STAR article.
        if let jh = model.spaces.first(where: { $0.name == "Job hunt" }) {
            model.switchSpace(to: jh.id)
            settle(model.currentTab.flatMap { $0.url.map { $0.isFileURL ? URLKey.fileKey($0) : URLKey.key(for: $0) } })
            cards("Job hunt, \(model.currentTab?.title ?? "?")")
            shoot("4-job-hunt-stories")
        }
        // 5. Personal: the flights note.
        if let pe = model.spaces.first(where: { $0.name == "Personal" }) {
            model.switchSpace(to: pe.id)
            settle(model.currentTab.flatMap { $0.url.map { $0.isFileURL ? URLKey.fileKey($0) : URLKey.key(for: $0) } })
            cards("Personal, \(model.currentTab?.title ?? "?")")
            shoot("5-personal-flights")
        }

        // 6. The graph, full window, back in School.
        if let sc = model.spaces.first(where: { $0.name == "School" }) { model.switchSpace(to: sc.id) }
        _ = model.openGraph()
        let g = GraphController.global
        let loaded = wait(25) { g.hasLoaded && g.layout.nodes.count > 50 }
        print("  graph: \(g.layout.nodes.count) nodes, \(g.layout.edges.count) lines\(loaded ? "" : " (still loading)")")
        let size = g.view?.bounds.size ?? CGSize(width: 1180, height: 860)
        g.settle(ticks: 900, size: size)
        for (suffix, a) in [("dark", dark), ("light", light)] {
            if let img = g.renderImage(size: size, appearance: a) {
                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("6-graph-\(suffix).png"))
                print("  6-graph-\(suffix).png")
            }
        }
        window.appearance = dark
        if let v = g.view, v.window === window {
            v.withStill { SmokeTest.snapshot(window.contentView!, out.appendingPathComponent("6b-graph-window-dark.png")) }
        }
        window.appearance = nil
        print("Done.")
        Intelligence.shared.shutdown()
        return 0
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
