import Foundation

/// Spaces: the model, migration from the old state file, and Related staying global.
enum SpaceTests {
    static func check(_ ok: Bool, _ label: String, _ detail: String = "") { SelfTest.check(ok, label, detail) }

    static func run(dir: URL) {
        let root = dir.appendingPathComponent("notes-root", isDirectory: true)
        MainActor.assumeIsolated {
            BrowserModel.useEphemeralStore = true
            migration(root: root)
            model(root: root, dir: dir)
        }
    }

    @MainActor
    static func migration(root: URL) {
        // A version 1 state file: no spaces, one folder, a page and a note.
        let fid = UUID(), pid = UUID(), nid = UUID()
        let old = """
        {"folders":[{"id":"\(fid.uuidString)","name":"Research","isExpanded":true,"createdAt":"2026-11-01T10:00:00Z"}],
         "tabs":[{"id":"\(pid.uuidString)","kind":"web","url":"about:blank","title":"Old page","isPinned":true,"createdAt":"2026-11-01T10:00:00Z"},
                 {"id":"\(nid.uuidString)","kind":"note","url":"\(root.appendingPathComponent("top.md").absoluteString)","title":"top","isPinned":false,"folderID":"\(fid.uuidString)","createdAt":"2026-11-01T10:00:00Z"}],
         "selectedTab":"\(nid.uuidString)"}
        """
        try? Data(old.utf8).write(to: Paths.stateFile)
        let m = BrowserModel()
        let home = m.spaces.first
        check(m.spaces.count == 1 && home?.name == "Home" && m.tabs.allSatisfy { $0.spaceID == home?.id }
              && m.folders.allSatisfy { $0.spaceID == home?.id } && m.currentTab?.id == nid && m.pinnedTabs.map { $0.id } == [pid],
              "an old state file moves into one space called Home")
        m.saveNow()
        let again = BrowserModel()
        check(again.spaces.map { $0.id } == m.spaces.map { $0.id } && again.tabs.count == 2, "the new state file reads back the same")
        try? FileManager.default.removeItem(at: Paths.stateFile)
    }

    @MainActor
    static func model(root: URL, dir: URL) {
        let m = BrowserModel()
        let home = m.currentSpaceID
        let a = m.openNote(root.appendingPathComponent("top.md"))
        let work = m.createSpace(name: "Work")
        m.switchSpace(to: work.id)
        check(m.currentSpaceID == work.id && m.currentTab == nil && m.looseTabs.isEmpty, "a new space starts empty")
        let page = Tab(url: URL(string: SelfTest.fixtures[1].key)!, title: SelfTest.fixtures[1].title)
        page.model = m
        m.tabs.append(page)
        let f = m.createFolder(named: "Extensions")
        m.move(page, to: f.id)
        check(page.spaceID == work.id && m.spaceFolders.map { $0.id } == [f.id], "tabs and folders belong to the space they're made in")
        m.switchSpace(to: home)
        check(m.currentTab?.id == a.id && m.spaceFolders.isEmpty && !m.looseTabs.contains { $0.id == page.id },
              "switching back restores the space's selection and hides the other space's items")
        // Per-space new notes folder.
        let sub = root.appendingPathComponent("ProjA", isDirectory: true)
        m.updateSpace(work.id) { $0.newNotesFolder = sub.path }
        check(m.newNotesFolder.standardizedFileURL.path == root.standardizedFileURL.path, "Home uses the app-wide new notes folder")
        m.switchSpace(to: work.id)
        check(m.newNotesFolder.standardizedFileURL.path == sub.standardizedFileURL.path, "a space can send its new notes to its own folder")
        // Move to space.
        let b = m.openNote(root.appendingPathComponent("ProjA/notes/plan.md"))
        m.move(b, toSpace: home)
        check(b.spaceID == home && !m.looseTabs.contains { $0.id == b.id }, "Move to space moves an item to another space")

        // Related isn't filtered by space: the page lives in Work, the context is in Home.
        m.switchSpace(to: home)
        let ctxNote = root.appendingPathComponent("space-context.md")
        SelfTest.write("# Extensions\n\nLoad Chrome extensions with WKWebExtensionController and WKWebExtensionContext in a WebKit browser. Handle native messaging for Bitwarden.\n", to: ctxNote)
        m.openNote(ctxNote)
        _ = SelfTest.spin(10) { m.resurfacer.cards.contains { $0.match.doc.key == SelfTest.fixtures[1].key } }
        let card = m.resurfacer.cards.first { $0.match.doc.key == SelfTest.fixtures[1].key }
        check(card != nil, "Related finds items from other spaces",
              "context \(m.resurfacer.context?.key ?? "nil"), cards \(m.resurfacer.cards.map { $0.match.doc.title.prefix(24) })")
        check(card.map { m.folderName(forURL: $0.match.doc.url) } == "Work, Extensions", "and labels them with their space",
              card.flatMap { m.folderName(forURL: $0.match.doc.url) } ?? "nil")

        // Delete: closes the space's tabs and drops its folders. Notes on disk stay.
        let planPath = root.appendingPathComponent("ProjA/notes/plan.md").path
        m.switchSpace(to: work.id)
        let n = m.openNote(root.appendingPathComponent("ProjA/notes/plan.md"))
        m.deleteSpace(work.id)
        check(m.spaces.count == 1 && m.currentSpaceID == home && !m.tabs.contains { $0.id == page.id || $0.id == n.id }
              && !m.folders.contains { $0.id == f.id } && FileManager.default.fileExists(atPath: planPath),
              "deleting a space closes its items and leaves notes on disk")
        m.prepareForQuit()
        try? FileManager.default.removeItem(at: Paths.stateFile)
    }
}
