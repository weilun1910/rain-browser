import AppKit
import SwiftUI

/// Every colour, size, alpha and timing the graph uses, in one place. The values follow the Look
/// and feel agent's design system (`UI/Theme/`, round 3): the canvas is the content card's grey,
/// floating panels use its sheet colour and hairline, names use its label greys, rings use the
/// space accent, and the timings match its hover, insert, remove and panel motion. They're copied
/// here rather than referenced, so the graph builds on its own and the merge stays clean.
struct GraphTheme {
    var background: SIMD4<Float>
    var label: SIMD4<Float>
    var ring: SIMD4<Float>
    var hoverRing: SIMD4<Float>
    var nodes: [GraphNodeKind: SIMD4<Float>]
    var edges: [GraphEdgeType: SIMD4<Float>]
    var isDark: Bool
    /// How far everything not near the hovered node fades.
    var dimAlpha: Float = 0.1
    /// Line width at the Link thickness default, in points.
    var lineWidth: Float = 0.9
    var arrowSize: Float = 6
    /// Names use the chrome's caption size (Theme.Font.caption, SF Pro 11).
    var labelFontSize: CGFloat = 11
    var labelMaxWidth: CGFloat = 220
    /// Node radius in world units is `base + perLink * sqrt(connections)`, times Node size.
    var radiusBase: Float = 3
    var radiusPerLink: Float = 1.4

    static func hex(_ s: String, _ a: Float = 1) -> SIMD4<Float> {
        var v: UInt64 = 0
        Scanner(string: s.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&v)
        return SIMD4(Float((v >> 16) & 0xFF) / 255, Float((v >> 8) & 0xFF) / 255, Float(v & 0xFF) / 255, a)
    }

    static func gray(_ w: Float, _ a: Float = 1) -> SIMD4<Float> { SIMD4(w, w, w, a) }

    /// `top` laid over `base` at `alpha`, flattened. The design system's `under`.
    static func mix(_ base: SIMD4<Float>, _ top: SIMD4<Float>, _ alpha: Float) -> SIMD4<Float> {
        SIMD4(base.x + (top.x - base.x) * alpha, base.y + (top.y - base.y) * alpha, base.z + (top.z - base.z) * alpha, base.w)
    }

    // Dark: card #202020, labels at the chrome's 0.85 white.
    static let dark = GraphTheme(
        background: gray(0.125),
        label: mix(gray(0.125), gray(1), 0.85),
        ring: gray(0.96),
        hoverRing: gray(1, 0.9),
        nodes: [
            .note: hex("#E2E2E2"),
            .doc: hex("#8FB0E8"),
            .site: hex("#8A8A8A"),
            .meeting: hex("#D9A960"),
            .topic: hex("#A996DA"),
            .unresolved: hex("#6E6E6E"),
            .siteGroup: hex("#9A9A9A"),
        ],
        edges: [
            .link: gray(0.85, 0.34),
            .navigation: hex("#6F9BD6", 0.42),
            .research: hex("#D9A960", 0.5),
            .together: hex("#5EAFA3", 0.4),
            .similar: hex("#9A86D6", 0.26),
            .topic: gray(0.6, 0.16),
        ],
        isDark: true)

    // Light: card white, labels at the chrome's 0.85 black.
    static let light = GraphTheme(
        background: gray(1),
        label: mix(gray(1), gray(0), 0.85),
        ring: gray(0.1),
        hoverRing: gray(0, 0.85),
        nodes: [
            .note: hex("#3A3A3A"),
            .doc: hex("#3F6FC4"),
            .site: hex("#A3A3A3"),
            .meeting: hex("#B9822F"),
            .topic: hex("#7A5FC2"),
            .unresolved: hex("#BDBDBD"),
            .siteGroup: hex("#8A8A8A"),
        ],
        edges: [
            .link: gray(0.25, 0.3),
            .navigation: hex("#3F6FC4", 0.38),
            .research: hex("#B9822F", 0.48),
            .together: hex("#2E8C80", 0.36),
            .similar: hex("#7A5FC2", 0.24),
            .topic: gray(0.45, 0.16),
        ],
        isDark: false)

    static func current(for appearance: NSAppearance?) -> GraphTheme {
        let dark = (appearance ?? NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing())
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? .dark : .light
    }

    func color(_ kind: GraphNodeKind) -> SIMD4<Float> { nodes[kind] ?? Self.hex("#888888") }
    func color(_ type: GraphEdgeType) -> SIMD4<Float> { edges[type] ?? Self.hex("#888888", 0.3) }

    /// A space's colour toned for small marks, the design system's `accent`: a little darker in
    /// light mode and a little lighter in dark mode, so it holds up on both.
    func accent(_ hex: String) -> SIMD4<Float> {
        let c = Self.hex(hex)
        return isDark ? Self.mix(c, Self.gray(1), 0.12) : Self.mix(c, Self.gray(0), 0.18)
    }

    /// A node coloured by its space. Things you write take the full accent. Sites you read sit
    /// back toward the canvas, so the clusters read by colour and the writing stands out in them.
    func spaceColor(_ hex: String, kind: GraphNodeKind) -> SIMD4<Float> {
        let a = accent(hex)
        switch kind {
        case .site, .siteGroup: return Self.mix(a, background, isDark ? 0.45 : 0.4)
        case .topic, .unresolved: return Self.mix(a, background, 0.6)
        default: return a
        }
    }

    /// A node with no space, when colouring by space: plain grey, lighter for things you write,
    /// so nothing unplaced borrows a space's hue.
    func neutral(_ kind: GraphNodeKind) -> SIMD4<Float> {
        switch kind {
        case .note, .doc, .meeting: return isDark ? Self.gray(0.78) : Self.gray(0.32)
        case .unresolved: return color(.unresolved)
        default: return isDark ? Self.gray(0.5) : Self.gray(0.66)
        }
    }

    /// Group colours, the same eight as the space palette.
    static let groupPalette: [(name: String, hex: String)] = [
        ("Slate", "#7A8CA8"), ("Blue", "#4C8DF6"), ("Teal", "#2FA8A0"), ("Green", "#5DA55A"),
        ("Amber", "#E0A030"), ("Orange", "#E57A3C"), ("Rose", "#D9607A"), ("Purple", "#9070D8"),
    ]

    // MARK: SwiftUI panels

    /// Floating panels and the hover card: the design system's sheet colour, hairline and radii.
    static let panelFill = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 0.161, alpha: 0.96) : NSColor(white: 0.995, alpha: 0.96)
    })
    static let hairline = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.09) : NSColor(white: 0, alpha: 0.07)
    })
    static let panelRadius: CGFloat = 14
    static let cardRadius: CGFloat = 10
    static let buttonRadius: CGFloat = 6

    // MARK: Motion

    /// Hover highlight and dimming, in and out. A little longer than the chrome's 0.12 s hover,
    /// since a whole neighbourhood changes at once.
    static let hoverFade: Double = 0.15
    /// Nodes arriving after a filter or search change, and leaving. Like the sidebar's row insert
    /// (0.2 s smooth) and remove (0.14 s ease in).
    static let enter: Double = 0.24
    static let exit: Double = 0.16
    /// The camera gliding to a clicked node, to a focus, or to fit everything.
    static let glide: Double = 0.5
    /// How long a flung background drag keeps going.
    static let momentumTime: Double = 0.35
    /// A mouse wheel step eases to its zoom over this long.
    static let wheelZoom: Double = 0.14
    /// After the last input, keep drawing every frame this long, so the next input never waits
    /// on a paused view.
    static let activityGrace: Double = 0.6
    /// Side panels: the chrome's panel spring.
    static let panelSpring = Animation.spring(duration: 0.3, bounce: 0.06)
    static let cardFade = Animation.easeOut(duration: 0.12)
}

extension SIMD4 where Scalar == Float {
    var swiftUI: Color { Color(.sRGB, red: Double(x), green: Double(y), blue: Double(z), opacity: Double(w)) }
}

extension GraphNodeKind {
    @MainActor func swatch(_ scheme: ColorScheme) -> Color {
        (scheme == .dark ? GraphTheme.dark : GraphTheme.light).color(self).swiftUI
    }
}

extension GraphEdgeType {
    @MainActor func swatch(_ scheme: ColorScheme) -> Color {
        var c = (scheme == .dark ? GraphTheme.dark : GraphTheme.light).color(self)
        c.w = min(1, c.w * 2.2)
        return c.swiftUI
    }
}

/// Smooth 0 to 1 easing for fades and glides.
@inline(__always) func graphEase(_ t: Float) -> Float {
    let x = min(1, max(0, t))
    return x * x * (3 - 2 * x)
}

@inline(__always) func graphEaseOut(_ t: Double) -> Double {
    let x = min(1, max(0, t))
    return 1 - pow(1 - x, 3)
}
