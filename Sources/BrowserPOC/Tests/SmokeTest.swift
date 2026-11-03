import AppKit
import SwiftUI
import WebKit

/// `--smoketest`: drives the real browser model headless (no window) against a throwaway folder.
/// A WKWebView loads a page, the page gets captured, cards appear, and Add to research runs.
@MainActor
enum SmokeTest {
    static func wait(_ seconds: Double, until done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        return done()
    }

    /// Renders a view to a PNG without putting any window on screen.
    static func snapshot(_ view: NSView, _ url: URL) {
        for _ in 0..<5 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
            print("      snapshot: \(url.lastPathComponent)")
        }
    }

    static func offscreenWindow(_ content: NSView, size: NSSize) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.contentView = content
        return w
    }

    static let webkitPage = """
    <!doctype html><html><head><title>Loading Chrome extensions into a WKWebView browser</title>
    <meta name="description" content="Notes on WKWebExtensionController and native messaging"></head>
    <body><nav>Home Blog</nav><article><h1>Loading Chrome extensions into a WKWebView browser</h1>
    <p>A Mac browser built on WebKit loads Chrome and Safari extensions with WKWebExtensionController. Create a WKWebExtension
    from the unpacked folder with its manifest, wrap it in a WKWebExtensionContext and load it into the controller.</p>
    <p>The browser reports tab events to the controller. Password managers such as Bitwarden and 1Password need native messaging,
    and CRX packages from the Chrome Web Store have to be converted to ZIP first.</p></article></body></html>
    """

    static func run(workdir: URL?) -> Int32 {
        let dir = workdir ?? FileManager.default.temporaryDirectory.appendingPathComponent("BrowserPOC-smoke-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: dir)
        Paths.ensure(dir)
        Paths.overrideRoot = dir
        defer { if workdir == nil { try? FileManager.default.removeItem(at: dir) } }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        print("Smoke test in \(dir.path)")

        do { IndexStore.shared = try IndexStore(url: dir.appendingPathComponent("index.sqlite")) } catch {
            print("FAIL  could not open index: \(error)")
            return 1
        }
        SelfTest.seed(IndexStore.shared, now: Date())
        SelfTest.failures = 0
        func check(_ ok: Bool, _ label: String, _ detail: String = "") { SelfTest.check(ok, label, detail) }

        BrowserModel.useEphemeralStore = true
        let model = BrowserModel()
        model.notes.reload()
        let snaps = dir.appendingPathComponent("snapshots", isDirectory: true)
        Paths.ensure(snaps)
        let window = offscreenWindow(MainView.host(model), size: NSSize(width: 1380, height: 860))
        snapshot(window.contentView!, snaps.appendingPathComponent("0-first-run.png"))
        Settings.shared.update { $0.firstRunDone = true }

        // 1. A page loads in a real WKWebView and becomes the context.
        let tab = model.newTab(url: nil, select: true)
        let pageURL = URL(string: "https://smoke.test/chrome-extensions-in-wkwebview")!
        tab.ensureWebView().loadHTMLString(webkitPage, baseURL: pageURL)
        let gotCards = wait(15) { !model.resurfacer.cards.isEmpty }
        let titles = model.resurfacer.cards.map { $0.match.doc.title }
        check(gotCards, "cards appear for a WebKit page", titles.joined(separator: " | "))
        let keys = Set(model.resurfacer.cards.map { $0.match.doc.key })
        let webkitKeys = Set([0, 1, 2, 7].map { SelfTest.fixtures[$0].key })
        check(!keys.isEmpty && keys.isSubset(of: webkitKeys), "cards are all WebKit items")
        for c in model.resurfacer.cards { print("      card: \(c.match.doc.title.prefix(50))  |  \(c.reason)") }
        snapshot(window.contentView!, snaps.appendingPathComponent("1-page-with-cards.png"))

        // 2. After about five seconds the page is captured into the index.
        let key = URLKey.key(for: pageURL)
        let captured = wait(12) { IndexStore.shared.doc(key: key)?.hasText == true }
        let doc = IndexStore.shared.doc(key: key)
        check(captured && doc?.source == .web, "page is captured after it stays open", doc.map { "\($0.title), visits \($0.visitCount)" } ?? "missing")

        // 3. The on-device model rewrites reasons when it's available.
        if ReasonWriter.isAvailable {
            let got = wait(45) { model.resurfacer.cards.contains { $0.reasonFromModel } }
            let r = model.resurfacer.cards.first { $0.reasonFromModel }?.reason ?? ""
            check(got, "Foundation Models wrote a reason", r)
            let bad = r.rangeOfCharacter(from: CharacterSet(charactersIn: "\u{2013}\u{2014}\u{00B7}")) != nil
            check(!bad && r.split(separator: " ").count <= 20, "model reason is short and plain")
        } else {
            print("      Foundation Models not available: \(ReasonWriter.availabilityText). Template reasons stay.")
        }

        snapshot(window.contentView!, snaps.appendingPathComponent("2-model-reasons.png"))

        // 4. Add to research from a page goes to an auto-created Research folder.
        if let card = model.resurfacer.cards.first {
            let msg = model.addToResearch(card)
            let research = model.folders.first { $0.name == "Research" }
            let filed = research.map { model.tabs(in: $0).contains { $0.url?.absoluteString == card.match.doc.url } } ?? false
            check(msg == "Added to Research" && filed, "Add to research files the item in Research", msg)
            check(model.addToResearch(card).hasPrefix("Already"), "adding twice is a no-op")
        }

        // 5. A note about bread brings back bread items, and Add to research links them in the note.
        let notesRoot = dir.appendingPathComponent("notes-root", isDirectory: true)
        Paths.ensure(notesRoot)
        Settings.shared.update { $0.notesFolders = [notesRoot.path] }
        guard let noteURL = model.notes.create(in: model.newNotesFolder, title: "Feeding schedule") else {
            check(false, "could create a note")
            return 1
        }
        let noteText = "# Feeding schedule\n\nMy sourdough starter is sluggish after feeding and the levain smells of acetone. Try rye flour and a warmer spot.\n"
        try? noteText.write(to: noteURL, atomically: true, encoding: .utf8)
        model.openNote(noteURL)
        _ = wait(5) { model.document?.state == .ready }
        let breadKeys = Set([3, 4].map { SelfTest.fixtures[$0].key })
        let gotBread = wait(10) { model.resurfacer.cards.contains { breadKeys.contains($0.match.doc.key) } }
        check(gotBread, "a bread note brings back bread items", model.resurfacer.cards.map { $0.match.doc.title }.joined(separator: " | "))
        check(model.resurfacer.cards.allSatisfy { breadKeys.contains($0.match.doc.key) }, "and nothing else")
        if let card = model.resurfacer.cards.first {
            let msg = model.addToResearch(card)
            let saved = (try? String(contentsOf: noteURL, encoding: .utf8)) ?? ""
            check(msg == "Added to note" && saved.contains("## Related") && saved.contains(card.match.doc.url),
                  "Add to research appends a link under Related", msg)
        }

        Settings.shared.update { $0.showScores = true }
        snapshot(window.contentView!, snaps.appendingPathComponent("3-note-with-cards.png"))
        Settings.shared.update { $0.showScores = false }
        if let doc = model.document {
            doc.showPreview = true
            snapshot(window.contentView!, snaps.appendingPathComponent("4-note-preview.png"))
            doc.showPreview = false
        }
        let settingsWindow = offscreenWindow(NSHostingView(rootView: SettingsView()), size: NSSize(width: 560, height: 520))
        snapshot(settingsWindow.contentView!, snaps.appendingPathComponent("5-settings.png"))

        // 6. Typing keeps cards in place.
        if let doc = model.document {
            let before = model.resurfacer.cards.map { $0.id }
            doc.userEdited(doc.text + "\nAlso check the hydration of the dough next bake.\n")
            _ = wait(4) { false }
            let after = model.resurfacer.cards.map { $0.id }
            check(Array(after.prefix(before.count)) == before || after.isEmpty == before.isEmpty && Set(before).isSubset(of: Set(after)),
                  "cards stay in place while typing", "\(before) -> \(after)")
        }

        // 7. A page and a note side by side, focused on the page.
        if let noteTab = model.currentTab, noteTab.kind == .note {
            model.openInSplit(tab, side: .left)
            model.focusPane(.left)
            _ = wait(10) { model.resurfacer.context?.key == key && !model.resurfacer.isWorking && !model.resurfacer.cards.isEmpty }
            check(model.currentSplit != nil && model.resurfacer.context?.key == key, "a page and note split takes Related from the focused page")
            _ = wait(2) { false } // a moved web view repaints on its next frame
            var title: String?
            tab.webView?.evaluateJavaScript("document.title") { r, _ in title = (r as? String) ?? "" }
            _ = wait(5) { title != nil }
            let wv = tab.webView
            check(wv?.window === window && (wv?.frame.width ?? 0) > 300 && title == "Loading Chrome extensions into a WKWebView browser",
                  "the page pane hosts the live web view", "window \(wv?.window === window), width \(Int(wv?.frame.width ?? 0)), title \(title ?? "nil")")
            snapshot(window.contentView!, snaps.appendingPathComponent("6-split-page-and-note.png"))
        }

        // 8. A sidebar folder with a page and a note, and a second space.
        if let sp = model.currentSplit { model.separate(sp) }
        if let research = model.spaceFolders.first(where: { $0.name == "Research" }),
           let note = model.tabs.first(where: { $0.kind == .note }) {
            model.move(note, to: research.id)
            let kinds = Set(model.tabs(in: research).map { $0.kind })
            check(kinds == [.web, .note], "the Research folder holds a page and a note")
        }
        model.createSpace(name: "Work", icon: "briefcase")
        model.updateSpace(model.currentSpaceID) { $0.color = "#4C8DF6" }
        snapshot(window.contentView!, snaps.appendingPathComponent("7-folder-and-two-spaces.png"))

        model.prepareForQuit()
        print(SelfTest.failures == 0 ? "\nSmoke test passed." : "\n\(SelfTest.failures) check(s) failed.")
        return SelfTest.failures == 0 ? 0 : 1
    }
}

/// `--extract-check <url>`: loads one public page headless with a throwaway WebKit store and prints
/// what the capture script reads from it. For checking sites like notion.site by hand.
@MainActor
enum ExtractCheck {
    static func run(_ s: String) -> Int32 {
        guard let url = URL(string: s), URLKey.isIndexableWeb(url) else { print("Give an http or https URL"); return 2 }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let c = WKWebViewConfiguration()
        c.websiteDataStore = .nonPersistent()
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900), configuration: c)
        wv.load(URLRequest(url: url))
        _ = SmokeTest.wait(20) { !wv.isLoading && wv.url != nil }
        _ = SmokeTest.wait(6) { false } // client-rendered pages fill in after load
        var out: [String: Any]?
        wv.evaluateJavaScript(Tab.extractJS, in: nil, in: .defaultClient) { r in
            if case .success(let v) = r { out = v as? [String: Any] } else { out = [:] }
        }
        _ = SmokeTest.wait(10) { out != nil }
        let title = out?["title"] as? String ?? ""
        let text = out?["text"] as? String ?? ""
        print("title: \(title)")
        print("text length: \(text.count)")
        print("start: \(text.prefix(300).replacingOccurrences(of: "\n", with: " | "))")
        return text.count > 200 ? 0 : 1
    }
}
