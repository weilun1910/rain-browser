import AppKit
import Foundation

/// `--shelf-demo --data-dir <folder>`: plays the shelf's motion in a real window without touching
/// the pointer, so it can be recorded and checked. It seeds the fixture index into that folder,
/// opens a page, then hovers along the pills, hides and shows the shelf, switches to the sidebar
/// and back, and types in a note. It refuses to run without --data-dir.
@MainActor
enum ShelfDemo {
    static var isOn: Bool { CommandLine.arguments.contains("--shelf-demo") }
    private static var t0 = Date()

    static func log(_ s: String) {
        print(String(format: "shelf-demo %5.2f  %@", Date().timeIntervalSince(t0), s))
        fflush(stdout)
    }

    static func start(model: BrowserModel) {
        guard isOn else { return }
        guard Paths.overrideRoot != nil else {
            print("--shelf-demo only runs on a throwaway profile. Pass --data-dir <folder>.")
            exit(2)
        }
        t0 = Date()
        // Nothing of WebKit's is kept on disk for the demo.
        BrowserModel.useEphemeralStore = true
        if IndexStore.shared.doc(key: SelfTest.fixtures[0].key) == nil { SelfTest.seed(IndexStore.shared, now: Date()) }
        Settings.shared.update { $0.firstRunDone = true }
        RelatedPrefs.shared.setMode(.shelf)
        after(2) {
            log("open page")
            let tab = model.newTab(url: nil, select: true)
            tab.ensureWebView().loadHTMLString(ShelfSmoke.page, baseURL: URL(string: "https://fieldnotes.smoke.test/chrome-extensions-in-webkit")!)
            waitForCards(model) { play(model) }
        }
    }

    static func after(_ s: Double, _ f: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { f() } }
    }

    static func waitForCards(_ model: BrowserModel, tries: Int = 120, _ then: @escaping @MainActor () -> Void) {
        if !model.resurfacer.cards.isEmpty { log("cards \(model.resurfacer.cards.count)"); then(); return }
        guard tries > 0 else { log("no cards"); return }
        after(0.25) { waitForCards(model, tries: tries - 1, then) }
    }

    static func play(_ model: BrowserModel) {
        let s = ShelfState.shared
        let ids = model.resurfacer.cards.map { ShelfTarget.card($0.id) }
        guard ids.count >= 2 else { log("need two cards"); return }
        var at = 2.5
        func step(_ gap: Double, _ label: String, _ f: @escaping @MainActor () -> Void) {
            at += gap
            after(at) { log(label); f() }
        }
        step(0, "hover pill 1") { s.enter(ids[0]) }
        step(1.8, "move to pill 2") { s.leave(ids[0]); s.enter(ids[1]) }
        step(1.5, "move to pill \(min(3, ids.count))") { s.leave(ids[1]); s.enter(ids[min(2, ids.count - 1)]) }
        step(1.5, "leave") { s.leave(ids[min(2, ids.count - 1)]) }
        step(1.2, "hide shelf") { RelatedPrefs.shared.toggleVisible() }
        step(1.2, "show shelf") { RelatedPrefs.shared.toggleVisible() }
        step(1.8, "sidebar") { RelatedPrefs.shared.setMode(.sidebar) }
        step(1.8, "shelf") { RelatedPrefs.shared.setMode(.shelf) }
        step(2.0, "open note") {
            guard let u = model.notes.create(in: model.newNotesFolder, title: "Starter troubleshooting") else { return }
            try? "# Starter troubleshooting\n\nThe sourdough starter is sluggish and the levain smells of acetone after feeding. Feed it rye flour twice a day and keep it warmer.\n"
                .write(to: u, atomically: true, encoding: .utf8)
            model.openNote(u)
        }
        step(4.0, "typing") {
            for i in 0..<10 { after(Double(i) * 0.15) { s.noteTyped() } }
        }
        step(4.5, "done") {}
    }
}
