import AppKit
import SwiftUI

/// The app icon, drawn from the same geometry as the mark: a graphite squircle in the macOS 26
/// shape with a frosted white loop. Nothing is drawn outside the squircle, so macOS shows it as
/// is instead of shrinking it into a grey box.
struct AppIconArt: View {
    /// Canvas size in pixels. The squircle is 824 of every 1024, centred, like Apple's template.
    let size: CGFloat

    static let tileShare: CGFloat = 824.0 / 1024.0
    static let cornerShare: CGFloat = 185.4 / 824.0
    static let glyphShare: CGFloat = 0.54

    var body: some View {
        let tile = size * Self.tileShare
        let shape = RoundedRectangle(cornerRadius: tile * Self.cornerShare, style: .continuous)
        let glyph = tile * Self.glyphShare
        // Thin at large sizes, with a floor so the loop still reads at 16 px.
        let weight = max(0.042, 1.25 / glyph)
        ZStack {
            Color.clear
            ZStack {
                shape.fill(LinearGradient(colors: [Color(white: 0.180), Color(white: 0.075)],
                                          startPoint: .top, endPoint: .bottom))
                // A soft light from above, inside the tile.
                shape.fill(RadialGradient(colors: [Color.white.opacity(0.075), .clear],
                                          center: UnitPoint(x: 0.5, y: 0.0), startRadius: 0, endRadius: tile * 0.75))
                // The rim catches the light at the top and fades by the bottom.
                shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.03)],
                                                  startPoint: .top, endPoint: .center),
                                   lineWidth: max(0.75, size * 0.0028))
                // The glyph: frosted white, a hint brighter at the top.
                LinearGradient(colors: [Color.white.opacity(0.97), Color.white.opacity(0.80)], startPoint: .top, endPoint: .bottom)
                    .frame(width: glyph, height: glyph)
                    .mask(BrandMark(weight: weight, color: .white))
                    .shadow(color: .black.opacity(0.45), radius: glyph * 0.025, y: glyph * 0.018)
                    .shadow(color: .white.opacity(size >= 128 ? 0.10 : 0), radius: glyph * 0.04)
            }
            .frame(width: tile, height: tile)
            .clipShape(shape)
        }
        .frame(width: size, height: size)
    }
}

/// `--render-art <dir>`: writes the app icon in every size macOS wants (as an .iconset for
/// iconutil), plus previews of the mark and the startup animation for review.
@MainActor
enum ArtRenderer {
    static func png(_ view: some View, size: CGSize, scale: CGFloat = 1, dark: Bool = false) -> Data? {
        let r = ImageRenderer(content: view.frame(width: size.width, height: size.height)
            .environment(\.colorScheme, dark ? .dark : .light))
        r.scale = scale
        r.isOpaque = false
        guard let cg = r.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:])
    }

    static let iconSizes: [(String, Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]

    static func writeIconset(to dir: URL) -> Bool {
        Paths.ensure(dir)
        for (name, px) in iconSizes {
            guard let d = png(AppIconArt(size: CGFloat(px)), size: CGSize(width: px, height: px)) else { return false }
            do { try d.write(to: dir.appendingPathComponent("\(name).png")) } catch { return false }
        }
        return true
    }

    static func run(_ out: URL) -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        Paths.ensure(out)
        let iconset = out.appendingPathComponent("AppIcon.iconset", isDirectory: true)
        guard writeIconset(to: iconset) else { print("Couldn't render the icon"); return 1 }
        print("wrote \(iconset.path)")

        // Mark previews on the frame colour, light and dark.
        for dark in [false, true] {
            let v = ZStack {
                Theme.Palette.frame
                BrandMark(weight: 0.05, color: .primary, opacity: 0.88).frame(width: 240, height: 240)
            }
            if let d = png(v, size: CGSize(width: 480, height: 480), scale: 2, dark: dark) {
                try? d.write(to: out.appendingPathComponent(dark ? "mark-dark.png" : "mark-light.png"))
            }
        }
        // The mark small, to check it reads at sidebar and menu sizes.
        let small = HStack(spacing: 28) {
            ForEach([12, 16, 24, 32, 48], id: \.self) { s in
                BrandMark(minLine: 1.2, color: .primary, opacity: 0.88).frame(width: CGFloat(s), height: CGFloat(s))
            }
        }
        if let d = png(ZStack { Theme.Palette.frame; small }, size: CGSize(width: 320, height: 80), scale: 2) {
            try? d.write(to: out.appendingPathComponent("mark-small.png"))
        }
        // The icon at a few sizes on light and dark grounds.
        let icons = HStack(spacing: 24) {
            ForEach([256, 128, 64, 32, 16], id: \.self) { s in AppIconArt(size: CGFloat(s)) }
        }
        for dark in [false, true] {
            let v = ZStack { (dark ? Color(white: 0.12) : Color(white: 0.93)); icons }
            if let d = png(v, size: CGSize(width: 640, height: 300), scale: 2, dark: dark) {
                try? d.write(to: out.appendingPathComponent(dark ? "icon-sizes-dark.png" : "icon-sizes-light.png"))
            }
        }
        // The startup, frame by frame.
        let times: [Double] = [0.1, 0.25, 0.4, 0.55, 0.7, 0.85, 1.0, 1.1]
        for dark in [false, true] {
            let strip = HStack(spacing: 0) {
                ForEach(times, id: \.self) { t in
                    ZStack {
                        Color(white: dark ? 0.2 : 0.75)
                        StartupOverlay(frame: StartupTimeline.frame(at: t), size: 68)
                        Text(String(format: "%.2f s", t)).font(Theme.Font.mono(10)).foregroundStyle(.secondary)
                            .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 8)
                    }
                    .frame(width: 160, height: 160)
                }
            }
            if let d = png(strip, size: CGSize(width: 160 * CGFloat(times.count), height: 160), scale: 2, dark: dark) {
                try? d.write(to: out.appendingPathComponent(dark ? "startup-frames-dark.png" : "startup-frames-light.png"))
            }
        }
        print("wrote previews to \(out.path)")
        return 0
    }
}
