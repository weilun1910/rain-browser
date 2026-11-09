import AppKit
import SwiftUI
import WebKit

/// `--sidebar-shots <out> --profile <demo profile>`: the sidebar at its default, narrowest and a
/// wide width, then icons only on the left, on the right and floating in compact mode, rendered
/// offscreen from a copy of the demo profile. The profile isn't written to. Snapshots of the
/// content view leave out the window's own buttons, so grey dots are drawn where the traffic
/// lights sit, to check nothing runs under them.
@MainActor
enum SidebarWidthShots {
    static func commandLine(_ args: [String]) -> Int32 {
        func arg(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        guard let o = arg("--sidebar-shots"), let p = arg("--profile") else {
            print("Usage: --sidebar-shots <out folder> --profile <demo profile>")
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
        let tmp = fm.temporaryDirectory.appendingPathComponent("BrowserPOC-sidebar-shots-\(UUID().uuidString)", isDirectory: true)
        Paths.ensure(tmp)
        Paths.ensure(out)
        defer { try? fm.removeItem(at: tmp) }
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
        // Related's shelf would cover the bottom of the page. These shots are about the sidebar.
        RelatedPrefs.shared.update { $0.shelfHidden = true }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        guard let store = try? IndexStore(url: tmp.appendingPathComponent("index.sqlite")) else { print("Couldn't open the index copy"); return 1 }
        IndexStore.shared = store
        BrowserModel.useEphemeralStore = true
        SpaceTintBackground.forceActive = true
        Motion.forceReduce = true
        HoverCards.shared.recorded = [:]
        // Offscreen there's no display link, so a space switch's fade and a reveal's slide never
        // finish. With motion held, every change lands at once.
        MotionSuppression.set(.launch, true)
        SidebarResize.headless = true
        let model = BrowserModel()
        model.notes.reload()
        let size = NSSize(width: 1280, height: 820)
        let window = SmokeTest.offscreenWindow(MainView.host(model), size: size)
        WindowChrome.configure(window)
        let resize = SidebarResize.shared
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
                drawTrafficLights(on: url, window: window)
            }
            window.appearance = nil
        }

        print("Rendering the sidebar into \(out.path)")
        // A space with Essentials, pins, an open folder and a split shows the most.
        if let sp = model.spaces.first(where: { $0.name == "School" }) { model.switchSpace(to: sp.id) }
        for f in model.folders(in: model.currentSpaceID) { model.setFolder(f.id, open: true) }
        settle()

        BrowserPrefs.shared.update { $0.sidebarIconsOnly = false; $0.sidebarWidth = Double(Theme.Space.sidebarWidth) }
        shoot("1-default")
        edgeDrag(window, check)

        // Drag the edge the way a pointer would, and check where it lands.
        resize.drag(by: -100)
        check(resize.current == .init(iconsOnly: false, width: SidebarWidth.min), "dragging in stops at the narrowest width with titles",
              "\(resize.current.width)")
        resize.drag(by: -(Theme.Space.sidebarWidth - SidebarWidth.snap) - 1)
        check(resize.current.iconsOnly, "dragging in past the snap point snaps to icons")
        resize.endDrag()
        check(BrowserPrefs.shared.value.sidebarIconsOnly && BrowserPrefs.shared.value.sidebarWidth == Double(Theme.Space.sidebarWidth),
              "letting go on icons saves icons and keeps the width with titles")
        resize.drag(by: 30)
        check(resize.current.iconsOnly, "a short drag out stays on icons")
        resize.drag(by: 300)
        check(resize.current == .init(iconsOnly: false, width: SidebarWidth.icons + 300), "dragging out brings titles back at the pointer",
              "\(resize.current.width)")
        resize.drag(by: 900)
        check(resize.current.width == SidebarWidth.max, "dragging out stops at the widest width")
        resize.endDrag()
        check(!BrowserPrefs.shared.value.sidebarIconsOnly && BrowserPrefs.shared.value.sidebarWidth == Double(SidebarWidth.max),
              "letting go saves the new width")

        BrowserPrefs.shared.update { $0.sidebarWidth = Double(SidebarWidth.min) }
        settle()
        shoot("2-narrowest")
        BrowserPrefs.shared.update { $0.sidebarWidth = 360 }
        settle()
        shoot("3-wide")

        // Right-click on the sidebar's empty space offers the three ways to show tabs, and a tab
        // keeps its own menu. An empty space has room to click.
        let home = model.currentSpaceID
        let empty = model.createSpace(name: "Menu check")
        model.switchSpace(to: empty.id)
        settle()
        let midY = window.contentView!.bounds.height / 2
        menuCheck(window, label: "the sidebar's empty space", at: NSPoint(x: 120, y: midY), wantsModes: true, check)
        resize.setIconsOnly(true)
        settle()
        menuCheck(window, label: "the icon column's empty space", at: NSPoint(x: 28, y: midY), wantsModes: true, check)
        resize.setIconsOnly(false)
        model.switchSpace(to: home)
        model.deleteSpace(empty.id)
        settle()

        resize.setIconsOnly(true)
        settle()
        shoot("4-icons")
        if let root = window.contentView {
            // The traffic lights sit in the toolbar, above the column, and the page starts below it.
            let close = window.standardWindowButton(.closeButton).map { $0.convert($0.bounds, to: nil) } ?? .zero
            let lightsBottom = root.bounds.height - close.minY
            check(lightsBottom < Theme.Space.titleBarHeight, "with icons only the traffic lights sit in the toolbar row",
                  "bottom \(Int(lightsBottom)) of \(Int(Theme.Space.titleBarHeight))")
            let field = root.superview?.hitTest(NSPoint(x: root.bounds.width / 2, y: root.bounds.height - Theme.Space.titleBarHeight / 2))
            check(field != nil && !(field is WKWebView), "the toolbar across the top answers clicks", field.map { String(describing: type(of: $0)) } ?? "nothing")
        }
        if let chip = firstChip(window) {
            let (_, titles) = menuTitles(window, at: chip)
            check(titles.contains("Close") && TabMode.allCases.allSatisfy { titles.contains($0.title) },
                  "a right-click on a tab in the icon column keeps the tab's menu and adds the three tab modes",
                  titles.filter { !$0.isEmpty }.joined(separator: ", "))
        } else {
            check(false, "found a tab in the icon column to right-click", "")
        }
        // The card a pinned tab in the column shows when the pointer rests on it.
        if let pin = model.refs(in: .pinned).first, case .tab(let id) = pin {
            LookRenders.skipWeb = true
            showCard(for: id, side: .trailing, label: "a tab in the icon column shows its name in a card beside it", outside: false, check)
            shoot("12-icons-hover-card")
            LookRenders.skipWeb = false
        }
        HoverCards.shared.hide()
        // The other spaces, for what each one's column looks like.
        for name in ["Swapshelf", "Job hunt"] {
            if let sp = model.spaces.first(where: { $0.name == name }) {
                model.switchSpace(to: sp.id)
                settle()
                shoot("5-icons-\(name.lowercased().replacingOccurrences(of: " ", with: "-"))")
            }
        }
        if let sp = model.spaces.first(where: { $0.name == "School" }) { model.switchSpace(to: sp.id) }

        BrowserPrefs.shared.update { $0.sidebarOnRight = true }
        settle()
        shoot("6-icons-right")
        BrowserPrefs.shared.update { $0.sidebarOnRight = false; $0.sidebarHidden = true }
        settle()
        // Offscreen, the floating sidebar hears the pointer leave as soon as it appears, which
        // would slide it away mid-shot. Hold it up for the picture.
        CompactReveal.holdForShots = true
        CompactReveal.shared.show()
        _ = SmokeTest.wait(0.5) { false }
        check(CompactReveal.shared.showing, "compact mode's floating sidebar shows on reveal")
        // Page pictures are pasted over the snapshot, so leave them out where something floats.
        LookRenders.skipWeb = true
        shoot("7-compact-revealed")
        CompactReveal.holdForShots = false
        CompactReveal.shared.reset()
        BrowserPrefs.shared.update { $0.sidebarHidden = false }

        // Essentials: three in the column, and the box grown into a grid of all of them.
        if let space = model.currentSpace {
            let extra = model.tabs.filter { $0.spaceID == space.id && $0.isWeb && !$0.isEssential && !$0.isPinned }.prefix(4)
            for t in extra { model.addToEssentials(t) }
        }
        settle()
        check(model.essentials.count > IconEssentials.shown, "the demo has more Essentials than the column shows", "\(model.essentials.count)")
        shoot("9-icons-essentials-closed")
        LookRenders.skipWeb = true
        EssentialsBloom.shared.forced = true
        settle()
        shoot("10-icons-essentials-open")
        // A hidden Essential's card sits past the grown box, so it never covers the next column.
        if let hidden = model.essentials.last {
            showCard(for: hidden.id, side: .trailing, label: "an Essential in the grown box shows its card past the box's edge", outside: true, check)
            shoot("13-icons-essentials-hover-card")
            HoverCards.shared.hide()
        }
        if let root = window.contentView {
            // A point in the grown box's second column, out past the column over the page.
            let p = NSPoint(x: SidebarWidth.icons + 14, y: root.bounds.height - 140)
            let hit = root.superview?.hitTest(p) // window coordinates, as AppKit routes a real click
            let name = hit.map { String(describing: type(of: $0)) } ?? "nothing"
            check(!(name.contains("WK") || name.contains("WebHost")), "a click on the grown box over the page goes to the box, not the page", name)
        }
        BrowserPrefs.shared.update { $0.sidebarOnRight = true }
        settle()
        shoot("11-icons-essentials-open-right")
        BrowserPrefs.shared.update { $0.sidebarOnRight = false }
        EssentialsBloom.shared.forced = false
        LookRenders.skipWeb = false

        // The command bar grows out of the address field in the toolbar.
        model.focusAddress()
        _ = SmokeTest.wait(0.6) { false }
        shoot("8-icons-command-bar")
        model.bar.close()
        LookRenders.skipWeb = false

        print(failed == 0 ? "Done." : "\(failed) checks failed.")
        Intelligence.shared.shutdown()
        return failed == 0 ? 0 : 1
    }

    /// The menu a right-click at `p` (window coordinates) would show, asked of the view AppKit
    /// hits there and its ancestors, without opening it.
    static func menuTitles(_ window: NSWindow, at p: NSPoint) -> (hit: String, titles: [String]) {
        guard let root = window.contentView, let hit = root.superview?.hitTest(p),
              let e = NSEvent.mouseEvent(with: .rightMouseDown, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return ("nothing", []) }
        var v: NSView? = hit
        while let x = v {
            if let m = x.menu(for: e) { return (String(describing: type(of: hit)), m.items.map(\.title)) }
            v = x.superview
        }
        return (String(describing: type(of: hit)), [])
    }

    static func menuCheck(_ window: NSWindow, label: String, at p: NSPoint, wantsModes: Bool, _ check: (Bool, String, String) -> Void) {
        let (hit, titles) = menuTitles(window, at: p)
        let modes = TabMode.allCases.allSatisfy { m in titles.contains(m.title) }
        check(modes == wantsModes, "a right-click on \(label) \(wantsModes ? "offers" : "doesn't offer") the three tab modes",
              "hit \(hit): \(titles.filter { !$0.isEmpty }.joined(separator: ", "))")
    }

    /// A point on a tab in the icon column, found by walking down the column until a right-click
    /// there would show a tab's menu.
    static func firstChip(_ window: NSWindow) -> NSPoint? {
        guard let h = window.contentView?.bounds.height else { return nil }
        for fromTop in stride(from: 260.0, to: h - 200, by: 8) {
            let p = NSPoint(x: 28, y: h - fromTop)
            if menuTitles(window, at: p).titles.contains("Close") { return p }
        }
        return nil
    }

    /// The card a tab's icon would show, shown as if the pointer rested there. An offscreen window
    /// gets no pointer, so this reads the card the icon recorded rather than hovering it.
    static func showCard(for id: UUID, side: Edge, label: String, outside: Bool, _ check: (Bool, String, String) -> Void) {
        let cards = HoverCards.shared
        cards.hide()
        guard let i = cards.recorded?[AnyHashable(id)] else {
            check(false, label, "the icon recorded no card")
            return
        }
        cards.enter(i)
        _ = SmokeTest.wait(1) { cards.item != nil }
        let beside = side == .trailing ? i.bounds.maxX <= i.frame.maxX + 0.5 || outside : true
        check(cards.item?.id == i.id && i.side == side && !i.title.isEmpty && beside
              && (outside ? i.bounds.width > i.frame.width : true),
              label, "\(i.title), \(i.detail ?? "no detail"), icon at \(Int(i.frame.minX)),\(Int(i.frame.minY)), card past x \(Int(i.bounds.maxX))")
    }

    /// Real mouse events on the sidebar's edge, at the top, middle and bottom of the window: what
    /// AppKit hits there, and whether a press and drag moves the edge.
    static func edgeDrag(_ window: NSWindow, _ check: (Bool, String, String) -> Void) {
        guard let root = window.contentView else { return }
        let h = root.bounds.height
        for (label, fromTop) in [("near the top", 120.0), ("over the tab list", h / 2), ("near the bottom", h - 70)] {
            BrowserPrefs.shared.update { $0.sidebarIconsOnly = false; $0.sidebarWidth = Double(Theme.Space.sidebarWidth) }
            _ = SmokeTest.wait(0.3) { false }
            let x = Theme.Space.sidebarWidth - 3
            let p = NSPoint(x: x, y: h - fromTop)
            let hit = root.superview?.hitTest(p) // window coordinates, as AppKit routes a real click
            // An offscreen window doesn't route mouse events, so they go straight to the view the
            // hit test found, which is where AppKit sends a press on screen.
            func send(_ type: NSEvent.EventType, _ at: NSPoint) {
                guard let v = hit, let e = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
                switch type {
                case .leftMouseDown: v.mouseDown(with: e)
                case .leftMouseDragged: v.mouseDragged(with: e)
                default: v.mouseUp(with: e)
                }
                _ = SmokeTest.wait(0.05) { false }
            }
            send(.leftMouseDown, p)
            for step in 1...6 { send(.leftMouseDragged, NSPoint(x: p.x + CGFloat(step) * 10, y: p.y)) }
            send(.leftMouseUp, NSPoint(x: p.x + 60, y: p.y))
            _ = SmokeTest.wait(0.2) { false }
            let w = BrowserPrefs.shared.value.sidebarWidth
            check(hit is SidebarEdgeView, "a press on the edge \(label) lands on the edge", hit.map { String(describing: type(of: $0)) } ?? "nothing")
            check(abs(w - Double(Theme.Space.sidebarWidth + 60)) < 2, "a press and drag on the edge \(label) moves it",
                  "width \(Int(w)), hit \(hit.map { String(describing: type(of: $0)) } ?? "nothing")")
        }
        BrowserPrefs.shared.update { $0.sidebarIconsOnly = false; $0.sidebarWidth = Double(Theme.Space.sidebarWidth) }
    }

    /// Grey dots where the traffic lights are, the way the quiet dots look at rest.
    static func drawTrafficLights(on url: URL, window: NSWindow) {
        guard let close = window.standardWindowButton(.closeButton), let data = try? Data(contentsOf: url),
              let image = NSImage(data: data), let source = NSBitmapImageRep(data: data),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: source.pixelsWide, pixelsHigh: source.pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        let width = max(window.contentView?.bounds.width ?? 1, 1)
        let scale = CGFloat(source.pixelsWide) / width
        let pts = NSSize(width: CGFloat(source.pixelsWide) / scale, height: CGFloat(source.pixelsHigh) / scale)
        // The size has to be set before the context is made, or drawing stays at one pixel a point.
        rep.size = pts
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        let first = close.convert(close.bounds, to: nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        image.draw(in: NSRect(origin: .zero, size: pts))
        let dark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSColor(white: dark ? 1 : 0, alpha: dark ? 0.24 : 0.18).setFill()
        // The buttons' centres, measured from the window's top, as AppKit lays them out.
        let cy = pts.height - (window.frame.height - first.midY)
        for i in 0..<3 {
            let cx = first.midX + CGFloat(i) * 23
            NSBezierPath(ovalIn: NSRect(x: cx - 6, y: cy - 6, width: 12, height: 12)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: url) }
    }
}
