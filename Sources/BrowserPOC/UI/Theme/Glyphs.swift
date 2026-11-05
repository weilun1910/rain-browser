import AppKit
import SwiftUI

// MARK: Folder glyph

/// A folder drawn as two thin shapes, a back with a tab and a front pocket, that opens when
/// `isOpen` changes: the front tips forward and the back leans away, like a folder seen from the
/// side. Zen animates its folder icon this way; this is our own drawing on a 16 pt grid. The open
/// state belongs to whoever owns the folder; this only draws it.
struct FolderGlyph: View {
    let isOpen: Bool
    var size: CGFloat = 16
    /// What the front pocket is filled with, so the back's lines don't show through it.
    /// Defaults to the sidebar's colour for the current space.
    var ground: Color?
    var stroke: Color = .secondary
    @Environment(\.spaceTintHex) private var hex
    @Environment(\.spaceAccent) private var accent

    var body: some View {
        let lw: CGFloat = max(1, size / 13)
        let base = ground ?? Theme.Palette.sidebarColor(hex)
        ZStack {
            FolderBack()
                .stroke(stroke, style: StrokeStyle(lineWidth: lw, lineJoin: .round))
                .modifier(LeanEffect(amount: isOpen ? 1 : 0, skew: 0.20, dx: -0.06, dy: 0.04, scale: 0.92))
            FolderFront()
                .fill(base)
                .overlay(FolderFront().fill(accent.opacity(isOpen ? 0.16 : 0.10)))
                .overlay(FolderFront().stroke(stroke, style: StrokeStyle(lineWidth: lw, lineJoin: .round)))
                .modifier(LeanEffect(amount: isOpen ? 1 : 0, skew: -0.30, dx: 0.12, dy: 0.06, scale: 0.86))
        }
        .frame(width: size, height: size)
        .motion(Motion.folderGlyph, value: isOpen)
        .accessibilityHidden(true)
    }
}

/// The folder's back: a rounded body with a tab at the top left.
struct FolderBack: Shape {
    func path(in r: CGRect) -> Path {
        let u = r.width / 16
        var p = Path()
        let left = r.minX + 1.75 * u, right = r.maxX - 1.75 * u, top = r.minY + 2.5 * u, bottom = r.maxY - 2.5 * u
        let tabEnd = left + 5 * u, shoulder = top + 1.75 * u, rad = 1.75 * u
        p.move(to: CGPoint(x: left, y: bottom - rad))
        p.addLine(to: CGPoint(x: left, y: top + rad))
        p.addQuadCurve(to: CGPoint(x: left + rad, y: top), control: CGPoint(x: left, y: top))
        p.addLine(to: CGPoint(x: tabEnd - 0.8 * u, y: top))
        p.addQuadCurve(to: CGPoint(x: tabEnd + 0.6 * u, y: shoulder - 0.4 * u), control: CGPoint(x: tabEnd, y: top))
        p.addQuadCurve(to: CGPoint(x: tabEnd + 1.6 * u, y: shoulder), control: CGPoint(x: tabEnd + 1.1 * u, y: shoulder))
        p.addLine(to: CGPoint(x: right - rad, y: shoulder))
        p.addQuadCurve(to: CGPoint(x: right, y: shoulder + rad), control: CGPoint(x: right, y: shoulder))
        p.addLine(to: CGPoint(x: right, y: bottom - rad))
        p.addQuadCurve(to: CGPoint(x: right - rad, y: bottom), control: CGPoint(x: right, y: bottom))
        p.addLine(to: CGPoint(x: left + rad, y: bottom))
        p.addQuadCurve(to: CGPoint(x: left, y: bottom - rad), control: CGPoint(x: left, y: bottom))
        p.closeSubpath()
        return p
    }
}

/// The folder's front pocket.
struct FolderFront: Shape {
    func path(in r: CGRect) -> Path {
        let u = r.width / 16
        let rect = CGRect(x: r.minX + 1.75 * u, y: r.minY + 6.25 * u, width: r.width - 3.5 * u, height: r.height - 8.75 * u)
        return Path(roundedRect: rect, cornerRadius: 1.75 * u, style: .continuous)
    }
}

/// Skews, shifts and scales a shape from its bottom edge, by `amount` from 0 to 1. Animatable,
/// so the folder opens smoothly instead of jumping between two transforms.
struct LeanEffect: GeometryEffect {
    var amount: CGFloat
    let skew: CGFloat
    let dx: CGFloat
    let dy: CGFloat
    let scale: CGFloat

    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let s = 1 + (scale - 1) * amount
        let k = skew * amount
        // Anchored at the bottom centre: move the anchor to the origin, scale and skew (points
        // above the base shift sideways in proportion to their height), then move back and shift.
        let ax = size.width / 2, ay = size.height
        let pre = CGAffineTransform(translationX: -ax, y: -ay)
        let m = CGAffineTransform(a: s, b: 0, c: -k * s, d: s, tx: 0, ty: 0)
        let post = CGAffineTransform(translationX: ax + dx * size.width * amount, y: ay + dy * size.height * amount)
        return ProjectionTransform(pre.concatenating(m).concatenating(post))
    }
}

/// A folder's children, revealed and collapsed with the folder: the rows slide out from under the
/// folder row while the space below opens, clipped so nothing draws over the folder itself.
/// Driven by `isOpen`, so the folder's owner keeps the state.
struct FolderReveal<Content: View>: View {
    let isOpen: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            if isOpen {
                content().transition(Motion.Transitions.folderContents)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .motion(Motion.expand, value: isOpen)
    }
}

// MARK: Favicons

/// How a site's icon sits in a row. It takes an optional image, so it works with whatever supplies
/// favicons: the image fades in when it arrives, and until then a quiet monogram holds its place.
/// Dark icons get a light backing in dark mode, and very light ones a dark backing in light mode,
/// so a black logo never disappears into a dark sidebar.
struct FaviconView: View {
    let image: NSImage?
    var size: CGFloat = 16
    /// Shown while there's no image: a letter for a site, or an SF Symbol for anything else.
    var fallback: Fallback = .symbol("globe")

    enum Fallback: Equatable {
        case monogram(String)
        case symbol(String)

        /// A monogram from a URL's host: the first letter of the site's name.
        static func site(_ url: URL?) -> Fallback {
            guard let h = url?.host?.lowercased() else { return .symbol("globe") }
            let parts = h.split(separator: ".").filter { !["www", "m", "en", "app", "docs"].contains($0) }
            let name = parts.count >= 2 ? parts[parts.count - 2] : (parts.first ?? Substring(h))
            return name.first.map { .monogram(String($0).uppercased()) } ?? .symbol("globe")
        }
    }

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let radius = max(2.5, size * 0.22)
        ZStack {
            if let image {
                let tone = FaviconTone.tone(of: image)
                let needsBacking = (scheme == .dark && tone == .dark) || (scheme == .light && tone == .light)
                if needsBacking {
                    RoundedRectangle(cornerRadius: radius + 1, style: .continuous)
                        .fill(scheme == .dark ? Color(white: 0.92) : Color(white: 0.22))
                        .frame(width: size + 3, height: size + 3)
                }
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .frame(width: needsBacking ? size - 2 : size, height: needsBacking ? size - 2 : size)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .transition(.opacity)
            } else {
                fallbackView(radius: radius).transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .motion(Motion.favicon, value: image != nil, fadeOnly: true)
        .accessibilityHidden(true)
    }

    @ViewBuilder func fallbackView(radius: CGFloat) -> some View {
        switch fallback {
        case .monogram(let letter):
            Text(letter)
                .font(.system(size: size * 0.58, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.Palette.rowPressed))
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size * 0.75))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}

/// Whether an icon is mostly dark, mostly light or neither, judged from its opaque pixels.
enum FaviconTone {
    case dark, light, normal

    @MainActor private static var cache: [ObjectIdentifier: FaviconTone] = [:]

    @MainActor static func tone(of image: NSImage) -> FaviconTone {
        let id = ObjectIdentifier(image)
        if let t = cache[id] { return t }
        let t = measure(image)
        if cache.count > 500 { cache.removeAll() }
        cache[id] = t
        return t
    }

    static func measure(_ image: NSImage) -> FaviconTone {
        let n = 12
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return .normal }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: n, height: n))
        NSGraphicsContext.restoreGraphicsState()
        var lum = 0.0, weight = 0.0, transparent = 0.0
        for y in 0..<n { for x in 0..<n {
            guard let c = rep.colorAt(x: x, y: y) else { continue }
            let a = Double(c.alphaComponent)
            if a < 0.1 { transparent += 1; continue }
            lum += a * (0.2126 * Double(c.redComponent) + 0.7152 * Double(c.greenComponent) + 0.0722 * Double(c.blueComponent))
            weight += a
        } }
        guard weight > 0 else { return .normal }
        let avg = lum / weight
        // A dark icon on a transparent ground, or a nearly black square, vanishes on dark grey.
        if avg < 0.22 { return .dark }
        if avg > 0.9 && transparent > Double(n * n) * 0.2 { return .light }
        return .normal
    }
}

/// Reads site icons that something else has saved to `<support folder>/favicons/<host>.png`.
/// A stand-in until the Arc and Zen agent's `Favicons` arrives at merge, which uses the same
/// files; then callers switch to `Favicons.shared.image(for:)` and this goes away.
@MainActor
enum FaviconLookup {
    private static var memory: [String: NSImage] = [:]
    private static var missing: Set<String> = []
    private static var root: String?

    static func image(for url: URL?) -> NSImage? {
        guard let url, url.scheme?.hasPrefix("http") == true, var h = url.host?.lowercased() else { return nil }
        if h.hasPrefix("www.") { h = String(h.dropFirst(4)) }
        if root != Paths.root.path { memory = [:]; missing = []; root = Paths.root.path }
        if let i = memory[h] { return i }
        if missing.contains(h) { return nil }
        let file = Paths.root.appendingPathComponent("favicons", isDirectory: true).appendingPathComponent(h + ".png")
        if let i = NSImage(contentsOf: file) { memory[h] = i; return i }
        missing.insert(h)
        return nil
    }
}
