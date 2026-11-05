import AppKit
import SwiftUI

/// The look and feel: contrast, neutral backgrounds, Reduce Motion, the launch timeline, the mark,
/// the icon's shape, the window chrome and the dash rule.
enum ThemeTests {
    static func check(_ ok: Bool, _ label: String, _ detail: String = "") { SelfTest.check(ok, label, detail) }
    typealias RGB = Theme.Palette.RGB

    static func run() {
        colour()
        layout()
        motion()
        glass()
        startup()
        mark()
        MainActor.assumeIsolated {
            icon()
            window()
        }
        punctuation()
        iconDocument()
    }

    static func colour() {
        let P = Theme.Palette.self
        check(P.frameDark.r == P.frameDark.g && P.frameDark.g == P.frameDark.b
              && P.frameLight.r == P.frameLight.g && P.frameLight.g == P.frameLight.b
              && P.cardDark.r == P.cardDark.g && P.sheetDark.r == P.sheetDark.g,
              "backgrounds are neutral grey with no tint of their own")
        check(P.sheetDark.luminance > P.cardDark.luminance && P.cardDark.luminance > P.frameDark.luminance,
              "in dark mode, sheets sit lighter than the card and the card lighter than the frame")

        // Text on the frame under every space colour, at the sidebar's full tint, in light and dark.
        var worst = (primary: 99.0, secondary: 99.0, name: "")
        for (name, hex) in Space.palette {
            for dark in [false, true] {
                let bg = (dark ? P.frameDark : P.frameLight).under(P.wash(hex, dark: dark), alpha: P.tintAlpha(dark: dark))
                let c1 = RGB.contrast(P.label(on: bg, dark: dark, level: 0), bg)
                let c2 = RGB.contrast(P.label(on: bg, dark: dark, level: 1), bg)
                if c1 < worst.primary || c2 < worst.secondary {
                    worst = (min(worst.primary, c1), min(worst.secondary, c2), "\(name) \(dark ? "dark" : "light")")
                }
            }
        }
        check(worst.primary >= 7 && worst.secondary >= 3.5, "sidebar text stays readable on every space colour",
              String(format: "worst primary %.1f, secondary %.1f (%@)", worst.primary, worst.secondary, worst.name))

        // The tint is noticeable but calm: every saturated space colour gives the sidebar a visible
        // hue, no space colour pushes it past a soft wash, and all of them sit at the same lightness.
        var chromas: [Double] = [], lights: [Double] = []
        for (name, hex) in Space.palette where name != "Slate" {
            for dark in [false, true] {
                let c = P.sidebar(hex, dark: dark).oklch
                chromas.append(c.c)
                lights.append(c.l)
            }
        }
        let cMin = chromas.min() ?? 0, cMax = chromas.max() ?? 0
        check(cMin > 0.018 && cMax < 0.045, "the sidebar tint is noticeable but calm in both modes",
              String(format: "OKLCH chroma %.3f to %.3f", cMin, cMax))
        let lightSpread = (0..<lights.count).filter { $0 % 2 == 0 }.map { lights[$0] }
        check((lightSpread.max() ?? 0) - (lightSpread.min() ?? 0) < 0.02,
              "every space colour gives the sidebar the same lightness")
        check(P.sidebar("#4C8DF6", dark: false, active: false).oklch.c < P.sidebar("#4C8DF6", dark: false).oklch.c,
              "the tint dims when the window isn't key")

        // In dark mode the tinted sidebar must stay darker than the card, or the card loses its edge.
        let brightest = Space.palette.map { P.frameDark.under(P.wash($0.1, dark: true), alpha: P.tintAlpha(dark: true)).luminance }.max() ?? 0
        check(brightest < P.cardDark.luminance * 0.85, "in dark mode the tinted sidebar stays darker than the card",
              String(format: "brightest sidebar %.4f, card %.4f", brightest, P.cardDark.luminance))
    }

    static func layout() {
        let concentric = Theme.Radius.card + Theme.Space.windowMargin
        check(abs(concentric - Theme.Radius.window) <= 2, "the content card's corner follows the window corner",
              "card \(Theme.Radius.card) + margin \(Theme.Space.windowMargin) vs window \(Theme.Radius.window)")
    }

    static func motion() {
        check(Motion.animation(Motion.panel, reduce: true) == nil, "Reduce Motion drops movement")
        check(Motion.animation(Motion.hover, reduce: true, fadeOnly: true) != nil, "Reduce Motion keeps a short fade")
        check(Motion.animation(Motion.panel, reduce: false) != nil, "animations run normally otherwise")
        check(!StartupTimeline.shouldPlay(reduceMotion: true) && StartupTimeline.shouldPlay(reduceMotion: false),
              "the launch animation is skipped under Reduce Motion")
        let steps = StepTracker()
        _ = steps.step(for: 0)
        let right = steps.step(for: 2), left = steps.step(for: 1), same = steps.step(for: 1)
        check(right == 1 && left == -1 && same == -1, "space switching knows which way to slide")
        let before = Motion.forceReduce
        Motion.forceReduce = true
        let reducedGraph = GraphTheme.glide < 0.01 && GraphTheme.momentumTime < 0.01
        Motion.forceReduce = false
        let fullGraph = GraphTheme.glide == 0.5 && GraphTheme.momentumTime == 0.35
        Motion.forceReduce = before
        check(reducedGraph && fullGraph, "the graph's camera jumps instead of gliding under Reduce Motion")
        check(Motion.animation(Motion.settle, reduce: true, tracked: true) == Motion.reducedSettle
              && Motion.animation(Motion.settle, reduce: false, tracked: true) == Motion.settle,
              "under Reduce Motion a gesture's end becomes a short ease-out, not a cut")
        check(Motion.gestureEnd(velocity: 800, distance: 200, reduce: false) != nil, "a gesture's settle starts at its velocity")
        check(Motion.stagger(0) == 0 && abs(Motion.stagger(3) - 0.12) < 1e-9 && Motion.stagger(40) == Motion.stagger(Motion.Timing.staggerCap)
              && abs(Motion.stagger(2, step: Motion.Timing.rowStagger) - 0.04) < 1e-9,
              "staggers step 40 ms for cards and 20 ms for rows, and stop growing past the cap")
        check(ShelfStyle.stagger == Motion.Timing.cardStagger, "the shelf's pills and the Related cards share one stagger")
        check(ShelfStyle.cardRadius == Theme.Radius.card && ShelfStyle.popoverRadius == Theme.Radius.popover,
              "the shelf uses the design system's radii")
        let springs = Motion.Springs.self
        check(springs.settle.duration == 0.3 && springs.spaceSwitch.duration == 0.28 && springs.settle.bounce == 0,
              "the per-frame springs match the animations they stand in for")
        Motion.suppressed = true
        let cut = Motion.animation(Motion.panel, reduce: false) == nil && Motion.animation(Motion.hover, reduce: false, fadeOnly: true) == nil
        Motion.suppressed = false
        check(cut && Motion.animation(Motion.panel, reduce: false) != nil, "nothing animates while motion is suppressed")
    }

    static func glass() {
        let G = Theme.GlassStyle.self
        let before = G.forceReduceTransparency
        G.forceReduceTransparency = false
        let glassy = !G.isSolid(false) && G.isSolid(true)
        G.forceReduceTransparency = true
        let forced = G.isSolid(false)
        G.forceReduceTransparency = before
        check(glassy && forced, "glass gives way to solid surfaces under Reduce Transparency, and --reduce-transparency forces it")
        check(G.containerSpacing < ShelfStyle.pillGap, "the shelf's pills never weld into one glass shape at rest",
              "spacing \(G.containerSpacing), gap \(ShelfStyle.pillGap)")
        let wash = { (dark: Bool) -> CGFloat in
            var alpha: CGFloat = 0
            NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                alpha = NSColor(G.readingWash).usingColorSpace(.sRGB)?.alphaComponent ?? 0
            }
            return alpha
        }
        check((0.4...0.65).contains(wash(false)) && (0.4...0.65).contains(wash(true)),
              "text-heavy glass carries a wash strong enough to read over a loud page, and light enough to stay glass",
              String(format: "light %.2f, dark %.2f", wash(false), wash(true)))
    }

    static func startup() {
        let T = StartupTimeline.self
        check(T.duration >= 0.9 && T.duration <= 1.3, "the launch animation lasts about a second", "\(T.duration) s")
        let first = T.frame(at: 0), last = T.frame(at: T.duration)
        check(first.cover == 1 && first.draw == 0 && first.dot == 0, "the launch starts with the cover up and nothing drawn")
        check(last.cover == 0 && last.markOpacity == 0, "the launch ends with the cover gone")
        var monotonic = true
        var prev = T.frame(at: 0)
        for i in 1...120 {
            let f = T.frame(at: T.duration * Double(i) / 120)
            if f.draw < prev.draw - 1e-9 || f.cover > prev.cover + 1e-9 { monotonic = false }
            prev = f
        }
        check(monotonic, "the stroke only draws forward and the cover only fades")
        let atExit = T.frame(at: T.exitStart)
        check(atExit.draw > 0.999 && atExit.dot > 0.999, "the mark is complete before the cover starts to fade")
        MainActor.assumeIsolated {
            let before = Motion.forceReduce
            Motion.forceReduce = true
            Startup.shared.begin()
            let skipped = Startup.shared.startedAt == nil
            Motion.forceReduce = before
            check(skipped, "under Reduce Motion the app never starts the launch animation")
        }
    }

    static func mark() {
        var inside = true
        for i in 0...200 {
            let p = MarkGeometry.point(Double(i) / 200)
            if p.x < 0.05 || p.x > 0.95 || p.y < 0.05 || p.y > 0.95 { inside = false }
        }
        check(inside, "the mark stays inside its box with room for the stroke")
        let start = MarkGeometry.point(0), end = MarkGeometry.point(1)
        let c = CGPoint(x: 0.5 + MarkGeometry.opticalOffset.x, y: 0.5 + MarkGeometry.opticalOffset.y)
        let endR = hypot(end.x - c.x, end.y - c.y)
        check(endR < MarkGeometry.radius - 0.02, "the loop curls back in toward the centre at the dot")
        check(hypot(end.x - start.x, end.y - start.y) > 0.18, "the loop stays open between its tail and the dot")
    }

    @MainActor
    static func icon() {
        let r = ImageRenderer(content: AppIconArt(size: 1024))
        r.scale = 1
        r.isOpaque = false
        guard let cg = r.cgImage else { check(false, "the icon renders"); return }
        let rep = NSBitmapImageRep(cgImage: cg)
        func alpha(_ x: Int, _ y: Int) -> CGFloat { rep.colorAt(x: x, y: y)?.alphaComponent ?? -1 }
        check(rep.pixelsWide == 1024 && rep.pixelsHigh == 1024, "the icon renders at 1024 px")
        let outside = [alpha(0, 0), alpha(1023, 1023), alpha(60, 512), alpha(512, 60), alpha(130, 130)]
        let inside = [alpha(512, 512), alpha(512, 110), alpha(110, 512), alpha(250, 250)]
        check(outside.allSatisfy { $0 == 0 }, "the icon is transparent outside the squircle, so macOS won't box it",
              outside.map { String(format: "%.2f", $0) }.joined(separator: " "))
        check(inside.allSatisfy { $0 > 0.99 }, "the icon's squircle is opaque",
              inside.map { String(format: "%.2f", $0) }.joined(separator: " "))
    }

    @MainActor
    static func window() {
        _ = NSApplication.shared
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        WindowChrome.configure(w)
        let titleBar = w.frame.height - w.contentLayoutRect.height
        guard let lights = WindowChrome.trafficLightsFrame(w) else { check(false, "the window has traffic lights"); return }
        let centreFromTop = w.frame.height - lights.midY
        check(abs(titleBar - Theme.Space.titleBarHeight) < 0.5, "the title bar matches the sidebar's top row", "\(titleBar) pt")
        check(abs(centreFromTop - Theme.Space.titleBarHeight / 2) < 1.5,
              "the traffic lights sit centred on the sidebar's top row", "centre \(centreFromTop) pt from the top")
        check(lights.maxX < Theme.Space.trafficLightsWidth + Theme.Space.sidebarInset,
              "the traffic lights leave the top row's buttons room", "they end at \(lights.maxX) pt")
    }

    /// The Icon Composer document names layers that exist, or actool would build nothing.
    static func iconDocument() {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let doc = repo.appendingPathComponent("Resources/AppIcon.icon")
        guard let data = try? Data(contentsOf: doc.appendingPathComponent("icon.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            check(!FileManager.default.fileExists(atPath: repo.appendingPathComponent("Resources").path), "the Icon Composer document reads")
            return
        }
        let names = (json["groups"] as? [[String: Any]] ?? []).flatMap { ($0["layers"] as? [[String: Any]] ?? []).compactMap { $0["image-name"] as? String } }
        let missing = names.filter { !FileManager.default.fileExists(atPath: doc.appendingPathComponent("Assets/\($0)").path) }
        check(!names.isEmpty && missing.isEmpty, "the Icon Composer document's layers all exist", missing.joined(separator: ", "))
    }

    /// The writing rules: only ASCII hyphens, no en or em dashes, no middle dots.
    static func punctuation() {
        let here = URL(fileURLWithPath: #filePath)
        let sources = here.deletingLastPathComponent().deletingLastPathComponent()
        let bad = CharacterSet(charactersIn: "\u{2013}\u{2014}\u{00B7}\u{2011}")
        var hits: [String] = []
        for folder in ["UI", "Startup"] {
            let dir = sources.appendingPathComponent(folder, isDirectory: true)
            guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let u as URL in e where u.pathExtension == "swift" {
                guard let text = try? String(contentsOf: u, encoding: .utf8) else { continue }
                for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                where line.rangeOfCharacter(from: bad) != nil {
                    hits.append("\(u.lastPathComponent):\(n + 1)")
                }
            }
        }
        check(FileManager.default.fileExists(atPath: sources.appendingPathComponent("UI").path) ? hits.isEmpty : true,
              "no en dashes, em dashes or middle dots in the UI and startup code", hits.prefix(5).joined(separator: ", "))
    }
}
