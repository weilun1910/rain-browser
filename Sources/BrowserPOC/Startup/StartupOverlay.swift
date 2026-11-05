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
        /// How far the mark sits below its resting place, in points. It rises as it draws.
        var markRise: Double
        /// The wordmark's opacity, and how far it sits below its resting place.
        var word: Double
        var wordRise: Double
        var cover: Double
    }

    // The stroke goes down quickly from the tail and slows into the curl, like a brush. The dot
    // lands last. Then the name settles in, and everything fades into the window.
    static let drawStart = 0.04, drawEnd = 0.56
    static let dotStart = 0.50, dotEnd = 0.74
    static let wordStart = 0.60, wordEnd = 0.86
    static let exitStart = 0.92, markGone = 1.16, coverGone = 1.28
    static var duration: Double { coverGone }

    static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    static func progress(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp((t - a) / (b - a)) }
    static func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
    static func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    static func easeIn(_ x: Double) -> Double { x * x }

    /// A CSS-style cubic bezier timing curve through (0, 0), (x1, y1), (x2, y2) and (1, 1).
    static func bezier(_ x: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        func coord(_ t: Double, _ a: Double, _ b: Double) -> Double {
            3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t
        }
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        var lo = 0.0, hi = 1.0, t = x
        for _ in 0..<28 {
            t = (lo + hi) / 2
            if coord(t, x1, x2) < x { lo = t } else { hi = t }
        }
        return coord(t, y1, y2)
    }

    /// Fast start, long soft landing: the brush curve for the stroke.
    static func brush(_ x: Double) -> Double { bezier(x, 0.32, 0.0, 0.12, 1.0) }

    static func frame(at t: Double) -> Frame {
        let draw = brush(progress(t, drawStart, drawEnd))
        let dot = easeOut(progress(t, dotStart, dotEnd))
        let grow = easeOut(progress(t, drawStart, dotEnd))
        let word = easeOut(progress(t, wordStart, wordEnd))
        let leave = easeIn(progress(t, exitStart, markGone))
        let cover = 1 - easeInOut(progress(t, exitStart, coverGone))
        return Frame(draw: draw, dot: dot,
                     markScale: 0.96 + 0.04 * grow + 0.015 * leave,
                     markOpacity: 1 - leave,
                     markBlur: 1.5 * leave,
                     markRise: 4 * (1 - grow),
                     word: word * (1 - leave),
                     wordRise: 4 * (1 - word),
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
            VStack(spacing: size * 0.3) {
                BrandMark(draw: frame.draw, dot: frame.dot, weight: 0.06, color: .primary, opacity: 0.9)
                    .frame(width: size, height: size)
                    .scaleEffect(frame.markScale)
                    .offset(y: frame.markRise)
                    .opacity(frame.markOpacity)
                Wordmark(size: size * 0.27)
                    .offset(y: frame.wordRise)
                    .opacity(frame.word)
            }
            .blur(radius: frame.markBlur)
            // Keeps the mark itself centred; the name hangs below it.
            .offset(y: size * 0.2)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
