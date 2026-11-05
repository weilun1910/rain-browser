import AppKit
import SwiftUI

/// Every animation in the app. Short, mostly zero-bounce springs, each tied to something you did.
/// Under Reduce Motion, movement turns into a short fade or nothing, all decided here.
enum Motion {
    /// Tests set this to check both paths. Nil follows the system setting.
    nonisolated(unsafe) static var forceReduce: Bool?

    static var reduceMotion: Bool {
        forceReduce ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: The animations

    /// Hover backgrounds and revealed controls.
    static let hover = Animation.easeOut(duration: 0.12)
    /// Pressing a button.
    static let press = Animation.easeOut(duration: 0.1)
    /// A tab, note or folder row arriving.
    static let insert = Animation.smooth(duration: 0.2)
    /// A row leaving.
    static let remove = Animation.easeIn(duration: 0.14)
    /// Folders opening and closing.
    static let expand = Animation.spring(duration: 0.26, bounce: 0)
    /// The folder glyph tipping open, on Zen's fast-settling curve, a touch quicker than the rows.
    static let folderGlyph = Animation.timingCurve(0.42, 0, 0, 1, duration: 0.28)
    /// Peek: the page behind settles back and dims on Zen's Glance spring, without bounce.
    static let peek = Animation.spring(duration: 0.32, bounce: 0)
    /// A toast rising in at the bottom of the page and leaving.
    static let toast = Animation.spring(duration: 0.26, bounce: 0)
    /// A site icon arriving in place of its monogram.
    static let favicon = Animation.easeOut(duration: 0.25)
    /// Moving between spaces: the list slides and the tint crossfades on the same spring.
    static let spaceSwitch = Animation.spring(duration: 0.28, bounce: 0)
    /// Side panels showing and hiding. A touch of settle, too small to read as bounce.
    static let panel = Animation.spring(duration: 0.3, bounce: 0.06)
    /// The command bar arriving and leaving.
    static let barIn = Animation.spring(duration: 0.22, bounce: 0)
    static let barOut = Animation.easeIn(duration: 0.12)
    static let scrim = Animation.easeOut(duration: 0.18)
    /// Split panes settling into their widths.
    static let split = Animation.spring(duration: 0.28, bounce: 0)
    /// The load progress line.
    static let progress = Animation.easeOut(duration: 0.25)
    /// Related cards arriving, one after another.
    static func card(index: Int) -> Animation {
        Animation.smooth(duration: 0.3).delay(Double(min(index, 6)) * 0.04)
    }

    /// The fade used instead of movement under Reduce Motion.
    static let reducedFade = Animation.easeInOut(duration: 0.12)

    /// `a`, or what to use instead under Reduce Motion. `fadeOnly` animations (opacity changes
    /// with no movement) keep a short fade; movement is dropped entirely.
    static func animation(_ a: Animation, reduce: Bool = reduceMotion, fadeOnly: Bool = false) -> Animation? {
        guard reduce else { return a }
        return fadeOnly ? reducedFade : nil
    }

    /// Runs `body` with animation `a`, or without movement under Reduce Motion.
    @MainActor
    static func run(_ a: Animation, fadeOnly: Bool = false, _ body: () -> Void) {
        if let anim = animation(a, fadeOnly: fadeOnly) { withAnimation(anim, body) } else { body() }
    }

    // MARK: Transitions

    enum Transitions {
        /// Rows arriving and leaving: a fade and a slight scale from the top, like Zen's 0.95 to 1.
        static var tabRow: AnyTransition {
            if Motion.reduceMotion { return .opacity }
            return .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)).animation(Motion.insert),
                removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)).animation(Motion.remove))
        }
        /// A folder's contents sliding out from under the folder row as it opens, and back in as it
        /// closes. Put it inside `FolderReveal` so the slide is clipped to the folder's own space.
        static var folderContents: AnyTransition {
            if Motion.reduceMotion { return .opacity }
            return .move(edge: .top).combined(with: .opacity)
        }
        /// A Related card arriving, `index` places in the list, so cards come in one after another.
        /// Cards leave at once, so a replaced list never overlaps the new one.
        static func card(index: Int) -> AnyTransition {
            if Motion.reduceMotion { return .asymmetric(insertion: .opacity.animation(Motion.reducedFade), removal: .identity) }
            return .asymmetric(insertion: .opacity.combined(with: .offset(y: 6)).animation(Motion.card(index: index)),
                               removal: .identity)
        }
        /// The command bar.
        static var commandBar: AnyTransition {
            if Motion.reduceMotion { return .opacity }
            return .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .top)).combined(with: .offset(y: -6)).animation(Motion.barIn),
                removal: .opacity.combined(with: .scale(scale: 0.99, anchor: .top)).animation(Motion.barOut))
        }
        /// The sidebar list when you move between spaces. `step` is +1 moving right, -1 moving left.
        /// Like Zen, the new space's list slides in a whole page from the side you're moving
        /// toward. The old one fades out quickly where it is instead of sliding too, so two lists
        /// never sit on top of each other and the direction is always right.
        static func spaceSlide(_ step: Int) -> AnyTransition {
            if Motion.reduceMotion || step == 0 { return .opacity }
            return .asymmetric(insertion: .move(edge: step > 0 ? .trailing : .leading).combined(with: .opacity),
                               removal: .opacity.animation(.easeOut(duration: 0.1)))
        }
        /// A side panel sliding in from its edge.
        static func panel(edge: Edge) -> AnyTransition {
            if Motion.reduceMotion { return .opacity }
            return .move(edge: edge).combined(with: .opacity)
        }
    }
}

/// `.appearEffect`: the view eases in from a slight scale and offset the first time it shows.
/// For things that appear inside an overlay that only fades, like the command bar's card.
struct AppearEffect: ViewModifier {
    let scale: CGFloat
    let y: CGFloat
    let animation: Animation
    @State private var shown = false

    func body(content: Content) -> some View {
        let still = shown || Motion.reduceMotion
        return content
            .scaleEffect(still ? 1 : scale, anchor: .top)
            .offset(y: still ? 0 : y)
            .opacity(still ? 1 : 0)
            .onAppear {
                guard !shown else { return }
                if Motion.reduceMotion { shown = true } else { withAnimation(animation) { shown = true } }
            }
    }
}

extension View {
    func appearEffect(scale: CGFloat = 0.98, y: CGFloat = -6, animation: Animation = Motion.barIn) -> some View {
        modifier(AppearEffect(scale: scale, y: y, animation: animation))
    }

    /// A Related card arriving: it fades and rises 6 pt, `index` places after the first card, the
    /// first time it shows. A card that stays put isn't animated again.
    func cardAppear(index: Int) -> some View {
        modifier(AppearEffect(scale: 1, y: 6, animation: Motion.card(index: index)))
    }
}

/// Remembers the last index it saw, so a view can tell which way a change went (for example,
/// which way to slide when you move to another space). Hold it in `@State`.
final class StepTracker {
    private var last: Int?
    private var lastStep = 1
    /// +1 if `index` is after the last one seen, -1 if before. Repeats the last answer when unchanged.
    func step(for index: Int?) -> Int {
        guard let index else { return lastStep }
        if let l = last, l != index { lastStep = index > l ? 1 : -1 }
        last = index
        return lastStep
    }
}

/// `.motion(_:value:)`: like `.animation(_:value:)`, but honours Reduce Motion.
struct MotionModifier<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    let fadeOnly: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce
    func body(content: Content) -> some View {
        content.animation(Motion.animation(animation, reduce: reduce || Motion.reduceMotion, fadeOnly: fadeOnly), value: value)
    }
}

extension View {
    func motion<V: Equatable>(_ animation: Animation, value: V, fadeOnly: Bool = false) -> some View {
        modifier(MotionModifier(animation: animation, value: value, fadeOnly: fadeOnly))
    }
}
