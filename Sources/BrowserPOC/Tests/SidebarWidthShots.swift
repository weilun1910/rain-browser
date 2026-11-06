import AppKit
import SwiftUI

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

        resize.setIconsOnly(true)
        settle()
        shoot("4-icons")
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

        // The command bar grows out of the search icon.
        model.focusAddress()
        _ = SmokeTest.wait(0.6) { false }
        shoot("8-icons-command-bar")
        model.bar.close()
        LookRenders.skipWeb = false

        print(failed == 0 ? "Done." : "\(failed) checks failed.")
        Intelligence.shared.shutdown()
        return failed == 0 ? 0 : 1
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
    private static func drawTrafficLights(on url: URL, window: NSWindow) {
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
