import AppKit
import SwiftUI

extension Theme {
    /// Surface materials. Zen and Arc lay a fine grain under the space colour, which gives the chrome
    /// a paper-like quality and stops the tint's gradient from banding. Ours is generated here,
    /// finer and quieter than theirs.
    enum Material {
        /// How strongly the grain shows, light then dark.
        static let grainOpacity = (light: 0.05, dark: 0.07)
        /// The tile size in points. Each point gets two pixels on a Retina screen.
        static let grainTile: CGFloat = 128

        /// A tile of soft grey noise, the same every launch.
        static let grain: NSImage = {
            let px = Int(grainTile * 2)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                       samplesPerPixel: 1, hasAlpha: false, isPlanar: false,
                                       colorSpaceName: .deviceWhite, bytesPerRow: px, bitsPerPixel: 8)!
            var seed: UInt64 = 0x9E3779B97F4A7C15
            func next() -> UInt64 {
                seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
                return seed
            }
            if let data = rep.bitmapData {
                for i in 0..<(px * px) {
                    // Two samples averaged: a softer, less speckled grain around mid grey.
                    let a = Int(next() & 0xFF), b = Int(next() & 0xFF)
                    data[i] = UInt8((a + b) / 2)
                }
            }
            let img = NSImage(size: NSSize(width: grainTile, height: grainTile))
            img.addRepresentation(rep)
            return img
        }()
    }
}

extension Theme {
    /// Liquid Glass, for the control layer that floats over the page: the command bar, the
    /// Related shelf's pills and popover, and the graph's toolbar, hover card and settings panel.
    /// The page, notes and the sidebar stay solid, as Apple's guidance has it: glass is for
    /// controls and navigation over content, never for the content itself.
    ///
    /// It's always the regular, untinted glass. Clear glass is for controls over photos and video,
    /// and a tint would compete with the space colour. Under Reduce Transparency every surface
    /// falls back to the solid one it replaced. Increase Contrast and Reduce Motion are handled by
    /// the system's own glass.
    enum GlassStyle {
        /// `--reduce-transparency` sets this, to check the solid fallback without System Settings.
        nonisolated(unsafe) static var forceReduceTransparency = false

        /// True when glass should give way to its solid fallback.
        static func isSolid(_ reduceTransparency: Bool) -> Bool { reduceTransparency || forceReduceTransparency }

        /// Glass shapes in one container closer than this blend into one. Kept under the gap
        /// between the shelf's pills (6 pt), so neighbours never weld together at rest.
        static let containerSpacing: CGFloat = 4

        /// A neutral wash inside text-heavy glass, under the text: the command bar, popovers and
        /// the graph's cards. Small grey text stays legible over a loud page, and the glass still
        /// shows the page's colour softly. Pills and icon buttons carry a word or a glyph and go
        /// without.
        static let readingWash = Color(nsColor: Palette.dynamic(NSColor(white: 1, alpha: 0.6), NSColor(white: 0.09, alpha: 0.5)))

        /// A hovered or toggled control on glass: a faint fill, never more glass on top.
        static let activeFill = Color.primary.opacity(0.08)
    }
}

extension Theme.Palette {
    /// A neutral wash laid over the system blur for things that float over a page, so the page's
    /// colours show through softly without tinting the controls.
    static let floatingWash = Color(nsColor: dynamic(NSColor(white: 1, alpha: 0.62), NSColor(white: 0.12, alpha: 0.62)))
    static let floatingWashHover = Color(nsColor: dynamic(NSColor(white: 1, alpha: 0.80), NSColor(white: 0.16, alpha: 0.72)))
    /// The colour a fade over the bottom of a page runs into: the card's own colour, so the fade
    /// reads as the page dimming rather than a grey band.
    static let fadeEnd = Color(nsColor: dynamic(cardLight, cardDark))
}

extension Theme.Radius {
    /// Compact floating cards, like the Related shelf's pills.
    static let chip: CGFloat = 9
    /// Popovers that hang off a control.
    static let popover: CGFloat = 12
}

/// A surface that floats over page content: system blur, a neutral wash, a hairline and a soft
/// shadow. For the Related shelf's pills, toasts and anything else that sits on a page.
struct FloatingSurface: ViewModifier {
    var radius: CGFloat = Theme.Radius.chip
    var hovering = false
    func body(content: Content) -> some View {
        let shape = Theme.Radius.shape(radius)
        return content
            .background(
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(hovering ? Theme.Palette.floatingWashHover : Theme.Palette.floatingWash)
                }
                .themeShadow(.floating)
            )
            .overlay(shape.strokeBorder(Theme.Palette.hairline, lineWidth: 0.5))
            .motion(Motion.hover, value: hovering, fadeOnly: true)
    }
}

/// A popover: opaque, so its text reads cleanly over anything, with a deeper shadow.
struct PopoverSurface: ViewModifier {
    var radius: CGFloat = Theme.Radius.popover
    func body(content: Content) -> some View {
        let shape = Theme.Radius.shape(radius)
        return content
            .background(shape.fill(Theme.Palette.sheet).themeShadow(.popover))
            .overlay(shape.strokeBorder(Theme.Palette.hairline, lineWidth: 0.5))
    }
}

/// Liquid Glass for a floating panel full of text, like the command bar or a popover, with the
/// solid sheet it replaced as the fallback under Reduce Transparency.
struct GlassPanel: ViewModifier {
    var radius: CGFloat = Theme.Radius.sheet
    /// The shadow the solid fallback casts. The glass draws its own depth.
    var fallbackShadow: Theme.Shadow = .sheet
    var wash = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = Theme.Radius.shape(radius)
        if Theme.GlassStyle.isSolid(reduceTransparency) {
            content
                .background(shape.fill(Theme.Palette.sheet).themeShadow(fallbackShadow))
                .overlay(shape.strokeBorder(Theme.Palette.hairline, lineWidth: 0.5).allowsHitTesting(false))
        } else {
            content
                .background(shape.fill(wash ? Theme.GlassStyle.readingWash : .clear))
                .glassEffect(.regular, in: shape)
        }
    }
}

/// Liquid Glass for a small control on a page, like an icon button or a search field.
/// Interactive, so it answers the pointer the way system glass buttons do. `active` lays a
/// faint fill on the glass for a hovered, pressed or toggled control.
struct GlassControl: ViewModifier {
    var radius: CGFloat = Theme.Radius.row
    var active = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = Theme.Radius.shape(radius)
        if Theme.GlassStyle.isSolid(reduceTransparency) {
            content
                .background(ZStack { shape.fill(Theme.Palette.sheet); shape.fill(active ? Theme.GlassStyle.activeFill : .clear) }.themeShadow(.row))
                .overlay(shape.strokeBorder(Theme.Palette.hairline, lineWidth: 0.5).allowsHitTesting(false))
        } else {
            content
                .background(shape.fill(active ? Theme.GlassStyle.activeFill : .clear))
                .glassEffect(.regular.interactive(), in: shape)
        }
    }
}

extension View {
    /// Liquid Glass for a floating panel full of text, solid under Reduce Transparency.
    func glassPanel(radius: CGFloat = Theme.Radius.sheet, fallbackShadow: Theme.Shadow = .sheet, wash: Bool = true) -> some View {
        modifier(GlassPanel(radius: radius, fallbackShadow: fallbackShadow, wash: wash))
    }
    /// Liquid Glass for a small control, solid under Reduce Transparency.
    func glassControl(radius: CGFloat = Theme.Radius.row, active: Bool = false) -> some View {
        modifier(GlassControl(radius: radius, active: active))
    }
}

/// The fade behind something floating along the bottom of a page: from clear to the card's colour.
struct ContentFade: View {
    var edge: VerticalEdge = .bottom
    var height: CGFloat = 76
    var strength: Double = 0.88
    var body: some View {
        LinearGradient(stops: [
            .init(color: Theme.Palette.fadeEnd.opacity(0), location: 0),
            .init(color: Theme.Palette.fadeEnd.opacity(strength * 0.6), location: 0.55),
            .init(color: Theme.Palette.fadeEnd.opacity(strength), location: 1),
        ], startPoint: edge == .bottom ? .top : .bottom, endPoint: edge == .bottom ? .bottom : .top)
        .frame(height: height)
        .allowsHitTesting(false)
    }
}

extension View {
    /// Blur, neutral wash, hairline and soft shadow, for things floating over a page.
    func floatingSurface(radius: CGFloat = Theme.Radius.chip, hovering: Bool = false) -> some View {
        modifier(FloatingSurface(radius: radius, hovering: hovering))
    }
    /// An opaque popover with a deeper shadow.
    func popoverSurface(radius: CGFloat = Theme.Radius.popover) -> some View {
        modifier(PopoverSurface(radius: radius))
    }
}

/// The grain, tiled over whatever it sits on. Blended as overlay, so it adds texture without
/// shifting the colour underneath.
struct GrainOverlay: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Image(nsImage: Theme.Material.grain)
            .resizable(resizingMode: .tile)
            .blendMode(.overlay)
            .opacity(scheme == .dark ? Theme.Material.grainOpacity.dark : Theme.Material.grainOpacity.light)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
