import AppKit
import SwiftUI
import WebKit

/// `--tabbar-shots <out> --profile <demo profile>`: the horizontal tab bar, offscreen, light and
/// dark. Each space at rest, the Essentials box open into its grid, the space menu open, a narrow
/// window where the tabs scroll, and the sidebar again after switching back. It renders a copy of
/// the profile with a throwaway WebKit store, so the profile itself isn't written to.
@MainActor
enum TabBarShots {
    static func commandLine(_ args: [String]) -> Int32 {
        func arg(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        guard let o = arg("--tabbar-shots"), let p = arg("--profile") else {
            print("Usage: --tabbar-shots <out folder> --profile <demo profile>")
            return 2
        }
        let out = URL(fileURLWithPath: (o as NSString).expandingTildeInPath, isDirectory: true)
        let profile = URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: profile.appendingPathComponent(DemoSeeder.marker).path) else {
            print("\(profile.path) isn't a demo profile.")
            return 1
        }
        return run(out: out, profile: profile)
    }

    static func run(out: URL, profile: URL) -> Int32 {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("BrowserPOC-tabbar-shots-\(UUID().uuidString)", isDirectory: true)
        Paths.ensure(tmp)
        Paths.ensure(out)
        defer { try? fm.removeItem(at: tmp) }
        for f in ["state.json", "settings.json", "sources.json", "browser.json", "index.sqlite", "index.sqlite-wal", "index.sqlite-shm",
                  "history.sqlite", "favicons", "demo-items", DemoSeeder.marker] {
            try? fm.copyItem(at: profile.appendingPathComponent(f), to: tmp.appendingPathComponent(f))
        }
        Paths.overrideRoot = tmp
        Settings.shared.reloadFromDisk()
        SourceSettings.shared.reload()
        RelatedPrefs.shared.reload()
        BrowserPrefs.shared.reload()
        // Related stays out of these: the shots are about the bar.
        RelatedPrefs.shared.update { $0.shelfHidden = true }
        Settings.shared.update { $0.rightPanelOpen = false }
        BrowserPrefs.shared.update { $0.tabLayout = .horizontal }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        guard let store = try? IndexStore(url: tmp.appendingPathComponent("index.sqlite")) else { print("Couldn't open the index copy"); return 1 }
        IndexStore.shared = store
        BrowserModel.useEphemeralStore = true
        SpaceTintBackground.forceActive = true
        Theme.GlassStyle.forceReduceTransparency = true
        // No display link offscreen, so nothing animates: every change lands at once.
        MotionSuppression.set(.launch, true)
        let model = BrowserModel()
        model.notes.reload()
        let window = SmokeTest.offscreenWindow(MainView.host(model), size: NSSize(width: 1440, height: 900))
        WindowChrome.configure(window)
        func wait(_ s: Double, _ done: () -> Bool) { _ = SmokeTest.wait(s, until: done) }
        func settle() {
            wait(15) { !model.spaceTabs.contains { $0.isLoading } }
            wait(1.2) { false }
        }
        func shoot(_ name: String, floating: Bool = false) {
            LookRenders.skipWeb = floating
            LookRenders.both(window, out, name)
            LookRenders.skipWeb = false
        }
        func slug(_ s: String?) -> String { (s ?? "space").lowercased().replacingOccurrences(of: " ", with: "-") }

        print("Rendering the tab bar into \(out.path)")
        let start = model.currentSpaceID
        let order = [start] + model.spaces.map(\.id).filter { $0 != start }
        for (i, id) in order.enumerated() {
            model.switchSpace(to: id)
            settle()
            shoot("1\(Character(UnicodeScalar(UInt8(97 + i))))-bar-\(slug(model.currentSpace?.name))")
        }
        model.switchSpace(to: start)
        settle()

        // Essentials: a few more, so the box has rows to open into.
        let spare = model.spaceTabs.filter { !$0.isEssential && !$0.isPinned && $0.isWeb && !model.isVisible($0) }
        let extra = spare.sorted { ($0.folderID == nil ? 1 : 0) < ($1.folderID == nil ? 1 : 0) }.prefix(max(0, 7 - model.essentials.count))
        for t in extra { model.addToEssentials(t) }
        settle()
        shoot("2a-essentials-closed")
        TabBarState.shared.essentialsOpen = true
        wait(0.5) { false }
        shoot("2b-essentials-open", floating: true)
        TabBarState.shared.closeAll()

        TabBarState.shared.openSpaceMenu(model)
        wait(0.5) { false }
        shoot("3-space-menu-open", floating: true)
        TabBarState.shared.closeAll()

        // A narrow window with every folder open: the strip scrolls, with soft edges.
        model.setAllFolders(expanded: true)
        window.setContentSize(NSSize(width: 1080, height: 720))
        settle()
        shoot("4-narrow-scrolling")
        model.setAllFolders(expanded: false)

        // Back to the sidebar, to show the switch goes both ways.
        TabLayoutSwitch.set(.sidebar)
        window.setContentSize(NSSize(width: 1440, height: 900))
        settle()
        shoot("5-sidebar-again")
        print("Done.")
        Intelligence.shared.shutdown()
        return 0
    }
}
