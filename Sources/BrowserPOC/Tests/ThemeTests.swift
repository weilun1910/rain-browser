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
        startup()
        mark()
        MainActor.assumeIsolated {
            icon()
            window()
        }
        punctuation()
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
                let bg = (dark ? P.frameDark : P.frameLight).under(RGB(hex: hex), alpha: P.tintAlpha(dark: dark))
                let c1 = RGB.contrast(P.label(on: bg, dark: dark, level: 0), bg)
                let c2 = RGB.contrast(P.label(on: bg, dark: dark, level: 1), bg)
                if c1 < worst.primary || c2 < worst.secondary {
                    worst = (min(worst.primary, c1), min(worst.secondary, c2), "\(name) \(dark ? "dark" : "light")")
                }
            }
        }
        check(worst.primary >= 7 && worst.secondary >= 3.5, "sidebar text stays readable on every space colour",
              String(format: "worst primary %.1f, secondary %.1f (%@)", worst.primary, worst.secondary, worst.name))

        // The tint is a wash, not a colour block.
        var biggest = 0.0
        for (_, hex) in Space.palette {
            for dark in [false, true] {
                let base = dark ? P.frameDark : P.frameLight
                let t = base.under(RGB(hex: hex), alpha: P.tintAlpha(dark: dark))
                biggest = max(biggest, abs(t.r - base.r), abs(t.g - base.g), abs(t.b - base.b))
            }
        }
        check(biggest < 0.12, "the space tint stays a light wash", String(format: "largest channel shift %.3f", biggest))
        check(P.tintAlpha(dark: false, active: false) < P.tintAlpha(dark: false), "the tint dims when the window isn't key")
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
