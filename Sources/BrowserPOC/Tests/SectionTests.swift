import Foundation

/// Sites versus Notes / Docs: classification, Docs export URLs and per-section ranking.
enum SectionTests {
    static func check(_ ok: Bool, _ label: String, _ detail: String = "") { SelfTest.check(ok, label, detail) }

    static func run(dir: URL) {
        classification()
        docsURLs()
        typingAndOverride()
        ranking(dir: dir)
    }

    static func sec(_ url: String, typed: Int = 0, override: CardSection? = nil, source: SourceType = .web) -> CardSection {
        WritingKey.section(source: source, url: url, typed: typed, override: override, writingSites: AppSettings.defaultWritingSites)
    }

    static func classification() {
        let docs = ["https://www.notion.so/Plan-0123456789abcdef0123456789abcdef", "https://felix.notion.site/Notes-0123",
                    "https://docs.google.com/document/d/1AbCdEfGhIjKlMnOp/edit", "https://docs.google.com/spreadsheets/d/1AbCdEfGhIjKlMnOp/edit#gid=0",
                    "https://docs.google.com/presentation/u/0/d/1AbCdEfGhIjKlMnOp/edit", "https://coda.io/d/Plan_d123",
                    "https://team.atlassian.net/wiki/spaces/ENG/pages/1", "https://www.figma.com/file/abc/Design"]
        let sites = ["https://docs.google.com/forms/d/1AbCdEfGhIjKlMnOp/viewform", "https://team.atlassian.net/jira/software/projects/X",
                     "https://developer.apple.com/documentation/webkit", "https://news.ycombinator.com/item?id=1"]
        let wrongDocs = docs.filter { sec($0) != .docs }
        let wrongSites = sites.filter { sec($0) != .sites }
        check(wrongDocs.isEmpty, "Notion, Google Docs and listed writing sites go under Notes / Docs", wrongDocs.joined(separator: " "))
        check(wrongSites.isEmpty, "other pages go under Sites", wrongSites.joined(separator: " "))
        check(sec("file:///x/note.md", source: .note) == .docs, "local notes go under Notes / Docs")
        check(sec("https://example.com/editor", typed: 199) == .sites && sec("https://example.com/editor", typed: 200) == .docs,
              "about 200 typed characters makes a page a writing surface")
        check(sec("https://www.notion.so/Plan-0123", override: .sites) == .sites && sec("https://example.com/a", override: .docs) == .docs,
              "a manual choice wins over the rules")
    }

    static func docsURLs() {
        let e1 = DocsExport.url(for: URL(string: "https://docs.google.com/document/d/1AbC_d-EfGhIjKl/edit?tab=t.0#heading=h.1")!)
        let e2 = DocsExport.url(for: URL(string: "https://docs.google.com/spreadsheets/u/1/d/1AbC_d-EfGhIjKl/edit#gid=0")!)
        let e3 = DocsExport.url(for: URL(string: "https://docs.google.com/presentation/d/1AbC_d-EfGhIjKl/edit#slide=id.p")!)
        let e4 = DocsExport.url(for: URL(string: "https://docs.google.com/forms/d/1AbC_d-EfGhIjKl/edit")!)
        check(e1?.absoluteString == "https://docs.google.com/document/d/1AbC_d-EfGhIjKl/export?format=txt"
              && e2?.absoluteString == "https://docs.google.com/spreadsheets/d/1AbC_d-EfGhIjKl/export?format=csv"
              && e3?.absoluteString == "https://docs.google.com/presentation/d/1AbC_d-EfGhIjKl/export/txt"
              && e4 == nil,
              "Docs, Sheets and Slides export URLs are built from the doc URL",
              [e1, e2, e3, e4].map { $0?.absoluteString ?? "nil" }.joined(separator: " "))
        let k1 = URLKey.key(for: URL(string: "https://docs.google.com/document/d/1AbC_d-EfGhIjKl/edit?tab=t.0")!)
        let k2 = URLKey.key(for: URL(string: "https://docs.google.com/document/u/0/d/1AbC_d-EfGhIjKl/edit#heading=h.2")!)
        let k3 = URLKey.key(for: URL(string: "https://www.notion.so/Plan-0123?pvs=4")!)
        check(k1 == k2 && k3 == "https://www.notion.so/Plan-0123", "one index entry and typing count per document", "\(k1) | \(k2) | \(k3)")
    }

    static func typingAndOverride() {
        let store = IndexStore.shared!
        let u = "https://example.com/my-editor"
        let a = TextAnalysis.analyze(title: "My editor", description: "", text: "Some text written in a web editor.")
        let t = Date().timeIntervalSince1970 - 86400 * 3
        store.recordCapture(DocUpsert(key: URLKey.key(for: URL(string: u)!), source: .web, url: u, title: "My editor",
                                      body: "Some text written in a web editor.", firstSeen: t, lastSeen: t), analysis: a)
        let key = URLKey.key(for: URL(string: u)!)
        store.addTyping(key: key, chars: 120)
        store.addTyping(key: key, chars: 79)
        let s1 = store.section(key: key, writingSites: [])
        store.addTyping(key: key, chars: 1)
        let s2 = store.section(key: key, writingSites: [])
        store.setOverride(key: key, section: .sites)
        let s3 = store.section(key: key, writingSites: [])
        check(s1 == .sites && s2 == .docs && s3 == .sites, "typing adds up across visits, and Move to Sites is remembered",
              "\(s1) \(s2) \(s3)")
    }

    static func page(_ store: IndexStore, _ key: String, _ title: String, _ text: String, source: SourceType = .web, daysAgo: Double = 5) {
        let t = Date().timeIntervalSince1970 - daysAgo * 86400
        let a = TextAnalysis.analyze(title: title, description: "", text: text)
        var d = DocUpsert(key: key, source: source, url: key, title: title, body: text, firstSeen: t, lastSeen: t, visitCount: 2, mtime: t)
        if source == .note {
            d.url = "file:///fixture/\(key).md"
            d.key = "file:///fixture/\(key).md"
            d.root = "/fixture"
            d.project = "Fixture"
            store.upsertFile(d, analysis: a)
        } else {
            store.recordCapture(d, analysis: a)
        }
    }

    static func ranking(dir: URL) {
        guard let store = try? IndexStore(url: dir.appendingPathComponent("sections.sqlite")) else {
            check(false, "could open a second index")
            return
        }
        // Unrelated filler so word statistics look like a real index rather than a dozen docs.
        let topics = ["hiking trails and mountain huts", "tax forms and quarterly payments", "tomato sauce and pasta recipes",
                      "football transfers and league tables", "camera lenses and street photography", "houseplants and watering schedules",
                      "jazz records and vinyl players", "electric cars and charging stations", "chess openings and endgames",
                      "coffee beans and espresso machines"]
        for i in 0..<40 {
            let t = topics[i % topics.count]
            page(store, "https://filler.example/\(i)", "Notes on \(t) \(i)", "A long read about \(t). Readers compare options, prices and tips about \(t) for beginners and experts, part \(i).")
        }
        // Strong pages about Swift concurrency, one weaker note.
        let swiftPages = [
            ("Actors in Swift", "Swift actors protect mutable state from data races. An actor serializes access, and calls from outside need await. Swift 6 strict concurrency checking turns data race warnings into errors."),
            ("Sendable and strict concurrency", "Sendable marks types that are safe to pass between concurrency domains. Swift 6 strict concurrency checking flags non Sendable captures in Task closures and actor calls."),
            ("MainActor explained", "MainActor is a global actor for UI work. Swift 6 strict concurrency checking requires MainActor isolation for UI types, and Sendable values to cross into Task closures."),
            ("Migrating to Swift 6 concurrency", "Turn on strict concurrency checking, fix Sendable warnings, mark UI code MainActor and move shared mutable state into actors to avoid data races."),
            ("Task groups and actors", "Structured concurrency with task groups runs child tasks in parallel. Actors keep shared state safe from data races, and Sendable results flow back to the parent task."),
            ("Data races in Swift", "Swift 6 catches data races at compile time with strict concurrency checking. Actors, Sendable and MainActor isolation are the tools to fix them."),
        ]
        for (i, p) in swiftPages.enumerated() { page(store, "https://swift.example/\(i)", p.0, p.1) }
        page(store, "swift-todo", "Week todo", "# Week todo\n\nFinish the Swift 6 migration. Strict concurrency checking still reports data races, Sendable warnings in Task closures and missing MainActor isolation in the networking actor. Then book the dentist.", source: .note)
        page(store, "bread", "Bread notes", "# Bread notes\n\nSourdough starter, rye flour, levain and hydration for the weekend loaf.", source: .note)
        // Strong notes about Gen Z interviews, one weaker page.
        let interviewNotes = [
            ("Interview 1", "Gen Z student at the convenience store late at night. Buys snacks and drinks with friends after class, wants faster checkout and fresh food."),
            ("Interview 2", "Gen Z shopper says late night convenience store trips are social. Snacks, drinks and fresh food matter more than price. Checkout lines are the pain."),
            ("Interview 3", "Student group buys late night snacks at the convenience store near campus. Fresh food runs out by night, and checkout is slow."),
            ("Interview 4", "Gen Z night owl uses the convenience store app for deals on snacks and drinks, and wants fresh food late at night and quick checkout."),
            ("Interview synthesis", "Across Gen Z interviews: late night convenience store visits are social, snacks and fresh food lead, and slow checkout frustrates students."),
        ]
        for (i, n) in interviewNotes.enumerated() { page(store, "interview-\(i)", n.0, "# \(n.0)\n\n" + n.1, source: .note) }
        page(store, "https://retail.example/gen-z", "Gen Z and convenience retail",
             "Gen Z shoppers like convenience stores for quick snacks, according to retail analysts. Many chains are testing self checkout to shorten lines.")

        var params = RankParams.fromSettings(AppSettings())
        params.writingSites = []
        // Pages strong, note weaker.
        let ctxA = ContextAnalysis.make(ContextInput(key: "https://swift.example/new", title: "Fixing Swift 6 concurrency errors",
            text: "Swift 6 strict concurrency checking reports data races. Use actors for shared mutable state, mark UI code MainActor, and make values Sendable before passing them into Task closures.", kind: .page))
        let rA = store.retrieve(ctxA, params)
        let noteA = rA.docs.first { $0.doc.title == "Week todo" }
        let thirdSite = rA.sites.count >= 3 ? rA.sites[2].score : 0
        check(rA.sites.count == 3 && noteA != nil, "a page context with strong page matches still shows the weaker note",
              "sites \(rA.sites.map { String(format: "%.2f", $0.score) }), docs \(rA.docs.map { "\($0.doc.title) " + String(format: "%.2f", $0.score) })")
        check(noteA.map { $0.score < thirdSite } ?? false, "and that note scores below the third page, so one shared list would have dropped it")
        check(!rA.docs.contains { $0.doc.title == "Bread notes" }, "an unrelated note doesn't fill the section")
        // Notes strong, page weaker.
        let ctxB = ContextAnalysis.make(ContextInput(key: "file:///fixture/new.md", title: "Gen Z night trips",
            text: "# Gen Z night trips\n\nStudents go to the convenience store late at night with friends for snacks and drinks. Fresh food and fast checkout decide where they go.", kind: .note))
        let rB = store.retrieve(ctxB, params)
        let pageB = rB.sites.first { $0.doc.title == "Gen Z and convenience retail" }
        check(rB.docs.count == 3 && pageB != nil, "a note context with strong note matches still shows the weaker page",
              "docs \(rB.docs.map { String(format: "%.2f", $0.score) }), sites \(rB.sites.map { "\($0.doc.title) " + String(format: "%.2f", $0.score) })")
        check(pageB.map { $0.score < (rB.docs.last?.score ?? 0) } ?? false, "and that page scores below the third note")
        // Nothing clears the bar: the section stays empty.
        let ctxC = ContextAnalysis.make(ContextInput(key: "https://swift.example/other", title: "Swift actors",
            text: "Swift actors and Sendable types with strict concurrency checking to stop data races in Swift 6.", kind: .page))
        var pC = params
        pC.threshold = 0.9
        let rC = store.retrieve(ctxC, pC)
        check(rC.docs.isEmpty && rC.sites.isEmpty, "a high bar leaves sections empty instead of filling them")
    }
}
