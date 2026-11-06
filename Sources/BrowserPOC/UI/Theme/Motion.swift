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
    /// The command bar rising in for Cmd-T: a short spring with the faintest settle.
    static let barIn = Animation.spring(duration: 0.26, bounce: 0.04)
    /// Leaving is quicker than arriving, like Zen's 0.12 s exits.
    static let barOut = Animation.easeIn(duration: 0.12)
    /// Cmd-L: the bar growing out of the sidebar's address field, and shrinking back into it.
    static let barGrow = Animation.spring(duration: 0.32, bounce: 0)
    static let barShrink = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.2)
    /// The backdrop behind the bar.
    static let scrim = Animation.easeOut(duration: 0.18)
    /// The selected row's highlight gliding to the next row, and the list following it.
    static let selection = Animation.spring(duration: 0.18, bounce: 0)
    /// The bar's height following its results as you type.
    static let barResize = Animation.spring(duration: 0.22, bounce: 0)
    /// Split panes settling into their widths.
    static let split = Animation.spring(duration: 0.28, bounce: 0)
    /// The load progress line.
    static let progress = Animation.easeOut(duration: 0.25)
    /// Related cards arriving, one after another.
    static func card(index: Int) -> Animation {
        Animation.smooth(duration: 0.3).delay(stagger(index))
    }

    // The tokens below came with the Motion plan (notes/plans/2026-11-05-motion.md).

    /// The end of any gesture: a zero-bounce spring to where it lands. Use
    /// `settle(velocity:distance:)` so it starts at the speed the fingers were moving.
    static let settle = Animation.spring(duration: 0.3, bounce: 0)
    /// `settle`, starting at `velocity` points per second toward a target `distance` points away.
    static func settle(velocity: CGFloat, distance: CGFloat) -> Animation {
        guard abs(distance) > 0.5 else { return settle }
        return Animation.interpolatingSpring(duration: 0.3, bounce: 0, initialVelocity: Double(velocity / distance))
    }
    /// A gesture's end under Reduce Motion: a short ease-out with no spring.
    static let reducedSettle = Animation.easeOut(duration: 0.15)
    /// Rows gliding to a new place and icons reordering. The same spring as `expand`.
    static let reorder = expand
    /// Peek shrinking back. Quicker than it opens, and easing in.
    static let peekOut = Animation.easeIn(duration: 0.18)
    /// Peek filling the pane. The same spring as `split`.
    static let peekExpand = split
    /// Cmd-S sliding the sidebar out and back. Quick, because the page's width changes every frame.
    static let sidebarToggle = Animation.spring(duration: 0.2, bounce: 0)
    /// The sidebar's edge snapping between titles and icons. A little slower than Cmd-S, since
    /// the rows change shape on the way, though quicker than Chrome's 350 to 400 ms.
    static let sidebarSnap = Animation.spring(duration: 0.3, bounce: 0)
    /// Compact mode's floating sidebar sliding in on hover, and away again.
    static let reveal = Animation.spring(duration: 0.24, bounce: 0)
    static let conceal = Animation.easeIn(duration: 0.16)
    /// Small floating controls arriving: the find bar, Peek's buttons.
    static let float = Animation.spring(duration: 0.18, bounce: 0)
    /// Content swapping in place: Edit and Preview, a toast's text.
    static let crossfade = Animation.easeInOut(duration: 0.15)

    /// The delay before the `index`th item of a list arrives, `step` apart. Items past `cap`
    /// arrive together, so a long list never keeps you waiting for its last rows.
    static func stagger(_ index: Int, step: TimeInterval = Timing.cardStagger, cap: Int = Timing.staggerCap) -> TimeInterval {
        Double(min(max(index, 0), cap)) * step
    }

    /// The same motion as plain values, for a per-frame driver that steps it itself (the space
    /// strip), since an `Animation` doesn't expose its in-flight value.
    enum Springs {
        static let spaceSwitch = Spring(duration: 0.28, bounce: 0)
        static let settle = Spring(duration: 0.3, bounce: 0)
        /// `reducedSettle` isn't a spring. Step it along this curve over this long.
        static let reducedSettleCurve = UnitCurve.easeOut
        static let reducedSettleDuration: TimeInterval = 0.15
    }

    /// Delays that decide when motion starts, in seconds.
    enum Timing {
        /// Compact mode: the pointer rests at the edge this long before the sidebar slides in.
        static let revealDwell: TimeInterval = 0.15
        /// Compact mode: the sidebar slides away this long after the pointer leaves it.
        static let concealDelay: TimeInterval = 0.3
        /// A load still running this long after it starts shows its progress line.
        static let progressDelay: TimeInterval = 0.15
        /// The Ctrl-Tab switcher shows if Ctrl is still held this long later.
        static let switcherDelay: TimeInterval = 0.12
        /// Holding a dragged tab over the page this long offers a split.
        static let holdToSplit: TimeInterval = 0.5
        /// Hovering a dragged row over a closed folder this long opens it.
        static let springLoad: TimeInterval = 0.6
        /// The media row stays this long after playback stops, so a pause between tracks doesn't flicker it.
        static let mediaLinger: TimeInterval = 2.0
        /// Related cards and shelf pills arrive this far apart. One value, so the two never drift.
        static let cardStagger: TimeInterval = 0.04
        /// Clear Today's rows leave this far apart.
        static let rowStagger: TimeInterval = 0.02
        /// Items past this many in a list arrive together.
        static let staggerCap = 6
    }

    /// True while nothing should animate: during a live window resize and under the launch cover.
    /// `animation`, `run`, `.motion` and the transitions below all turn into cuts while it's set.
    nonisolated(unsafe) static var suppressed = false

    /// The fade used instead of movement under Reduce Motion.
    static let reducedFade = Animation.easeInOut(duration: 0.12)

    /// `a`, or what to use instead under Reduce Motion. `fadeOnly` animations (opacity changes
    /// with no movement) keep a short fade; triggered movement is dropped entirely.
    ///
    /// Gestures are the exception, as Apple's HIG allows. Anything under the fingers (the space
    /// swipe, a drag) sets its values directly with no animation, and keeps doing so under Reduce
    /// Motion. Pass `tracked` for the movement that finishes such a gesture: under Reduce Motion
    /// it becomes `reducedSettle` rather than a cut, since the content is already moving.
    static func animation(_ a: Animation, reduce: Bool = reduceMotion, fadeOnly: Bool = false, tracked: Bool = false) -> Animation? {
        if suppressed { return nil }
        guard reduce else { return a }
        if tracked { return reducedSettle }
        return fadeOnly ? reducedFade : nil
    }

    /// The settle at the end of a gesture that followed the fingers, or nil while motion is suppressed.
    static func gestureEnd(velocity: CGFloat, distance: CGFloat, reduce: Bool = reduceMotion) -> Animation? {
        animation(settle(velocity: velocity, distance: distance), reduce: reduce, tracked: true)
    }

    /// Runs `body` with animation `a`, or without movement under Reduce Motion.
    @MainActor
    static func run(_ a: Animation, fadeOnly: Bool = false, tracked: Bool = false, _ body: () -> Void) {
        if let anim = animation(a, fadeOnly: fadeOnly, tracked: tracked) { withAnimation(anim, body) } else { body() }
    }

    // MARK: Transitions

    enum Transitions {
        /// Rows arriving and leaving: a fade and a slight scale from the top, like Zen's 0.95 to 1.
        static var tabRow: AnyTransition {
            if Motion.suppressed { return .identity }
            if Motion.reduceMotion { return .opacity }
            return .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)).animation(Motion.insert),
                removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)).animation(Motion.remove))
        }
        /// A folder's contents sliding out from under the folder row as it opens, and back in as it
        /// closes. Put it inside `FolderReveal` so the slide is clipped to the folder's own space.
        static var folderContents: AnyTransition {
            if Motion.suppressed { return .identity }
            if Motion.reduceMotion { return .opacity }
            return .move(edge: .top).combined(with: .opacity)
        }
        /// A Related card arriving, `index` places in the list, so cards come in one after another.
        /// Cards leave at once, so a replaced list never overlaps the new one.
        static func card(index: Int) -> AnyTransition {
            if Motion.suppressed { return .identity }
            if Motion.reduceMotion { return .asymmetric(insertion: .opacity.animation(Motion.reducedFade), removal: .identity) }
            return .asymmetric(insertion: .opacity.combined(with: .offset(y: 6)).animation(Motion.card(index: index)),
                               removal: .identity)
        }
        /// The command bar for Cmd-T: it rises 10 pt from just below where it rests and grows from
        /// 97 percent, and leaves with a small shrink and a fade.
        static var commandBar: AnyTransition {
            if Motion.suppressed { return .identity }
            if Motion.reduceMotion { return .opacity.animation(Motion.reducedFade) }
            return .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .center)).combined(with: .offset(y: 10)).animation(Motion.barIn),
                removal: .opacity.combined(with: .scale(scale: 0.985, anchor: .center)).animation(Motion.barOut))
        }
        /// The sidebar list when you move between spaces. `step` is +1 moving right, -1 moving left.
        /// Like Zen, the new space's list slides in a whole page from the side you're moving
        /// toward. The old one fades out quickly where it is instead of sliding too, so two lists
        /// never sit on top of each other and the direction is always right.
        static func spaceSlide(_ step: Int) -> AnyTransition {
            if Motion.suppressed { return .identity }
            if Motion.reduceMotion || step == 0 { return .opacity }
            return .asymmetric(insertion: .move(edge: step > 0 ? .trailing : .leading).combined(with: .opacity),
                               removal: .opacity.animation(.easeOut(duration: 0.1)))
        }
        /// A side panel sliding in from its edge.
        static func panel(edge: Edge) -> AnyTransition {
            if Motion.suppressed { return .identity }
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
