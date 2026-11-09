import AppKit
import SwiftUI

/// `--drag-shots <out> --profile <demo profile>`: folders inside folders in the sidebar, the icon
/// column and the tab bar, the folder drop zones, a tab dragged over the page on each side and over
/// a split, and the split's divider, rendered offscreen from a copy of the demo profile. A real
/// drag can't be started offscreen, so the drop zones and the page preview are shown through the
/// stand-ins the views read when no drag is going on. The profile isn't written to.
@MainActor
enum DragShots {
    static func commandLine(_ args: [String]) -> Int32 {
        func arg(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        guard let o = arg("--drag-shots"), let p = arg("--profile") else {
            print("Usage: --drag-shots <out folder> --profile <demo profile>")
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

    /// The app's window on a throwaway copy of the demo profile, offscreen. The copy is deleted
    /// with `close`.
    struct Harness {
        let model: BrowserModel
        let window: NSWindow
        let tmp: URL
        func close() { try? FileManager.default.removeItem(at: tmp) }
    }

    static func open(profile: URL) -> Harness? {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("BrowserPOC-drag-shots-\(UUID().uuidString)", isDirectory: true)
        Paths.ensure(tmp)
        for f in ["state.json", "settings.json", "sources.json", "browser.json", "related.json", "index.sqlite", "index.sqlite-wal",
                  "index.sqlite-shm", "history.sqlite", "favicons", "demo-items", DemoSeeder.marker] {
            try? fm.copyItem(at: profile.appendingPathComponent(f), to: tmp.appendingPathComponent(f))
        }
        Paths.overrideRoot = tmp
        ModelFiles.overrideDir = profile.appendingPathComponent("Models", isDirectory: true)
        ModelFiles.clearReadyCache()
        Settings.shared.reloadFromDisk()
        SourceSettings.shared.reload()
        RelatedPrefs.shared.reload()
        BrowserPrefs.shared.reload()
        RelatedPrefs.shared.update { $0.shelfHidden = true }
        BrowserPrefs.shared.update { $0.sidebarIconsOnly = false; $0.sidebarOnRight = false; $0.tabLayout = .sidebar; $0.sidebarHidden = false }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        guard let store = try? IndexStore(url: tmp.appendingPathComponent("index.sqlite")) else {
            print("Couldn't open the index copy")
            try? fm.removeItem(at: tmp)
            return nil
        }
        IndexStore.shared = store
        BrowserModel.useEphemeralStore = true
        SpaceTintBackground.forceActive = true
        Motion.forceReduce = true
        HoverCards.shared.recorded = [:]
        MotionSuppression.set(.launch, true)
        SidebarResize.headless = true
        let model = BrowserModel()
        model.notes.reload()
        let window = SmokeTest.offscreenWindow(MainView.host(model), size: NSSize(width: 1280, height: 820))
        WindowChrome.configure(window)
        return Harness(model: model, window: window, tmp: tmp)
    }

    static func run(out: URL, profile: URL) -> Int32 {
        Paths.ensure(out)
        guard let h = open(profile: profile) else { return 1 }
        defer { h.close() }
        let model = h.model, window = h.window
        var failed = 0
        func check(_ ok: Bool, _ label: String, _ detail: String = "") {
            print("  \(ok ? "ok  " : "FAIL") \(label)\(detail.isEmpty ? "" : " (\(detail))")")
            if !ok { failed += 1 }
        }
        func settle() {
            _ = SmokeTest.wait(20) { !model.spaceTabs.contains { $0.isLoading } }
            _ = SmokeTest.wait(1) { false }
        }
        func shoot(_ name: String) {
            for (suffix, a) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                window.appearance = NSAppearance(named: a)
                _ = SmokeTest.wait(0.4) { false }
                let url = out.appendingPathComponent("\(name)-\(suffix).png")
                LookRenders.snapshot(window, url)
                SidebarWidthShots.drawTrafficLights(on: url, window: window)
            }
            window.appearance = nil
        }

        print("Rendering drags into \(out.path)")
        guard let school = model.spaces.first(where: { $0.name == "School" }) else { print("No School space in the demo profile"); return 1 }
        model.switchSpace(to: school.id)
        let folders = model.childFolders(of: nil)
        guard let sources = folders.first(where: { $0.name == "Paper sources" }), let drafts = folders.first(where: { $0.name == "Drafts" }) else {
            print("The School space has no Paper sources and Drafts folders")
            return 1
        }
        // Two levels inside Paper sources, with a couple of its tabs moved in.
        let primary = model.createFolder(named: "Primary sources", in: sources.id)
        let interviews = model.createFolder(named: "Interviews", in: primary.id)
        let filed = model.refs(in: .folder(sources.id))
        if filed.count >= 3 {
            model.place([filed[0], filed[1]], in: .folder(primary.id), at: 0)
            model.place([filed[2]], in: .folder(interviews.id), at: 0)
        }
        model.placeFolder(primary.id, in: sources.id, at: 0)
        for f in model.folders(in: school.id) { model.setFolder(f.id, open: true) }
        settle()
        check(model.folderTree().contains { $0.folder.id == interviews.id && $0.depth == 2 }, "the demo now has a folder two levels down")
        shoot("1-nested-folders")

        // Drop zones: a tab or folder over the middle of a folder, and a folder over its top edge.
        SidebarDrag.shared.folderPreview = (drafts.id, .into)
        settle()
        shoot("2-folder-drop-into")
        SidebarDrag.shared.folderPreview = (drafts.id, .before)
        settle()
        shoot("3-folder-drop-beside")
        SidebarDrag.shared.folderPreview = nil

        BrowserPrefs.shared.update { $0.sidebarIconsOnly = true }
        settle()
        shoot("4-icons-nested")
        BrowserPrefs.shared.update { $0.sidebarIconsOnly = false }

        // In the tab bar, only Paper sources open, with a tab inside its subfolder on screen, so the
        // strip scrolls to the nested chips.
        for f in model.childFolders(of: nil) where f.id != sources.id { model.setFolder(f.id, open: false) }
        if case .tab(let id)? = model.refs(in: .folder(primary.id)).first, let t = model.tab(id) { model.select(t) }
        BrowserPrefs.shared.update { $0.tabLayout = .horizontal }
        settle()
        shoot("5-tabbar-nested")
        SidebarDrag.shared.folderPreview = (primary.id, .into)
        settle()
        shoot("6-tabbar-folder-drop-into")
        SidebarDrag.shared.folderPreview = nil
        BrowserPrefs.shared.update { $0.tabLayout = .sidebar }
        for f in model.folders(in: school.id) { model.setFolder(f.id, open: true) }
        settle()

        // A tab dragged over a single page, left of the middle and then right of it.
        let loose = model.refs(in: .today).compactMap { r -> Tab? in if case .tab(let id) = r { return model.tab(id) }; return nil }
        guard let page = loose.first(where: { $0.isWeb }), let incoming = loose.first(where: { $0.isWeb && $0.id != page.id }) else {
            print("The School space needs two loose pages")
            return 1
        }
        model.select(page)
        settle()
        func drop(at fx: CGFloat, _ fy: CGFloat, dragging id: UUID) {
            ContentArea.tourDrop = { size, frames in
                ContentDropDelegate.compute(CGPoint(x: size.width * fx, y: size.height * fy), frames: model.currentSplit == nil ? [:] : frames,
                                            bounds: CGRect(origin: .zero, size: size), model: model, dragged: [.tab(id)])
            }
            // The stand-in isn't observed, so the page is asked to draw again.
            model.objectWillChange.send()
        }
        func endDrop() {
            ContentArea.tourDrop = nil
            model.objectWillChange.send()
        }
        drop(at: 0.3, 0.5, dragging: incoming.id)
        settle()
        check(ContentArea.tourDrop?(CGSize(width: 1000, height: 700), [:])?.side == .left, "left of the middle the tab would land on the left")
        shoot("7-page-drop-left")
        drop(at: 0.7, 0.5, dragging: incoming.id)
        settle()
        shoot("8-page-drop-right")
        drop(at: 0.5, 0.06, dragging: incoming.id)
        settle()
        shoot("9-page-drop-top")
        endDrop()

        // The space's split: its divider at rest, then a tab dragged over its right pane.
        if let sp = model.splits.first(where: { $0.spaceID == school.id }) {
            model.selectSplit(sp)
            settle()
            shoot("10-split-divider")
            drop(at: 0.85, 0.5, dragging: incoming.id)
            settle()
            shoot("11-split-drop")
            endDrop()
        } else {
            check(false, "found a split in the School space")
        }
        settle()

        print(failed == 0 ? "All drag shots rendered." : "\(failed) drag shot checks failed.")
        return failed == 0 ? 0 : 1
    }
}
