import AppKit
import Foundation

/// Moving today's sidebar folders onto disk, and pinned folders: what the sidebar shows is read
/// from disk, follows changes made in Finder, and dragging in and out files things on disk. All of
/// it in throwaway folders, with a stand-in for the Trash.
enum PinnedFolderTests {
    static func check(_ ok: Bool, _ label: String, _ detail: String = "") { SelfTest.check(ok, label, detail) }

    static func run(dir: URL) {
        let base = dir.appendingPathComponent("pinned-folders", isDirectory: true)
        let before = Paths.overrideRoot
        defer {
            Paths.overrideRoot = before
            Settings.shared.reloadFromDisk()
            FolderMeta.shared.reload()
        }
        MainActor.assumeIsolated {
            BrowserModel.useEphemeralStore = true
            migration(base.appendingPathComponent("migration"))
            pinned(base.appendingPathComponent("pinned"))
        }
    }

    // MARK: A demo-like profile from before space folders

    static let home = "61111111-1111-4111-8111-111111111111"
    static let work = "62222222-2222-4222-8222-222222222222"
    static let fReading = "63333333-3333-4333-8333-333333333331"
    static let fDeep = "63333333-3333-4333-8333-333333333332"
    static let fClients = "63333333-3333-4333-8333-333333333333"
    static let fClients2 = "63333333-3333-4333-8333-333333333334"
    static let t = (1...10).map { String(format: "64444444-4444-4444-8444-%012d", $0) }

    /// state.json the way a build from before space folders wrote it, with folders inside folders,
    /// pages with and without a pinned address, a note, a note whose file is gone, an app page,
    /// and two folders with the same name.
    static func legacyState(notes: URL) -> String {
        """
        {
          "currentSpace" : "\(home)",
          "folders" : [
            { "createdAt" : "2026-11-01T09:00:00Z", "id" : "\(fReading)", "isExpanded" : true, "name" : "Reading", "order" : 0, "spaceID" : "\(home)" },
            { "createdAt" : "2026-11-01T09:00:00Z", "id" : "\(fDeep)", "isExpanded" : false, "name" : "Deep: cuts", "order" : 0, "spaceID" : "\(home)", "parentID" : "\(fReading)" },
            { "createdAt" : "2026-11-02T09:00:00Z", "id" : "\(fClients)", "isExpanded" : true, "name" : "Clients", "order" : 0, "spaceID" : "\(work)" },
            { "createdAt" : "2026-11-02T09:00:00Z", "id" : "\(fClients2)", "isExpanded" : true, "name" : "Clients", "order" : 1, "spaceID" : "\(work)" }
          ],
          "spaces" : [
            { "color" : "#7A8CA8", "icon" : "house", "id" : "\(home)", "name" : "Home" },
            { "color" : "#4C8DF6", "icon" : "briefcase", "id" : "\(work)", "name" : "Work" }
          ],
          "tabs" : [
            { "createdAt" : "2026-11-02T10:00:00Z", "folderID" : "\(fReading)", "id" : "\(t[0])", "isPinned" : false, "kind" : "web",
              "order" : 1, "spaceID" : "\(home)", "title" : "An essay", "url" : "https://example.com/essay/page-2", "pinnedURL" : "https://example.com/essay" },
            { "createdAt" : "2026-11-02T10:00:00Z", "folderID" : "\(fReading)", "id" : "\(t[1])", "isPinned" : false, "kind" : "web",
              "order" : 0, "spaceID" : "\(home)", "title" : "First / best", "url" : "https://example.com/first" },
            { "createdAt" : "2026-11-02T10:00:00Z", "folderID" : "\(fReading)", "id" : "\(t[2])", "isPinned" : false, "kind" : "note",
              "order" : 2, "spaceID" : "\(home)", "title" : "Plan", "url" : "\(notes.appendingPathComponent("Plan.md").absoluteString)" },
            { "createdAt" : "2026-11-02T10:00:00Z", "folderID" : "\(fReading)", "id" : "\(t[3])", "isPinned" : false, "kind" : "note",
              "order" : 3, "spaceID" : "\(home)", "title" : "Gone", "url" : "\(notes.appendingPathComponent("Gone.md").absoluteString)" },
            { "createdAt" : "2026-11-02T10:00:00Z", "folderID" : "\(fDeep)", "id" : "\(t[4])", "isPinned" : false, "kind" : "web",
              "order" : 0, "spaceID" : "\(home)", "title" : "Deep page", "url" : "https://example.com/deep" },
            { "createdAt" : "2026-11-02T10:00:00Z", "folderID" : "\(fClients)", "id" : "\(t[5])", "isPinned" : false, "kind" : "app",
              "order" : 0, "spaceID" : "\(work)", "title" : "History", "url" : "browser://history" },
            { "createdAt" : "2026-11-02T10:00:00Z", "folderID" : "\(fClients2)", "id" : "\(t[6])", "isPinned" : false, "kind" : "web",
              "order" : 0, "spaceID" : "\(work)", "title" : "Client site", "url" : "https://client.example/" },
            { "createdAt" : "2026-11-05T06:00:00Z", "id" : "\(t[7])", "isPinned" : false, "kind" : "web", "order" : 3, "spaceID" : "\(home)",
              "title" : "Loose page", "url" : "https://example.com/loose" }
          ],
          "version" : 3
        }
        """
    }

    static func uuid(_ s: String) -> UUID { UUID(uuidString: s)! }

    /// Every file and link under `dir`, with what a link points at, to compare two runs.
    static func listing(_ dir: URL) -> [String] {
        var out: [String] = []
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        while let u = e?.nextObject() as? URL {
            let rel = String(u.path.dropFirst(dir.path.count))
            let extra = FileLink.isLink(u) ? " -> " + (FileLink.resolve(u)?.lastPathComponent ?? "?") : (u.pathExtension == "webloc" ? " = " + (Webloc.read(u)?.url.absoluteString ?? "?") : "")
            out.append(rel + extra)
        }
        return out.sorted()
    }

    @MainActor static func migration(_ dir: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        let original = dir.appendingPathComponent("profile", isDirectory: true)
        let notes = dir.appendingPathComponent("Notes", isDirectory: true)
        Paths.ensure(original)
        Paths.ensure(notes)
        try? Data("# Plan\n".utf8).write(to: notes.appendingPathComponent("Plan.md"))
        let stateText = legacyState(notes: notes)
        try? Data(stateText.utf8).write(to: original.appendingPathComponent("state.json"))
        var settings = AppSettings()
        settings.notesFolders = [notes.path]
        try? JSONEncoder.pretty.encode(settings).write(to: original.appendingPathComponent("settings.json"))
        // The move runs on a copy, as the shots and the demo do.
        let copy = dir.appendingPathComponent("copy", isDirectory: true)
        try? fm.copyItem(at: original, to: copy)
        let trash = dir.appendingPathComponent("fake-trash", isDirectory: true)
        Paths.ensure(trash)
        let saved = (enabled: SpaceFolders.enabled, root: SpaceFolders.overrideRoot, recycle: NotesStore.recycle)
        defer { SpaceFolders.enabled = saved.enabled; SpaceFolders.overrideRoot = saved.root; NotesStore.recycle = saved.recycle; SpaceFolders.refreshLinkedRoots() }
        Paths.overrideRoot = copy
        Settings.shared.reloadFromDisk()
        BrowserPrefs.shared.reload()
        FolderMeta.shared.reload()
        SpaceFolders.enabled = true
        SpaceFolders.customRoot = nil
        let root = copy.appendingPathComponent("Space Folders", isDirectory: true)
        SpaceFolders.overrideRoot = root

        let m = BrowserModel()
        let homeDir = root.appendingPathComponent("Home"), reading = homeDir.appendingPathComponent("Reading")
        check(m.diskFolders && SpaceFolders.isDirectory(homeDir) && SpaceFolders.isDirectory(root.appendingPathComponent("Work")),
              "the move gives each space its folder")
        check(SpaceFolders.isDirectory(reading) && SpaceFolders.isDirectory(reading.appendingPathComponent("Deep- cuts"))
              && SpaceFolders.isDirectory(root.appendingPathComponent("Work/Clients")) && SpaceFolders.isDirectory(root.appendingPathComponent("Work/Clients 2")),
              "each sidebar folder and subfolder becomes a real folder, and two with the same name get a number")
        check(Webloc.read(reading.appendingPathComponent("An essay.webloc"))?.url.absoluteString == "https://example.com/essay",
              "a page with a pinned address is saved at that address")
        check(Webloc.read(reading.appendingPathComponent("First - best.webloc"))?.url.absoluteString == "https://example.com/first"
              && Webloc.read(reading.appendingPathComponent("Deep- cuts/Deep page.webloc")) != nil
              && Webloc.read(root.appendingPathComponent("Work/Clients/History.webloc"))?.url.absoluteString == "browser://history",
              "pages, pages in subfolders and app pages become saved pages")
        check(FileLink.resolve(reading.appendingPathComponent("Plan"))?.path == notes.appendingPathComponent("Plan.md").standardizedFileURL.path
              && SpaceFolders.exists(notes.appendingPathComponent("Plan.md")), "a note becomes a link to its file, and the file stays where it is")
        check(FileLink.resolve(homeDir.appendingPathComponent("Notes"))?.path == notes.standardizedFileURL.path, "the notes folders are linked into Home")
        let top = m.childFolders(of: nil, space: uuid(home))
        check(top.map(\.id) == [uuid(fReading)] && top.first?.path == "Home/Reading" && top.first?.bookmark != nil,
              "the top folders are pinned, keeping their place")
        check(m.childFolders(of: uuid(fReading)).map(\.id) == [uuid(fDeep)] && m.folder(uuid(fDeep))?.isExpanded == false,
              "a subfolder keeps its place and whether it was open")
        check(m.childFolders(of: nil, space: uuid(work)).map(\.name) == ["Clients", "Clients 2"], "folders stay in order")
        let inReading = m.refs(in: .folder(uuid(fReading))).map(\.id)
        check(inReading == [uuid(t[1]), uuid(t[0]), uuid(t[2])], "the same tabs stay in the folder, in the same order",
              inReading.map { m.tab($0)?.displayTitle ?? "?" }.joined(separator: ", "))
        check(m.tab(uuid(t[0]))?.savedFile == "Home/Reading/An essay.webloc" && m.tab(uuid(t[0]))?.url?.absoluteString == "https://example.com/essay/page-2",
              "a tab keeps the page it was on and remembers its saved page")
        check(m.tab(uuid(t[3]))?.folderID == nil && m.tab(uuid(t[3])) != nil, "a note whose file is gone stays, in Tabs")
        check(m.tab(uuid(t[7]))?.folderID == nil && m.tab(uuid(t[7]))?.savedFile == nil, "loose tabs aren't touched")
        m.saveNow()
        let after = (try? String(contentsOf: copy.appendingPathComponent("state.json"), encoding: .utf8)) ?? ""
        check(after.contains("\"diskFolders\" : 1"), "the state records that the move finished")
        check((try? String(contentsOf: original.appendingPathComponent("state.json"), encoding: .utf8)) == stateText
              && !SpaceFolders.exists(original.appendingPathComponent("Space Folders")), "the profile it was copied from isn't touched")

        // Twice: a second launch moves nothing, and a run cut short before the state was saved
        // reuses what it wrote.
        let first = listing(root)
        let m2 = BrowserModel()
        check(listing(root) == first && m2.folders.count == m.folders.count && m2.tabs.count == m.tabs.count, "a second launch doesn't move anything again")
        if let legacy = SavedFile.read(SavedState.self, from: original.appendingPathComponent("state.json"), label: "test"),
           let (again, report) = try? SpaceFolderMigration.run(legacy, notesFolders: [notes.path], root: root) {
            check(listing(root) == first && report.pages == 0 && report.notes == 0 && report.linkedFolders == 0 && report.reused >= 9,
                  "running the move again after it was cut short makes nothing twice", "\(report)")
            check(again.diskFolders == 1 && again.folders.allSatisfy { $0.path != nil }, "and still finishes")
        } else {
            check(false, "the move runs again on the old state")
        }

        // When it can't write, the old folders keep working and it tries again next time.
        let blocked = dir.appendingPathComponent("blocked")
        try? Data("a file where the folder would go".utf8).write(to: blocked)
        let copy2 = dir.appendingPathComponent("copy2", isDirectory: true)
        try? fm.copyItem(at: original, to: copy2)
        Paths.overrideRoot = copy2
        SpaceFolders.overrideRoot = blocked.appendingPathComponent("Space Folders")
        let m3 = BrowserModel()
        check(!m3.diskFolders && m3.folders.count == 4 && m3.folders.allSatisfy { $0.path == nil } && m3.refs(in: .folder(uuid(fReading))).count == 4,
              "if the move fails, the old folders stay as they were")
        m3.saveNow()
        let kept = (try? String(contentsOf: copy2.appendingPathComponent("state.json"), encoding: .utf8)) ?? ""
        check(!kept.contains("diskFolders"), "and the move is tried again next launch")
        Paths.overrideRoot = copy
        SpaceFolders.overrideRoot = root
        Settings.shared.reloadFromDisk()
        FolderMeta.shared.reload()
    }

    // MARK: Pinned folders

    @MainActor static func pinned(_ dir: URL) {
        SpaceFolderTests.withSpaceFolders(dir) { root, trash in
            Paths.overrideRoot = dir
            Settings.shared.reloadFromDisk()
            FolderMeta.shared.reload()
            let m = ArcZenTests.freshModel()
            check(m.diskFolders, "a new profile starts with its folders on disk")
            guard let homeDir = m.currentSpace.flatMap({ m.spaceFolderURL($0) }) else { check(false, "a home folder"); return }

            // + makes a folder in the space's folder and pins it.
            let work = m.createFolder(named: "Work")
            let workDir = homeDir.appendingPathComponent("Work")
            check(SpaceFolders.isDirectory(workDir) && work.path == "Home/Work" && work.parentID == nil && m.pinnedFolders.map(\.id) == [work.id],
                  "a new folder is made in the space's folder and pinned")
            let q3 = m.createFolder(named: "Q3", in: work.id)
            check(SpaceFolders.isDirectory(workDir.appendingPathComponent("Q3")) && q3.parentID == work.id, "a subfolder is made inside it on disk")

            // A tab dragged into a pinned folder is saved there.
            let page = ArcZenTests.page(m, "https://example.com/report", "Quarterly report")
            m.place([.tab(page.id)], in: .folder(work.id), at: 0)
            let saved = workDir.appendingPathComponent("Quarterly report.webloc")
            check(Webloc.read(saved)?.url.absoluteString == "https://example.com/report" && page.folderID == work.id && page.savedFile == "Home/Work/Quarterly report.webloc",
                  "dragging a tab onto a pinned folder saves it there")
            m.syncPinnedFolders()
            check(m.refs(in: .folder(work.id)) == [.tab(page.id)], "the folder shows it, once")

            // What's on disk shows up: added, renamed and deleted in Finder.
            try? SpaceFolders.savePage(URL(string: "https://example.com/finder")!, title: "From Finder", in: workDir)
            m.syncPinnedFolders()
            let fromFinder = m.tabs.first { $0.savedFile == "Home/Work/From Finder.webloc" }
            check(fromFinder?.folderID == work.id && fromFinder?.isLoaded == false && m.refs(in: .folder(work.id)).last == fromFinder.map { .tab($0.id) },
                  "a page saved in Finder shows up at the end of the folder")
            try? FileManager.default.moveItem(at: workDir.appendingPathComponent("Q3"), to: workDir.appendingPathComponent("Q4"))
            m.syncPinnedFolders()
            check(m.childFolders(of: work.id).map(\.name) == ["Q4"], "a folder renamed in Finder shows its new name")
            try? FileManager.default.removeItem(at: workDir.appendingPathComponent("From Finder.webloc"))
            m.syncPinnedFolders()
            check(fromFinder.map { m.tab($0.id) == nil } == true, "a page deleted in Finder leaves the folder")
            try? FileManager.default.moveItem(at: workDir, to: homeDir.appendingPathComponent("Work renamed"))
            m.syncPinnedFolders()
            check(m.folder(work.id)?.name == "Work renamed" && m.folder(work.id)?.path == "Home/Work renamed" && page.savedFile == "Home/Work renamed/Quarterly report.webloc",
                  "a pinned folder renamed in Finder is found again, and its pages with it")
            let workDir2 = homeDir.appendingPathComponent("Work renamed")

            // Rain's own order, kept on disk.
            let second = ArcZenTests.page(m, "https://example.com/second", "Second")
            m.place([.tab(second.id)], in: .folder(work.id), at: 0)
            m.syncPinnedFolders()
            check(m.refs(in: .folder(work.id)).first == .tab(second.id) && FolderMeta.shared.order(of: workDir2).contains("Second.webloc"),
                  "dragging to reorder keeps Rain's order for the folder")

            // Opening an item that's already in the sidebar goes to its tab.
            if let e = SpaceFolders.entry(workDir2.appendingPathComponent("Second.webloc")) {
                let n = m.tabs.count
                check(m.openFolderEntry(e)?.id == second.id && m.tabs.count == n, "opening a saved page that's in a pinned folder goes to its tab")
            }
            // Closing a page in a folder goes back to its saved address and unloads it.
            second.url = URL(string: "https://example.com/second/elsewhere")
            m.close(second)
            check(second.url?.absoluteString == "https://example.com/second" && !second.isLoaded && m.tab(second.id) != nil,
                  "closing a page in a folder takes it back to the saved page")

            // Dragging a page out to Tabs takes it out of the folder, and its saved page goes to the Trash.
            m.place([.tab(page.id)], in: .today, at: 0)
            _ = SelfTest.spin(3) { !SpaceFolders.exists(workDir2.appendingPathComponent("Quarterly report.webloc")) }
            check(page.folderID == nil && page.savedFile == nil && !SpaceFolders.exists(workDir2.appendingPathComponent("Quarterly report.webloc"))
                  && SpaceFolders.exists(trash.appendingPathComponent("Quarterly report.webloc")), "dragging a page out to Tabs moves its saved page to the Trash")

            // A note from elsewhere dropped on a pinned folder gets a link. Dragged out, the link stays
            // and the note opens as a tab.
            let vault = dir.appendingPathComponent("Vault", isDirectory: true)
            Paths.ensure(vault)
            let noteURL = vault.appendingPathComponent("Idea.md")
            try? Data("# Idea\n".utf8).write(to: noteURL)
            let note = m.openNote(noteURL, select: false)
            m.place([.tab(note.id)], in: .folder(work.id), at: Int.max)
            check(FileLink.resolve(workDir2.appendingPathComponent("Idea"))?.path == noteURL.standardizedFileURL.path && note.folderID == work.id
                  && SpaceFolders.exists(noteURL), "a note dropped on a pinned folder is linked there, and stays where it is")
            m.place([.tab(note.id)], in: .today, at: 0)
            check(note.folderID == work.id && m.refs(in: .today).contains { m.tab($0.id)?.url?.path == noteURL.standardizedFileURL.path && $0.id != note.id },
                  "dragging a note out of a folder opens it as a tab, and it stays in the folder")

            // Moving folders: inside another moves it on disk, to the top pins it where it is.
            let later = m.createFolder(named: "Later")
            check(m.nestFolder(later.id, into: work.id) && SpaceFolders.isDirectory(workDir2.appendingPathComponent("Later"))
                  && !SpaceFolders.exists(homeDir.appendingPathComponent("Later")) && m.folder(later.id)?.parentID == work.id,
                  "a pinned folder dropped into another moves there on disk")
            if let q4 = m.childFolders(of: work.id).first(where: { $0.name == "Q4" }) {
                check(m.placeFolder(q4.id, in: nil, at: 0) && m.pinnedFolders.first?.path == "Home/Work renamed/Q4"
                      && SpaceFolders.isDirectory(workDir2.appendingPathComponent("Q4")), "a subfolder dragged to the top is pinned and stays where it is")
                if let pin = m.pinnedFolders.first {
                    m.renameFolder(pin, to: "Q5")
                    check(SpaceFolders.isDirectory(workDir2.appendingPathComponent("Q5")) && m.folder(pin.id)?.name == "Q5", "renaming a folder renames it on disk")
                    m.deleteFolder(m.folder(pin.id)!)
                    check(m.folder(pin.id) == nil && SpaceFolders.isDirectory(workDir2.appendingPathComponent("Q5")), "unpinning leaves the folder on disk")
                }
            }

            // Pinning from the popup.
            let pinnedAgain = m.pinFolder(workDir2.appendingPathComponent("Q5"))
            let count = m.pinnedFolders.count
            m.pinFolder(workDir2.appendingPathComponent("Q5"))
            check(pinnedAgain != nil && m.pinnedFolders.count == count, "pinning a folder that's already pinned doesn't add it twice")
            m.toastState = nil
            _ = root
        }
    }
}
