import Foundation
import WebKit

/// The demo profile: content loading, the folder safety rules, a seed into a throwaway folder
/// (offline, no topics), the saved layout, the index, the graph and the demo:// pages.
enum DemoTests {
    static func check(_ ok: Bool, _ label: String, _ detail: String = "") { SelfTest.check(ok, label, detail) }

    static func run(dir: URL) {
        print("\nDemo profile")
        guard let content = DemoContent.locate(nil), let c = try? DemoContent.load(content) else {
            check(false, "the Demo folder is found and loads", "looked up from \(Bundle.main.executablePath ?? "?")")
            return
        }
        let docs = c.items.filter { !$0.isMeeting }.count, meetings = c.items.filter(\.isMeeting).count
        check(c.notes.count >= 35 && docs >= 20 && meetings >= 8 && c.pages.count >= 140 && (c.expected?.cases.count ?? 0) >= 10,
              "the demo content loads", "\(c.notes.count) notes, \(docs) docs, \(meetings) meetings, \(c.pages.count) pages, \(c.expected?.cases.count ?? 0) cases")

        // Front matter and dates.
        let (fm, body) = DemoContent.frontMatter("""
            ---
            id: x
            tags: [a, "b, c"]
            attendees:
              - {name: Priya Raman, role: interviewer, org: "Yale '27, PM intern"}
            ---
            # Hello
            """)
        check(fm["tags"]?.list == ["a", "b, c"] && fm["attendees"]?.maps?.first?["org"] == "Yale '27, PM intern" && body.hasPrefix("# Hello"),
              "demo front matter reads lists, quoted commas and attendee maps")
        check(DemoContent.parseDate("2026-11-04T16:40-05:00") == DemoContent.parseDate("2026-11-04T16:40:00-05:00") && DemoContent.parseDate("2026-11-04T16:40:00-05:00") != nil,
              "demo times parse with or without seconds")
        check(DemoContent.uuid("school") == DemoContent.uuid("school") && DemoContent.uuid("school") != DemoContent.uuid("swapshelf"),
              "demo ids map to stable, distinct UUIDs")

        // Where it may seed.
        let fmgr = FileManager.default
        let busy = dir.appendingPathComponent("demo-busy", isDirectory: true)
        Paths.ensure(busy)
        try? Data("x".utf8).write(to: busy.appendingPathComponent("keep.txt"))
        check(MainActor.assumeIsolated { DemoSeeder.refusal(busy) } != nil, "the seeder refuses a folder that isn't empty")
        check(MainActor.assumeIsolated { DemoSeeder.refusal(DemoSeeder.realSupportRoot) } != nil
              && MainActor.assumeIsolated { DemoSeeder.refusal(DemoSeeder.realSupportRoot.appendingPathComponent("x")) } != nil,
              "the seeder refuses the app's real support folder")
        check(MainActor.assumeIsolated { DemoSeeder.refusal(fmgr.homeDirectoryForCurrentUser) } != nil, "the seeder refuses the home folder")
        let target = dir.appendingPathComponent("demo-profile", isDirectory: true)
        check(MainActor.assumeIsolated { DemoSeeder.refusal(target) } == nil, "the seeder accepts a folder that doesn't exist yet")

        // A seed, offline. It points the app at the demo folder, so put everything back after.
        let oldRoot = Paths.overrideRoot, oldStore = IndexStore.shared, oldModels = ModelFiles.overrideDir
        let oldStoreID = MainActor.assumeIsolated { BrowserModel.dataStoreID }
        defer {
            Paths.overrideRoot = oldRoot
            IndexStore.shared = oldStore
            ModelFiles.overrideDir = oldModels
            MainActor.assumeIsolated { BrowserModel.dataStoreID = oldStoreID }
            Settings.shared.reloadFromDisk()
            SourceSettings.shared.reload()
            if let s = oldStore { GraphStore.reset(indexURL: s.fileURL, index: s) }
        }
        var o = DemoSeeder.Options(content: content, target: target)
        o.fetchText = false; o.topics = false; o.favicons = false
        o.log = { _ in }
        let summary: DemoSeeder.Summary? = MainActor.assumeIsolated { try? DemoSeeder.seed(o) }
        guard let summary else { check(false, "the demo seeds into an empty folder"); return }
        check(summary.notes == c.notes.count && summary.items == c.items.count && summary.pages == c.pages.count && summary.visits > summary.pages,
              "the demo seeds into an empty folder", "\(summary.notes) notes, \(summary.items) items, \(summary.pages) pages, \(summary.visits) visits in \(Int(summary.seconds)) s")
        check(fmgr.fileExists(atPath: target.appendingPathComponent(DemoSeeder.marker).path), "the demo profile carries its marker")

        // The saved layout.
        let state = (try? Data(contentsOf: target.appendingPathComponent("state.json"))).flatMap { try? JSONDecoder.iso.decode(SavedState.self, from: $0) }
        let spaces = state?.spaces ?? []
        let essentials = state?.tabs.filter { $0.isEssential == true } ?? []
        let focus = c.layout.focus
        let sel = state?.selectedSplit
        let focusedSplit = state?.splits?.first { $0.id == sel }
        check(spaces.map(\.name) == c.layout.spaces.map(\.name) && essentials.count == c.layout.essentials.count,
              "the layout has the spaces and Essentials", "\(spaces.map(\.name)), \(essentials.count) Essentials")
        check(state?.currentSpace == DemoContent.uuid(focus.space) && sel == focus.split.map(DemoContent.uuid) && focusedSplit?.focused == DemoContent.uuid(focus.item),
              "the demo opens on its focused split and pane")
        let folderCount = c.layout.spaces.reduce(0) { $0 + $1.folders.count }
        check(state?.folders.count == folderCount && state?.splits?.count == c.layout.spaces.reduce(0) { $0 + $1.splits.count },
              "folders and splits are laid out", "\(state?.folders.count ?? 0) folders, \(state?.splits?.count ?? 0) splits")
        let demoTabs = state?.tabs.filter { ($0.url ?? "").hasPrefix("demo://") } ?? []
        check(!demoTabs.isEmpty && demoTabs.allSatisfy { $0.kind == .web } && !(state?.tabs.contains { ($0.url ?? "").contains("docs.google.com") || ($0.url ?? "").contains("notion.so") } ?? true),
              "demo docs open at demo:// addresses, never Google or Notion", "\(demoTabs.count) demo tabs")

        // Settings that keep the demo to itself.
        let src = (try? Data(contentsOf: target.appendingPathComponent("sources.json"))).flatMap { try? JSONDecoder.iso.decode(SourceConfig.self, from: $0) }
        let prefs = (try? Data(contentsOf: target.appendingPathComponent("browser.json"))).flatMap { try? JSONDecoder.iso.decode(BrowserPrefsValue.self, from: $0) }
        check(src.map { !$0.notionEnabled && !$0.googleDocsEnabled && !$0.granolaEnabled } == true && prefs?.archiveAfterHours == 0,
              "the demo profile keeps outside sources off and doesn't archive its tabs")

        // Notes on disk, the index and the graph.
        let tokyo = target.appendingPathComponent("Notes/Personal/Tokyo food list.md")
        let tokyoText = (try? String(contentsOf: tokyo, encoding: .utf8)) ?? ""
        check(tokyoText.hasPrefix("---\ntags: [japan, food]\n---\n\n# Tokyo food list") && !tokyoText.contains("id: note-"),
              "demo notes are real files with only their tags in front matter")
        if let s = IndexStore.shared {
            let bySource = Dictionary(uniqueKeysWithValues: s.counts().map { ($0.source, $0.total) })
            check(bySource[.note] == c.notes.count && bySource[.granola] == meetings && (bySource[.gdocs] ?? 0) + (bySource[.notion] ?? 0) == docs && bySource[.web] == c.pages.count,
                  "each demo item is indexed as its own source", bySource.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: " "))
            let plan = c.item("gdoc-swapshelf-pilot-plan")!.demoURL
            let visits = s.doc(key: plan).map { s.visits(docID: $0.id) } ?? []
            check(visits.contains { $0.kind == "edited" && $0.during == "in your Swapshelf space" }, "demo visits say when and in which space")
            check(s.searchCount() > 50, "past searches are seeded", "\(s.searchCount())")
            let g = GraphStore.shared.stats()
            check((g.edges["link"] ?? 0) > 5 && (g.edges["together"] ?? 0) >= 2, "the graph has wikilinks and the splits",
                  g.edges.map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", "))
        }

        // demo:// pages.
        let page = MainActor.assumeIsolated { DemoScheme.response(for: URL(string: c.item("gsheet-swapshelf-waitlist")!.demoURL)!) }
        let html = String(decoding: page.2, as: UTF8.self)
        check(page.0 == 200 && html.contains("Swapshelf waitlist and pilot metrics") && html.contains("<table>") && html.contains("Demo copy, read-only"),
              "a demo sheet opens as a read-only page with its table")
        check(!html.contains("docs.google.com") && !html.contains("notion.so"), "a demo page never points at the real service")
        let meeting = MainActor.assumeIsolated { DemoScheme.response(for: URL(string: c.item("granola-2026-10-16-paper-check-in")!.demoURL)!) }
        check(meeting.0 == 200 && String(decoding: meeting.2, as: UTF8.self).contains("Ruth Hartley"), "a demo meeting shows its attendees")
        let bad = ["demo://google-docs/nope", "demo://google-docs/..%2Fstate", "demo://google-docs/a/b", "demo://google-docs/"].map { s in
            MainActor.assumeIsolated { DemoScheme.response(for: URL(string: s)!).0 }
        }
        check(bad.allSatisfy { $0 == 404 }, "unknown or odd demo addresses are not found", "\(bad)")
        let registered = MainActor.assumeIsolated { BrowserModel.makeConfig(store: .nonPersistent()).urlSchemeHandler(forURLScheme: "demo") != nil }
        check(registered, "the browser's web views handle demo://")

        // A reseed over its own profile works and leaves other folders alone.
        let again: DemoSeeder.Summary? = MainActor.assumeIsolated { try? DemoSeeder.seed(o) }
        check(again?.notes == c.notes.count, "a demo profile can be seeded again")
        check(fmgr.fileExists(atPath: busy.appendingPathComponent("keep.txt").path), "seeding never touches another folder")
    }
}
