import Foundation

/// Your data across updates: files saved by earlier builds still load with nothing missing, and
/// a file that can't be read is set aside instead of saved over.
///
/// The samples below are frozen copies of what Rain wrote as of 5 Nov 2026 (and the older formats
/// it still reads). Don't edit a sample to make a check pass. A failure here means a change would
/// lose someone's tabs, settings or history: make the new code read the old format instead, or
/// move it over once. Add a new sample when a format changes, and keep the old ones.
enum SavedDataTests {
    static func check(_ ok: Bool, _ label: String, _ detail: String = "") { SelfTest.check(ok, label, detail) }

    static func run(dir: URL) {
        let before = (root: Paths.overrideRoot, repair: SavedFile.mayRepair)
        let sub = dir.appendingPathComponent("saved-data", isDirectory: true)
        try? FileManager.default.removeItem(at: sub)
        Paths.ensure(sub)
        SavedFile.mayRepair = true
        _ = DataNotices.take()
        defer {
            Paths.overrideRoot = before.root
            SavedFile.mayRepair = before.repair
            SavedFile.unblockAll()
            _ = DataNotices.take()
        }
        Paths.overrideRoot = sub
        MainActor.assumeIsolated {
            BrowserModel.useEphemeralStore = true
            currentState(sub)
            olderState(sub)
            lenientState(sub)
            unreadableState(sub)
            blockedState(sub)
            history(sub)
        }
        settingsFiles(sub)
        index(sub)
    }

    // MARK: - Spaces and tabs (state.json)

    static let home = "11111111-1111-4111-8111-111111111111"
    static let work = "22222222-2222-4222-8222-222222222222"
    static let fReading = "33333333-3333-4333-8333-333333333331"
    static let fClients = "33333333-3333-4333-8333-333333333332"
    static let t = (1...10).map { String(format: "44444444-4444-4444-8444-%012d", $0) }
    static let split1 = "55555555-5555-4555-8555-555555555551"

    /// state.json as Rain wrote it on 5 Nov 2026 (version 3): two spaces, Essentials, a pin with
    /// its own address and name, folders, a note, an app page and a split.
    static var stateV3: String {
        """
        {
          "currentSpace" : "\(work)",
          "folders" : [
            { "createdAt" : "2026-11-01T09:00:00Z", "id" : "\(fReading)", "isExpanded" : true, "name" : "Reading", "order" : 0, "spaceID" : "\(home)" },
            { "createdAt" : "2026-11-02T09:00:00Z", "id" : "\(fClients)", "isExpanded" : false, "name" : "Clients", "order" : 1, "spaceID" : "\(work)" }
          ],
          "selectedSplit" : "\(split1)",
          "spaces" : [
            { "color" : "#7A8CA8", "icon" : "house", "id" : "\(home)", "name" : "Home", "selectedTab" : "\(t[3])" },
            { "color" : "#4C8DF6", "icon" : "briefcase", "id" : "\(work)", "name" : "Work", "newNotesFolder" : "/tmp/rain-sample/notes",
              "profile" : "work", "selectedSplit" : "\(split1)" }
          ],
          "splits" : [
            { "createdAt" : "2026-11-05T08:00:00Z", "focused" : "\(t[7])", "id" : "\(split1)", "isPinned" : false, "order" : 4,
              "root" : { "axis" : "row", "children" : [ { "item" : "\(t[6])" }, { "item" : "\(t[7])" } ], "sizes" : [ 0.4, 0.6 ] },
              "spaceID" : "\(work)" }
          ],
          "tabs" : [
            { "createdAt" : "2026-11-01T09:00:00Z", "id" : "\(t[0])", "isEssential" : true, "isPinned" : false, "kind" : "web",
              "lastActiveAt" : "2026-11-05T07:00:00Z", "order" : 0, "spaceID" : "\(home)", "title" : "Mail", "url" : "https://mail.example.com/" },
            { "createdAt" : "2026-11-01T09:05:00Z", "customTitle" : "Morning news", "id" : "\(t[1])", "isPinned" : true, "kind" : "web",
              "lastActiveAt" : "2026-11-05T07:10:00Z", "order" : 1, "pinnedURL" : "https://news.example.com/", "spaceID" : "\(home)",
              "title" : "Today's stories", "url" : "https://news.example.com/today" },
            { "createdAt" : "2026-11-02T10:00:00Z", "folderID" : "\(fReading)", "id" : "\(t[2])", "isMuted" : true, "isPinned" : false,
              "kind" : "web", "lastActiveAt" : "2026-11-04T10:00:00Z", "order" : 2, "spaceID" : "\(home)", "title" : "An essay",
              "url" : "https://example.com/essay" },
            { "createdAt" : "2026-11-05T06:00:00Z", "id" : "\(t[3])", "isPinned" : false, "kind" : "web", "lastActiveAt" : "2026-11-05T06:30:00Z",
              "order" : 3, "spaceID" : "\(home)", "title" : "Loose page", "url" : "https://example.com/loose" },
            { "createdAt" : "2026-11-03T09:00:00Z", "folderID" : "\(fClients)", "id" : "\(t[4])", "isPinned" : false, "kind" : "note",
              "order" : 0, "spaceID" : "\(work)", "title" : "plan", "url" : "file:///tmp/rain-sample/notes/plan.md" },
            { "createdAt" : "2026-11-03T09:30:00Z", "id" : "\(t[5])", "isPinned" : true, "kind" : "app", "order" : 1, "spaceID" : "\(work)",
              "title" : "History", "url" : "browser://history" },
            { "createdAt" : "2026-11-05T08:00:00Z", "id" : "\(t[6])", "isPinned" : false, "kind" : "web", "order" : 2, "spaceID" : "\(work)",
              "title" : "Left pane", "url" : "https://example.com/left" },
            { "createdAt" : "2026-11-05T08:00:00Z", "id" : "\(t[7])", "isPinned" : false, "kind" : "web", "order" : 3, "spaceID" : "\(work)",
              "title" : "Right pane", "url" : "https://example.com/right" }
          ],
          "version" : 3
        }
        """
    }

    static func uuid(_ s: String) -> UUID { UUID(uuidString: s)! }

    @MainActor
    static func checkV3(_ m: BrowserModel, _ what: String) {
        let ids = Set(m.tabs.map { $0.id })
        check(ids == Set(t.prefix(8).map(uuid)), "\(what): every tab is there", "\(m.tabs.count) tabs")
        check(m.spaces.map { $0.id } == [uuid(home), uuid(work)] && m.spaces.map { $0.name } == ["Home", "Work"], "\(what): both spaces, in order")
        let w = m.spaces.last
        check(w?.color == "#4C8DF6" && w?.icon == "briefcase" && w?.profile == "work" && w?.newNotesFolder == "/tmp/rain-sample/notes",
              "\(what): a space keeps its colour, icon, profile and notes folder")
        check(m.currentSpaceID == uuid(work), "\(what): the space you were in")
        check(m.essentials.map { $0.id } == [uuid(t[0])], "\(what): Essentials")
        let pin = m.tab(uuid(t[1]))
        check(pin?.isPinned == true && pin?.customTitle == "Morning news" && pin?.pinnedURL?.absoluteString == "https://news.example.com/",
              "\(what): a pin keeps its own name and address")
        let inFolder = m.tab(uuid(t[2]))
        check(inFolder?.folderID == uuid(fReading) && inFolder?.isMuted == true, "\(what): a tab stays in its folder, muted")
        check(m.folders.map { $0.id } == [uuid(fReading), uuid(fClients)] && m.folders.last?.isExpanded == false,
              "\(what): folders, open and closed")
        check(m.tab(uuid(t[4]))?.kind == .note && m.tab(uuid(t[5]))?.kind == .app, "\(what): notes and app pages")
        let order = [0, 1, 2, 3].map { m.tab(uuid(t[$0]))?.order ?? -1 }
        check(order == [0, 1, 2, 3], "\(what): tab order", "\(order)")
        var sizes: [Double] = []
        if case .branch(_, _, let s)? = m.splits.first?.root { sizes = s }
        check(m.splits.count == 1 && m.splits.first?.items == [uuid(t[6]), uuid(t[7])] && sizes.map { ($0 * 100).rounded() } == [40, 60],
              "\(what): the split, with its pane sizes")
        check(m.selection == .split(uuid(split1)), "\(what): the split you had open")
    }

    @MainActor
    static func currentState(_ sub: URL) {
        try? Data(stateV3.utf8).write(to: Paths.stateFile)
        let m = BrowserModel()
        checkV3(m, "today's state file")
        check(DataNotices.take().isEmpty, "today's state file reads without notices")
        m.saveNow()
        checkV3(BrowserModel(), "saved and read back")
        try? FileManager.default.removeItem(at: Paths.stateFile)
    }

    /// Version 2: spaces, but no Essentials, ordering or split trees. One space has no colour.
    static var stateV2: String {
        """
        {"version":2,"currentSpace":"\(home)",
         "spaces":[{"id":"\(home)","name":"Home","icon":"house","color":"#7A8CA8","selectedTab":"\(t[0])"},{"id":"\(work)","name":"Work"}],
         "folders":[{"id":"\(fReading)","spaceID":"\(home)","name":"Reading","isExpanded":true,"createdAt":"2026-10-20T09:00:00Z"}],
         "tabs":[{"id":"\(t[0])","kind":"web","url":"https://example.com/a","title":"A","isPinned":true,"createdAt":"2026-10-20T09:00:00Z","spaceID":"\(home)"},
                 {"id":"\(t[1])","kind":"web","url":"https://example.com/b","title":"B","isPinned":false,"folderID":"\(fReading)","createdAt":"2026-10-21T09:00:00Z","spaceID":"\(home)"},
                 {"id":"\(t[2])","kind":"web","url":"https://example.com/c","title":"C","isPinned":false,"createdAt":"2026-10-22T09:00:00Z","spaceID":"\(work)"},
                 {"id":"\(t[3])","kind":"file","url":"file:///tmp/rain-sample/old.md","title":"old","isPinned":false,"createdAt":"2026-10-22T09:00:00Z","spaceID":"\(work)"}],
         "splits":[{"id":"\(split1)","left":"\(t[2])","right":"\(t[3])","ratio":0.3,"focusRight":true,"createdAt":"2026-10-23T09:00:00Z","spaceID":"\(work)"}],
         "selectedTab":"\(t[0])"}
        """
    }

    @MainActor
    static func olderState(_ sub: URL) {
        try? Data(stateV2.utf8).write(to: Paths.stateFile)
        let m = BrowserModel()
        check(Set(m.tabs.map { $0.id }) == Set(t.prefix(4).map(uuid)) && m.spaces.count == 2 && m.folders.count == 1,
              "a version 2 state file keeps every tab, space and folder")
        check(m.spaces.last?.color == Space(name: "x").color && m.tab(uuid(t[3]))?.kind == .note,
              "a space with no colour gets the default, and an old file tab becomes a note")
        var ratio = 0.0
        if case .branch(_, _, let s)? = m.splits.first?.root { ratio = s.first ?? 0 }
        check(m.splits.first?.items == [uuid(t[2]), uuid(t[3])] && abs(ratio - 0.3) < 0.001 && m.splits.first?.focused == uuid(t[3]),
              "a two-pane split from the first version keeps its panes, divider and focus")
        check(DataNotices.take().isEmpty, "an older state file reads without notices")
        try? FileManager.default.removeItem(at: Paths.stateFile)
    }

    /// Today's file with things a newer build might write, and a few broken values.
    static var stateLenient: String {
        var s = stateV3
        s = s.replacingOccurrences(of: "\"version\" : 3", with: "\"version\" : 3, \"futureFeature\" : { \"x\" : 1 }")
        s = s.replacingOccurrences(of: "\"name\" : \"Work\",", with: "\"name\" : \"Work\", \"tint\" : \"aurora\",")
        s = s.replacingOccurrences(of: "\"tabs\" : [", with: """
        "tabs" : [
            "not a tab",
            { "createdAt" : "2026-11-05T09:00:00Z", "id" : "\(t[8])", "isPinned" : false, "kind" : "hologram", "spaceID" : "\(work)",
              "title" : "From a newer build", "url" : "https://example.com/holo" },
            { "createdAt" : "2026-11-05T09:00:00Z", "id" : "\(t[9])", "isPinned" : false, "kind" : "web", "spaceID" : "\(work)",
              "title" : 42, "url" : "https://example.com/number-title" },
        """)
        s = s.replacingOccurrences(of: "\"folders\" : [", with: """
        "folders" : [
            { "id" : "not-a-uuid", "name" : "Broken id", "spaceID" : "\(home)", "createdAt" : "2026-11-05T09:00:00Z" },
        """)
        return s
    }

    @MainActor
    static func lenientState(_ sub: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: SavedFile.recoveredDir)
        let original = Data(stateLenient.utf8)
        check((try? JSONSerialization.jsonObject(with: original)) != nil, "the lenient sample is valid JSON")
        try? original.write(to: Paths.stateFile)
        let m = BrowserModel()
        let ids = Set(m.tabs.map { $0.id })
        check(ids.isSuperset(of: Set(t.prefix(8).map(uuid))), "one bad tab doesn't cost the others")
        check(m.tab(uuid(t[8]))?.kind == .web && m.tab(uuid(t[8]))?.url?.absoluteString == "https://example.com/holo",
              "a tab kind from a newer build opens as a page")
        check(m.tab(uuid(t[9]))?.url?.absoluteString == "https://example.com/number-title", "a tab with a broken title keeps its page")
        check(m.folders.contains { $0.name == "Broken id" } && m.spaces.count == 2, "a folder with a broken ID is kept, and unknown keys are ignored")
        let kept = (try? fm.contentsOfDirectory(atPath: SavedFile.recoveredDir.path)) ?? []
        let copy = kept.first.flatMap { try? Data(contentsOf: SavedFile.recoveredDir.appendingPathComponent($0)) }
        check(kept.count == 1 && kept[0].hasPrefix("state ") && copy == original, "a copy of the whole file is kept before it's saved over", "\(kept)")
        let notices = DataNotices.take()
        check(notices.count == 1 && { if case .partlyRead(_, 4, _) = notices[0] { return true } else { return false } }(),
              "the app says what it left out", "\(notices)")
        try? fm.removeItem(at: Paths.stateFile)
        try? fm.removeItem(at: SavedFile.recoveredDir)
    }

    @MainActor
    static func unreadableState(_ sub: URL) {
        let fm = FileManager.default
        let garbage = Data("{ \"tabs\": [ this isn't JSON".utf8)
        try? garbage.write(to: Paths.stateFile)
        let m = BrowserModel()
        check(m.spaces.map { $0.name } == ["Home"] && m.tabs.isEmpty, "an unreadable state file starts a fresh Home")
        let kept = (try? fm.contentsOfDirectory(atPath: SavedFile.recoveredDir.path)) ?? []
        let keptURL = kept.first.map { SavedFile.recoveredDir.appendingPathComponent($0) }
        check(kept.count == 1 && keptURL.flatMap { try? Data(contentsOf: $0) } == garbage && !fm.fileExists(atPath: Paths.stateFile.path),
              "the unreadable file moves into Recovered before anything is saved")
        m.saveNow()
        check(fm.fileExists(atPath: Paths.stateFile.path) && keptURL.flatMap { try? Data(contentsOf: $0) } == garbage,
              "saving afterwards leaves the recovered file alone")
        let notices = DataNotices.take()
        check(notices.count == 1 && { if case .setAside(let l, _) = notices[0] { return l == "spaces and tabs" } else { return false } }(),
              "the app says it set the file aside", "\(notices)")
        try? fm.removeItem(at: Paths.stateFile)
        try? fm.removeItem(at: SavedFile.recoveredDir)
    }

    /// When the file can't even be set aside, Rain doesn't write over it.
    @MainActor
    static func blockedState(_ sub: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: SavedFile.recoveredDir)
        try? Data("a file where the folder should be".utf8).write(to: SavedFile.recoveredDir)
        let garbage = Data("not json at all".utf8)
        try? garbage.write(to: Paths.stateFile)
        let m = BrowserModel()
        m.saveNow()
        check(SavedFile.isBlocked(Paths.stateFile) && (try? Data(contentsOf: Paths.stateFile)) == garbage,
              "a file that can't be read or set aside is never saved over")
        let notices = DataNotices.take()
        check(notices.contains { if case .untouched = $0 { return true } else { return false } }, "the app says it left the file alone")
        SavedFile.unblockAll()
        try? fm.removeItem(at: SavedFile.recoveredDir)
        try? fm.removeItem(at: Paths.stateFile)
    }

    // MARK: - Settings and preferences

    static func settingsFiles(_ sub: URL) {
        let fm = FileManager.default
        func read<T: Decodable>(_ type: T.Type, _ name: String, _ json: String) -> T? {
            let u = sub.appendingPathComponent(name)
            try? Data(json.utf8).write(to: u)
            defer { try? fm.removeItem(at: u) }
            return SavedFile.read(type, from: u, label: name)
        }

        // settings.json as of 5 Nov 2026, every field away from its default.
        let s = read(AppSettings.self, "settings.json", """
        {"notesFolders":["/tmp/rain-sample/notes"],"newNotesFolder":"/tmp/rain-sample/notes/inbox","excludedDomains":["bank.example.com"],
         "writingSites":["docs.example.com"],"threshold":0.55,"keywordWeight":0.9,"semanticWeight":0.8,"entityWeight":0.25,"showScores":true,
         "rightPanelOpen":false,"firstRunDone":true,"chromeImportedAt":"2026-11-04T08:00:00Z","chromeSummary":"2,000 pages from Chrome"}
        """)
        var want = AppSettings()
        want.notesFolders = ["/tmp/rain-sample/notes"]
        want.newNotesFolder = "/tmp/rain-sample/notes/inbox"
        want.excludedDomains = ["bank.example.com"]
        want.writingSites = ["docs.example.com"]
        want.threshold = 0.55
        want.keywordWeight = 0.9
        want.semanticWeight = 0.8
        want.entityWeight = 0.25
        want.showScores = true
        want.rightPanelOpen = false
        want.firstRunDone = true
        want.chromeImportedAt = ISO8601DateFormatter().date(from: "2026-11-04T08:00:00Z")
        want.chromeSummary = "2,000 pages from Chrome"
        check(s == want, "today's settings file keeps every setting")
        check(read(AppSettings.self, "settings.json", "{\"markdownRoots\":[\"/tmp/old\"]}")?.notesFolders == ["/tmp/old"],
              "the oldest settings file's notes folders still carry over")

        let b = read(BrowserPrefsValue.self, "browser.json", """
        {"archiveAfterHours":24,"peekForPinnedLinks":false,"littleArc":false,"autoPictureInPicture":false,"sidebarHidden":true,
         "sidebarOnRight":true,"actionScores":{"new-note":3}}
        """)
        var wantB = BrowserPrefsValue()
        wantB.archiveAfterHours = 24
        wantB.peekForPinnedLinks = false
        wantB.littleArc = false
        wantB.autoPictureInPicture = false
        wantB.sidebarHidden = true
        wantB.sidebarOnRight = true
        wantB.actionScores = ["new-note": 3]
        check(b == wantB, "today's browser preferences keep every setting")

        let r = read(RelatedPrefsValue.self, "related.json", "{\"mode\":\"sidebar\",\"shelfHidden\":true}")
        check(r?.mode == .sidebar && r?.shelfHidden == true, "today's Related preferences keep their mode")

        let closed = read(LossyArray<ClosedItem>.self, "closed.json", """
        [{"id":"\(t[0])","kind":"web","url":"https://example.com/closed","title":"Closed page","closedAt":"2026-11-05T08:00:00Z","reason":"closed"},
         {"id":"\(t[1])","kind":"note","url":"file:///tmp/x.md","title":"x","customTitle":"Old note","spaceID":"\(work)",
          "closedAt":"2026-11-04T08:00:00Z","reason":"archived","group":"\(split1)",
          "splitRoot":{"axis":"row","children":[{"item":"\(t[1])"},{"item":"\(t[2])"}],"sizes":[0.5,0.5]}}]
        """)?.items ?? []
        check(closed.count == 2 && closed[0].reason == .closed && closed[1].customTitle == "Old note" && closed[1].splitRoot?.leaves.count == 2,
              "today's recently closed list and archive keep every item")
        check(DataNotices.take().isEmpty, "today's settings files read without notices")

        // Read-only tools (the MCP server, evals) never move a file, even one they can't read.
        let u = sub.appendingPathComponent("browser.json")
        try? Data("nope".utf8).write(to: u)
        SavedFile.mayRepair = false
        let none = SavedFile.read(BrowserPrefsValue.self, from: u, label: "browser preferences")
        SavedFile.mayRepair = true
        check(none == nil && fm.fileExists(atPath: u.path) && DataNotices.take().isEmpty, "tools that only read a profile leave its files where they are")
        try? fm.removeItem(at: u)
    }

    // MARK: - History and the index

    @MainActor
    static func history(_ sub: URL) {
        let u = sub.appendingPathComponent("history.sqlite")
        try? FileManager.default.removeItem(at: u)
        // history.sqlite as of 5 Nov 2026.
        do {
            let db = try SQLiteDB(path: u.path)
            try db.exec("""
            CREATE TABLE visits(id INTEGER PRIMARY KEY, url TEXT NOT NULL, title TEXT NOT NULL DEFAULT '',
                host TEXT NOT NULL DEFAULT '', at REAL NOT NULL, space TEXT);
            CREATE INDEX visits_at ON visits(at);
            CREATE INDEX visits_host ON visits(host);
            CREATE INDEX visits_url ON visits(url);
            INSERT INTO visits VALUES(1, 'https://example.com/a', 'Page A', 'example.com', 1793865600, '\(home)');
            INSERT INTO visits VALUES(2, 'https://example.org/b', 'Page B', 'example.org', 1793869200, NULL);
            INSERT INTO visits VALUES(3, 'https://example.com/c', 'Page C', 'example.com', 1793872800, '\(work)');
            """)
        } catch { check(false, "the history sample is written", "\(error)"); return }
        let h = HistoryStore(path: u.path)
        let v = h.visits()
        check(v.map { $0.title } == ["Page C", "Page B", "Page A"] && v.first?.spaceID == uuid(work) && v.last?.host == "example.com",
              "today's history file keeps every visit")
    }

    static func index(_ sub: URL) {
        let u = sub.appendingPathComponent("index-sample.sqlite")
        try? FileManager.default.removeItem(at: u)
        // index.sqlite's tables as of 5 Nov 2026, with a row in each.
        let tables = ["docs": 2, "passages": 2, "entities": 1, "dismissals": 1, "typing": 1, "overrides": 1, "searches": 1,
                      "reasons": 1, "visits": 2, "topics": 1, "source_state": 1]
        do {
            let db = try SQLiteDB(path: u.path)
            try db.exec("""
            CREATE TABLE docs(id INTEGER PRIMARY KEY, key TEXT UNIQUE NOT NULL, source TEXT NOT NULL, url TEXT NOT NULL,
              title TEXT NOT NULL DEFAULT '', description TEXT NOT NULL DEFAULT '', body TEXT NOT NULL DEFAULT '', project TEXT, root TEXT,
              first_seen REAL NOT NULL DEFAULT 0, last_seen REAL NOT NULL DEFAULT 0, visit_count INTEGER NOT NULL DEFAULT 0,
              dwell REAL NOT NULL DEFAULT 0, last_opened REAL NOT NULL DEFAULT 0, has_text INTEGER NOT NULL DEFAULT 0,
              mtime REAL NOT NULL DEFAULT 0, indexed_at REAL NOT NULL DEFAULT 0);
            CREATE INDEX docs_source ON docs(source);
            CREATE INDEX docs_root ON docs(root);
            CREATE TABLE passages(id INTEGER PRIMARY KEY, doc_id INTEGER NOT NULL, idx INTEGER NOT NULL, text TEXT NOT NULL, vec BLOB, vec_model TEXT);
            CREATE INDEX passages_doc ON passages(doc_id);
            CREATE VIRTUAL TABLE pfts USING fts5(title, body, tokenize='unicode61 remove_diacritics 2');
            CREATE VIRTUAL TABLE pfts_vocab USING fts5vocab(pfts, 'row');
            CREATE TABLE entities(doc_id INTEGER NOT NULL, name TEXT NOT NULL, display TEXT NOT NULL, kind TEXT NOT NULL, count INTEGER NOT NULL);
            CREATE INDEX entities_name ON entities(name);
            CREATE INDEX entities_doc ON entities(doc_id);
            CREATE TABLE dismissals(doc_id INTEGER NOT NULL, context_key TEXT NOT NULL, terms TEXT NOT NULL, at REAL NOT NULL);
            CREATE INDEX dismissals_doc ON dismissals(doc_id);
            CREATE TABLE typing(key TEXT PRIMARY KEY, chars INTEGER NOT NULL);
            CREATE TABLE overrides(key TEXT PRIMARY KEY, section TEXT NOT NULL);
            CREATE TABLE searches(id INTEGER PRIMARY KEY, query TEXT NOT NULL, norm TEXT NOT NULL, at REAL NOT NULL, source TEXT NOT NULL);
            CREATE UNIQUE INDEX searches_norm ON searches(norm);
            CREATE TABLE reasons(doc_id INTEGER NOT NULL, context_key TEXT NOT NULL, text TEXT NOT NULL, PRIMARY KEY(doc_id, context_key));
            CREATE TABLE visits(doc_id INTEGER NOT NULL, at REAL NOT NULL, kind TEXT NOT NULL, during TEXT);
            CREATE INDEX visits_doc ON visits(doc_id);
            CREATE TABLE topics(doc_id INTEGER NOT NULL, topic TEXT NOT NULL, source TEXT NOT NULL);
            CREATE INDEX topics_doc ON topics(doc_id);
            CREATE INDEX topics_topic ON topics(topic);
            CREATE TABLE source_state(source TEXT PRIMARY KEY, value TEXT NOT NULL);
            INSERT INTO docs(id, key, source, url, title, body, first_seen, last_seen, visit_count, has_text)
              VALUES(1, 'https://example.com/essay', 'web', 'https://example.com/essay', 'An essay on marketplaces', 'Two-sided markets start small.', 1793865600, 1793869200, 3, 1);
            INSERT INTO docs(id, key, source, url, title, body, project, root, first_seen, last_seen, has_text)
              VALUES(2, 'note:/tmp/rain-sample/notes/plan.md', 'note', 'file:///tmp/rain-sample/notes/plan.md', 'Pilot plan', 'Launch with one campus.', 'Notes', '/tmp/rain-sample/notes', 1793865600, 1793865600, 1);
            INSERT INTO passages VALUES(1, 1, 0, 'Two-sided markets start small.', NULL, NULL);
            INSERT INTO passages VALUES(2, 2, 0, 'Launch with one campus.', NULL, 'nlsent');
            INSERT INTO pfts(rowid, title, body) VALUES(1, 'An essay on marketplaces', 'Two-sided markets start small.');
            INSERT INTO pfts(rowid, title, body) VALUES(2, 'Pilot plan', 'Launch with one campus.');
            INSERT INTO entities VALUES(1, 'marketplace', 'Marketplace', 'topic', 2);
            INSERT INTO dismissals VALUES(1, 'ctx', 'campus', 1793869200);
            INSERT INTO typing VALUES('note:/tmp/rain-sample/notes/plan.md', 120);
            INSERT INTO overrides VALUES('https://example.com/essay', 'reading');
            INSERT INTO searches VALUES(1, 'Marketplace Essay', 'marketplace essay', 1793869200, 'command-bar');
            INSERT INTO reasons VALUES(1, 'ctx', 'You read this on 4 Nov.');
            INSERT INTO visits VALUES(1, 1793865600, 'open', NULL);
            INSERT INTO visits VALUES(1, 1793869200, 'open', '\(home)');
            INSERT INTO topics VALUES(1, 'marketplaces', 'model');
            INSERT INTO source_state VALUES('notion', '{"cursor":"abc"}');
            """)
        } catch { check(false, "the index sample is written", "\(error)"); return }
        guard let store = try? IndexStore(url: u) else { check(false, "today's index opens"); return }
        check(store.doc(key: "https://example.com/essay")?.title == "An essay on marketplaces"
              && store.doc(key: "note:/tmp/rain-sample/notes/plan.md")?.title == "Pilot plan"
              && store.counts().reduce(0) { $0 + $1.total } == 2,
              "today's index opens with every page and note")
        guard let raw = try? SQLiteDB(path: u.path) else { check(false, "the index sample reopens"); return }
        let counts = tables.keys.sorted().map { ($0, Int((try? raw.scalarInt("SELECT count(*) FROM \($0)")) ?? -1)) }
        let lost = counts.filter { tables[$0.0] != $0.1 }
        check(lost.isEmpty, "opening today's index keeps visits, searches, dismissals and the rest", "\(lost)")
    }
}
