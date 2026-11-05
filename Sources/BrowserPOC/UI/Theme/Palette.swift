import AppKit
import SwiftUI

/// The design system. Everything visual reads from here so the look can change in one place.
/// See notes/plans/2026-11-04-look-and-feel.md for the reasoning behind each value.
enum Theme {}

extension Theme {
    /// Colours. Every one resolves for light and dark from the view's appearance, so they follow
    /// the system setting. Backgrounds are neutral grey. The only colour in the chrome is the
    /// space's tint, laid over the frame by `SpaceTintBackground`.
    enum Palette {
        /// An sRGB colour with its parts kept around, so tests can check contrast.
        struct RGB: Equatable {
            var r: Double, g: Double, b: Double
            init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
            init(white w: Double) { self.init(w, w, w) }
            init(hex: String) {
                var v: UInt64 = 0
                Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&v)
                self.init(Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
            }
            var ns: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
            /// This colour with `top` laid over it at `alpha`.
            func under(_ top: RGB, alpha a: Double) -> RGB {
                RGB(r * (1 - a) + top.r * a, g * (1 - a) + top.g * a, b * (1 - a) + top.b * a)
            }
            /// WCAG relative luminance.
            var luminance: Double {
                func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
                return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
            }
            static func contrast(_ a: RGB, _ b: RGB) -> Double {
                let la = a.luminance, lb = b.luminance
                return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
            }

            // OKLab, Björn Ottosson's perceptual colour space, so every space colour can be set to
            // the same perceived lightness and strength.
            private static func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            private static func gam(_ c: Double) -> Double { c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055 }

            /// Lightness, chroma and hue in OKLCH.
            var oklch: (l: Double, c: Double, h: Double) {
                let lr = Self.lin(r), lg = Self.lin(g), lb = Self.lin(b)
                let l = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
                let m = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
                let s = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
                let L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
                let A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
                let B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
                return (L, hypot(A, B), atan2(B, A))
            }

            init(oklch L: Double, _ C: Double, _ h: Double) {
                let A = C * cos(h), B = C * sin(h)
                let l = pow(L + 0.3963377774 * A + 0.2158037573 * B, 3)
                let m = pow(L - 0.1055613458 * A - 0.0638541728 * B, 3)
                let s = pow(L - 0.0894841775 * A - 1.2914855480 * B, 3)
                let r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
                let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
                let b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
                self.init(min(1, max(0, Self.gam(r))), min(1, max(0, Self.gam(g))), min(1, max(0, Self.gam(b))))
            }
        }

        // MARK: Raw values, light then dark

        /// The window frame behind the sidebar and around the content card. Pure neutral grey.
        static let frameLight = RGB(white: 0.929)   // #EDEDED
        static let frameDark = RGB(white: 0.071)    // #121212
        /// The content card: what a page or note sits on.
        static let cardLight = RGB(white: 1)
        static let cardDark = RGB(white: 0.125)     // #202020, clearly lighter than the tinted frame
        /// Floating sheets like the command bar and the first run panel.
        static let sheetLight = RGB(white: 0.995)
        static let sheetDark = RGB(white: 0.161)    // #292929, lighter than the card so it lifts off it

        /// The sidebar's colour for a space: the space's hue at a fixed perceived lightness and
        /// strength, so every space colour reads equally calm. A shade darker than the frame in
        /// light mode and a shade lighter in dark mode, always darker than the card.
        /// Dims to half strength when the window isn't key.
        static let sidebarLightness = (light: 0.918, dark: 0.218)
        static let sidebarChroma = (light: 0.030, dark: 0.032)
        static func sidebar(_ hex: String?, dark: Bool, active: Bool = true) -> RGB {
            let c = RGB(hex: hex ?? defaultTintHex).oklch
            let strength = min(1, c.c / 0.09) * (active ? 1 : 0.5)
            return RGB(oklch: dark ? sidebarLightness.dark : sidebarLightness.light,
                       (dark ? sidebarChroma.dark : sidebarChroma.light) * strength, c.h)
        }
        /// How much of the sidebar colour reaches the trailing edge of the window.
        static let tintTrailingShare = 0.18
        /// Kept for callers that blend a colour over the frame themselves: the sidebar colour is
        /// laid on at full strength.
        static func tintAlpha(dark: Bool, active: Bool = true) -> Double { 1 }
        static func wash(_ hex: String?, dark: Bool) -> RGB { sidebar(hex, dark: dark) }

        /// The approximate text colours macOS uses for labels, flattened onto a background.
        static func label(on bg: RGB, dark: Bool, level: Int = 0) -> RGB {
            let alpha: [Double] = dark ? [0.85, 0.55, 0.25] : [0.85, 0.50, 0.26]
            return bg.under(RGB(white: dark ? 1 : 0), alpha: alpha[min(level, 2)])
        }

        // MARK: Colours for views

        static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
            NSColor(name: nil) { a in a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
        }
        static func dynamic(_ light: RGB, _ dark: RGB) -> NSColor { dynamic(light.ns, dark.ns) }

        static let frameNS = dynamic(frameLight, frameDark)
        static let frame = Color(nsColor: frameNS)
        static let card = Color(nsColor: dynamic(cardLight, cardDark))
        static let sheet = Color(nsColor: dynamic(sheetLight, sheetDark))
        /// Cards in the right panel: neutral, a little lifted off the frame.
        static let raised = Color(nsColor: dynamic(NSColor(white: 1, alpha: 0.80), NSColor(white: 1, alpha: 0.055)))
        static let raisedHover = Color(nsColor: dynamic(NSColor(white: 1, alpha: 0.96), NSColor(white: 1, alpha: 0.085)))
        /// A thin line where an edge needs one.
        static let hairline = Color(nsColor: dynamic(NSColor(white: 0, alpha: 0.07), NSColor(white: 1, alpha: 0.09)))
        /// The selected sidebar row: a near-white chip, like Arc and Zen.
        static let rowSelected = Color(nsColor: dynamic(NSColor(white: 1, alpha: 1), NSColor(white: 1, alpha: 0.115)))
        static let rowHover = Color(nsColor: dynamic(NSColor(white: 0, alpha: 0.045), NSColor(white: 1, alpha: 0.055)))
        static let rowPressed = Color(nsColor: dynamic(NSColor(white: 0, alpha: 0.08), NSColor(white: 1, alpha: 0.09)))
        /// Behind the command bar.
        static let scrim = Color(nsColor: dynamic(NSColor(white: 0, alpha: 0.10), NSColor(white: 0, alpha: 0.32)))
        /// Fill for a quiet field, like the address in the sidebar.
        static let field = Color(nsColor: dynamic(NSColor(white: 0, alpha: 0.045), NSColor(white: 1, alpha: 0.06)))
        static let fieldHover = Color(nsColor: dynamic(NSColor(white: 0, alpha: 0.07), NSColor(white: 1, alpha: 0.085)))

        /// Grey used when a space has no colour, matching the first palette entry.
        static let defaultTintHex = "#7A8CA8"

        /// The space colour as a wash, for backgrounds. Darkened in dark mode, see `wash`.
        static func tint(_ hex: String?) -> Color {
            let c = RGB(hex: hex ?? defaultTintHex)
            return Color(nsColor: dynamic(c, c.under(RGB(white: 0), alpha: 0.25)))
        }
        /// The sidebar colour for a space, as a SwiftUI colour that follows light and dark.
        static func sidebarColor(_ hex: String?, active: Bool = true) -> Color {
            Color(nsColor: dynamic(sidebar(hex, dark: false, active: active), sidebar(hex, dark: true, active: active)))
        }

        /// The space colour toned for small marks (icons, rings, progress) so it holds up on both
        /// light and dark grounds. Darker in light mode, lighter in dark mode.
        static func accent(_ hex: String?) -> Color {
            let c = RGB(hex: hex ?? defaultTintHex)
            let light = c.under(RGB(white: 0), alpha: 0.18)
            let dark = c.under(RGB(white: 1), alpha: 0.12)
            return Color(nsColor: dynamic(light, dark))
        }
    }
}
