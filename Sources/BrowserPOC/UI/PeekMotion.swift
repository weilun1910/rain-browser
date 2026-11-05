import AppKit
import SwiftUI

// Peek's choreography (notes/plans/2026-11-05-motion.md, section 3). It grows out of the link you
// clicked, shrinks back into it when it closes, and fills the pane before it becomes a tab, so the
// page never jumps. The model asks here before it closes, expands or splits a Peek: in the app it
// waits for the animation, and everywhere else (the tests) it goes straight on.

@MainActor
final class PeekMotion: ObservableObject {
    static let shared = PeekMotion()

    enum Phase: Equatable { case open, closing, expanding, splitting }

    /// The phase of the Peek showing `tab`. Other tabs are always `.open`.
    @Published private(set) var phase: Phase = .open
    private(set) var tab: UUID?
    private var pending: (() -> Void)?
    private var token = 0

    /// True in the app. Tests and offscreen renders leave it off, so Peek changes at once.
    nonisolated(unsafe) static var live = false

    /// The last mouse-down over the page, in the content area's own coordinates.
    private(set) var lastClick: (point: CGPoint, at: TimeInterval)?

    func recordClick(_ p: CGPoint) { lastClick = (p, ProcessInfo.processInfo.systemUptime) }

    /// Where a Peek opened just now came from: the click that opened it, if there was one.
    var recentClick: CGPoint? {
        guard let c = lastClick, ProcessInfo.processInfo.systemUptime - c.at < 1.0 else { return nil }
        return c.point
    }

    func phase(for id: UUID) -> Phase { tab == id ? phase : .open }

    var isLeaving: Bool { phase != .open }

    /// Plays `phase` for the Peek showing `tab`, then runs `finish`. Returns false if there's
    /// nothing to wait for, and the caller should finish now.
    func play(_ phase: Phase, tab: UUID, duration: TimeInterval, finish: @escaping () -> Void) -> Bool {
        guard Self.live, !Motion.suppressed else { return false }
        if self.tab == tab && self.phase != .open { return true }  // Already on its way out.
        self.tab = tab
        self.phase = phase
        pending = finish
        token += 1
        let t = token
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.token == t else { return }
                self.flush()
            }
        }
        return true
    }

    /// Finishes whatever is playing now, for example before another Peek opens.
    func flush() {
        let f = pending
        pending = nil
        token += 1
        // The change lands with no animation: the overlay goes at once and the page's web view
        // moves straight into its pane. An animated removal would keep the overlay, still holding
        // the web view, on screen at zero opacity, and the pane would stay blank.
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            phase = .open
            tab = nil
            f?()
        }
    }

    /// How long each phase plays. Exits are quicker than entrances.
    static var closeDuration: TimeInterval { Motion.reduceMotion ? 0.12 : 0.18 }
    static var expandDuration: TimeInterval { Motion.reduceMotion ? 0.12 : 0.28 }
}

/// Remembers where the last mouse-down over the content area landed, so a Peek can grow from it.
struct ClickRecorder: NSViewRepresentable {
    final class RecorderView: NSView {
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .otherMouseDown]) { [weak self] e in
                guard let self, e.window === self.window else { return e }
                let p = self.convert(e.locationInWindow, from: nil)
                if self.bounds.contains(p) {
                    let local = CGPoint(x: p.x, y: self.isFlipped ? p.y : self.bounds.height - p.y)
                    MainActor.assumeIsolated { PeekMotion.shared.recordClick(local) }
                }
                return e
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }

    func makeNSView(context: Context) -> RecorderView { RecorderView() }
    func updateNSView(_ v: RecorderView, context: Context) {}
}
