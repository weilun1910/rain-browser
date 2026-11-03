import Foundation
import CryptoKit

/// `--selftest`: builds a throwaway index from fixture docs and checks retrieval and the safety rules.
enum SelfTest {
    struct Fixture {
        let key: String
        let source: SourceType
        let title: String
        let text: String
        let daysAgo: Double
        let visits: Int
    }

    static let day: Double = 86400

    static let fixtures: [Fixture] = [
        // Topic 1: WebKit browsers and extensions
        Fixture(key: "https://developer.apple.com/documentation/webkit/wkwebextension", source: .web,
                title: "WKWebExtension | Apple Developer Documentation",
                text: """
                WKWebExtension is an object that encapsulates a web extension's resources that the browser loads. \
                Create it from a folder or ZIP archive that contains a manifest.json file, or from a Safari web extension app bundle. \
                A WKWebExtensionController manages a set of loaded extension contexts. The browser app reports tab and window events \
                to the controller, such as opening, closing and activating tabs, so extensions see the same tab model as the user. \
                Each WKWebExtensionContext holds the permissions and state for one extension. Manifest version 3 extensions with \
                service worker background content are supported. Blocking webRequest is not supported, so content blockers use \
                declarative rules instead.
                """, daysAgo: 6, visits: 3),
        Fixture(key: "https://github.com/nook-browser/Nook/blob/main/ExtensionManager.md", source: .web,
                title: "Nook ExtensionManager: installing Chrome extensions in a WebKit browser",
                text: """
                Nook is an open source browser for macOS written in Swift on top of WKWebView. Its ExtensionManager installs \
                extensions from ZIP files, folders, Firefox XPI files and Chrome Web Store CRX packages, converting CRX to ZIP before \
                handing it to WKWebExtension. Nook implements Chrome style native messaging itself, launching native messaging hosts \
                from manifests in the Chrome and Firefox folders. Password managers like Bitwarden needed extra shims for biometric \
                unlock and clipboard access. The extension manager is around five thousand lines of Swift.
                """, daysAgo: 4, visits: 2),
        Fixture(key: "note:browser-engine.md", source: .note, title: "Browser engine notes",
                text: """
                # Browser engine notes

                Picked WebKit over Chromium. Apple ships WKWebView engine updates with the OS, so there's no engine upkeep. \
                Extensions go through WKWebExtension and WKWebExtensionController, available since macOS 15.4. \
                Need to test 1Password, Bitwarden and uBlock Origin Lite. isInspectable turns on Safari's Web Inspector.
                """, daysAgo: 2, visits: 0),
        // Topic 2: sourdough
        Fixture(key: "https://www.kingarthurbaking.com/sourdough-starter-guide", source: .web,
                title: "How to feed and maintain a sourdough starter",
                text: """
                A healthy sourdough starter rises predictably after each feeding. Feed it equal weights of flour and water, \
                which is 100 percent hydration, and keep it at a warm room temperature. A sluggish starter that smells of acetone \
                is hungry; feed it twice a day for a few days. When the levain doubles and smells pleasantly sour it's ready to mix \
                into dough. Whole rye flour speeds up fermentation. Store a mature starter in the fridge between weekly bakes.
                """, daysAgo: 20, visits: 4),
        Fixture(key: "note:bread-log.md", source: .note, title: "Bread bake log",
                text: """
                # Bread bake log

                Saturday loaf: 75 percent hydration, levain built the night before, bulk fermentation five hours. \
                Crumb was tight and the loaf spread. Starter probably wasn't at peak. Next time do a longer cold proof \
                in the fridge and feed the starter with rye the morning before.
                """, daysAgo: 12, visits: 0),
        // Topic 3: running
        Fixture(key: "https://www.runnersworld.com/training/marathon-plan", source: .web,
                title: "A 16 week marathon training plan for beginners",
                text: """
                This marathon training plan builds weekly mileage gradually, about ten percent a week. Each week has an easy run, \
                a tempo run at comfortable hard effort, intervals for VO2 max and a long slow distance run on the weekend. \
                Taper for two weeks before race day by cutting mileage while keeping some intensity. Fuel on long runs with gels \
                every forty five minutes and practise your race day breakfast.
                """, daysAgo: 30, visits: 2),
        Fixture(key: "https://www.calculator.net/pace-calculator.html", source: .chrome,
                title: "Half marathon pace calculator", text: "", daysAgo: 15, visits: 5),
        Fixture(key: "https://webkit.org/blog/safari-web-extensions-wkwebextension", source: .chrome,
                title: "Safari web extensions and WKWebExtension in WebKit apps", text: "", daysAgo: 9, visits: 3),
        // Distractors
        Fixture(key: "file:///fixtures/7-eleven/interviews.md", source: .markdown, title: "Gen Z interview synthesis",
                text: """
                # Gen Z interview synthesis

                Students at the convenience store want faster checkout and fresh food late at night. Several said \
                they compare prices on their phone and use the app for deals. Group night outers buy snacks and drinks together.
                """, daysAgo: 8, visits: 0),
        Fixture(key: "https://www.seriouseats.com/kitchen-tools", source: .web, title: "Kitchen tools we actually use",
                text: """
                A good chef's knife, a heavy skillet and an instant read thermometer cover most cooking. You can open our \
                printable checklist in your browser. A digital scale makes baking more consistent than measuring cups.
                """, daysAgo: 40, visits: 1),
    ]

    static let contextWebKit = ContextInput(
        key: "https://example.com/adding-chrome-extensions-to-a-webkit-browser",
        title: "Adding Chrome extensions to your WebKit browser",
        text: """
        If you're building a Mac browser on WKWebView, WKWebExtensionController is how you load Chrome and Safari extensions. \
        Create a WKWebExtension from the unpacked extension folder with its manifest, wrap it in a WKWebExtensionContext and \
        load it into the controller. Your browser has to report tab events to the controller. Native messaging for password \
        managers like Bitwarden and 1Password needs extra work, and CRX files from the Chrome Web Store must be converted first.
        """, kind: .page)

    static let contextBread = ContextInput(
        key: "note:new-bake.md",
        title: "Starter is sluggish",
        text: """
        # Starter is sluggish

        My sourdough starter barely rose after feeding and the levain smelled like acetone. Maybe feed it with rye flour \
        twice a day and keep it warmer before the next bake. Check hydration too.
        """, kind: .note)

    static var failures = 0

    static func check(_ ok: Bool, _ label: String, _ detail: String = "") {
        print((ok ? "PASS  " : "FAIL  ") + label + (detail.isEmpty ? "" : "  (\(detail))"))
        if !ok { failures += 1 }
    }

    static func describe(_ ms: [Match]) -> String {
        ms.map { String(format: "%@ %.2f [k%.2f s%.2f e%.2f]", $0.doc.title.prefix(28) as CVarArg, $0.score, $0.keyword, $0.semantic, $0.entity) }
            .joined(separator: "; ")
    }

    static func seed(_ store: IndexStore, now: Date) {
        for f in fixtures {
            let t = now.timeIntervalSince1970 - f.daysAgo * day
            let a = TextAnalysis.analyze(title: f.title, description: "", text: f.text)
            var d = DocUpsert(key: f.key, source: f.source, url: f.key.hasPrefix("note:") ? "file:///notes/\(f.key.dropFirst(5))" : f.key,
                              title: f.title, body: f.text, firstSeen: t, lastSeen: t, visitCount: f.visits, mtime: t)
            switch f.source {
            case .web: store.recordCapture(d, analysis: a)
            case .chrome:
                d.body = ""
                _ = store.importChrome([(d, a)])
            case .note, .markdown:
                d.project = f.source == .markdown ? "7-Eleven" : "Notes"
                d.root = f.source == .markdown ? "/fixtures" : nil
                store.upsertFile(d, analysis: a)
            }
        }
    }

    static func run(workdir: URL?) -> Int32 {
        let dir = workdir ?? FileManager.default.temporaryDirectory.appendingPathComponent("BrowserPOC-selftest-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: dir)
        Paths.ensure(dir)
        Paths.overrideRoot = dir
        defer { if workdir == nil { try? FileManager.default.removeItem(at: dir) } }
        print("Self test in \(dir.path)")
        print("Sentence embedding: \(Embedder.shared.isAvailable ? "available, \(Embedder.shared.dimension) dims" : "not available")")
        print("Foundation Models: \(ReasonWriter.availabilityText)")

        do {
            IndexStore.shared = try IndexStore(url: dir.appendingPathComponent("index.sqlite"))
        } catch {
            print("FAIL  could not open index: \(error)")
            return 1
        }
        let store = IndexStore.shared!
        let now = Date()
        seed(store, now: now)
        let counts = store.counts()
        check(counts.reduce(0) { $0 + $1.total } == fixtures.count, "all fixtures indexed", "\(counts.map { "\($0.source.rawValue)=\($0.total)" })")

        let params = RankParams.fromSettings(AppSettings())
        let webkitKeys: Set<String> = [fixtures[0].key, fixtures[1].key, fixtures[2].key, fixtures[7].key]
        let breadKeys: Set<String> = [fixtures[3].key, fixtures[4].key]

        // Retrieval for a WebKit page.
        let ctxA = ContextAnalysis.make(contextWebKit)
        let rA = store.retrieve(ctxA, params)
        print("      webkit context terms: \(rA.terms.prefix(10).joined(separator: ", "))")
        print("      webkit results: \(describe(rA.matches))")
        let aKeys = Set(rA.matches.map { $0.doc.key })
        check(aKeys.contains(fixtures[0].key) && aKeys.contains(fixtures[1].key), "WebKit page brings back the WebKit pages")
        check(aKeys.isSubset(of: webkitKeys), "WebKit page brings back nothing unrelated", aKeys.subtracting(webkitKeys).joined(separator: ", "))

        // Retrieval for a bread note.
        let ctxB = ContextAnalysis.make(contextBread)
        let rB = store.retrieve(ctxB, params)
        print("      bread context terms: \(rB.terms.prefix(10).joined(separator: ", "))")
        print("      bread results: \(describe(rB.matches))")
        let bKeys = Set(rB.matches.map { $0.doc.key })
        check(!bKeys.isEmpty && bKeys.isSubset(of: breadKeys), "bread note brings back only bread items", bKeys.joined(separator: ", "))
        check(bKeys.contains(fixtures[3].key), "bread note finds the starter guide")

        // Unrelated context shows nothing.
        let ctxC = ContextAnalysis.make(ContextInput(key: "https://example.com/tax", title: "Filing quarterly estimated taxes",
            text: "Freelancers pay estimated taxes four times a year. Use form 1040-ES to work out the amount and avoid an underpayment penalty from the IRS.",
            kind: .page))
        let rC = store.retrieve(ctxC, params)
        check(rC.matches.isEmpty, "unrelated page shows no cards", describe(rC.matches))

        // The current item is never shown.
        let selfCtx = ContextAnalysis.make(ContextInput(key: fixtures[0].key, title: fixtures[0].title, text: fixtures[0].text, kind: .page))
        let rSelf = store.retrieve(selfCtx, params)
        check(!rSelf.matches.contains { $0.doc.key == fixtures[0].key }, "current item is excluded")

        // Anything opened in the last ten minutes is excluded.
        store.touchOpened(key: fixtures[1].key, at: now.addingTimeInterval(-120))
        let rRecent = store.retrieve(ctxA, params)
        check(!rRecent.matches.contains { $0.doc.key == fixtures[1].key }, "recently opened item is excluded")
        store.touchOpened(key: fixtures[1].key, at: now.addingTimeInterval(-3 * day))

        // Dismiss hides it for this context and lowers it for similar ones.
        if let m = rA.matches.first(where: { $0.doc.key == fixtures[0].key }) {
            store.dismiss(docID: m.doc.id, contextKey: contextWebKit.key, terms: rA.terms)
            let rD = store.retrieve(ctxA, params)
            check(!rD.matches.contains { $0.doc.key == fixtures[0].key }, "dismissed card stays hidden for the same context")
            let similar = ContextAnalysis.make(ContextInput(key: "https://example.com/other", title: contextWebKit.title,
                                                            text: contextWebKit.text, kind: .page))
            let rS = store.retrieve(similar, params)
            let after = rS.matches.first { $0.doc.key == fixtures[0].key }
            check(after == nil || (after!.penalized && after!.score < m.score), "dismissed card scores lower in a similar context",
                  after.map { String(format: "%.2f -> %.2f", m.score, $0.score) } ?? "hidden")
        } else {
            check(false, "dismiss test needs the WKWebExtension page in the results")
        }

        // Reason template.
        if let m = rB.matches.first {
            let r = Reasons.template(m)
            print("      reason: \(r)")
            check(!r.isEmpty && r.rangeOfCharacter(from: CharacterSet(charactersIn: "\u{2013}\u{2014}\u{00B7}")) == nil,
                  "reason template is plain text")
        }
        check(Reasons.tidy("\"Both pages cover WKWebExtension \u{2014} and native messaging for Bitwarden.\"") == "Both pages cover WKWebExtension, and native messaging for Bitwarden.",
              "model reasons are tidied", Reasons.tidy("\"Both pages cover WKWebExtension \u{2014} and native messaging for Bitwarden.\"") ?? "nil")

        urlFilterTests()
        markdownTests()
        htmlTests()
        folderTests(dir: dir)
        chromePlanTests()

        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
        return failures == 0 ? 0 : 1
    }

    static func urlFilterTests() {
        func fetch(_ s: String, _ visits: Int = 3) -> URLFilter.FetchDecision { URLFilter.fetchDecision(URL(string: s)!, visitCount: visits) }
        check(fetch("https://developer.apple.com/documentation/webkit/wkwebview") == .fetch, "plain docs page is fetched")
        check(fetch("https://example.com/blog/inside-the-keyboard") == .fetch, "ordinary words like inside and keyboard are fine")
        check(fetch("https://example.com/article", 1) != .fetch, "pages visited once are not fetched")
        let blocked = [
            "https://example.com/auth/callback?code=abc", "https://example.com/unsubscribe?u=1", "https://example.com/login",
            "https://example.com/account/confirm-email", "https://example.com/?token=1", "https://example.com/magic-link/xyz",
            "https://example.com/reset-password", "https://example.com/oauth2/authorize", "https://example.com/x?apiKey=1",
            "https://example.com/x?sid=1", "https://example.com/invite/abc", "https://example.com/sign-in",
            "http://localhost:3000/", "http://192.168.1.2/admin", "https://mail.google.com/mail/u/0/",
            "https://docs.google.com/document/d/1", "https://www.notion.so/page", "https://www.linkedin.com/feed/",
            "https://app.apollo.io/#/people", "https://example.com/d/9f8e7d6c5b4a39281706f5e4d3c2b1a0aabbccdd",
        ]
        let leaks = blocked.filter { fetch($0) == .fetch }
        check(leaks.isEmpty, "risky URLs are never fetched", leaks.joined(separator: " "))
        let s = AppSettings()
        check(URLFilter.importDecision(URL(string: "https://www.google.com/search?q=webkit")!, settings: s) != .importIt, "search pages aren't imported")
        check(URLFilter.importDecision(URL(string: "https://secure.chase.com/web/auth")!, settings: s) != .importIt, "banking domains aren't imported")
        check(URLFilter.importDecision(URL(string: "chrome://settings")!, settings: s) != .importIt, "chrome pages aren't imported")
    }

    static func markdownTests() {
        let a = Markdown.appendRelated(to: "# Plan\n\nSome text", title: "WKWebExtension", url: "https://x.com/a")
        check(a == "# Plan\n\nSome text\n\n## Related\n\n- [WKWebExtension](https://x.com/a)\n", "first related link adds a Related section", a ?? "nil")
        let b = a.flatMap { Markdown.appendRelated(to: $0, title: "Nook", url: "https://x.com/b") }
        check(b == "# Plan\n\nSome text\n\n## Related\n\n- [WKWebExtension](https://x.com/a)\n- [Nook](https://x.com/b)\n", "second link joins the same section", b ?? "nil")
        check(b.flatMap { Markdown.appendRelated(to: $0, title: "Nook", url: "https://x.com/b") } == nil, "duplicate links are skipped")
        let html = Markdown.html("# T\n\n- one\n- [two](https://a.b)\n\n`code` and **bold**", title: "T")
        check(html.contains("<h1>T</h1>") && html.contains("<a href=\"https://a.b\">two</a>") && html.contains("<code>code</code>"), "Markdown preview renders")
    }

    static func htmlTests() {
        let page = """
        <html><head><title>Test &amp; page</title><meta name="description" content="A short summary"></head>
        <body><nav>Home About</nav><script>var x = 1;</script><article><h1>Heading</h1><p>\(String(repeating: "Real article text about WebKit extensions. ", count: 20))</p></article><footer>Footer</footer></body></html>
        """
        let e = HTMLText.extract(page)
        check(e.title == "Test & page" && e.description == "A short summary", "HTML title and description", "\(e.title) | \(e.description)")
        check(e.text.contains("Real article text") && !e.text.contains("var x") && !e.text.contains("Home About"), "HTML article text without scripts or nav")
        check(HTMLText.isLoginWall(HTMLText.Extract(title: "", description: "", text: "Please sign in to continue.")), "login walls are detected")
        check(!HTMLText.isLoginWall(e), "real articles aren't login walls")
    }

    static func sha(_ url: URL) -> String {
        guard let d = try? Data(contentsOf: url) else { return "" }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    static func folderTests(dir: URL) {
        let root = dir.appendingPathComponent("md-root", isDirectory: true)
        let files = ["ProjA/notes/plan.md": "# Plan\nWebKit things", "top.md": "# Top", "ProjA/.git/x.md": "git",
                     "node_modules/pkg/readme.md": "nm", "build.nosync/y.md": "nosync", ".build/z.md": "build",
                     "ProjB/data.txt": "not markdown"]
        for (p, c) in files {
            let u = root.appendingPathComponent(p)
            Paths.ensure(u.deletingLastPathComponent())
            try? c.write(to: u, atomically: true, encoding: .utf8)
        }
        let before = files.keys.map { (k: String) -> (String, String, Date?) in
            let u = root.appendingPathComponent(k)
            return (k, sha(u), (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
        }
        let found = MarkdownFolders.scan(root: root)
        let resolvedRoot = root.resolvingSymlinksInPath().path
        let rel = Set(found.files.map { $0.url.resolvingSymlinksInPath().path.replacingOccurrences(of: resolvedRoot + "/", with: "") })
        check(rel == ["ProjA/notes/plan.md", "top.md"], "Markdown scan skips .git, node_modules, .build and .nosync", rel.sorted().joined(separator: ", "))
        let projA = found.files.first { $0.url.lastPathComponent == "plan.md" }.map { MarkdownFolders.project(for: $0.url, root: root) }
        check(projA == "ProjA", "project label is the first folder under the root", projA ?? "nil")
        for f in found.files {
            if let text = MarkdownFolders.read(f.url) {
                let (d, a) = Indexer.fileDoc(url: f.url, text: text, source: .markdown, project: "ProjA", root: root.path, mtime: f.mtime)
                IndexStore.shared.upsertFile(d, analysis: a)
            }
        }
        let after = before.map { (k, _, _) -> (String, String, Date?) in
            let u = root.appendingPathComponent(k)
            return (k, sha(u), (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
        }
        let unchanged = zip(before, after).allSatisfy { $0.1 == $1.1 && $0.2 == $1.2 }
        check(unchanged, "indexing Markdown folders leaves the files untouched")

        let notes = dir.appendingPathComponent("Notes", isDirectory: true)
        Paths.ensure(notes)
        check(FileSafety.canWriteNote(notes.appendingPathComponent("a.md"), notesDir: notes), "notes folder is writable")
        check(!FileSafety.canWriteNote(root.appendingPathComponent("top.md"), notesDir: notes), "Markdown folders are not writable")
        check(!FileSafety.canWriteNote(notes.appendingPathComponent("../index.sqlite"), notesDir: notes), "paths outside the notes folder are not writable")
    }

    static func chromePlanTests() {
        let now = Date()
        let rows = [
            ChromeRow(url: URL(string: "https://developer.apple.com/documentation/webkit")!, title: "WebKit", visitCount: 9, lastVisit: now),
            ChromeRow(url: URL(string: "https://example.com/once")!, title: "Once", visitCount: 1, lastVisit: now),
            ChromeRow(url: URL(string: "https://www.google.com/search?q=x")!, title: "x - Google Search", visitCount: 3, lastVisit: now),
            ChromeRow(url: URL(string: "https://mail.google.com/mail/u/0/")!, title: "Inbox", visitCount: 50, lastVisit: now),
            ChromeRow(url: URL(string: "https://www.notion.so/Plan-123")!, title: "Plan", visitCount: 5, lastVisit: now),
            ChromeRow(url: URL(string: "https://example.com/verify?t=1")!, title: "Verify", visitCount: 2, lastVisit: now),
        ]
        let p = ChromeHistory.plan(rows, settings: AppSettings())
        check(p.imports.count == 4 && p.fetch.count == 1 && p.titleOnly.count == 3 && p.notImported.count == 2,
              "Chrome plan splits rows into import, fetch and skip",
              "import \(p.imports.count), fetch \(p.fetch.count), title only \(p.titleOnly.count), skipped \(p.notImported.count)")
    }
}
