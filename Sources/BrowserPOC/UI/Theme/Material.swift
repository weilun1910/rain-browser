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
