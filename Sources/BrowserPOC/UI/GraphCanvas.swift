import AppKit
import MetalKit
import SwiftUI

/// The Metal view a graph draws into. It only redraws while something moves, and passes the
/// pointer, scroll, pinch and keys to its controller.
final class GraphMetalView: MTKView {
    let controller: GraphController
    private var tracking: NSTrackingArea?

    init(controller: GraphController) {
        self.controller = controller
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        colorPixelFormat = GraphRenderer.pixelFormat
        colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        preferredFramesPerSecond = 60
        enableSetNeedsDisplay = false
        isPaused = false
        framebufferOnly = true
        autoResizeDrawable = true
        layer?.isOpaque = true
    }

    required init(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { MainActor.assumeIsolated { controller.attach(self) } }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        MainActor.assumeIsolated { controller.themeChanged() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        MainActor.assumeIsolated { controller.wake() }
    }

    override func draw(_ dirtyRect: NSRect) {
        controller.drawFrame(in: self)
    }

    private var still: NSImageView?

    /// `cacheDisplay` can't read a Metal layer, so offscreen snapshots put a rendered still on top
    /// for as long as `body` runs.
    func withStill(_ body: () -> Void) {
        if let img = controller.renderImage(size: bounds.size, pixelRatio: window?.backingScaleFactor ?? 2, appearance: effectiveAppearance) {
            let iv = NSImageView(frame: bounds)
            iv.image = NSImage(cgImage: img, size: bounds.size)
            iv.imageScaling = .scaleAxesIndependently
            addSubview(iv)
            still = iv
        }
        body()
        still?.removeFromSuperview()
        still = nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    override func mouseMoved(with e: NSEvent) { MainActor.assumeIsolated { controller.pointerMoved(point(e)) } }
    override func mouseExited(with e: NSEvent) { MainActor.assumeIsolated { controller.pointerExited() } }
    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        MainActor.assumeIsolated { controller.pointerDown(point(e)) }
    }
    override func mouseDragged(with e: NSEvent) { MainActor.assumeIsolated { controller.pointerDragged(point(e)) } }
    override func mouseUp(with e: NSEvent) { MainActor.assumeIsolated { controller.pointerUp(point(e), modifiers: e.modifierFlags) } }
    override func scrollWheel(with e: NSEvent) { MainActor.assumeIsolated { controller.scroll(e, at: point(e)) } }
    override func magnify(with e: NSEvent) {
        MainActor.assumeIsolated { controller.zoom(by: Float(1 + e.magnification), at: point(e)) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let i = controller.node(at: point(event)) else { return nil }
        return controller.menu(for: i)
    }

    override func keyDown(with e: NSEvent) {
        let handled: Bool = MainActor.assumeIsolated {
            let fast: Float = e.modifierFlags.contains(.shift) ? 4 : 1
            switch e.keyCode {
            case 123: controller.pan(-40 * fast, 0)
            case 124: controller.pan(40 * fast, 0)
            case 125: controller.pan(0, 40 * fast)
            case 126: controller.pan(0, -40 * fast)
            case 53:
                if controller.focusID != nil { controller.focusID = nil } else { controller.fit() }
            default:
                switch e.charactersIgnoringModifiers {
                case "+", "=": controller.zoom(by: 1.25, at: controller.viewMiddle)
                case "-", "_": controller.zoom(by: 0.8, at: controller.viewMiddle)
                case "0": controller.fit()
                default: return false
                }
            }
            return true
        }
        if !handled { super.keyDown(with: e) }
    }
}

/// SwiftUI wrapper for a graph's Metal view.
struct GraphCanvas: NSViewRepresentable {
    let controller: GraphController

    func makeNSView(context: Context) -> GraphMetalView { GraphMetalView(controller: controller) }
    func updateNSView(_ v: GraphMetalView, context: Context) {}
}
