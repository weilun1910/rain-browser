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
        }

        // MARK: Raw values, light then dark

        /// The window frame behind the sidebar and around the content card. Pure neutral grey.
        static let frameLight = RGB(white: 0.929)   // #EDEDED
        static let frameDark = RGB(white: 0.082)    // #151515
        /// The content card: what a page or note sits on.
        static let cardLight = RGB(white: 1)
        static let cardDark = RGB(white: 0.118)     // #1E1E1E
        /// Floating sheets like the command bar and the first run panel.
        static let sheetLight = RGB(white: 0.995)
        static let sheetDark = RGB(white: 0.145)    // #252525, lighter than the card so it lifts off it

        /// How strongly the space colour washes the sidebar side of the frame.
        static func tintAlpha(dark: Bool, active: Bool = true) -> Double {
            (dark ? 0.085 : 0.14) * (active ? 1 : 0.55)
        }
        /// The wash fades to this share of its strength at the window's trailing edge.
        static let tintTrailingShare = 0.2

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
        static let hairline = Color(nsColor: dynamic(NSColor(white: 0, alpha: 0.07), NSColor(white: 1, alpha: 0.08)))
        /// The selected sidebar row: a near-white chip, like Arc and Zen.
        static let rowSelected = Color(nsColor: dynamic(NSColor(white: 1, alpha: 0.85), NSColor(white: 1, alpha: 0.10)))
        static let rowHover = Color(nsColor: dynamic(NSColor(white: 0, alpha: 0.045), NSColor(white: 1, alpha: 0.055)))
        static let rowPressed = Color(nsColor: dynamic(NSColor(white: 0, alpha: 0.08), NSColor(white: 1, alpha: 0.09)))
        /// Behind the command bar.
        static let scrim = Color(nsColor: dynamic(NSColor(white: 0, alpha: 0.10), NSColor(white: 0, alpha: 0.32)))
        /// Fill for a quiet field, like the address in the sidebar.
        static let field = Color(nsColor: dynamic(NSColor(white: 0, alpha: 0.045), NSColor(white: 1, alpha: 0.06)))
        static let fieldHover = Color(nsColor: dynamic(NSColor(white: 0, alpha: 0.07), NSColor(white: 1, alpha: 0.085)))

        /// Grey used when a space has no colour, matching the first palette entry.
        static let defaultTintHex = "#7A8CA8"

        /// The space colour as a SwiftUI colour.
        static func tint(_ hex: String?) -> Color { Color(nsColor: RGB(hex: hex ?? defaultTintHex).ns) }

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
