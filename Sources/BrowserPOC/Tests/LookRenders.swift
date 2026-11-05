import AppKit
import SwiftUI
import WebKit

/// `--render-review <dir>`: light and dark snapshots of every main view, rendered offscreen from
/// the real model against a throwaway folder, the same way the smoke test runs. For looking at
/// alignment, spacing, contrast and density without opening a window.
@MainActor
enum LookRenders {
    static let page2 = """
    <!doctype html><html><head><title>Sourdough hydration, explained</title>
    <style>body{font:16px/1.6 -apple-system,system-ui;margin:56px auto;max-width:640px;padding:0 24px;color:#222}
    h1{font:600 30px/1.2 -apple-system;margin:0 0 16px} p{color:#444} @media (prefers-color-scheme: dark){body{background:#1e1e1e;color:#ddd} p{color:#aaa}}</style></head>
    <body><h1>Sourdough hydration, explained</h1>
    <p>Hydration is the weight of water divided by the weight of flour. A 75 percent dough is slack and open, a 65 percent dough is easier to shape.
    A sluggish starter and a cold kitchen both slow fermentation, so the same recipe behaves differently in winter.</p>
    <p>Feed the levain with rye the night before, keep it warm, and mix when it has doubled and smells pleasantly sour.</p></body></html>
    """

    static func styledPage(_ html: String) -> String {
        html.replacingOccurrences(of: "</head>", with: """
        <style>body{font:16px/1.6 -apple-system,system-ui;margin:56px auto;max-width:640px;padding:0 24px;color:#222}
        h1{font:600 30px/1.2 -apple-system} nav{display:none} @media (prefers-color-scheme: dark){body{background:#1e1e1e;color:#ddd}}</style></head>
        """)
    }

    static func run(out: URL) -> Int32 {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BrowserPOC-renders-\(UUID().uuidString)")
        Paths.ensure(dir)
        Paths.overrideRoot = dir
        defer { try? FileManager.default.removeItem(at: dir) }
        Paths.ensure(out)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        print("Rendering into \(out.path)")

        do { IndexStore.shared = try IndexStore(url: dir.appendingPathComponent("index.sqlite")) } catch {
            print("Couldn't open the index: \(error)")
            return 1
        }
        SelfTest.seed(IndexStore.shared, now: Date())
        BrowserModel.useEphemeralStore = true
        SpaceTintBackground.forceActive = true
        // Snapshots catch views mid-animation otherwise.
        Motion.forceReduce = true
        let notesRoot = dir.appendingPathComponent("Notes", isDirectory: true)
        Paths.ensure(notesRoot)
        Settings.shared.update { $0.notesFolders = [notesRoot.path]; $0.firstRunDone = false; $0.rightPanelOpen = true }

        let model = BrowserModel()
        model.notes.reload()
        let window = SmokeTest.offscreenWindow(MainView.host(model), size: NSSize(width: 1380, height: 860))
        WindowChrome.configure(window)
        func shoot(_ name: String) { both(window, name, out) }

        // 1. First run, and the Chrome permission help inside it.
        shoot("01-first-run")
        ChromeImporter.shared.phase = .needsPermission
        shoot("02-chrome-permission")
        ChromeImporter.shared.phase = .idle
        Settings.shared.update { $0.firstRunDone = true }

        // 2. The empty start view.
        shoot("03-start")

        // 3. A page with Related cards.
        let tab = model.newTab(url: nil, select: true)
        tab.ensureWebView().loadHTMLString(styledPage(SmokeTest.webkitPage), baseURL: URL(string: "https://smoke.test/chrome-extensions-in-wkwebview")!)
        _ = SmokeTest.wait(15) { !model.resurfacer.cards.isEmpty && !tab.isLoading }
        _ = SmokeTest.wait(1) { false }
        shoot("04-page-related")

        // 4. A note with Related cards, then its preview.
        guard let noteURL = model.notes.create(in: model.newNotesFolder, title: "Feeding schedule") else { print("Couldn't create a note"); return 1 }
        let noteText = """
        # Feeding schedule

        My sourdough starter is sluggish after feeding and the levain smells of acetone. Try rye flour and a warmer spot.

        ## This week

        - Feed twice a day, equal weights of flour and water
        - Move the jar on top of the fridge
        - Bake on Saturday if it doubles in six hours

        Notes from the last bake are in the bread log.
        """
        try? noteText.write(to: noteURL, atomically: true, encoding: .utf8)
        let noteTab = model.openNote(noteURL)
        _ = SmokeTest.wait(5) { model.document?.state == .ready }
        _ = SmokeTest.wait(10) { !model.resurfacer.cards.isEmpty }
        shoot("05-note-related")
        if let d = model.document {
            d.showPreview = true
            _ = SmokeTest.wait(2) { false }
            shoot("06-note-preview")
            d.showPreview = false
        }

        // 5. A page and a note side by side, the note focused.
        model.openInSplit(tab, side: .left)
        model.focusPane(.right)
        _ = SmokeTest.wait(2) { false }
        shoot("07-split")
        if let sp = model.currentSplit { model.separate(sp) }

        // 6. Folders and pins in Home, then a second space with its own colour.
        let research = model.createFolder(named: "Research")
        model.move(noteTab, to: research.id)
        let page2 = model.newTab(url: nil, select: false)
        page2.ensureWebView().loadHTMLString(page2HTML, baseURL: URL(string: "https://bread.test/hydration")!)
        _ = SmokeTest.wait(5) { !page2.isLoading && page2.title != "" }
        model.move(page2, to: research.id)
        model.togglePin(tab)
        model.select(tab)
        _ = SmokeTest.wait(2) { false }
        shoot("08-folders-home")
        let work = model.createSpace(name: "Work", icon: "briefcase", color: "#4C8DF6")
        model.switchSpace(to: work.id)
        let workNote = model.notes.create(in: model.newNotesFolder, title: "Launch checklist")
        if let workNote {
            try? "# Launch checklist\n\n- Icon and name\n- Demo video\n- Post on X and LinkedIn\n".write(to: workNote, atomically: true, encoding: .utf8)
            _ = model.openNote(workNote)
            _ = SmokeTest.wait(3) { model.document?.state == .ready }
        }
        model.createSpace(name: "Reading", icon: "book", color: "#2FA8A0")
        model.switchSpace(to: work.id)
        _ = SmokeTest.wait(2) { false }
        shoot("09-second-space")

        // 7. The command bar over a note.
        model.switchSpace(index: 0)
        model.select(noteTab)
        _ = SmokeTest.wait(2) { model.document?.state == .ready }
        IndexStore.shared.addSearch("sourdough starter rye")
        model.bar.open(.newTab, text: "sourdough")
        _ = SmokeTest.wait(1) { false }
        shoot("10-command-bar")
        model.bar.close()

        // 8. The right panel hidden.
        Settings.shared.update { $0.rightPanelOpen = false }
        model.select(tab)
        _ = SmokeTest.wait(1) { false }
        shoot("11-panel-hidden")
        Settings.shared.update { $0.rightPanelOpen = true }

        // 9. Settings, one tab at a time.
        let tabs: [(String, AnyView)] = [("12-settings-general", AnyView(GeneralSettings())),
                                         ("13-settings-sources", AnyView(SourcesSettings())),
                                         ("14-settings-tuning", AnyView(TuningSettings()))]
        for (name, v) in tabs {
            let w = SmokeTest.offscreenWindow(NSHostingView(rootView: v.frame(width: 580, height: 620)), size: NSSize(width: 580, height: 620))
            both(w, name, out)
        }

        model.prepareForQuit()
        print("Done.")
        return 0
    }

    static var page2HTML: String { page2 }

    /// `--render-review <dir> --profile <data dir>`: renders an existing profile instead of the
    /// fixtures. The profile's state, settings and index are copied to a throwaway folder first,
    /// so the profile itself is never changed. Notes are read where the profile points.
    static func runProfile(out: URL, profile: URL, query: String) -> Int32 {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BrowserPOC-renders-\(UUID().uuidString)")
        Paths.ensure(dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        for f in ["state.json", "settings.json", "index.sqlite", "index.sqlite-wal", "index.sqlite-shm", "favicons"] {
            try? FileManager.default.copyItem(at: profile.appendingPathComponent(f), to: dir.appendingPathComponent(f))
        }
        Paths.overrideRoot = dir
        Settings.shared.reloadFromDisk()
        Paths.ensure(out)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        print("Rendering \(profile.lastPathComponent) into \(out.path)")
        do { IndexStore.shared = try IndexStore(url: dir.appendingPathComponent("index.sqlite")) } catch {
            print("Couldn't open the index: \(error)")
            return 1
        }
        BrowserModel.useEphemeralStore = true
        SpaceTintBackground.forceActive = true
        Motion.forceReduce = true
        let model = BrowserModel()
        model.notes.reload()
        let window = SmokeTest.offscreenWindow(MainView.host(model), size: NSSize(width: 1440, height: 900))
        WindowChrome.configure(window)

        func settle() {
            _ = SmokeTest.wait(12) { !model.spaceTabs.contains { $0.isLoading } }
            _ = SmokeTest.wait(10) { !model.resurfacer.isWorking && model.resurfacer.hasContext }
            _ = SmokeTest.wait(1.5) { false }
        }
        let start = model.currentSpaceID
        let order = [start] + model.spaces.map { $0.id }.filter { $0 != start }
        for (i, id) in order.enumerated() {
            model.switchSpace(to: id)
            settle()
            let name = model.currentSpace?.name.lowercased().replacingOccurrences(of: " ", with: "-") ?? "space"
            both(window, out, "p\(i + 1)-space-\(name)")
        }
        model.switchSpace(to: start)
        settle()
        model.bar.open(.newTab, text: query)
        _ = SmokeTest.wait(1) { false }
        // Web snapshots are laid over everything, so they would cover the bar. Leave them out here.
        skipWeb = true
        both(window, out, "p\(order.count + 1)-command-bar")
        skipWeb = false
        model.bar.close()
        Settings.shared.update { $0.rightPanelOpen = false }
        _ = SmokeTest.wait(1) { false }
        both(window, out, "p\(order.count + 2)-panel-hidden")
        Settings.shared.update { $0.rightPanelOpen = true }
        print("Done.")
        return 0
    }

    static func both(_ w: NSWindow, _ out: URL, _ name: String) { both(w, name, out) }

    /// Renders the window in light and dark.
    /// Leave web view snapshots out, for scenes with something floating over a page.
    static var skipWeb = false

    static func both(_ w: NSWindow, _ name: String, _ out: URL) {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            w.appearance = NSAppearance(named: appearance)
            snapshot(w, out.appendingPathComponent("\(name)-\(suffix).png"))
        }
        w.appearance = nil
    }

    /// A rectangle in unflipped coordinates with the card radius on the chosen corners.
    static func clipPath(_ r: NSRect, roundTop: Bool, roundBottom: Bool) -> NSBezierPath {
        let rad = Theme.Radius.card
        let t = roundTop ? rad : 0, b = roundBottom ? rad : 0
        let p = NSBezierPath()
        p.move(to: NSPoint(x: r.minX + b, y: r.minY))
        p.line(to: NSPoint(x: r.maxX - b, y: r.minY))
        if b > 0 { p.appendArc(withCenter: NSPoint(x: r.maxX - b, y: r.minY + b), radius: b, startAngle: 270, endAngle: 0) }
        p.line(to: NSPoint(x: r.maxX, y: r.maxY - t))
        if t > 0 { p.appendArc(withCenter: NSPoint(x: r.maxX - t, y: r.maxY - t), radius: t, startAngle: 0, endAngle: 90) }
        p.line(to: NSPoint(x: r.minX + t, y: r.maxY))
        if t > 0 { p.appendArc(withCenter: NSPoint(x: r.minX + t, y: r.maxY - t), radius: t, startAngle: 90, endAngle: 180) }
        p.line(to: NSPoint(x: r.minX, y: r.minY + b))
        if b > 0 { p.appendArc(withCenter: NSPoint(x: r.minX + b, y: r.minY + b), radius: b, startAngle: 180, endAngle: 270) }
        p.close()
        return p
    }

    static func webViews(in v: NSView) -> [WKWebView] {
        var out: [WKWebView] = []
        for s in v.subviews {
            if let wv = s as? WKWebView { out.append(wv) } else { out += webViews(in: s) }
        }
        return out
    }

    /// Draws the window's content, then lays each web view's own snapshot over its frame,
    /// because offscreen drawing leaves web content blank.
    static func snapshot(_ w: NSWindow, _ url: URL) {
        guard let view = w.contentView else { return }
        for _ in 0..<6 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.08))
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        var shots: [(NSRect, NSImage)] = []
        for wv in webViews(in: view) where !skipWeb && !wv.isHiddenOrHasHiddenAncestor && wv.bounds.width > 20 {
            var img: NSImage?
            var done = false
            wv.takeSnapshot(with: nil) { i, _ in img = i; done = true }
            _ = SmokeTest.wait(5) { done }
            if let img { shots.append((wv.convert(wv.bounds, to: view), img)) }
        }
        if !shots.isEmpty, let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            for (r, img) in shots {
                // Round only the corners that sit on the content card's edge (8 pt from the window's
                // top or bottom). A web view under a note's header keeps square top corners.
                let m = Theme.Space.windowMargin
                let fromTop = view.isFlipped ? r.minY : view.bounds.height - r.maxY
                let fromBottom = view.isFlipped ? view.bounds.height - r.maxY : r.minY
                var rect = r
                if view.isFlipped { rect.origin.y = view.bounds.height - r.maxY }
                clipPath(rect, roundTop: abs(fromTop - m) < 1.5, roundBottom: abs(fromBottom - m) < 1.5).setClip()
                img.draw(in: rect)
                NSBezierPath(rect: view.bounds).setClip()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
            print("  \(url.lastPathComponent)")
        }
    }
}
