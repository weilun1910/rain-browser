import Foundation

/// A labelled set for measuring resurfacing: items Felix might have seen, and contexts with the
/// items that should come back. Close-but-wrong items share words with a context on purpose.
enum EvalFixture {
    struct Item {
        let key: String
        let source: SourceType
        let title: String
        let text: String
        let daysAgo: Double
        var visits: Int = 1
    }

    struct Context {
        let name: String
        let input: ContextInput
        /// Items that would help. Empty means the panel should stay quiet.
        let relevant: Set<String>
    }

    static func note(_ slug: String) -> String { "file:///eval/notes/\(slug).md" }

    static let items: [Item] = [
        // Browser engineering
        Item(key: "https://developer.apple.com/documentation/webkit/wkwebextensioncontroller", source: .web,
             title: "WKWebExtensionController | Apple Developer Documentation",
             text: "A WKWebExtensionController manages a set of loaded extension contexts. Load a WKWebExtensionContext into the controller to run an extension. The app reports tab and window events, such as opening, closing and activating tabs, so extensions see the same tab model as the user. Available in macOS 15.4 and later.", daysAgo: 9, visits: 3),
        Item(key: "https://github.com/nook-browser/Nook/blob/main/docs/extensions.md", source: .web,
             title: "How Nook installs Chrome extensions",
             text: "Nook converts CRX packages from the Chrome Web Store to ZIP archives before handing them to WKWebExtension. It implements Chrome native messaging itself so password managers like Bitwarden can talk to their desktop apps. Manifest version 3 service workers are supported.", daysAgo: 6, visits: 2),
        Item(key: note("browser-extensions-plan"), source: .note, title: "Extensions plan",
             text: "# Extensions plan\n\nShip uBlock Origin Lite first since it only needs declarativeNetRequest. 1Password and Bitwarden need native messaging, which WebKit doesn't bridge, so we'd write the host launcher ourselves like Nook does. Test with the Web Inspector on.", daysAgo: 3),
        Item(key: "https://webkit.org/blog/16000/safari-web-inspector-tips", source: .web,
             title: "Web Inspector tips for Safari 26",
             text: "The Web Inspector's Timelines tab records layout, painting and JavaScript. Use the Network tab to see request waterfalls. The Console supports top level await. Responsive design mode simulates devices.", daysAgo: 25),
        Item(key: "https://www.swift.org/documentation/concurrency/", source: .web,
             title: "Swift concurrency: actors, tasks and Sendable",
             text: "Actors protect mutable state by serialising access. Use Task.detached sparingly. Mark types Sendable when they can cross concurrency domains. MainActor isolates UI code. Strict concurrency checking in Swift 6 turns data races into compile errors.", daysAgo: 14, visits: 4),
        // Thesis on memory and resurfacing
        Item(key: "https://www.science.org/doi/10.1126/science.1207745", source: .web,
             title: "Google Effects on Memory: Cognitive Consequences of Having Information at Our Fingertips",
             text: "Sparrow, Liu and Wegner found that when people expect to have future access to information, they have lower rates of recall of the information itself and enhanced recall instead for where to access it. The Internet has become a primary form of external or transactive memory.", daysAgo: 21, visits: 2),
        Item(key: "https://www.theatlantic.com/magazine/archive/1945/07/as-we-may-think/303881/", source: .web,
             title: "As We May Think, by Vannevar Bush",
             text: "Bush describes the memex, a device in which an individual stores all his books, records and communications, mechanized so that it may be consulted with exceeding speed and flexibility. Associative trails link items so a researcher can return to a train of thought.", daysAgo: 30),
        Item(key: note("thesis-sources"), source: .note, title: "Thesis sources",
             text: "# Thesis sources\n\n- Sparrow et al 2011 on the Google effect and transactive memory\n- Bush 1945, the memex and associative trails\n- Need something on spaced repetition and the testing effect\n- Maybe Licklider's Man-Computer Symbiosis", daysAgo: 5),
        Item(key: "https://en.wikipedia.org/wiki/Spaced_repetition", source: .chrome,
             title: "Spaced repetition - Wikipedia", text: "", daysAgo: 40, visits: 3),
        Item(key: "https://www.gwern.net/Spaced-repetition", source: .web,
             title: "Spaced Repetition for Efficient Learning",
             text: "Reviewing material at increasing intervals exploits the spacing effect. The testing effect means retrieval practice strengthens memory more than rereading. Software like Anki schedules reviews just before you would forget.", daysAgo: 18),
        // Sourdough
        Item(key: "https://www.kingarthurbaking.com/sourdough-starter", source: .web,
             title: "How to feed and maintain a sourdough starter",
             text: "A healthy starter rises predictably after each feeding. Feed it equal weights of flour and water. A sluggish starter that smells of acetone is hungry; feed it twice a day. Whole rye flour speeds up fermentation.", daysAgo: 20, visits: 4),
        Item(key: note("bread-log"), source: .note, title: "Bread bake log",
             text: "# Bread bake log\n\nSaturday loaf: 75 percent hydration, levain built the night before, bulk fermentation five hours. Crumb was tight. Starter probably wasn't at peak. Next time feed with rye the morning before and do a longer cold proof.", daysAgo: 12),
        // Running
        Item(key: "https://www.runnersworld.com/training/a20/marathon-plan", source: .web,
             title: "A 16 week marathon training plan",
             text: "Build weekly mileage about ten percent a week. Each week has an easy run, a tempo run, intervals for VO2 max and a long slow run. Taper for two weeks before race day. Fuel on long runs with gels every 45 minutes.", daysAgo: 30, visits: 2),
        Item(key: "https://www.calculator.net/pace-calculator.html", source: .chrome,
             title: "Pace calculator for running", text: "", daysAgo: 15, visits: 5),
        // 7-Eleven consulting project
        Item(key: note("7-eleven-interviews"), source: .note, title: "Gen Z interview synthesis",
             text: "# Gen Z interview synthesis\n\nStudents want faster checkout and fresh food late at night. Several compare prices on their phones and use the 7-Eleven app for deals. Group night outers buy snacks and drinks together after 11pm.", daysAgo: 8),
        Item(key: "https://www.notion.so/7-Eleven-midpoint-deck-3f2a9c1b8d7e4f60a1b2c3d4e5f60718", source: .notion,
             title: "7-Eleven midpoint deck outline",
             text: "Opportunity: late night fresh food for group night outers. Evidence from 12 interviews and the receipt study. Next: concept tests for a pre-order pickup shelf and app-only bundles.", daysAgo: 4),
        Item(key: "https://www.nacsonline.com/research/convenience-gen-z", source: .web,
             title: "Gen Z and convenience stores: NACS consumer research",
             text: "Gen Z shoppers visit convenience stores more often than older groups and care most about speed, fresh food and digital deals. Loyalty apps drive repeat trips. Late night traffic is growing in urban stores.", daysAgo: 11),
        // Job search
        Item(key: note("mckinsey-case-prep"), source: .note, title: "Case interview prep",
             text: "# Case interview prep\n\nStructure: clarify the goal, lay out a MECE issue tree, do the math out loud, synthesise with a recommendation. Practise market sizing. Final round feedback: synthesis was slow, so lead with the answer.", daysAgo: 16),
        Item(key: "https://www.granola.ai/meetings/coffee-chat-apple-epm", source: .granola,
             title: "Coffee chat with an Apple EPM",
             text: "She said engineering program managers at Apple own the schedule across hardware and software teams. Interviews test cross-functional judgment with past project stories. Advice: bring one launch story with numbers and one conflict story.", daysAgo: 7),
        Item(key: "https://docs.google.com/document/d/1AbCdEfGhIjKlMnOpQrStUvWxYz012345", source: .gdocs,
             title: "Cover letter draft for Apple EPM",
             text: "I want to join Apple as an engineering program manager because I like owning the messy middle of a launch. At Yale I ran the hardware schedule for a robotics team of twelve.", daysAgo: 6),
        // Personal and distractors
        Item(key: "https://www.seriouseats.com/kitchen-tools", source: .web, title: "Kitchen tools we actually use",
             text: "A good chef's knife, a heavy skillet and an instant read thermometer cover most cooking. A digital scale makes baking more consistent than cups.", daysAgo: 40),
        Item(key: "https://www.japan-guide.com/e/e2164.html", source: .web, title: "Kyoto travel guide",
             text: "Kyoto has over a thousand temples. Visit Fushimi Inari early in the morning to avoid crowds. The Arashiyama bamboo grove is best at dawn. Buy an ICOCA card for buses and trains.", daysAgo: 50),
        Item(key: "https://www.nerdwallet.com/article/taxes/estimated-taxes", source: .web, title: "How estimated taxes work",
             text: "Freelancers pay estimated taxes four times a year using form 1040-ES. Paying late can mean an underpayment penalty.", daysAgo: 35),
        Item(key: "https://news.ycombinator.com/item?id=4000001", source: .chrome, title: "Show HN: I built a browser in a weekend", text: "", daysAgo: 10, visits: 1),
        Item(key: note("reading-list"), source: .note, title: "Reading list",
             text: "# Reading list\n\n- The Design of Everyday Things\n- Thinking, Fast and Slow\n- Range by David Epstein\n- The Mom Test", daysAgo: 22),
        Item(key: "https://developer.apple.com/documentation/foundationmodels", source: .web,
             title: "Foundation Models | Apple Developer Documentation",
             text: "The Foundation Models framework gives access to the on-device large language model behind Apple Intelligence. Use guided generation with @Generable types to get structured output. Sessions keep a transcript within the context window.", daysAgo: 2, visits: 3),
        Item(key: note("resurfacing-ideas"), source: .note, title: "Resurfacing ideas",
             text: "# Resurfacing ideas\n\nCards should say why they're back: when I saw it and what I was doing. Use a reranker so only strong matches show. The panel should stay empty more often than not.", daysAgo: 1),
    ]

    static let contexts: [Context] = [
        Context(name: "Chrome extensions article",
                input: ContextInput(key: "https://example.com/chrome-extensions-in-webkit", title: "Adding Chrome extensions to a WebKit browser",
                                    text: "If you're building a Mac browser on WKWebView, WKWebExtensionController is how you load extensions. Create a WKWebExtension from the unpacked folder, wrap it in a context and load it. Password managers need native messaging, and CRX files from the Chrome Web Store must be converted first.", kind: .page),
                relevant: ["https://developer.apple.com/documentation/webkit/wkwebextensioncontroller", "https://github.com/nook-browser/Nook/blob/main/docs/extensions.md", note("browser-extensions-plan")]),
        Context(name: "Thesis chapter draft",
                input: ContextInput(key: note("thesis-chapter-2"), title: "Thesis chapter 2: memory in the age of search",
                                    text: "# Chapter 2\n\nThis chapter argues that browsers which resurface what you've read act as transactive memory. People remember where to find things rather than the things themselves, so a tool that brings the right page back at the right moment extends memory. I'll start from the memex and move to recent studies.", kind: .note),
                relevant: ["https://www.science.org/doi/10.1126/science.1207745", "https://www.theatlantic.com/magazine/archive/1945/07/as-we-may-think/303881/", note("thesis-sources"), note("resurfacing-ideas")]),
        Context(name: "Starter question",
                input: ContextInput(key: note("starter-sluggish"), title: "Starter is sluggish",
                                    text: "# Starter is sluggish\n\nMy sourdough starter barely rose after feeding and smelled like acetone. Maybe feed it with rye twice a day and keep it warmer before the next bake.", kind: .note),
                relevant: ["https://www.kingarthurbaking.com/sourdough-starter", note("bread-log")]),
        Context(name: "Half marathon plan",
                input: ContextInput(key: "https://example.com/half-marathon-training", title: "Half marathon training for beginners",
                                    text: "A 12 week half marathon plan with easy runs, one tempo run and a long run each week. Work out your goal pace and practise fuelling on long runs before race day.", kind: .page),
                relevant: ["https://www.runnersworld.com/training/a20/marathon-plan", "https://www.calculator.net/pace-calculator.html"]),
        Context(name: "7-Eleven concept test plan",
                input: ContextInput(key: note("7-eleven-concept-tests"), title: "Concept test plan for 7-Eleven",
                                    text: "# Concept tests\n\nWe're testing a pre-order pickup shelf for late night group trips and app-only snack bundles with Gen Z students. Recruit students who shop after 11pm. Measure purchase intent and price sensitivity.", kind: .note),
                relevant: [note("7-eleven-interviews"), "https://www.notion.so/7-Eleven-midpoint-deck-3f2a9c1b8d7e4f60a1b2c3d4e5f60718", "https://www.nacsonline.com/research/convenience-gen-z"]),
        Context(name: "Apple EPM interview prep",
                input: ContextInput(key: "https://jobs.apple.com/en-us/details/200500000/engineering-program-manager", title: "Engineering Program Manager - Apple Jobs",
                                    text: "Apple is looking for an Engineering Program Manager to drive schedules across hardware and software teams. You will lead cross-functional programs from concept to launch. Strong communication and judgment required.", kind: .page),
                relevant: ["https://www.granola.ai/meetings/coffee-chat-apple-epm", "https://docs.google.com/document/d/1AbCdEfGhIjKlMnOpQrStUvWxYz012345"]),
        Context(name: "Swift 6 migration",
                input: ContextInput(key: "https://example.com/swift-6-migration", title: "Migrating an app to Swift 6",
                                    text: "Swift 6 language mode turns data race warnings into errors. Start by marking UI types MainActor, make model types Sendable, and replace shared mutable state with actors.", kind: .page),
                relevant: ["https://www.swift.org/documentation/concurrency/"]),
        Context(name: "On-device model notes",
                input: ContextInput(key: note("engine-notes"), title: "Engine notes",
                                    text: "# Engine notes\n\nUse Foundation Models guided generation to describe what the user is doing, then rerank candidates and only show strong matches. Each card should say when I saw it.", kind: .note),
                relevant: ["https://developer.apple.com/documentation/foundationmodels", note("resurfacing-ideas")]),
        Context(name: "Learning science article",
                input: ContextInput(key: "https://example.com/retrieval-practice", title: "Why retrieval practice beats rereading",
                                    text: "Students who test themselves remember more a week later than students who reread. Spacing reviews over days helps even more. Flashcard apps use both effects.", kind: .page),
                relevant: ["https://www.gwern.net/Spaced-repetition", "https://en.wikipedia.org/wiki/Spaced_repetition", note("thesis-sources")]),
        // Should stay quiet
        Context(name: "Unrelated: car insurance",
                input: ContextInput(key: "https://example.com/car-insurance", title: "Comparing car insurance quotes",
                                    text: "Liability coverage pays for damage you cause to others. Collision covers your own car. Raising your deductible lowers the premium. Compare at least three quotes every year.", kind: .page),
                relevant: []),
        Context(name: "Unrelated: houseplants",
                input: ContextInput(key: "https://example.com/houseplants", title: "Keeping a fiddle leaf fig alive",
                                    text: "Fiddle leaf figs want bright indirect light and dislike being moved. Water when the top two inches of soil are dry. Brown spots usually mean overwatering.", kind: .page),
                relevant: []),
        Context(name: "Unrelated: football scores",
                input: ContextInput(key: "https://example.com/premier-league", title: "Premier League results and table",
                                    text: "Arsenal beat Chelsea two nil at the Emirates. Liverpool drew with Manchester City. The title race is tight with eight games left.", kind: .page),
                relevant: []),
        Context(name: "Near miss: bread machine review",
                input: ContextInput(key: "https://example.com/bread-machine-review", title: "Best bread machines of the year",
                                    text: "We tested twelve bread machines for crust, noise and ease of cleaning. The best one bakes a loaf in three hours and has a gluten free setting. Prices range from 80 to 300 dollars.", kind: .page),
                relevant: []),
        Context(name: "Near miss: car starter motor",
                input: ContextInput(key: "https://example.com/replace-starter-motor", title: "How to replace a car starter motor",
                                    text: "If the car clicks but won't start, the starter motor may be failing. Disconnect the battery, unbolt the starter from the transmission housing and swap in the new one. Check the solenoid wiring first.", kind: .page),
                relevant: []),
    ]
}
