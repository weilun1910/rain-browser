import Foundation

/// Split view: the model, Add to research into the note pane, and Related following focus.
enum SplitTests {
    static func check(_ ok: Bool, _ label: String, _ detail: String = "") { SelfTest.check(ok, label, detail) }

    static func run(dir: URL) {
        let root = dir.appendingPathComponent("notes-root", isDirectory: true)
        let n1 = root.appendingPathComponent("split-left.md")
        let n2 = root.appendingPathComponent("split-right.md")
        SelfTest.write("# Starter care\n\nMy sourdough starter needs rye flour feeding and warmer hydration for the levain.\n", to: n1)
        SelfTest.write("# Extension plan\n\nLoad Chrome extensions with WKWebExtensionController in the WebKit browser, then handle native messaging for Bitwarden.\n", to: n2)
        MainActor.assumeIsolated {
            BrowserModel.useEphemeralStore = true
            try? FileManager.default.removeItem(at: Paths.stateFile)
            let model = BrowserModel()
            let page = Tab(url: URL(string: "about:blank")!, title: "A page")
            page.model = model
            model.tabs.append(page)
            let a = model.openNote(n1)
            let b = model.openNote(n2, select: false)

            // Open: pairs the new item with the current one.
            model.openInSplit(b, side: .right)
            let sp = model.currentSplit
            check(sp?.left == a.id && sp?.right == b.id && sp?.focusRight == true && !model.looseTabs.contains { $0.id == a.id || $0.id == b.id },
                  "open in split view pairs the item with the current one and joins them in the sidebar")
            // Swap.
            if let sp { model.swap(sp) }
            check(model.currentSplit?.left == b.id && model.currentSplit?.right == a.id, "swap sides")
            // Related follows the focused pane.
            model.focusPane(.left)
            _ = SelfTest.spin(5) { model.document?.state == .ready && model.resurfacer.context?.key == URLKey.fileKey(n2) }
            _ = SelfTest.spin(5) { !model.resurfacer.isWorking }
            let keyLeft = model.resurfacer.context?.key
            model.focusPane(.right)
            _ = SelfTest.spin(5) { model.document?.state == .ready && model.resurfacer.context?.key == URLKey.fileKey(n1) }
            let keyRight = model.resurfacer.context?.key
            check(keyLeft == URLKey.fileKey(n2) && keyRight == URLKey.fileKey(n1), "Related takes its context from the focused pane")
            _ = SelfTest.spin(5) { !model.resurfacer.isWorking }
            _ = SelfTest.spin(3) { false } // let earlier index notifications settle
            let before = model.resurfacer.retrievalCount
            model.focusPane(.left)
            model.focusPane(.right)
            _ = SelfTest.spin(1) { false }
            check(model.resurfacer.retrievalCount == before, "toggling focus back uses cached cards instead of refetching",
                  "\(before) -> \(model.resurfacer.retrievalCount)")
            // Persistence round trip.
            model.setSplitRatio(0.62, save: false)
            model.saveNow()
            let saved = model.currentSplit
            let reloaded = BrowserModel()
            let r = reloaded.splits.first
            check(r?.id == saved?.id && r?.left == saved?.left && r?.right == saved?.right && r?.ratio == saved?.ratio
                  && r?.focusRight == saved?.focusRight && reloaded.currentSplit?.id == saved?.id, "splits and divider positions survive a relaunch",
                  "\(reloaded.splits.first?.ratio ?? -1)")
            // Close a pane: the other one stays, full width.
            model.focusPane(.right)
            model.closeCurrent()
            check(model.splits.isEmpty && model.currentTab?.id == b.id && model.currentSplit == nil,
                  "Cmd-W closes the focused pane and leaves the other one full width")
            check(FileManager.default.fileExists(atPath: n1.path), "closing a note pane leaves its file")
            // Separate.
            let c = model.openNote(n1, select: false)
            model.openInSplit(c)
            if let s2 = model.currentSplit { model.separate(s2) }
            check(model.splits.isEmpty && model.looseTabs.contains { $0.id == c.id } && model.looseTabs.contains { $0.id == b.id },
                  "separate puts both back as normal items")
            // Add to research with the page focused goes into the note pane.
            model.select(page)
            model.openInSplit(c, side: .right)
            model.focusPane(.left)
            _ = SelfTest.spin(5) { model.docs[n1.standardizedFileURL.path]?.state == .ready }
            if let meta = IndexStore.shared.doc(key: SelfTest.fixtures[3].key) {
                let m = Match(doc: meta, keyword: 1, semantic: 1, entity: 0, score: 1, passage: "", sharedTerms: [], sharedEntities: [],
                              topicTerms: [], penalized: false)
                let msg = model.addToResearch(Card(match: m, reason: ""))
                let text = SelfTest.read(n1)
                check(model.currentTab?.id == page.id && msg == "Added to note" && text.contains("## Related") && text.contains(meta.url),
                      "Add to research from the page pane goes into the note pane", msg)
            } else {
                check(false, "fixture page for Add to research")
            }
            model.prepareForQuit()
        }
    }
}
