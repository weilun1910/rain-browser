import AppKit
import SwiftUI

/// The motion plan's checks (notes/plans/2026-11-05-motion.md): the space swipe's physics on
/// made-up gestures, the strip's driver over time, Reduce Motion, and the dash rule for these files.
enum MotionTests {
    static func check(_ ok: Bool, _ label: String, _ detail: String = "") { SelfTest.check(ok, label, detail) }

    static func run(dir: URL) {
        gesture()
        physics()
        MainActor.assumeIsolated {
            BrowserModel.useEphemeralStore = true
            strip()
            events()
        }
        punctuation()
    }

    // MARK: The gesture

    /// A gesture as samples 8 ms apart: `moves` are the fingers' (dx, dy) per event.
    static func samples(_ moves: [(CGFloat, CGFloat)], start: TimeInterval = 100, end: Bool = true) -> [SwipeSample] {
        var out = [SwipeSample(dx: 0, phase: .mayBegin, time: start)]
        for (i, m) in moves.enumerated() {
            out.append(SwipeSample(dx: m.0, dy: m.1, phase: i == 0 ? .began : .changed, time: start + 0.008 * Double(i + 1)))
        }
        if end { out.append(SwipeSample(dx: 0, phase: .ended, time: start + 0.008 * Double(moves.count + 1))) }
        return out
    }

    static func feed(_ g: inout SwipeGesture, _ ss: [SwipeSample], inside: Bool = true) -> [(Bool, SwipeGesture.Action)] {
        ss.map { s in let r = g.feed(s, inside: inside); return (r.swallow, r.action) }
    }

    static func gesture() {
        var g = SwipeGesture()
        let slow = feed(&g, samples(Array(repeating: (-4, 0), count: 30)))
        let claimed = slow.firstIndex { if case .began = $0.1 { return true }; return false }
        check(claimed == 3, "a sideways swipe is claimed after 10 points of travel", "claimed at event \(claimed ?? -1)")
        if case .ended(let o, _)? = slow.last?.1 {
            check(abs(o - (-110)) < 0.01, "the strip follows the fingers from the claim on, without jumping by the claim", "offset \(o)")
        } else { check(false, "a claimed swipe ends with an offset") }
        check(slow.dropFirst(3).allSatisfy { $0.0 }, "every event after the claim is swallowed, so the tab list doesn't scroll")
        check(slow.prefix(3).allSatisfy { !$0.0 }, "events before the claim still reach the tab list")

        g = SwipeGesture()
        let vertical = feed(&g, samples(Array(repeating: (1, 5), count: 20)))
        check(vertical.allSatisfy { !$0.0 && $0.1 == .none }, "a vertical scroll is never claimed")

        g = SwipeGesture()
        let diagonal = feed(&g, samples(Array(repeating: (3, 2), count: 20)))
        check(diagonal.allSatisfy { $0.1 == .none }, "a diagonal that isn't twice as wide as it is tall stays a scroll")

        g = SwipeGesture()
        let outside = feed(&g, samples(Array(repeating: (-6, 0), count: 20)), inside: false)
        check(outside.allSatisfy { !$0.0 && $0.1 == .none }, "a gesture that begins off the sidebar is left alone")

        g = SwipeGesture()
        _ = feed(&g, samples(Array(repeating: (-6, 0), count: 10)))
        let momentum = (1...5).map { i in g.feed(SwipeSample(dx: -3, phase: .none, momentum: true, momentumEnded: i == 5, time: 101 + Double(i) * 0.01), inside: true) }
        check(momentum.allSatisfy { $0.swallow } && g.state == .idle, "momentum after a swipe is swallowed, then the gesture is over")

        g = SwipeGesture()
        let lone = g.feed(SwipeSample(dx: -20, phase: .none, momentum: true, time: 100), inside: true)
        check(!lone.swallow && lone.action == .none, "momentum never starts a swipe")

        g = SwipeGesture()
        let wheel = feed(&g, [SwipeSample(dx: -30, phase: .began, precise: false, time: 100), SwipeSample(dx: -30, phase: .changed, precise: false, time: 100.01)])
        check(wheel.allSatisfy { $0.1 == .none }, "a mouse wheel's line deltas never track")

        // Velocity: a quick flick reads fast, and a pause before lifting reads as standing still.
        g = SwipeGesture()
        let flick = feed(&g, samples(Array(repeating: (-8, 0), count: 6)))
        if case .ended(_, let v)? = flick.last?.1 {
            check(v < -600, "a flick's release velocity is fast", "\(Int(v)) pt/s")
        } else { check(false, "a flick ends") }
        g = SwipeGesture()
        var paused = samples(Array(repeating: (-8, 0), count: 10), end: false)
        paused.append(SwipeSample(dx: 0, phase: .ended, time: paused.last!.time + 0.2))
        if case .ended(_, let v)? = feed(&g, paused).last?.1 {
            check(abs(v) < 1, "lifting after a pause has no velocity", "\(v)")
        } else { check(false, "a paused swipe ends") }
    }

    // MARK: Physics

    static func physics() {
        let rb = [0.2, 0.5, 1, 2, 5].map(SwipePhysics.rubberBand)
        check(zip(rb, rb.dropFirst()).allSatisfy { $0 < $1 } && rb.allSatisfy { $0 < 1 } && abs(rb[2] - 0.3548) < 0.001,
              "the rubber band gives less and less and never a whole page", rb.map { String(format: "%.3f", $0) }.joined(separator: " "))
        check(SwipePhysics.banded(-0.5, lo: 0, hi: 1) > -0.5 && SwipePhysics.banded(0.5, lo: 0, hi: 1) == 0.5,
              "the band only applies past the ends")
        let w: CGFloat = 248
        func land(_ p: Double, _ v: Double, lo: Int = 0, hi: Int = 2) -> Int {
            SwipePhysics.landing(start: 1, position: 1 + p, velocity: v, width: w, lo: lo, hi: hi)
        }
        check(land(0.4, 0) == 2 && land(-0.4, 0) == 0, "a slow drag past 35 percent of a page commits")
        check(land(0.3, 0) == 1, "a slow drag to 30 percent springs back")
        check(land(0.1, 3.2) == 2, "a flick commits from 10 percent")
        check(land(0.6, -1.2) == 1, "fingers moving back at release cancel, however far they went")
        check(land(0.6, 0, hi: 1) == 1, "there's nowhere to go past the last space")
        check(land(0.05, 0.6) == 1, "a small nudge does nothing")
    }

    // MARK: The strip

    @MainActor
    static func model(spaces n: Int) -> BrowserModel {
        let m = BrowserModel()
        while m.spaces.count < n { m.createSpace(name: "Space \(m.spaces.count + 1)") }
        m.switchSpace(index: 0)
        return m
    }

    /// Steps `s` at 120 frames a second until it rests, or `limit` seconds. Returns the positions.
    @MainActor
    static func run(_ s: SpaceStrip, limit: Double = 2) -> [Double] {
        var out: [Double] = []
        var t = 0.0
        while s.isMoving && t < limit { s.tick(1.0 / 120); out.append(s.position); t += 1.0 / 120 }
        return out
    }

    @MainActor
    static func swipe(_ s: SpaceStrip, _ moves: [CGFloat]) {
        for x in samples(moves.map { ($0, 0) }) { s.handle(x, inside: true) }
    }

    @MainActor
    static func strip() {
        Motion.forceReduce = false
        defer { Motion.forceReduce = nil }
        let m = model(spaces: 4)
        let s = SpaceStrip.of(m)
        s.manualClock = true
        s.width = 248
        check(s.position == 0 && !s.isMoving, "the strip starts on the current space")

        // A slow drag to the left, past 35 percent: the page changes as the fingers lift.
        swipe(s, Array(repeating: -5, count: 22))
        check(m.currentSpaceID == m.spaces[1].id, "a swipe that commits changes the space when the fingers lift")
        check(s.isMoving && s.position > 0.3 && s.position < 0.6, "and the sidebar is still on its way", String(format: "%.2f", s.position))
        let settle = run(s)
        check(s.position == 1 && !s.isMoving && settle.allSatisfy { $0 <= 1.0001 }, "it settles on the next page without overshooting",
              String(format: "%.2f s, max %.4f", Double(settle.count) / 120, settle.max() ?? 0))
        check(Double(settle.count) / 120 < 0.6, "the settle is quick")

        // A short drag springs back and the page never changes.
        s.beginDrag(); s.drag(-60); s.endDrag(velocity: 0)
        check(m.currentSpaceID == m.spaces[1].id, "a short, slow swipe doesn't change the space")
        _ = run(s)
        check(s.position == 1, "and springs back")

        // Past the first space, the band gives and springs back.
        m.switchSpace(index: 0); _ = run(s)
        s.beginDrag(); s.drag(200)
        check(s.position < 0 && s.position > -0.5, "pulling past the first space gives a little", String(format: "%.2f", s.position))
        s.endDrag(velocity: 0); _ = run(s)
        check(s.position == 0 && m.currentSpaceID == m.spaces[0].id, "and springs back to it")

        // Clicks and shortcuts: a jump of several spaces slides one page, with the target standing in next door.
        m.switchSpace(index: 3)
        check(s.standIns[1] == m.spaces[3].id && s.target == 1, "a jump slides one page, with the target next to where you are")
        let jump = run(s)
        check(s.position == 3 && s.standIns.isEmpty, "and lands back on plain pages", String(format: "%.2f in %d frames", s.position, jump.count))

        // Rapid presses retarget from where the strip is, with no jumps.
        m.switchSpace(index: 0); _ = run(s)
        m.switchSpace(index: 1)
        for _ in 0..<6 { s.tick(1.0 / 120) }
        m.switchSpace(index: 2)
        var prev = s.position
        var biggest = 0.0
        for _ in 0..<240 where s.isMoving { s.tick(1.0 / 120); biggest = max(biggest, abs(s.position - prev)); prev = s.position }
        check(m.currentSpaceID == m.spaces[2].id && !s.isMoving && biggest < 0.12,
              "rapid switches land on the last one in one continuous motion", String(format: "largest step %.3f pages", biggest))

        // A swipe that starts while the strip is settling picks it up where it is.
        m.switchSpace(index: 0); _ = run(s)
        m.switchSpace(index: 1)
        for _ in 0..<8 { s.tick(1.0 / 120) }
        let mid = s.position
        s.beginDrag()
        check(s.position == mid && s.dragging, "grabbing the strip mid-slide holds it where it is")
        s.drag(0); s.endDrag(velocity: 0); _ = run(s)

        // Reduce Motion: the swipe still follows the fingers, and the settle is a short ease.
        Motion.forceReduce = true
        m.switchSpace(index: 0)
        check(s.position == 0 && !s.isMoving, "under Reduce Motion a click swaps the list in place")
        _ = run(s)
        s.beginDrag(); s.drag(-120)
        check(abs(s.position - 120.0 / 248) < 0.001, "under Reduce Motion the swipe still tracks the fingers")
        s.endDrag(velocity: 0)
        let reduced = run(s)
        check(s.position == 1 && Double(reduced.count) / 120 <= 0.17, "and finishes on a short ease",
              String(format: "%.2f s", Double(reduced.count) / 120))
        Motion.forceReduce = false

        // Motion suppressed (a live resize): everything snaps.
        Motion.suppressed = true
        m.switchSpace(index: 3)
        check(s.position == 3 && !s.isMoving, "while motion is suppressed the strip snaps")
        Motion.suppressed = false
    }

    // MARK: Real events

    @MainActor
    static func events() {
        // A trackpad scroll event made the way the window server makes them, read back as a sample.
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -7, wheel3: 0) else {
            check(false, "a scroll event can be made"); return
        }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.began.rawValue))
        guard let e = NSEvent(cgEvent: cg) else { check(false, "the scroll event converts"); return }
        let s = SwipeSample(e)
        check(s.phase == .began && s.precise && !s.momentum, "a trackpad event reads as a precise gesture beginning")
        check(abs(s.dx) > 0 && (s.dx < 0) == (e.isDirectionInvertedFromDevice ? e.scrollingDeltaX < 0 : e.scrollingDeltaX > 0),
              "its direction is the fingers' own, whatever the scroll setting")
    }

    // MARK: Writing

    static func punctuation() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let files = ["UI/SpacePager.swift", "UI/SwipePhysics.swift", "Tests/MotionTests.swift", "Tests/MotionTours.swift"]
        let bad = files.filter { f in
            guard let s = try? String(contentsOf: root.appendingPathComponent(f), encoding: .utf8) else { return false }
            return s.unicodeScalars.contains { [0x2013, 0x2014, 0x00B7, 0x2011, 0x2012, 0x2015].contains($0.value) }
        }
        check(bad.isEmpty, "the motion sources use plain hyphens and no middle dots", bad.joined(separator: ", "))
    }
}
