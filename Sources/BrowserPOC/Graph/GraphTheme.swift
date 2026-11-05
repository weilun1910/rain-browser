import AppKit
import SwiftUI

/// Every colour, size and alpha the graph uses, in one place, so the look can be restyled
/// without touching the renderer. Neutral backgrounds, colour only in nodes and lines.
struct GraphTheme {
    var background: SIMD4<Float>
    var label: SIMD4<Float>
    var ring: SIMD4<Float>
    var hoverRing: SIMD4<Float>
    var nodes: [GraphNodeKind: SIMD4<Float>]
    var edges: [GraphEdgeType: SIMD4<Float>]
    /// How far everything not near the hovered node fades.
    var dimAlpha: Float = 0.12
    /// Line width at the Link thickness default, in points.
    var lineWidth: Float = 0.9
    var arrowSize: Float = 6
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

    static let dark = GraphTheme(
        background: hex("#131313"),
        label: hex("#D6D6D6"),
        ring: hex("#F2F2F2"),
        hoverRing: hex("#FFFFFF", 0.9),
        nodes: [
            .note: hex("#E4E4E4"),
            .doc: hex("#86A9E6"),
            .site: hex("#8C8C8C"),
            .meeting: hex("#D8A45C"),
            .topic: hex("#A792D9"),
            .unresolved: hex("#6A6A6A"),
            .siteGroup: hex("#9A9A9A"),
        ],
        edges: [
            .link: hex("#C8C8C8", 0.42),
            .navigation: hex("#6F9BD6", 0.5),
            .research: hex("#D8A45C", 0.6),
            .together: hex("#5EAFA3", 0.45),
            .similar: hex("#9A86D6", 0.38),
            .topic: hex("#8A8A8A", 0.22),
        ])

    static let light = GraphTheme(
        background: hex("#F7F7F6"),
        label: hex("#3A3A3A"),
        ring: hex("#1A1A1A"),
        hoverRing: hex("#000000", 0.85),
        nodes: [
            .note: hex("#3C3C3C"),
            .doc: hex("#3F6FC4"),
            .site: hex("#9C9C9C"),
            .meeting: hex("#B9822F"),
            .topic: hex("#7A5FC2"),
            .unresolved: hex("#B5B5B5"),
            .siteGroup: hex("#8A8A8A"),
        ],
        edges: [
            .link: hex("#555555", 0.38),
            .navigation: hex("#3F6FC4", 0.45),
            .research: hex("#B9822F", 0.55),
            .together: hex("#2E8C80", 0.42),
            .similar: hex("#7A5FC2", 0.34),
            .topic: hex("#777777", 0.2),
        ])

    static func current(for appearance: NSAppearance?) -> GraphTheme {
        let dark = (appearance ?? NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing())
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? .dark : .light
    }

    func color(_ kind: GraphNodeKind) -> SIMD4<Float> { nodes[kind] ?? Self.hex("#888888") }
    func color(_ type: GraphEdgeType) -> SIMD4<Float> { edges[type] ?? Self.hex("#888888", 0.3) }

    /// Group colours, restrained to match the space tints.
    static let groupPalette: [String] = ["#4C8DF6", "#2FA8A0", "#5DA55A", "#E0A030", "#E57A3C", "#D9607A", "#9070D8", "#7A8CA8"]
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
        c.w = min(1, c.w * 2)
        return c.swiftUI
    }
}
