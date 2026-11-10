import AppKit
import SwiftUI
import WebKit

/// `--motion-tour readme [light|dark] [scene ...]` (only with `--data-dir`, on a copy of the demo
/// profile): sets up the README's screenshots one after another in a 1440 by 900 window and writes
/// `ready <scene> <window number>` to `<data dir>/readme-tour.log` once each has settled, so a
/// script can capture that window. Every scene waits for its pages to finish loading and its
/// cards to arrive. The scenes are hero, command-bar, split, graph, ai-clients, shelf, tab-bar
/// and folders. Shelf and folders are shot in light, the rest in dark. The app quits at the end.
@MainActor
enum ReadmeTour {
    static let size = NSSize(width: 1440, height: 900)
    static let hold: Double = 2.0
    static var log: URL { Paths.root.appendingPathComponent("readme-tour.log") }

    static func note(_ s: String) {
        if let h = try? FileHandle(forWritingTo: log) { h.seekToEndOfFile(); h.write(Data((s + "\n").utf8)); try? h.close() }
    }
    static func pause(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
    static func until(_ timeout: Double, _ ok: () -> Bool) async -> Bool {
        var t = 0.0
        while !ok() && t < timeout { await pause(0.2); t += 0.2 }
        return ok()
    }

    static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.frameAutosaveName == "BrowserPOCMain" } ?? NSApp.windows.first { $0.isVisible }
    }

    /// The window at 1440 by 900 in the middle of its screen. A window macOS restored tiled comes
    /// back at the tile's size after the first try, so this runs again once the app has settled.
    static func fitWindow(_ label: String) {
        // The window runs on a screen someone is using, so it may have been hidden or minimized
        // since the last scene. It comes back before anything is set up.
        if let w = NSApp.windows.first(where: { $0.frameAutosaveName == "BrowserPOCMain" }), !w.isVisible || NSApp.isHidden {
            note("\(label) window was \(NSApp.isHidden ? "hidden" : w.isMiniaturized ? "minimized" : "off screen"), bringing it back")
            if NSApp.isHidden { NSApp.unhide(nil) }
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.orderFrontRegardless()
        }
        guard let w = mainWindow else { note("\(label) no window"); return }
        let vis = (w.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let want = NSRect(x: vis.midX - size.width / 2, y: vis.midY - size.height / 2, width: size.width, height: size.height)
        if w.frame != want { w.setFrame(want, display: true) }
        note("\(label) window \(Int(w.frame.width))x\(Int(w.frame.height)) on a \(Int(vis.width))x\(Int(vis.height)) screen")
    }

    /// No red spelling underlines in a screenshot: they mark made-up names like Swapshelf.
    static func quietSpelling(_ v: NSView?) {
        guard let v else { return }
        if let tv = v as? NSTextView, tv.isContinuousSpellCheckingEnabled {
            tv.isContinuousSpellCheckingEnabled = false
            tv.needsDisplay = true
        }
        for sub in v.subviews { quietSpelling(sub) }
    }

    static func ready(_ name: String, window: NSWindow? = nil) async {
        if window == nil, mainWindow?.frame.size != size {
            fitWindow(name)
            await pause(1.0)
        }
        let w = window ?? mainWindow
        quietSpelling(w?.contentView)
        await pause(0.4)
        if let w, w.frame.contains(NSEvent.mouseLocation) { note("\(name): the pointer is over the window") }
        note("ready \(name) \(w?.windowNumber ?? 0)")
        await pause(hold)
    }

    /// WebKit stops painting a page whose window isn't visible, and a page that draws itself with
    /// script stays blank while it thinks it's hidden, for example while the screen is locked. So
    /// every page keeps drawing, and WebKit's own check for a covered window is off for the tour.
    static func keepPainting(_ model: BrowserModel) {
        for wv in model.tabs.compactMap(\.webView) + [model.peek?.tab.webView].compactMap({ $0 }) {
            wv.configuration.preferences.inactiveSchedulingPolicy = .none
            ignoreOcclusion(wv)
        }
    }

    /// WebKit's `_setWindowOcclusionDetectionEnabled:`, called only when it's there.
    static func ignoreOcclusion(_ wv: WKWebView) {
        let sel = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard let m = class_getInstanceMethod(type(of: wv), sel) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(m), to: Setter.self)(wv, sel, false)
    }

    /// True once every page on screen has finished loading and has its site icon.
    static func pagesSettled(_ model: BrowserModel) -> Bool {
        model.visibleTabs.allSatisfy { t in
            guard t.kind == .web else { return true }
            guard let wv = t.webView else { return false }
            return !wv.isLoading && wv.estimatedProgress >= 1 && Favicons.shared.image(for: t.url) != nil
        }
    }

    /// Notes each visible page's state, for finding a pane that didn't draw.
    static func describePages(_ model: BrowserModel, _ label: String) async {
        note("\(label) window visible \(mainWindow?.occlusionState.contains(.visible) ?? false)")
        for t in model.visibleTabs where t.kind == .web {
            guard let wv = t.webView else { note("\(label) page \(t.displayTitle): no web view"); continue }
            let text = (try? await wv.evaluateJavaScript("document.body ? document.body.innerText.length : -1")) as? Int ?? -2
            let bg = (try? await wv.evaluateJavaScript("getComputedStyle(document.body).backgroundColor + ' ' + document.visibilityState + ' ' + getComputedStyle(document.body).opacity + ' ' + (document.querySelector('h1') ? getComputedStyle(document.querySelector('h1')).opacity : 'no h1')")) as? String ?? "?"
            note("\(label) page \(t.displayTitle.prefix(30)): url \(wv.url?.host ?? "nil") loading \(wv.isLoading) progress \(wv.estimatedProgress) frame \(Int(wv.frame.width))x\(Int(wv.frame.height)) window \(wv.window != nil) hidden \(wv.isHiddenOrHasHiddenAncestor) text \(text) bg \(bg)")
        }
    }

    static func waitForPages(_ model: BrowserModel, _ label: String) async {
        keepPainting(model)
        if !(await until(40, { keepPainting(model); return pagesSettled(model) })) { note("pages still loading in \(label)") }
        // Give the page a moment to lay out and paint after it says it's done.
        await pause(1.5)
        await describePages(model, label)
    }

    static func card(_ model: BrowserModel, titled words: String) -> Card? {
        model.resurfacer.cards.first { $0.match.doc.title.localizedCaseInsensitiveContains(words) }
    }

    /// The words after `prefix:` on the command line, like `card:Nadia`.
    static func pick(_ prefix: String) -> String? {
        CommandLine.arguments.first { $0.hasPrefix(prefix + ":") }.map { String($0.dropFirst(prefix.count + 1)) }
    }

    /// Waits for Related to settle on its cards, notes them with their reasons, and returns the
    /// one matching any of `words`, or the first card if none does.
    static func settledCard(_ model: BrowserModel, _ words: [String], label: String) async -> Card? {
        _ = await until(60) { !model.resurfacer.isWorking && !model.resurfacer.cards.isEmpty }
        for _ in 0..<20 {
            if words.contains(where: { card(model, titled: $0) != nil }) { break }
            await pause(1.0)
        }
        for c in model.resurfacer.cards { note("\(label) card: \(c.match.doc.title) | \(c.match.doc.project ?? "") | \(c.reason)") }
        return words.lazy.compactMap { card(model, titled: $0) }.first ?? model.resurfacer.cards.first
    }

    static func start(_ model: BrowserModel) {
        let args = CommandLine.arguments
        NSApp.appearance = NSAppearance(named: args.contains("light") ? .aqua : .darkAqua)
        try? "".write(to: log, atomically: true, encoding: .utf8)
        BrowserModel.pasteboard = NSPasteboard(name: NSPasteboard.Name("local.browserpoc.readme-tour"))
        // The AI clients tab shows the steps a normal install in /Applications would show, not
        // this build folder's paths.
        MCPInstall.screenshotInstall = true
        BrowserModel.keepPaintingWhenHidden = true
        // The tab bar comes before folders, which saves three more pages into Paper sources.
        let all = ["hero", "command-bar", "split", "graph", "ai-clients", "shelf", "tab-bar", "folders", "queries"]
        let asked = all.filter { args.contains($0) }
        let scenes = asked.isEmpty ? all.filter { $0 != "queries" } : asked

        Task { @MainActor in
            await pause(0.5)
            fitWindow("launch")
            if let w = mainWindow {
                w.level = .floating
                // Clicks from whoever is using the screen go to the windows behind it.
                w.ignoresMouseEvents = true
                w.orderFrontRegardless()
                NSApp.activate()
            }
            // The launch animation, and the models settling in.
            await pause(2.5)
            _ = await until(60) { ModelStore.shared.overallProgress == nil }
            fitWindow("start")
            for s in scenes {
                switch s {
                case "hero": await hero(model)
                case "command-bar": await bar(model)
                case "split": await split(model)
                case "graph": await graph(model)
                case "ai-clients": await aiClients(model)
                case "queries": await queries(model)
                case "shelf": await shelf(model)
                case "folders": await folders(model)
                case "tab-bar": await tabBar(model)
                default: break
                }
            }
            note("done")
            await pause(0.3)
            NSApp.terminate(nil)
        }
    }

    // MARK: Scenes

    /// The demo's opening moment: School, the chicken-or-egg article beside the paper draft, and
    /// the shelf's card for the Nadia coffee chat open.
    static func hero(_ model: BrowserModel) async {
        if let school = model.spaces.firstIndex(where: { $0.name == "School" }) { model.switchSpace(index: school) }
        await waitForPages(model, "hero")
        guard let c = await settledCard(model, [pick("card") ?? "Nadia"], label: "hero") else { note("no cards"); return }
        note("hero opens \(c.match.doc.title)")
        // In a narrow pane the card can sit past the end of the row, so bring its pill into view.
        ShelfState.shared.reveal(.card(c.id))
        await pause(1.2)
        ShelfState.shared.enter(.card(c.id))
        await pause(1.2)
        await ready("hero")
        ShelfState.shared.closeNow()
        await pause(0.6)
    }

    /// Cmd-T over the page with a few letters typed: an open tab, notes and history, with icons.
    static func bar(_ model: BrowserModel) async {
        ShelfState.shared.closeNow()
        model.bar.open(.newTab)
        await pause(0.4)
        model.bar.query = ""
        let typed = pick("query") ?? "network"
        for ch in typed { model.bar.lastEditWasInsertion = false; model.bar.query.append(ch); await pause(0.08) }
        _ = await until(10) { model.bar.results.count >= 5 }
        await pause(1.2)
        // The caret after the letters, as if they'd just been typed.
        if let tv = (mainWindow?.firstResponder as? NSTextView) ?? (mainWindow?.fieldEditor(false, for: nil) as? NSTextView) {
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        }
        for r in model.bar.results { note("bar: \(r.group.rawValue) | \(r.title) | \(r.url?.host ?? "")") }
        await pause(0.8)
        await ready("command-bar")
        model.bar.close()
        await pause(0.6)
    }

    /// Three panes in School with the paper draft on the right, and the Paper sources folder open.
    static func split(_ model: BrowserModel) async {
        if let school = model.spaces.firstIndex(where: { $0.name == "School" }) { model.switchSpace(index: school) }
        for i in model.folders.indices where model.folders[i].spaceID == model.currentSpaceID && model.folders[i].name == "Paper sources" {
            model.folders[i].isExpanded = true
        }
        let draft = model.tabs.first { $0.displayTitle.hasPrefix("Paper draft - section 2") }
        let facebook = model.tabs.first { $0.displayTitle.localizedCaseInsensitiveContains("History of Facebook") }
        if let sp = model.currentSplit, sp.items.count == 2, let draft, let facebook, !sp.items.contains(facebook.id) {
            _ = model.openInSplit(facebook, side: .left, of: draft.id)
        }
        await pause(1.0)
        if let sp = model.currentSplit { model.evenOut(sp) }
        if let draft { model.focusPane(item: draft.id) }
        await waitForPages(model, "split")
        await ready("split")
    }

    /// The global graph, settled and fit, hovering the Nadia coffee chat, which bridges spaces.
    static func graph(_ model: BrowserModel) async {
        ShelfState.shared.closeNow()
        _ = model.openGraph()
        let g = GraphController.global
        guard await until(30, { g.hasLoaded && g.liveCount > 20 && !g.isBuilding }) else { note("no graph"); return }
        await pause(8.0)
        g.fit()
        await pause(2.0)
        // A node whose neighbours sit in more than one space: the one named with node:, else the
        // Nadia coffee chat if it bridges, else Paul Graham's essay, else the best-connected bridge
        // that isn't the weekly plan hub.
        let L = g.layout
        func spaces(_ i: Int) -> Int { Set(([i] + Array(L.neighbours(i))).compactMap { L.nodes[$0].space }).count }
        func named(_ w: String) -> Int? { L.nodes.indices.first { L.nodes[$0].title.localizedCaseInsensitiveContains(w) && spaces($0) >= 2 } }
        let bridges = L.nodes.indices.filter { spaces($0) >= 2 && !L.nodes[$0].title.hasPrefix("Weekly plan") }
        for i in bridges.sorted(by: { L.nodes[$0].degree > L.nodes[$1].degree }).prefix(8) {
            note("graph bridge: \(L.nodes[i].title) spaces \(spaces(i)) degree \(L.nodes[i].degree)")
        }
        let target = pick("node").flatMap(named) ?? named("Nadia") ?? named("Don't Scale") ?? named("Don’t Scale")
            ?? bridges.max(by: { L.nodes[$0].degree < L.nodes[$1].degree })
        if let i = target {
            note("graph hovers \(L.nodes[i].title)")
            let p = g.sim.positions()
            if i < p.count { g.pointerMoved(g.screen(p[i])) }
        } else {
            note("no bridge node")
        }
        await pause(1.2)
        await ready("graph")
        g.pointerExited()
        await pause(0.4)
    }

    /// Logs the bar's results for a few queries, to pick one for the screenshot.
    static func queries(_ model: BrowserModel) async {
        for q in ["chicken", "facebook", "cold start", "marketplace", "network eff", "andrew", "two-sided", "campus"] {
            model.bar.open(.newTab)
            await pause(0.3)
            model.bar.query = q
            _ = await until(6) { !model.bar.results.isEmpty }
            await pause(1.2)
            note("query \(q): " + model.bar.results.prefix(9).map { "\($0.group.rawValue):\($0.title.prefix(40))" }.joined(separator: " | "))
            model.bar.close()
            await pause(0.4)
        }
    }

    /// Settings, on the AI clients tab.
    static func aiClients(_ model: BrowserModel) async {
        SettingsView.initialTab = .aiClients
        AppDelegate.shared?.openSettings()
        await pause(0.6)
        let w = NSApp.windows.first { $0.isVisible && $0.title == "Settings" }
        w?.level = .floating
        w?.orderFrontRegardless()
        await pause(1.6)
        await ready("ai-clients", window: w)
        w?.close()
        await pause(0.4)
    }

    /// The shelf's card open in light mode, over the Swapshelf pilot plan, on Paul Graham's essay.
    static func shelf(_ model: BrowserModel) async {
        if let i = model.spaces.firstIndex(where: { $0.name == "Swapshelf" }) { model.switchSpace(index: i) }
        await waitForPages(model, "shelf")
        let words = pick("card").map { [$0] } ?? ["Don't Scale", "Don’t Scale"]
        guard let c = await settledCard(model, words, label: "shelf") else { note("no cards"); return }
        note("shelf opens \(c.match.doc.title)")
        await pause(1.0)
        ShelfState.shared.enter(.card(c.id))
        await pause(1.2)
        await ready("shelf")
        ShelfState.shared.closeNow()
        await pause(0.4)
    }

    /// Cookie and fundraising banners a reader would have dismissed long ago. The tour's WebKit
    /// store is thrown away each run, so every site asks again. With `inPlace` a banner in the
    /// page is only hidden, so nothing below it moves.
    static func quietBanners(inPlace: Bool) -> String {
        let gone = inPlace ? "e.style.visibility = 'hidden'" : "e.remove()"
        return """
        document.querySelectorAll('#siteNotice, #centralNotice, [id^="frb"], [class^="frb"]').forEach(e => \(gone));
        for (const e of Array.from(document.querySelectorAll('body *'))) {
          const s = getComputedStyle(e), t = e.innerText || '';
          if (!/cookie|consent/i.test(t) || t.length > 4000) continue;
          if (s.position === 'fixed') e.style.display = 'none';
          else if (s.position === 'sticky') \(gone);
        }
        true
        """
    }

    /// Shows a saved page until it has loaded, takes its banners down and takes its picture again,
    /// so the folder popup's card shows the top of the page as a reader sees it.
    static func picture(_ t: Tab, _ page: URL, inPlace: Bool = false) async -> Bool {
        if let m = t.model { keepPainting(m) }
        _ = await until(30) { t.webView.map { !$0.isLoading && $0.estimatedProgress >= 1 } ?? false }
        // Banners arrive a moment after the page.
        await pause(2.5)
        _ = try? await t.webView?.evaluateJavaScript(quietBanners(inPlace: inPlace))
        await pause(0.4)
        let ok = await withCheckedContinuation { c in Thumbnails.shared.capture(t) { c.resume(returning: $0) } }
        // The picture is written in the background.
        await pause(0.6)
        return ok && Thumbnails.exists(for: page)
    }

    /// Waits a while for the pointer to be off the window. Hover still follows the pointer while
    /// the window ignores clicks, so a card or row under it would show lifted.
    static func pointerAway(_ label: String) async {
        guard let w = mainWindow else { return }
        if !(await until(30) { !w.frame.contains(NSEvent.mouseLocation) }) { note("\(label) the pointer stayed over the window") }
    }

    /// True if the pointer stays off the window for `seconds`.
    static func pointerStaysAway(_ seconds: Double) async -> Bool {
        guard let w = mainWindow else { return true }
        var t = 0.0
        while t < seconds {
            if w.frame.contains(NSEvent.mouseLocation) { return false }
            await pause(0.1)
            t += 0.1
        }
        return true
    }

    static func school(_ model: BrowserModel) {
        if let school = model.spaces.firstIndex(where: { $0.name == "School" }) { model.switchSpace(index: school) }
    }

    /// School's paper draft split, selected with the draft focused, the way the demo opens.
    static func selectDraftSplit(_ model: BrowserModel) {
        guard let draft = model.tabs.first(where: { $0.displayTitle.hasPrefix("Paper draft - section 2") }),
              let sp = model.splits.first(where: { $0.contains(draft.id) }) else { note("no paper draft split"); return }
        model.selectSplit(sp, focusItem: draft.id)
    }

    /// Run in light. The folder popup over a page in School, open on Paper sources: saved pages,
    /// each with a picture of the top of its page, and two linked notes. The sidebar's Folders
    /// section lists the pinned folders, all closed. Three of School's open tabs are saved into
    /// the folder first, the way Save Page does it, so the grid fills its rows, and every page in
    /// it is shown once so its card gets a fresh picture without cookie or donation banners. The
    /// shelf steps aside while the popup is up, so its cards don't peek out under it.
    static func folders(_ model: BrowserModel) async {
        fitWindow("folders")
        ShelfState.shared.closeNow()
        TabLayoutSwitch.set(.sidebar)
        school(model)
        guard let sp = model.currentSpace, let root = model.spaceFolderURL(sp) else { note("folders: no space folder"); return }
        let dir = root.appendingPathComponent("Paper sources", isDirectory: true)
        let had = Set(SpaceFolders.list(dir).compactMap { $0.page.map(URLKey.key(for:)) })
        for words in ["History of Facebook", "Critical mass", "kickstart"] {
            guard let t = model.spaceTabs.first(where: { $0.isWeb && $0.folderID == nil && $0.displayTitle.localizedCaseInsensitiveContains(words) }),
                  let u = t.url, !had.contains(URLKey.key(for: u)) else { continue }
            model.savePage(t, in: dir, quiet: true)
        }
        let entries = SpaceFolders.ordered(SpaceFolders.list(dir), in: dir)
        note("folders \(dir.lastPathComponent): " + entries.map { "\($0.kind.rawValue):\($0.name)" }.joined(separator: " | "))
        // Every page is shown once, so its card has a fresh picture of the top of the page. The
        // page that goes under the popup comes last, with its banners hidden in place, so its
        // title stays behind the popup.
        let under = entries.first { $0.kind == .page && $0.name.hasPrefix("Two-sided market") }
        for e in entries where e.kind == .page && e.id != under?.id {
            guard let page = e.page, let t = model.openFolderEntry(e) else { continue }
            note("folders picture \(await picture(t, page)) \(e.name)")
        }
        let open = model.pinnedFolders.map { ($0.id, $0.isExpanded) }
        for f in model.pinnedFolders { model.setFolder(f.id, open: false) }
        let hadShelf = !RelatedPrefs.shared.value.shelfHidden
        RelatedPrefs.shared.update { $0.shelfHidden = true }
        if let e = under, let page = e.page, let t = model.openFolderEntry(e) {
            note("folders picture \(await picture(t, page, inPlace: true)) \(e.name)")
        }
        await waitForPages(model, "folders")
        // A card under the pointer lifts, so the popup opens again until the pointer has stayed
        // off the window.
        for attempt in 1...5 {
            await pointerAway("folders")
            FolderPopup.shared.open(model, at: dir)
            if await pointerStaysAway(2.0) || attempt == 5 { break }
            note("folders: the pointer crossed the window, opening the popup again")
            FolderPopup.shared.close()
            await pause(0.8)
        }
        await ready("folders")
        FolderPopup.shared.close()
        await pause(0.8)
        if hadShelf { RelatedPrefs.shared.update { $0.shelfHidden = false } }
        for (id, was) in open { model.setFolder(id, open: was) }
        selectDraftSplit(model)
        await pause(0.4)
    }

    /// Run in dark. The tab bar along the top in School: Essentials, the pinned tabs, the pinned
    /// folders as chips, School's tabs, and the paper draft split below. Every folder is closed,
    /// so the tabs have room for their names. The sidebar comes back after.
    static func tabBar(_ model: BrowserModel) async {
        fitWindow("tab-bar")
        ShelfState.shared.closeNow()
        FolderPopup.shared.close()
        school(model)
        let open = model.pinnedFolders.map { ($0.id, $0.isExpanded) }
        TabLayoutSwitch.set(.horizontal)
        for f in model.pinnedFolders { model.setFolder(f.id, open: false) }
        selectDraftSplit(model)
        await waitForPages(model, "tab-bar")
        // A tab under the pointer shows hovered, so the bar is drawn again until the pointer has
        // stayed off the window.
        for attempt in 1...5 {
            await pointerAway("tab-bar")
            TabLayoutSwitch.set(.sidebar)
            await pause(0.6)
            TabLayoutSwitch.set(.horizontal)
            if await pointerStaysAway(2.0) || attempt == 5 { break }
            note("tab-bar: the pointer crossed the window, drawing the bar again")
        }
        await ready("tab-bar")
        TabLayoutSwitch.set(.sidebar)
        for (id, was) in open { model.setFolder(id, open: was) }
        await pause(0.6)
    }
}
