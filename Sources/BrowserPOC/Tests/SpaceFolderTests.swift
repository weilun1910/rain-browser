import AppKit
import Foundation

/// Space folders: saved pages, links that survive a move, file changes that only ever reach the
/// Trash, and the model opening and saving what's in them. Everything happens in a throwaway
/// folder inside the self test's own, with a stand-in for the Trash.
enum SpaceFolderTests {
    static func check(_ ok: Bool, _ label: String, _ detail: String = "") { SelfTest.check(ok, label, detail) }

    /// Space folders on, rooted in `dir`, with a folder standing in for the Trash, for `body`.
    @MainActor static func withSpaceFolders(_ dir: URL, _ body: (URL, URL) -> Void) {
        let root = dir.appendingPathComponent("root", isDirectory: true)
        let trash = dir.appendingPathComponent("fake-trash", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        Paths.ensure(root)
        Paths.ensure(trash)
        let before = (enabled: SpaceFolders.enabled, root: SpaceFolders.overrideRoot, custom: SpaceFolders.customRoot, recycle: NotesStore.recycle)
        SpaceFolders.enabled = true
        SpaceFolders.overrideRoot = root
        SpaceFolders.customRoot = nil
        NotesStore.recycle = { urls, done in
            var moved: [URL: URL] = [:]
            for u in urls {
                let t = SpaceFolders.uniqueURL(in: trash, base: u.deletingPathExtension().lastPathComponent, ext: u.pathExtension)
                if (try? FileManager.default.moveItem(at: u, to: t)) != nil { moved[u] = t }
            }
            done(moved, nil)
        }
        defer {
            SpaceFolders.enabled = before.enabled
            SpaceFolders.overrideRoot = before.root
            SpaceFolders.customRoot = before.custom
            NotesStore.recycle = before.recycle
            SpaceFolders.refreshLinkedRoots()
        }
        FolderMeta.shared.reload()
        body(root, trash)
    }

    static func run(dir: URL) {
        let base = dir.appendingPathComponent("space-folders", isDirectory: true)
        MainActor.assumeIsolated {
            BrowserModel.useEphemeralStore = true
            webloc(base.appendingPathComponent("webloc"))
            fileChanges(base.appendingPathComponent("files"))
            links(base.appendingPathComponent("links"))
            listing(base.appendingPathComponent("listing"))
            model(base.appendingPathComponent("model"))
            try? FileManager.default.removeItem(at: Paths.stateFile)
            FolderMeta.shared.reload()
        }
    }

    static func read(_ u: URL) -> String { (try? String(contentsOf: u, encoding: .utf8)) ?? "" }

    // MARK: .webloc

    @MainActor static func webloc(_ dir: URL) {
        withSpaceFolders(dir) { root, _ in
            let page = SavedPage(url: URL(string: "https://example.com/essay?ref=1")!, title: "An essay", savedAt: Date(timeIntervalSince1970: 1_800_000_000))
            let f = root.appendingPathComponent("An essay.webloc")
            try? Webloc.write(page, to: f)
            check(Webloc.read(f) == page, "a saved page reads back with its address, title and date")
            let plist = (try? PropertyListSerialization.propertyList(from: Data(contentsOf: f), options: [], format: nil)) as? [String: Any]
            check(plist?["URL"] as? String == "https://example.com/essay?ref=1", "the file keeps the address under URL, where Finder and Safari look")
            check((try? Webloc.write(SavedPage(url: URL(string: "https://other.example/")!), to: f)) == nil && Webloc.read(f) == page,
                  "a new saved page never writes over another")
            // Safari writes a binary list with only the address.
            let safari = root.appendingPathComponent("From Safari.webloc")
            if let d = try? PropertyListSerialization.data(fromPropertyList: ["URL": "https://www.apple.com/"], format: .binary, options: 0) { try? d.write(to: safari) }
            check(Webloc.read(safari)?.url.absoluteString == "https://www.apple.com/" && Webloc.read(safari)?.title == nil,
                  "a saved page from Safari reads too")
            try? Data("not a plist".utf8).write(to: root.appendingPathComponent("Broken.webloc"))
            check(Webloc.read(root.appendingPathComponent("Broken.webloc")) == nil, "a damaged saved page is skipped, not guessed at")
        }
    }

    // MARK: Making, renaming, moving and trashing

    @MainActor static func fileChanges(_ dir: URL) {
        withSpaceFolders(dir) { root, trash in
            let home = root.appendingPathComponent("Home", isDirectory: true)
            Paths.ensure(home)
            let work = try? SpaceFolders.makeFolder(named: "Work", in: home)
            let work2 = try? SpaceFolders.makeFolder(named: "Work", in: home)
            check(work?.lastPathComponent == "Work" && work2?.lastPathComponent == "Work 2" && SpaceFolders.isDirectory(work2!),
                  "a new folder with a name that's taken gets a number")
            check((try? SpaceFolders.makeFolder(named: "../../Escape", in: home))?.lastPathComponent == "-..-Escape",
                  "a folder name can't climb out of its folder")
            let page = try? SpaceFolders.savePage(URL(string: "https://example.com/a")!, title: "Reading: notes/ideas", in: work!)
            check(page?.lastPathComponent == "Reading- notes-ideas.webloc", "a saved page is named after its title, made safe", page?.lastPathComponent ?? "nil")
            let renamed = try? SpaceFolders.rename(page!, to: "Good read")
            check(renamed?.lastPathComponent == "Good read.webloc" && Webloc.read(renamed!)?.url.absoluteString == "https://example.com/a",
                  "renaming a saved page keeps its extension and its address")
            let other = try? SpaceFolders.savePage(URL(string: "https://example.com/b")!, title: "Other", in: work!)
            var clash = false
            do { _ = try SpaceFolders.rename(other!, to: "Good read") } catch { clash = true }
            check(clash && SpaceFolders.exists(other!), "renaming onto a name that's taken is refused and changes nothing")
            let moved = try? SpaceFolders.move(renamed!, into: work2!)
            check(moved?.deletingLastPathComponent().lastPathComponent == "Work 2" && !SpaceFolders.exists(renamed!), "a saved page moves into another folder")
            try? Data("x".utf8).write(to: work!.appendingPathComponent("Good read.webloc"))
            let again = try? SpaceFolders.move(work!.appendingPathComponent("Good read.webloc"), into: work2!)
            check(again?.lastPathComponent == "Good read 2.webloc", "moving onto a name that's taken there picks a free one")
            var refused = false
            do { _ = try SpaceFolders.move(home, into: work!) } catch { refused = true }
            check(refused && SpaceFolders.isDirectory(home), "a folder can't move inside itself")
            let outside = dir.appendingPathComponent("elsewhere", isDirectory: true)
            Paths.ensure(outside)
            var blocked = false
            do { _ = try SpaceFolders.makeFolder(named: "Nope", in: outside) } catch { blocked = true }
            check(blocked && !SpaceFolders.exists(outside.appendingPathComponent("Nope")), "Rain doesn't write outside the space folders and notes folders")
            var done: Bool?
            SpaceFolders.trash([work2!]) { done = $0 }
            _ = SelfTest.spin(5) { done != nil }
            check(done == true && !SpaceFolders.exists(work2!) && SpaceFolders.exists(trash.appendingPathComponent("Work 2")),
                  "deleting a folder moves it to the Trash, with what's inside")
            done = nil
            SpaceFolders.trash([outside]) { done = $0 }
            _ = SelfTest.spin(5) { done != nil }
            check(done == false && SpaceFolders.isDirectory(outside), "nothing outside the folders goes to the Trash from here")
        }
    }

    // MARK: Links

    @MainActor static func links(_ dir: URL) {
        withSpaceFolders(dir) { root, trash in
            let home = root.appendingPathComponent("Home", isDirectory: true)
            Paths.ensure(home)
            // A notes folder somewhere else, like an Obsidian vault.
            let vault = dir.appendingPathComponent("Vault", isDirectory: true)
            Paths.ensure(vault.appendingPathComponent("Projects"))
            let note = vault.appendingPathComponent("Projects/Plan.md")
            try? Data("# Plan\n\nShip it.\n".utf8).write(to: note)
            let before = read(note)
            let link = try? SpaceFolders.link(vault, in: home)
            check(link?.lastPathComponent == "Vault" && FileLink.isLink(link!), "linking a folder puts an alias to it in the space folder")
            check(FileLink.resolve(link!)?.path == vault.standardizedFileURL.path && read(note) == before
                  && ((try? FileManager.default.contentsOfDirectory(atPath: vault.path)) ?? []).sorted() == ["Projects"],
                  "the alias points at the original, and nothing in it is copied or changed")
            let moved = dir.appendingPathComponent("Moved vault", isDirectory: true)
            try? FileManager.default.moveItem(at: vault, to: moved)
            check(FileLink.resolve(link!)?.path == moved.standardizedFileURL.path, "the alias still finds the folder after it's moved and renamed",
                  FileLink.resolve(link!)?.path ?? "nil")
            let noteLink = try? SpaceFolders.link(moved.appendingPathComponent("Projects/Plan.md"), in: home)
            try? FileManager.default.moveItem(at: moved.appendingPathComponent("Projects/Plan.md"), to: moved.appendingPathComponent("Plan v2.md"))
            check(noteLink?.lastPathComponent == "Plan" && FileLink.resolve(noteLink!)?.lastPathComponent == "Plan v2.md",
                  "a link to a note follows it when it's renamed")
            let e = SpaceFolders.entry(link!)
            check(e?.kind == .folder && e?.isLink == true && e?.target.path == moved.standardizedFileURL.path, "a linked folder lists as a folder with a link")
            check(SpaceFolders.entry(noteLink!)?.kind == .note, "a linked note lists as a note")
            // The linked folder is a notes root, once and only once.
            check(SpaceFolders.refreshLinkedRoots() && SpaceFolders.notesRoots.map(\.path) == [root.path, moved.standardizedFileURL.path],
                  "the root and the linked folder are notes roots", SpaceFolders.notesRoots.map(\.lastPathComponent).joined(separator: ", "))
            var s = AppSettings()
            s.notesFolders = [moved.path]
            check(s.notesRoots.map(\.path) == [moved.path, root.path], "a linked folder that's already a notes folder isn't indexed twice",
                  s.notesRoots.map(\.lastPathComponent).joined(separator: ", "))
            // Trashing the link takes the alias, never the folder it points at.
            var done: Bool?
            SpaceFolders.trash([link!]) { done = $0 }
            _ = SelfTest.spin(5) { done != nil }
            check(done == true && !SpaceFolders.exists(link!) && SpaceFolders.isDirectory(moved) && SpaceFolders.exists(moved.appendingPathComponent("Plan v2.md")),
                  "deleting a link moves the alias to the Trash and leaves the original alone")
            _ = trash
            // A link whose original is gone shows as broken.
            try? FileManager.default.removeItem(at: moved.appendingPathComponent("Plan v2.md"))
            check(SpaceFolders.entry(noteLink!)?.isBroken == true, "a link whose original is gone is marked, not followed")
        }
    }

    // MARK: Listing, order and search

    @MainActor static func listing(_ dir: URL) {
        withSpaceFolders(dir) { root, _ in
            let home = root.appendingPathComponent("Home", isDirectory: true)
            Paths.ensure(home.appendingPathComponent("Zeta"))
            Paths.ensure(home.appendingPathComponent("Alpha/Deep"))
            try? SpaceFolders.savePage(URL(string: "https://swift.org/")!, title: "Swift", in: home)
            try? SpaceFolders.savePage(URL(string: "https://webkit.org/blog/")!, title: "WebKit blog", in: home.appendingPathComponent("Alpha/Deep"))
            try? Data("# Ideas\n".utf8).write(to: home.appendingPathComponent("Ideas.md"))
            try? Data("%PDF".utf8).write(to: home.appendingPathComponent("Paper.pdf"))
            try? Data().write(to: home.appendingPathComponent(".DS_Store"))
            let list = SpaceFolders.list(home)
            let kinds = Dictionary(list.map { ($0.name, $0.kind) }, uniquingKeysWith: { a, _ in a })
            check(kinds == ["Zeta": .folder, "Alpha": .folder, "Swift": .page, "Ideas": .note, "Paper.pdf": .file],
                  "a folder lists its folders, pages, notes and files, and hides the rest", kinds.map { "\($0.key)=\($0.value.rawValue)" }.sorted().joined(separator: " "))
            let byName = SpaceFolders.ordered(list, in: home).map(\.name)
            check(byName == ["Alpha", "Zeta", "Ideas", "Paper.pdf", "Swift"], "folders come first, then the rest, by name until Rain has an order", byName.joined(separator: ", "))
            FolderMeta.shared.setOrder(["Zeta", "Swift.webloc", "Alpha"], of: home)
            let custom = SpaceFolders.ordered(list, in: home).map(\.name)
            check(custom == ["Zeta", "Alpha", "Swift", "Ideas", "Paper.pdf"], "Rain keeps its own order, and things it hasn't seen go at the end by name",
                  custom.joined(separator: ", "))
            let found = SpaceFolders.search("webkit", in: home).map(\.name)
            check(found == ["WebKit blog"], "search finds a page in a folder inside a folder", found.joined(separator: ", "))
            check(SpaceFolders.search("swift", in: home.appendingPathComponent("Alpha")).isEmpty, "search stays inside the folder you're in")
            check(SpaceFolders.count(home) == 5, "a folder's card counts what's inside, not hidden files", "\(SpaceFolders.count(home))")
            check(SpaceFolders.encode(home.appendingPathComponent("Alpha")) == "Home/Alpha" && SpaceFolders.decode("Home/Alpha")?.path == home.appendingPathComponent("Alpha").path
                  && SpaceFolders.encode(URL(fileURLWithPath: "/tmp/x")) == "/tmp/x",
                  "paths inside the root are kept relative to it, others in full")
        }
    }

    // MARK: The model

    @MainActor static func model(_ dir: URL) {
        withSpaceFolders(dir) { root, _ in
            let m = ArcZenTests.freshModel()
            guard let home = m.spaces.first, let homeDir = m.spaceFolderURL(home) else { check(false, "the first space gets a folder"); return }
            check(homeDir.path == root.appendingPathComponent("Home").path && SpaceFolders.isDirectory(homeDir), "each space gets a folder named after it")
            let school = m.createSpace(name: "School")
            check(m.spaceFolderURL(school).map(SpaceFolders.isDirectory) == true, "a new space gets its folder right away")
            m.updateSpace(school.id) { $0.name = "Classes" }
            let classes = root.appendingPathComponent("Classes")
            check(SpaceFolders.isDirectory(classes) && !SpaceFolders.exists(root.appendingPathComponent("School"))
                  && m.spaces.first { $0.id == school.id }?.folderName == "Classes", "renaming a space renames its folder")
            Paths.ensure(root.appendingPathComponent("Taken"))
            m.updateSpace(school.id) { $0.name = "Taken" }
            check(m.spaces.first { $0.id == school.id }?.folderName == "Classes" && SpaceFolders.isDirectory(classes),
                  "a space renamed to a folder name that's taken keeps its folder")
            check(m.newNotesFolder.path == homeDir.path, "new notes in a space go to its folder")
            check(FileSafety.canWriteNote(homeDir.appendingPathComponent("New idea.md")), "notes can be written in a space folder")

            // Saving a page.
            let t = ArcZenTests.page(m, "https://example.com/essay", "An essay")
            let file = m.savePage(t, in: homeDir)
            check(file.map { Webloc.read($0)?.url.absoluteString } == "https://example.com/essay" && t.savedFile == "Home/An essay.webloc"
                  && t.pinnedURL?.absoluteString == "https://example.com/essay", "saving a page writes it into the folder, and the tab remembers it")
            check(SavedPages.shared.isSaved(t.url) && m.savedFiles(for: t).count == 1, "the page shows as saved")
            check(t.keepsSavedURL && !t.isAwayFromPin, "the tab keeps the saved address")
            t.url = URL(string: "https://example.com/essay/part-2")
            check(t.isAwayFromPin, "browsing away inside it shows it's away from the saved page")
            m.updateSavedAddress(t)
            check(Webloc.read(file!)?.url.absoluteString == "https://example.com/essay/part-2" && !t.isAwayFromPin,
                  "Update Saved Address points the saved page at where the tab is")

            // Opening what's in a folder.
            let tabsBefore = m.tabs.count
            if let e = SpaceFolders.entry(file!) {
                let opened = m.openFolderEntry(e)
                check(opened?.id == t.id && m.tabs.count == tabsBefore && m.currentTab?.id == t.id, "opening a page that's already open in this space goes to that tab")
            } else { check(false, "the saved page lists") }
            let other = try? SpaceFolders.savePage(URL(string: "https://example.com/other")!, title: "Other page", in: homeDir)
            if let other, let e = SpaceFolders.entry(other) {
                let o = m.openFolderEntry(e, background: true)
                check(o?.savedFile == "Home/Other page.webloc" && o?.pinnedURL?.absoluteString == "https://example.com/other" && m.currentTab?.id == t.id
                      && m.tabs.count == tabsBefore + 1, "a page opened in the background is a new tab with its saved address, and you stay where you were")
                if let o {
                    o.url = URL(string: "https://example.com/elsewhere")
                    m.resetPinned(o, load: false)
                    check(o.url?.absoluteString == "https://example.com/other", "Back to Saved Page goes back to the saved address")
                    m.close(o)
                    check(m.tab(o.id) == nil && SpaceFolders.exists(other), "closing a tab opened from a saved page closes it and keeps the file")
                }
            } else { check(false, "a second saved page lists") }
            try? Data("# Plan\n".utf8).write(to: homeDir.appendingPathComponent("Plan.md"))
            if let e = SpaceFolders.entry(homeDir.appendingPathComponent("Plan.md")) {
                let n1 = m.openFolderEntry(e), n2 = m.openFolderEntry(e)
                check(n1?.isNote == true && n1?.id == n2?.id, "a note opens once, and again goes to the same tab")
            }
            var removed: Bool?
            m.removeSavedPage(file!) { removed = $0 }
            _ = SelfTest.spin(5) { removed != nil }
            check(removed == true && t.savedFile == nil && !SpaceFolders.exists(file!), "removing a saved page moves it to the Trash and the tab forgets it")

            // Saved state.
            m.saveNow()
            let again = BrowserModel()
            check(again.spaces.first?.folderName == "Home" && again.spaces.first { $0.id == school.id }?.folderName == "Classes",
                  "space folders are remembered")
        }
    }
}
