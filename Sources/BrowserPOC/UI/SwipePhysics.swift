import AppKit

// The space swipe's rules, as plain values and pure functions so the self test can feed them
// recorded and made-up gestures. The numbers come from the motion plan
// (notes/plans/2026-11-05-motion.md), which takes them from WebKit, Firefox, Zen and Apple.

enum SwipeTuning {
    /// Horizontal travel before the swipe takes the gesture, in points.
    static let claim: CGFloat = 10
    /// The horizontal travel has to be at least this many times the vertical to claim.
    static let axisRatio: CGFloat = 2
    /// Vertical travel that hands the gesture to the tab list's scrolling, if it leads first.
    static let verticalClaim: CGFloat = 8
    /// How stiff the rubber band is past the first and last space (Apple's 0.55).
    static let rubberBand: Double = 0.55
    /// Commit to the next space when progress plus the projected travel reaches this much of a page.
    static let commit: Double = 0.35
    /// How far ahead the release velocity is projected, in seconds.
    static let projection: Double = 0.2
    /// Fingers moving back faster than this at release cancel the swipe, in points per second.
    static let backCancel: Double = 150
    /// The release velocity is measured over this last stretch of the gesture, in seconds.
    static let velocityWindow: TimeInterval = 0.06
    /// A mouse wheel moves one space per notch group, this far apart.
    static let wheelCooldown: TimeInterval = 0.2
}

/// One scroll event, reduced to what the swipe needs. `dx` and `dy` are the fingers' own
/// movement (positive is right and down), whatever the scroll direction setting is.
struct SwipeSample: Equatable {
    enum Phase: Equatable { case mayBegin, began, changed, ended, cancelled, none }
    var dx: CGFloat
    var dy: CGFloat
    var phase: Phase
    /// A momentum event, sent after the fingers lift.
    var momentum = false
    /// The last momentum event.
    var momentumEnded = false
    /// Trackpad and Magic Mouse deltas in points. A mouse wheel's are lines.
    var precise = true
    var time: TimeInterval

    init(dx: CGFloat, dy: CGFloat = 0, phase: Phase, momentum: Bool = false, momentumEnded: Bool = false,
         precise: Bool = true, time: TimeInterval) {
        self.dx = dx; self.dy = dy; self.phase = phase; self.momentum = momentum
        self.momentumEnded = momentumEnded; self.precise = precise; self.time = time
    }

    init(_ e: NSEvent) {
        // With natural scrolling the deltas already follow the fingers. Without it they're flipped.
        let s: CGFloat = e.isDirectionInvertedFromDevice ? 1 : -1
        dx = e.scrollingDeltaX * s
        dy = e.scrollingDeltaY * s
        precise = e.hasPreciseScrollingDeltas
        time = e.timestamp
        momentum = !e.momentumPhase.isEmpty
        momentumEnded = e.momentumPhase.contains(.ended) || e.momentumPhase.contains(.cancelled)
        let p = e.phase
        if p.contains(.began) { phase = .began }
        else if p.contains(.changed) { phase = .changed }
        else if p.contains(.ended) { phase = .ended }
        else if p.contains(.cancelled) { phase = .cancelled }
        else if p.contains(.mayBegin) { phase = .mayBegin }
        else { phase = .none }
    }
}

/// Follows one two-finger gesture and decides whether it's a space swipe. Feed it every scroll
/// event; it says whether to let the event through and what the strip should do.
struct SwipeGesture {
    enum State: Equatable { case idle, deciding, tracking, passing, finishing }
    enum Action: Equatable {
        case none
        /// The gesture is now a swipe, `offset` points of finger travel in.
        case began(offset: CGFloat)
        case moved(offset: CGFloat)
        /// The fingers lifted. `velocity` is in points per second, positive to the right.
        case ended(offset: CGFloat, velocity: CGFloat)
    }

    private(set) var state: State = .idle
    private var sumX: CGFloat = 0
    private var sumY: CGFloat = 0
    private(set) var offset: CGFloat = 0
    private var recent: [(t: TimeInterval, dx: CGFloat)] = []

    /// `inside` is whether the pointer is over the sidebar. It only matters when a gesture begins.
    /// Returns true in `swallow` for events that belong to the swipe and must not scroll anything.
    mutating func feed(_ s: SwipeSample, inside: Bool) -> (swallow: Bool, action: Action) {
        if s.momentum {
            // Momentum never starts a swipe. After one, it's swallowed so the tab list stays put.
            guard state == .finishing || state == .tracking else { return (false, .none) }
            if s.momentumEnded { state = .idle }
            return (true, .none)
        }
        switch s.phase {
        case .mayBegin:
            if state == .finishing { state = .idle }
            return (false, .none)
        case .began:
            sumX = 0; sumY = 0; offset = 0; recent = []
            state = inside && s.precise ? .deciding : .passing
            return feedChange(s)
        case .changed:
            return feedChange(s)
        case .ended, .cancelled:
            if state == .tracking {
                state = .finishing
                let v = s.phase == .cancelled ? 0 : velocity(at: s.time)
                return (true, .ended(offset: offset, velocity: v))
            }
            if state != .finishing { state = .idle }
            return (state == .finishing, .none)
        case .none:
            return (false, .none)
        }
    }

    private mutating func feedChange(_ s: SwipeSample) -> (swallow: Bool, action: Action) {
        switch state {
        case .deciding:
            sumX += s.dx; sumY += s.dy
            if abs(sumY) >= SwipeTuning.verticalClaim && abs(sumY) > abs(sumX) {
                state = .passing
                return (false, .none)
            }
            if abs(sumX) >= SwipeTuning.claim && abs(sumX) >= SwipeTuning.axisRatio * abs(sumY) {
                state = .tracking
                // Start from where the claim happened, so the strip doesn't jump by the claim distance.
                offset = sumX - (sumX > 0 ? SwipeTuning.claim : -SwipeTuning.claim)
                recent = [(s.time, s.dx)]
                return (true, .began(offset: offset))
            }
            return (false, .none)
        case .tracking:
            offset += s.dx
            recent.append((s.time, s.dx))
            recent.removeAll { s.time - $0.t > 0.2 }
            return (true, .moved(offset: offset))
        case .finishing:
            return (true, .none)
        case .idle, .passing:
            return (false, .none)
        }
    }

    /// Points per second over the last stretch of the gesture. A pause before lifting reads as 0.
    private func velocity(at t: TimeInterval) -> CGFloat {
        let w = SwipeTuning.velocityWindow
        let travel = recent.filter { t - $0.t <= w }.reduce(0) { $0 + $1.dx }
        return travel / CGFloat(w)
    }
}

enum SwipePhysics {
    /// How far content travels when pulled `x` pages past an end: less and less, never a full page.
    static func rubberBand(_ x: Double) -> Double {
        let c = SwipeTuning.rubberBand
        let ax = abs(x)
        let out = 1 - 1 / (ax * c + 1)
        return x < 0 ? -out : out
    }

    /// `raw`, held between `lo` and `hi` with a rubber band past either end.
    static func banded(_ raw: Double, lo: Double, hi: Double) -> Double {
        if raw < lo { return lo + rubberBand(raw - lo) }
        if raw > hi { return hi + rubberBand(raw - hi) }
        return raw
    }

    /// Where a released swipe lands. Positions are in pages, increasing toward later spaces.
    /// `velocity` is in pages per second. `start` is the page the swipe began on; it lands on
    /// `start` or one page either side, if that page exists (`lo...hi`).
    static func landing(start: Int, position: Double, velocity: Double, width: CGFloat, lo: Int, hi: Int) -> Int {
        let projected = position + SwipeTuning.projection * velocity
        let delta = projected - Double(start)
        guard abs(delta) >= SwipeTuning.commit else { return start }
        let dir = delta > 0 ? 1 : -1
        let target = start + dir
        guard target >= lo && target <= hi else { return start }
        // Fingers moving back at release mean "never mind", however far they went.
        let backward = velocity * Double(dir) < 0 && abs(velocity) * Double(width) > SwipeTuning.backCancel
        return backward ? start : target
    }
}
