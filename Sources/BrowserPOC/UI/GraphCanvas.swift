import AppKit
import MetalKit
import SwiftUI

/// The Metal view a graph draws into. It has its own camera, draws at the display's full rate
/// (120 Hz on ProMotion) while anything moves, and pauses when nothing does.
final class GraphMetalView: MTKView {
    let controller: GraphController
    let state: GraphViewState
    private var tracking: NSTrackingArea?

    init(controller: GraphController, id: UUID) {
        self.controller = controller
        state = MainActor.assumeIsolated { GraphViewState(id: id) }
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        colorPixelFormat = GraphRenderer.pixelFormat
        colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        preferredFramesPerSecond = 120
        enableSetNeedsDisplay = false
        isPaused = false
        framebufferOnly = true
        autoResizeDrawable = true
        layer?.isOpaque = true
        allowedTouchTypes = [.indirect]
    }

    required init(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if IndexStore.debug || GraphMotionScript.isRequested { print("graph view \(state.id.uuidString.prefix(8)) moved to window: \(window != nil)"); fflush(stdout) }
        if let w = window {
            preferredFramesPerSecond = max(60, w.screen?.maximumFramesPerSecond ?? 120)
            controller.attach(self)
        } else {
            controller.detach(self)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        controller.themeChanged(self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        state.size = newSize
        controller.wake(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        controller.drawFrame(in: self)
    }

    private var still: NSImageView?

    /// `cacheDisplay` can't read a Metal layer, so offscreen snapshots put a rendered still on top
    /// for as long as `body` runs.
    func withStill(_ body: () -> Void) {
        if let img = controller.renderImage(size: bounds.size, pixelRatio: window?.backingScaleFactor ?? 2,
                                            appearance: effectiveAppearance, state: state) {
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

    override func mouseMoved(with e: NSEvent) { controller.pointerMoved(point(e), in: self) }
    override func mouseExited(with e: NSEvent) { controller.pointerExited(in: self) }
    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        controller.pointerDown(point(e), in: self)
    }
    override func mouseDragged(with e: NSEvent) { controller.pointerDragged(point(e), in: self) }
    override func mouseUp(with e: NSEvent) {
        controller.pointerUp(point(e), modifiers: e.modifierFlags, clickCount: e.clickCount, in: self)
    }
    override func scrollWheel(with e: NSEvent) { controller.scroll(e, at: point(e), in: self) }
    override func magnify(with e: NSEvent) { controller.zoom(by: Float(1 + e.magnification), at: point(e), in: self) }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let i = controller.node(at: point(event), in: self) else { return nil }
        return controller.menu(for: i, in: self)
    }

    override func keyDown(with e: NSEvent) {
        let fast: Float = e.modifierFlags.contains(.shift) ? 4 : 1
        switch e.keyCode {
        case 123: controller.panStep(-60 * fast, 0, in: self)
        case 124: controller.panStep(60 * fast, 0, in: self)
        case 125: controller.panStep(0, 60 * fast, in: self)
        case 126: controller.panStep(0, -60 * fast, in: self)
        case 53: controller.escape(in: self)
        default:
            switch e.charactersIgnoringModifiers {
            case "+", "=": controller.zoomStep(1.3, in: self)
            case "-", "_": controller.zoomStep(1 / 1.3, in: self)
            case "0": controller.fit(in: self)
            default: super.keyDown(with: e)
            }
        }
    }
}

/// SwiftUI wrapper for a graph's Metal view. `occluders` are rects in the view's coordinates
/// that names keep clear of, like the toolbar and the hover card.
struct GraphCanvas: NSViewRepresentable {
    let controller: GraphController
    var id = UUID()
    var occluders: [CGRect] = []

    func makeNSView(context: Context) -> GraphMetalView { GraphMetalView(controller: controller, id: id) }
    func updateNSView(_ v: GraphMetalView, context: Context) {
        if v.state.occluders != occluders {
            v.state.occluders = occluders
            controller.wake(v)
        }
    }
}
