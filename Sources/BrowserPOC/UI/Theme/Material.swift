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
