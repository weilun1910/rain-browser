import AppKit
import CoreText
import Metal

/// Node names drawn once with Core Text into a single-channel texture, then reused every frame.
/// Shelf packing; when the atlas fills up it starts over and the visible names come back on the
/// next frames.
final class LabelAtlas {
    struct Entry {
        /// Normalized x0, y0, x1, y1.
        let uv: SIMD4<Float>
        /// Size in points.
        let size: SIMD2<Float>
    }

    let texture: MTLTexture
    let side: Int
    private(set) var pixelRatio: CGFloat
    private var entries: [String: Entry] = [:]
    private var shelfY = 0
    private var shelfH = 0
    private var cursorX = 0
    private let font: CTFont
    private let maxWidth: CGFloat
    /// New names drawn this frame. Capped so a big zoom-in doesn't stall one frame.
    private var drawnThisFrame = 0
    static let perFrameBudget = 80

    init?(device: MTLDevice, side: Int = 2048, pixelRatio: CGFloat, fontSize: CGFloat, maxWidth: CGFloat) {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: side, height: side, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        texture = t
        self.side = side
        self.pixelRatio = pixelRatio
        font = CTFontCreateWithName(NSFont.systemFont(ofSize: fontSize).fontName as CFString, fontSize, nil)
        self.maxWidth = maxWidth
    }

    func beginFrame(pixelRatio r: CGFloat) {
        drawnThisFrame = 0
        if r != pixelRatio { pixelRatio = r; reset() }
    }

    func reset() {
        entries = [:]
        shelfY = 0; shelfH = 0; cursorX = 0
    }

    static func shorten(_ s: String) -> String {
        let t = Fmt.clean(s).replacingOccurrences(of: "\n", with: " ")
        return t.count > 48 ? String(t.prefix(46)) + "..." : t
    }

    func entry(id: String, text raw: String) -> Entry? {
        if let e = entries[id] { return e }
        guard drawnThisFrame < Self.perFrameBudget else { return nil }
        drawnThisFrame += 1
        let text = Self.shorten(raw)
        let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
        let line = CTLineCreateWithAttributedString(attr)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = min(CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading)), maxWidth)
        let ptW = ceil(width) + 2
        let ptH = ceil(ascent + descent) + 2
        let pw = Int(ceil(ptW * pixelRatio)), ph = Int(ceil(ptH * pixelRatio))
        guard pw > 0, ph > 0, pw < side, ph < side else { return nil }
        if cursorX + pw > side { shelfY += shelfH + 1; shelfH = 0; cursorX = 0 }
        if shelfY + ph > side {
            reset()
            return nil
        }
        var pixels = [UInt8](repeating: 0, count: pw * ph)
        let drew: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.setAllowsFontSmoothing(false)
            ctx.setShouldAntialias(true)
            ctx.scaleBy(x: pixelRatio, y: pixelRatio)
            ctx.textPosition = CGPoint(x: 1, y: descent + 1)
            // Names wider than the limit are cut at the edge.
            ctx.clip(to: CGRect(x: 0, y: 0, width: ptW, height: ptH))
            CTLineDraw(line, ctx)
            return true
        }
        guard drew else { return nil }
        // A bitmap context keeps its top row first in memory, the same order as the texture.
        pixels.withUnsafeBytes { buf in
            texture.replace(region: MTLRegionMake2D(cursorX, shelfY, pw, ph), mipmapLevel: 0, withBytes: buf.baseAddress!, bytesPerRow: pw)
        }
        let s = Float(side)
        let e = Entry(uv: SIMD4(Float(cursorX) / s, Float(shelfY) / s, Float(cursorX + pw) / s, Float(shelfY + ph) / s),
                      size: SIMD2(Float(ptW), Float(ptH)))
        entries[id] = e
        cursorX += pw + 1
        shelfH = max(shelfH, ph)
        return e
    }
}
