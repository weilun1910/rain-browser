import AppKit
import SwiftUI

/// The main window's chrome: no visible title bar, the traffic lights in the sidebar's top row,
/// and the neutral frame colour behind everything.
@MainActor
enum WindowChrome {
    /// An empty toolbar in the compact unified style makes the title bar 40 pt tall and puts the
    /// traffic lights at 12, 13, centred on the sidebar's 40 pt top row. Clicks under the empty
    /// toolbar still reach our views, so the sidebar's buttons there keep working.
    static func configure(_ w: NSWindow) {
        w.styleMask.insert(.fullSizeContentView)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        let bar = NSToolbar(identifier: "BrowserPOC.chrome")
        bar.showsBaselineSeparator = false
        bar.allowsUserCustomization = false
        bar.displayMode = .iconOnly
        w.toolbar = bar
        w.toolbarStyle = .unifiedCompact
        w.titlebarSeparatorStyle = .none
        w.backgroundColor = Theme.Palette.frameNS
        w.isOpaque = true
    }

    /// Whether the traffic lights rest as grey dots until you hover them, like Zen on macOS.
    nonisolated(unsafe) static var quietTrafficLights = true

    /// Puts the grey dots over the traffic lights. Call once the window has its toolbar.
    static func installQuietTrafficLights(_ w: NSWindow) {
        guard quietTrafficLights, let close = w.standardWindowButton(.closeButton), let bar = close.superview else { return }
        if bar.subviews.contains(where: { $0 is QuietTrafficLights }) { return }
        let v = QuietTrafficLights(frame: .zero)
        bar.addSubview(v, positioned: .below, relativeTo: close)
        v.attach(to: w)
    }

    /// Hides the quiet dots along with the buttons, for compact mode.
    static func setTrafficLightsHidden(_ w: NSWindow, _ hidden: Bool) {
        guard let bar = w.standardWindowButton(.closeButton)?.superview else { return }
        for v in bar.subviews where v is QuietTrafficLights { v.isHidden = hidden }
    }

    /// A debug build run straight from `.build` has no bundle icon, so draw one for the Dock.
    static func setDockIconIfUnbundled() {
        guard Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") == nil else { return }
        let r = ImageRenderer(content: AppIconArt(size: 512))
        r.scale = 1
        if let img = r.nsImage { NSApp.applicationIconImage = img }
    }

    /// The About panel: Rain, its icon and one line about what this build is.
    static func showAbout() {
        let r = ImageRenderer(content: AppIconArt(size: 256))
        r.scale = 2
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: Wordmark.name,
            .credits: NSAttributedString(string: "A proof of concept for a Mac browser where things you've seen come back when they matter.",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]),
        ]
        if let img = r.nsImage { options[.applicationIcon] = img }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    /// Where the close button sits, for tests and for lining things up.
    static func trafficLightsFrame(_ w: NSWindow) -> NSRect? {
        guard let close = w.standardWindowButton(.closeButton), let zoom = w.standardWindowButton(.zoomButton) else { return nil }
        let a = close.convert(close.bounds, to: nil), b = zoom.convert(zoom.bounds, to: nil)
        return a.union(b)
    }
}

/// Three quiet dots where the traffic lights are. The real buttons sit on top at zero opacity and
/// fade in while the pointer is over them, so they always work but only show colour when you
/// reach for them. The dots never take clicks.
final class QuietTrafficLights: NSView {
    private weak var host: NSWindow?
    private var tracking: NSTrackingArea?
    private var observers: [NSObjectProtocol] = []
    private(set) var revealed = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var buttons: [NSButton] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { host?.standardWindowButton($0) }
    }

    func attach(to w: NSWindow) {
        host = w
        for b in buttons { b.alphaValue = 0 }
        let nc = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didExitFullScreenNotification] {
            observers.append(nc.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sync() }
            })
        }
        sync()
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    /// Follows the buttons wherever AppKit lays them out.
    func sync() {
        let frames = buttons.map { $0.frame }
        guard let first = frames.first else { return }
        frame = frames.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -6, dy: -6)
        if !revealed { for b in buttons { b.alphaValue = 0 } }
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // AppKit places the buttons after the toolbar lays out, so check again on the next turn.
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.sync() } }
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill = NSColor.labelColor.withAlphaComponent(effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.24 : 0.18)
        fill.setFill()
        for b in buttons {
            let c = convert(NSPoint(x: b.frame.midX, y: b.frame.midY), from: superview)
            let d: CGFloat = 12
            NSBezierPath(ovalIn: NSRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)).fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { reveal(true) }
    override func mouseExited(with event: NSEvent) { reveal(false) }

    func reveal(_ on: Bool) {
        revealed = on
        let reduce = Motion.reduceMotion
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduce ? 0 : 0.15
            for b in buttons { b.animator().alphaValue = on ? 1 : 0 }
            self.animator().alphaValue = on ? 0 : 1
        }
    }
}
