import Foundation

/// A throwaway profile with made-up content for the MCP tests and the end to end runs with
/// real AI clients: an index, a notes folder, saved spaces, the current context and settings.
/// Nothing here is Felix's data.
enum MCPFixture {
    struct Built {
        let root: URL
        let notes: URL
        let outside: URL
        let hiddenNote: URL
        let sourdough: URL
        let breadLog: URL
        let engineNotes: URL
        let googleDoc: String
        let privatePage: String
        let excludedPage: String
    }

    static func run(_ dir: URL) -> Int32 {
        do {
            let b = try build(at: dir)
            print("Fixture profile in \(b.root.path)")
            print("Notes folder: \(b.notes.path)")
            print("Try: BrowserPOC --mcp --data-dir \"\(b.root.path)\"")
            return 0
        } catch {
            FileHandle.standardError.write(Data("fixture failed: \(error)\n".utf8))
            return 1
        }
    }

    static let day: Double = 86400

    @discardableResult
    static func build(at root: URL, pid: Int32 = 0, binary: String? = Bundle.main.executablePath, now: Date = Date()) throws -> Built {
        let fm = FileManager.default
        try? fm.removeItem(at: root)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let notes = root.appendingPathComponent("Notes 🌱", isDirectory: true)
        try fm.createDirectory(at: notes.appendingPathComponent("Browser"), withIntermediateDirectories: true)
        try fm.createDirectory(at: notes.appendingPathComponent(".hidden"), withIntermediateDirectories: true)

        let googleDoc = "https://docs.google.com/document/d/1AbCdEfGhIjKlMnOpQrStUvWxYz0123456789/edit"
        let googleKey = "https://docs.google.com/document/d/1AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"
        let notion = "https://www.notion.so/Browser-roadmap-0123456789abcdef0123456789abcdef"
        let kingArthur = "https://www.kingarthurbaking.com/sourdough-starter-guide"
        let wkext = "https://developer.apple.com/documentation/webkit/wkwebextension"
        let nook = "https://github.com/nook-browser/Nook/blob/main/ExtensionManager.md"
        let privatePage = "https://example.com/magic-link/abc123?token=zzz"
        let excludedPage = "https://www.chase.com/personal/checking"

        // Notes on disk.
        let sourdough = notes.appendingPathComponent("Sourdough plan.md")
        let breadLog = notes.appendingPathComponent("Bread bake log.md")
        let engineNotes = notes.appendingPathComponent("Browser/Browser engine notes.md")
        let mcpIdeas = notes.appendingPathComponent("Browser/MCP ideas.md")
        let hiddenNote = notes.appendingPathComponent(".hidden/secret.md")
        let outside = root.appendingPathComponent("outside.md")
        let files: [(URL, String)] = [
            (sourdough, """
            # Sourdough plan

            The starter has been sluggish all week. Plan: feed it with rye flour twice a day and keep it warm, \
            then try 75 percent hydration again with a longer cold proof. Compare with the [[Bread bake log]].

            TODO: work out the price per loaf for the pop-up.

            ## Related

            - [How to feed and maintain a sourdough starter](\(kingArthur))
            """),
            (breadLog, """
            # Bread bake log

            Saturday loaf: 75 percent hydration, levain built the night before, bulk fermentation five hours. \
            Crumb was tight and the loaf spread. Starter probably wasn't at peak. Next time do a longer cold proof \
            in the fridge and feed the starter with rye the morning before.
            """),
            (engineNotes, """
            # Browser engine notes

            Picked WebKit over Chromium. Apple ships WKWebView engine updates with the OS, so there's no engine upkeep. \
            Extensions go through WKWebExtension and WKWebExtensionController. Nook's approach is worth reading: \
            [Nook ExtensionManager](\(nook)). Need to test 1Password, Bitwarden and uBlock Origin Lite.
            """),
            (mcpIdeas, """
            # MCP ideas

            Let Claude and Codex read the browser's knowledge over MCP: search, related items, the graph of connections \
            and what I'm working on now. Keep it local, read-only by default, and log what gets served. See [[Browser engine notes]].
            """),
            (hiddenNote, "# Secret\n\nThis note lives in a hidden folder and must never be served.\n"),
            (outside, "# Outside\n\nThis file is outside the notes folder.\n"),
        ]
        for (u, t) in files { try Data((t + "\n").utf8).write(to: u) }

        // The index.
        do {
            let store = try IndexStore(url: root.appendingPathComponent("index.sqlite"))
            let t = now.timeIntervalSince1970
            func page(_ url: String, _ title: String, _ text: String, daysAgo: Double, visits: Int = 2, source: SourceType = .web) {
                let a = TextAnalysis.analyze(title: title, description: "", text: text)
                let key = URL(string: url).map { URLKey.key(for: $0) } ?? url
                let d = DocUpsert(key: key, source: source, url: url, title: title, body: source == .chrome ? "" : text,
                                  firstSeen: t - (daysAgo + 3) * day, lastSeen: t - daysAgo * day, visitCount: visits)
                if source == .chrome { _ = store.importChrome([(d, a)]) } else { store.recordCapture(d, analysis: a) }
            }
            page(wkext, "WKWebExtension | Apple Developer Documentation", """
                WKWebExtension is an object that encapsulates a web extension's resources that the browser loads. \
                A WKWebExtensionController manages a set of loaded extension contexts. The browser app reports tab and window events \
                to the controller. Manifest version 3 extensions with service worker background content are supported.
                """, daysAgo: 6)
            page(nook, "Nook ExtensionManager: installing Chrome extensions in a WebKit browser", """
                Nook is an open source browser for macOS written in Swift on top of WKWebView. Its ExtensionManager installs \
                extensions from ZIP files and Chrome Web Store CRX packages before handing them to WKWebExtension. \
                Password managers like Bitwarden needed extra shims for native messaging.
                """, daysAgo: 4)
            page(kingArthur, "How to feed and maintain a sourdough starter", """
                A healthy sourdough starter rises predictably after each feeding. Feed it equal weights of flour and water, \
                which is 100 percent hydration, and keep it warm. A sluggish starter that smells of acetone is hungry; \
                feed it twice a day. Whole rye flour speeds up fermentation.
                """, daysAgo: 1, visits: 4)
            page("https://www.runnersworld.com/training/marathon-plan", "A 16 week marathon training plan for beginners", """
                This marathon training plan builds weekly mileage gradually. Each week has an easy run, a tempo run, \
                intervals and a long slow distance run. Taper for two weeks before race day.
                """, daysAgo: 30)
            page(googleDoc, "Bread pop-up plan", """
                Bread pop-up plan. Sell sourdough loaves at the Saturday market. Price per loaf, starter schedule, \
                rye flour order and a cold proof timeline. Meera from the market asked for twenty loaves.
                """, daysAgo: 2)
            page(notion, "Browser roadmap", """
                Browser roadmap. WebKit shell, spaces, split view, notes as tabs, Related panel, and an MCP connector \
                so Claude and Codex can read the knowledge base.
                """, daysAgo: 3)
            page(privatePage, "Sign in to Example", "Your sign in link. Sourdough club members area.", daysAgo: 1)
            page(excludedPage, "Chase checking account", "Checking account balance and sourdough bakery payments.", daysAgo: 1)
            page("https://www.calculator.net/pace-calculator.html", "Half marathon pace calculator", "", daysAgo: 15, visits: 5, source: .chrome)
            page("https://webkit.org/blog/safari-web-extensions-wkwebextension", "Safari web extensions and WKWebExtension in WebKit apps", "",
                 daysAgo: 9, visits: 3, source: .chrome)
            for u in [sourdough, breadLog, engineNotes, mcpIdeas] {
                let text = String(decoding: try Data(contentsOf: u), as: UTF8.self)
                let mtime = NotesScan.mtime(u) ?? t
                let (d, a) = Indexer.fileDoc(url: u, text: text, root: notes, mtime: mtime)
                store.upsertFile(d, analysis: a)
            }
            store.touchOpened(key: URLKey.key(for: URL(string: kingArthur)!), at: now.addingTimeInterval(-3600))
            store.touchOpened(key: googleKey, at: now.addingTimeInterval(-7200))
            store.importSearches([("sourdough hydration", t - 3600), ("wkwebextension native messaging", t - 2 * day)], source: "bar")
        }

        // Settings and saved state.
        var s = AppSettings()
        s.notesFolders = [notes.path]
        try JSONEncoder.pretty.encode(s).write(to: root.appendingPathComponent("settings.json"))

        let home = Space(name: "Home", icon: "house")
        var baking = Space(name: "Baking", icon: "leaf", color: "#E0A030")
        baking.newNotesFolder = notes.path
        let research = Folder(spaceID: home.id, name: "Research")
        func tab(_ kind: TabKind, _ url: String, _ title: String, space: Space, pinned: Bool = false, folder: Folder? = nil) -> TabRecord {
            TabRecord(id: UUID(), kind: kind, url: url, title: title, isPinned: pinned, folderID: folder?.id, createdAt: now, spaceID: space.id)
        }
        let nookTab = tab(.web, nook, "Nook ExtensionManager", space: home, pinned: true)
        let wkTab = tab(.web, wkext, "WKWebExtension", space: home, folder: research)
        let engineTab = tab(.note, engineNotes.absoluteString, "Browser engine notes", space: home, folder: research)
        let notionTab = tab(.web, notion, "Browser roadmap", space: home)
        let planTab = tab(.note, sourdough.absoluteString, "Sourdough plan", space: baking, pinned: true)
        let kaTab = tab(.web, kingArthur, "How to feed and maintain a sourdough starter", space: baking)
        let logTab = tab(.note, breadLog.absoluteString, "Bread bake log", space: baking)
        let chaseTab = tab(.web, excludedPage, "Chase", space: baking)
        let docTab = tab(.web, googleDoc, "Bread pop-up plan", space: baking)
        var state = SavedState()
        state.spaces = [home, baking]
        state.currentSpace = baking.id
        state.folders = [research]
        state.tabs = [nookTab, wkTab, engineTab, notionTab, planTab, kaTab, logTab, chaseTab, docTab]
        state.splits = [SplitRecord(left: kaTab.id, right: logTab.id, spaceID: baking.id)]
        try JSONEncoder.pretty.encode(state).write(to: root.appendingPathComponent("state.json"))

        // What's on screen.
        typealias Ref = CurrentContextFile.Ref
        let planRef = Ref(title: "Sourdough plan", url: sourdough.standardizedFileURL.absoluteString, kind: "note", key: URLKey.fileKey(sourdough))
        let kaRef = Ref(title: "How to feed and maintain a sourdough starter", url: kingArthur, kind: "page", key: kingArthur)
        let chaseRef = Ref(title: "Chase", url: excludedPage, kind: "page", key: excludedPage)
        let logRef = Ref(title: "Bread bake log", url: breadLog.standardizedFileURL.absoluteString, kind: "note", key: URLKey.fileKey(breadLog))
        let docRef = Ref(title: "Bread pop-up plan", url: googleKey, kind: "page", key: googleKey)
        var cc = CurrentContextFile(updatedAt: now, pid: pid)
        cc.binary = binary
        cc.space = .init(id: baking.id.uuidString, name: baking.name)
        cc.focused = planRef
        cc.splitWith = kaRef
        cc.openTabs = [planRef, kaRef, logRef, chaseRef, docRef]
        cc.related = [logRef, docRef]
        cc.trail = [planRef, kaRef, chaseRef, logRef].enumerated().map { i, r in var x = r; x.at = now.addingTimeInterval(Double(-600 * i)); return x }
        try JSONEncoder.pretty.encode(cc).write(to: CurrentContextFile.url(root))

        MCPSettings().save(root: root)
        return Built(root: root, notes: notes, outside: outside, hiddenNote: hiddenNote, sourdough: sourdough, breadLog: breadLog,
                     engineNotes: engineNotes, googleDoc: googleKey, privatePage: privatePage, excludedPage: excludedPage)
    }
}
