import AppKit
import SwiftUI
import WebKit

/// `--folder-shots <out> --profile <demo profile>`: the folder popup offscreen, light and dark, on
/// a throwaway copy of the demo profile: a space's folder, a folder inside it, an empty folder,
/// a linked folder, search results, and the popup over the tab bar. It checks a click on the
/// popup over the page reaches the popup, and that the keys move around the grid. The profile
/// isn't written to.
@MainActor
enum FolderShots {
    static func commandLine(_ args: [String]) -> Int32 {
        func arg(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        guard let o = arg("--folder-shots"), let p = arg("--profile") else {
            print("Usage: --folder-shots <out folder> --profile <demo profile>")
            return 2
        }
        let out = URL(fileURLWithPath: (o as NSString).expandingTildeInPath, isDirectory: true)
        let profile = URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: profile.appendingPathComponent(DemoSeeder.marker).path) else {
            print("\(profile.path) isn't a demo profile.")
            return 1
        }
        Paths.ensure(out)
        guard let h = DragShots.open(profile: profile) else { return 1 }
        defer { h.close() }
        return run(h.model, h.window, out: out)
    }

    static func run(_ model: BrowserModel, _ window: NSWindow, out: URL) -> Int32 {
        var failed = 0
        func check(_ ok: Bool, _ label: String, _ detail: String = "") {
            print("  \(ok ? "ok  " : "FAIL") \(label)\(detail.isEmpty ? "" : " (\(detail))")")
            if !ok { failed += 1 }
        }
        func settle(_ extra: Double = 0.6) {
            _ = SmokeTest.wait(15) { !model.spaceTabs.contains { $0.isLoading } }
            _ = SmokeTest.wait(extra) { false }
        }
        func shoot(_ name: String) {
            for (suffix, a) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                window.appearance = NSAppearance(named: a)
                _ = SmokeTest.wait(0.5) { false }
                let url = out.appendingPathComponent("\(name)-\(suffix).png")
                LookRenders.snapshot(window, url)
                SidebarWidthShots.drawTrafficLights(on: url, window: window)
            }
            window.appearance = nil
        }
        let popup = FolderPopup.shared
        let fm = FileManager.default

        print("Rendering the folder popup into \(out.path)")
        guard let school = model.spaces.first(where: { $0.name == "School" }), let schoolDir = model.spaceFolderURL(school) else {
            print("No School space folder in the demo profile")
            return 1
        }
        model.switchSpace(to: school.id)
        check(SpaceFolders.root.map { FileSafety.isInside($0, Paths.root) } == true, "the shots use the copy's own folders")

        // A few of the folder's pages opened once, so their cards show a real picture of the top
        // of the page. The rest show their icon and site, as pages Rain has never shown do.
        let pages = SpaceFolders.ordered(SpaceFolders.list(schoolDir), in: schoolDir).filter { $0.kind == .page }
        var opened: [Tab] = []
        for e in pages.prefix(3) {
            guard let t = model.openFolderEntry(e) else { continue }
            opened.append(t)
            _ = SmokeTest.wait(15) { t.webView?.url != nil && !(t.webView?.isLoading ?? true) }
            _ = SmokeTest.wait(Thumbnails.delay + 3) { fm.fileExists(atPath: Thumbnails.file(for: e.page!).path) }
        }
        let pictured = pages.prefix(3).filter { fm.fileExists(atPath: Thumbnails.file(for: $0.page!).path) }.count
        print("  \(pictured) of \(min(3, pages.count)) pages got a picture (needs the network)")
        for t in opened { model.close(t) }
        // A note on screen, so the page area under the popup draws in the shots.
        if let note = model.spaceTabs.first(where: { $0.isNote }) { model.select(note) }
        settle()
        LookRenders.skipWeb = true

        // The space's folder.
        popup.open(model)
        settle()
        check(popup.isOpen && popup.current?.path == schoolDir.path, "the popup opens on the current space's folder")
        check(popup.entries.first?.kind == .folder && popup.entries.contains { $0.kind == .page } && popup.entries.contains { $0.isLink },
              "it lists folders first, then pages and links", "\(popup.entries.count) things")
        shoot("1-browse")

        // A click on the popup over the page reaches the popup, and one beside it closes it.
        if let root = window.contentView {
            let size = FolderPopupLayer.panelSize(in: root.bounds.size)
            let mid = NSPoint(x: root.bounds.midX + size.width * 0.2, y: root.bounds.midY)
            let hit = root.superview?.hitTest(mid)
            let name = hit.map { String(describing: type(of: $0)) } ?? "nothing"
            var v: NSView? = hit
            var inPage = false
            while let x = v { if x is WebHostView || x is WKWebView { inPage = true }; v = x.superview }
            check(hit != nil && !inPage && !name.contains("WK"), "a click on the popup over the page goes to the popup, not the page", name)
        }

        // The keys.
        popup.selection = nil
        popup.moveSelection(124)
        check(popup.selection == popup.shown.first?.id, "an arrow key picks the first card")
        popup.moveSelection(125)
        check(popup.shown.firstIndex { $0.id == popup.selection } == min(popup.columns, popup.shown.count - 1), "down moves a row",
              "\(popup.columns) across")
        if let reading = popup.entries.first(where: { $0.name == "Reading" }) {
            popup.selection = reading.id
            popup.activate(reading)
            settle()
            check(popup.current?.lastPathComponent == "Reading" && popup.trail.count == 2 && popup.canGoBack, "a folder card goes into the folder")
            shoot("2-subfolder")
            popup.goBack()
            settle()
            check(popup.current?.path == schoolDir.path, "back comes out again")
        } else {
            check(false, "the School folder has a Reading folder")
        }

        // An empty folder.
        popup.go(popup.trail(for: schoolDir.appendingPathComponent("Ideas")), direction: 1)
        settle()
        check(popup.entries.isEmpty, "an empty folder says so")
        shoot("3-empty")

        // A linked folder: the space's notes, kept where they are.
        popup.go(popup.trail(for: schoolDir), direction: -1)
        settle()
        if let link = popup.entries.first(where: { $0.isLink && $0.kind == .folder && $0.name == "School notes" }) {
            popup.enter(link)
            settle()
            check(popup.entries.contains { $0.kind == .note } && popup.current?.path == link.target.path, "a linked folder opens on its original, with its notes")
            shoot("4-linked")
            popup.goBack()
            settle()
        } else {
            check(false, "the School folder links its notes")
        }

        // Search, in this folder and every folder inside it.
        popup.query = "wikipedia"
        _ = SmokeTest.wait(3) { popup.results != nil }
        settle()
        check((popup.results?.count ?? 0) > 3 && popup.results?.contains { $0.url.deletingLastPathComponent().lastPathComponent == "Later" } == true,
              "search finds pages in folders inside folders", "\(popup.results?.count ?? 0) found")
        shoot("5-search")
        popup.clearSearch()

        // Over the tab bar.
        BrowserPrefs.shared.update { $0.tabLayout = .horizontal }
        settle()
        shoot("6-tabbar")
        BrowserPrefs.shared.update { $0.tabLayout = .sidebar }
        settle()

        // Save mode: Cmd-Shift-S on a page picks a folder for it, like saving a download.
        let loose = model.refs(in: .today).compactMap { r -> Tab? in if case .tab(let id) = r { return model.tab(id) }; return nil }
        if let pageTab = loose.first(where: { $0.isWeb && $0.url != nil }) {
            popup.close()
            LookRenders.skipWeb = false
            model.select(pageTab)
            settle(1.5)
            LookRenders.skipWeb = true
            model.saveCurrentPage(from: "address-save")
            settle()
            check(popup.isOpen && popup.mode == .save(pageTab.id) && popup.saveName == pageTab.displayTitle,
                  "Save Page opens the popup to pick a folder, with the page's title filled in")
            if let reading = popup.entries.first(where: { $0.name == "Reading" }) { popup.enter(reading) }
            settle()
            shoot("7-save")
            popup.saveName = "Saved from the shots"
            popup.save()
            settle()
            check(!popup.isOpen && SpaceFolders.exists(schoolDir.appendingPathComponent("Reading/Saved from the shots.webloc")) && !model.savedFiles(for: pageTab).isEmpty,
                  "Save puts the page in that folder, and the page shows as saved",
                  "open \(popup.isOpen), in \(popup.current?.lastPathComponent ?? "-"), files \(((try? FileManager.default.contentsOfDirectory(atPath: schoolDir.appendingPathComponent("Reading").path)) ?? []).filter { $0.hasPrefix("Saved") }), saved \(model.savedFiles(for: pageTab).count), toast \(model.toastState?.message ?? "")")
            LookRenders.skipWeb = false
            shoot("8-saved-icon")
            LookRenders.skipWeb = true
            popup.open(model)
            settle()
        }

        // Pinned folders in the sidebar, the icon column and the tab bar.
        popup.close()
        settle()
        LookRenders.skipWeb = false
        let readingDir = schoolDir.appendingPathComponent("Reading", isDirectory: true)
        let pin = model.pinFolder(readingDir)
        for f in model.childFolders(of: nil) { model.setFolder(f.id, open: f.id == pin?.id || f.name == "Drafts") }
        settle(1)
        check(model.pinnedFolders.count >= 3 && model.pinnedFolders.allSatisfy { $0.path != nil }, "the Folders section shows pinned folders",
              model.pinnedFolders.map(\.name).joined(separator: ", "))
        check(pin.map { !model.refs(in: .folder($0.id)).isEmpty && !model.childFolders(of: $0.id).isEmpty } == true,
              "a pinned folder shows what's on disk in it, subfolders first")
        shoot("9-sidebar-pinned")
        BrowserPrefs.shared.update { $0.sidebarIconsOnly = true }
        settle()
        shoot("10-icons-pinned")
        BrowserPrefs.shared.update { $0.sidebarIconsOnly = false; $0.tabLayout = .horizontal }
        settle(1)
        shoot("11-tabbar-pinned")
        BrowserPrefs.shared.update { $0.tabLayout = .sidebar }
        settle()
        LookRenders.skipWeb = true
        popup.open(model)
        settle()

        // Esc closes it.
        if let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                      context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
            _ = popup.handleKey(esc)
        }
        settle()
        check(!popup.isOpen, "Esc closes it")
        LookRenders.skipWeb = false

        print(failed == 0 ? "Done." : "\(failed) checks failed.")
        Intelligence.shared.shutdown()
        return failed == 0 ? 0 : 1
    }
}
