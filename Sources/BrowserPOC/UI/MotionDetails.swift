import SwiftUI

// The smaller pieces of the motion plan (notes/plans/2026-11-05-motion.md): toasts, the find bar,
// Clear Today and Undo, the load progress line, the Ctrl-Tab switcher's hold, and keeping still
// during a live resize and under the launch cover.

/// Why motion is off right now. `Motion.suppressed` is on while any reason holds.
@MainActor
enum MotionSuppression {
    enum Reason: Hashable { case liveResize, launch }
    private static var reasons: Set<Reason> = []

    static func set(_ r: Reason, _ on: Bool) {
        if on { reasons.insert(r) } else { reasons.remove(r) }
        Motion.suppressed = !reasons.isEmpty
    }

    /// Holds `r` for `seconds`, then lets go.
    static func hold(_ r: Reason, for seconds: TimeInterval) {
        set(r, true)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { set(r, false) } }
    }
}

extension Motion.Transitions {
    /// A toast rising 8 pt into place, and leaving with a fade and a 4 pt drop.
    static var toast: AnyTransition {
        if Motion.suppressed { return .identity }
        if Motion.reduceMotion { return .opacity.animation(Motion.reducedFade) }
        return .asymmetric(insertion: .opacity.combined(with: .offset(y: 8)).animation(Motion.toast),
                           removal: .opacity.combined(with: .offset(y: 4)).animation(Motion.remove))
    }

    /// A small floating control, like the find bar, dropping 4 pt into place and fading out.
    static var float: AnyTransition {
        if Motion.suppressed { return .identity }
        if Motion.reduceMotion { return .opacity.animation(Motion.reducedFade) }
        return .asymmetric(insertion: .opacity.combined(with: .offset(y: -4)).animation(Motion.float),
                           removal: .opacity.animation(Motion.barOut))
    }

    /// A Today row during Clear Today and its Undo: rows leave toward the leading edge and come
    /// back, top to bottom, 20 ms apart. Other times a row comes and goes like any row.
    static func todayRow(index: Int, sweeping: Bool) -> AnyTransition {
        guard sweeping, !Motion.suppressed else { return tabRow }
        if Motion.reduceMotion { return .opacity.animation(Motion.reducedFade) }
        let delay = Motion.stagger(index, step: Motion.Timing.rowStagger, cap: 12)
        return .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)).animation(Motion.insert.delay(delay)),
                           removal: .opacity.combined(with: .offset(x: -12)).animation(Motion.remove.delay(delay)))
    }
}

/// Clear Today and its Undo sweep the rows instead of dropping them all at once.
@MainActor
final class TodaySweep: ObservableObject {
    static let shared = TodaySweep()
    @Published private(set) var sweeping = false

    /// True in the app. Tests leave it off, so Clear Today and Undo happen at once.
    nonisolated(unsafe) static var live = false

    /// Runs `change` a turn after the rows have picked up their sweeping transitions.
    func run(_ change: @escaping @MainActor () -> Void) {
        guard Self.live, !Motion.suppressed else { change(); return }
        sweeping = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                Motion.run(Motion.insert) { change() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { MainActor.assumeIsolated { self.sweeping = false } }
            }
        }
    }
}

/// Shows its content only once it has been there `delay` seconds, fading in. Something removed
/// before then never shows, so a quick Ctrl-Tab flips tabs without flashing the switcher.
struct DelayedAppear: ViewModifier {
    let delay: TimeInterval
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    Motion.run(Animation.easeOut(duration: 0.1), fadeOnly: true) { shown = true }
                }
            }
    }
}

/// The load progress line for a page. A load that finishes within 0.15 s shows nothing. The line
/// never moves backward, and when the load ends it runs to the end before it fades.
struct LoadProgress: View {
    @ObservedObject var tab: Tab
    @State private var shown = false
    @State private var value: Double = 0
    @State private var started: Date?

    var body: some View {
        TintedProgressLine(progress: value, visible: shown)
            .onAppear { if tab.isLoading { begin() } }
            .onChange(of: tab.isLoading) { _, loading in loading ? begin() : finish() }
            .onChange(of: tab.progress) { _, p in if tab.isLoading { value = max(value, p) } }
    }

    private func begin() {
        let now = Date()
        started = now
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { value = tab.progress; shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.Timing.progressDelay) {
            if started == now && tab.isLoading { shown = true }
        }
    }

    private func finish() {
        started = nil
        guard shown else { return }
        value = 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { if started == nil { shown = false } }
    }
}
