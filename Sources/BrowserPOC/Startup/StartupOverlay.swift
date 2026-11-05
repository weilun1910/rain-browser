import AppKit
import SwiftUI

/// The launch animation: the mark draws on in the middle of the window, then the cover fades and
/// the app is there. About a second long. The window restores behind it and the cover never takes
/// clicks, so it never blocks anything. It's skipped under Reduce Motion and never runs in tests.
enum StartupTimeline {
    struct Frame: Equatable {
        var draw: Double
        var dot: Double
        var markScale: Double
        var markOpacity: Double
        var markBlur: Double
        var cover: Double
    }

    static let drawStart = 0.06, drawEnd = 0.62
    static let dotStart = 0.50, dotEnd = 0.78
    static let exitStart = 0.80, markGone = 1.04, coverGone = 1.15
    static var duration: Double { coverGone }

    static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    static func progress(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp((t - a) / (b - a)) }
    static func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
    static func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    static func easeIn(_ x: Double) -> Double { x * x }

    static func frame(at t: Double) -> Frame {
        let draw = easeInOut(progress(t, drawStart, drawEnd))
        let dot = easeOut(progress(t, dotStart, dotEnd))
        let grow = easeOut(progress(t, drawStart, dotEnd))
        let leave = easeIn(progress(t, exitStart, markGone))
        let cover = 1 - easeInOut(progress(t, exitStart, coverGone))
        return Frame(draw: draw, dot: dot,
                     markScale: 0.94 + 0.06 * grow + 0.02 * leave,
                     markOpacity: 1 - leave,
                     markBlur: 2 * leave,
                     cover: cover)
    }

    /// Whether the startup should play at all.
    static func shouldPlay(reduceMotion: Bool) -> Bool { !reduceMotion }
}

/// Tells the main view when the launch animation is running.
@MainActor
final class Startup: ObservableObject {
    static let shared = Startup()
    @Published private(set) var startedAt: Date?

    /// Called once from the app delegate as the main window opens.
    func begin() {
        guard StartupTimeline.shouldPlay(reduceMotion: Motion.reduceMotion) else { return }
        let now = Date()
        startedAt = now
        DispatchQueue.main.asyncAfter(deadline: .now() + StartupTimeline.duration + 0.05) { [weak self] in
            if self?.startedAt == now { self?.startedAt = nil }
        }
    }
}

/// Sits over the main view while `Startup.shared` is running.
struct StartupOverlayHost: View {
    @ObservedObject var startup = Startup.shared
    var body: some View {
        if let start = startup.startedAt {
            TimelineView(.animation) { ctx in
                StartupOverlay(frame: StartupTimeline.frame(at: ctx.date.timeIntervalSince(start)))
            }
            .allowsHitTesting(false)
            .transition(.identity)
        }
    }
}

/// One frame of the launch animation. Pure, so renders can show any moment of it.
struct StartupOverlay: View {
    let frame: StartupTimeline.Frame
    var size: CGFloat = 68

    var body: some View {
        ZStack {
            Theme.Palette.frame.opacity(frame.cover)
            BrandMark(draw: frame.draw, dot: frame.dot, weight: 0.05, color: .primary, opacity: 0.88)
                .frame(width: size, height: size)
                .scaleEffect(frame.markScale)
                .blur(radius: frame.markBlur)
                .opacity(frame.markOpacity)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
