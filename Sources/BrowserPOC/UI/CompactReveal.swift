import SwiftUI

/// Compact mode's floating sidebar (notes/plans/2026-11-05-motion.md, section 5). The pointer has
/// to rest at the window's edge for a moment before it slides in, so passing the edge on the way
/// to the Dock doesn't flash it, and it slides away a moment after the pointer leaves it.
@MainActor
final class CompactReveal: ObservableObject {
    static let shared = CompactReveal()

    @Published private(set) var showing = false
    private var work: DispatchWorkItem?

    /// The pointer reached the edge strip.
    func pointerAtEdge() { schedule(after: Motion.Timing.revealDwell) { self.show() } }

    /// The pointer left the edge strip before the sidebar came.
    func pointerLeftEdge() { if !showing { work?.cancel() } }

    /// The pointer is over the sidebar itself.
    func pointerInside() {
        work?.cancel()
        if !showing { show() }
    }

    /// The pointer left the sidebar.
    func pointerLeft() {
        if Self.holdForShots { return }
        schedule(after: Motion.Timing.concealDelay) { self.hide() }
    }

    /// Offscreen snapshots keep the sidebar up, since nothing there is under a pointer.
    nonisolated(unsafe) static var holdForShots = false

    func show() {
        work?.cancel()
        guard !showing else { return }
        Motion.run(Motion.reveal) { showing = true }
    }

    func hide() {
        work?.cancel()
        guard showing else { return }
        Motion.run(Motion.conceal) { showing = false }
    }

    /// The sidebar came back for good (Cmd-S), so the floating one isn't waiting to show next time.
    func reset() {
        work?.cancel()
        showing = false
    }

    private func schedule(after delay: TimeInterval, _ f: @escaping @MainActor () -> Void) {
        work?.cancel()
        let w = DispatchWorkItem { MainActor.assumeIsolated { f() } }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }
}

extension Motion.Transitions {
    /// A sidebar sliding in from its edge with no fade, the way Arc and Zen move it. Under Reduce
    /// Motion it fades instead.
    static func sidebar(edge: Edge) -> AnyTransition {
        if Motion.suppressed { return .identity }
        if Motion.reduceMotion { return .opacity }
        return .move(edge: edge)
    }
}
