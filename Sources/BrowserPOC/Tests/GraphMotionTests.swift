import AppKit
import simd

/// The second pass: fades between layouts, separate cameras per view, saved positions, spaces,
/// names keeping clear of panels, blended positions and wikilinks only from notes.
enum GraphMotionTests {
    static func check(_ ok: Bool, _ label: String, _ detail: String = "") { SelfTest.check(ok, label, detail) }

    static func run(store: GraphStore) {
        let snap = store.snapshot()
        MainActor.assumeIsolated {
            let c = GraphController(mode: .global)
            var s = GraphSettings()
            s.showOrphans = true
            let full = GraphBuilder.build(snap, s, GraphBuildContext())
            c.load(full)
            c.settle(ticks: 60, size: CGSize(width: 900, height: 700))
            let before = c.layout.nodes.count

            // A narrower layout: the missing nodes fade out where they are, then drop away.
            s.search = "sourdough"
            let narrow = GraphBuilder.build(snap, s, GraphBuildContext())
            c.load(narrow)
            check(c.layout.nodes.count == before && c.liveCount == narrow.nodes.count,
                  "after a filter change, leaving nodes stay drawn while they fade", "\(c.layout.nodes.count) drawn, \(c.liveCount) live")
            let f1 = c.makeFrame(size: CGSize(width: 900, height: 700), pixelRatio: 2, appearance: nil)
            let leavingAlpha = f1.styles.suffix(from: c.liveCount).map(\.alpha).max() ?? 0
            check(leavingAlpha > 0.5, "they start out visible", String(format: "%.2f", leavingAlpha))
            c.settle(ticks: 10, size: CGSize(width: 900, height: 700))
            check(c.layout.nodes.count == c.liveCount, "then they're gone", "\(c.layout.nodes.count)")

            // Back to everything: returning nodes grow in from nothing.
            s.search = ""
            c.load(GraphBuilder.build(snap, s, GraphBuildContext()))
            let f2 = c.makeFrame(size: CGSize(width: 900, height: 700), pixelRatio: 2, appearance: nil)
            let entering = zip(c.layout.nodes, f2.styles).filter { !narrow.indexByID.keys.contains($0.0.id) }.map(\.1.alpha)
            check(!entering.isEmpty && entering.allSatisfy { $0 < 0.5 }, "nodes coming back fade in instead of popping",
                  entering.prefix(4).map { String(format: "%.2f", $0) }.joined(separator: " "))
            c.settle(ticks: 10, size: CGSize(width: 900, height: 700))

            // Two views on one graph keep their own cameras.
            let v1 = GraphMetalView(controller: c, id: UUID()), v2 = GraphMetalView(controller: c, id: UUID())
            v1.state.size = CGSize(width: 600, height: 400); v2.state.size = CGSize(width: 600, height: 400)
            let c2 = v2.state.center
            c.pan(120, 0, in: v1)
            c.zoom(by: 2, at: CGPoint(x: 300, y: 200), in: v1)
            check(v1.state.center != c2 && v2.state.center == c2 && v2.state.scale != v1.state.scale,
                  "two panes on the same graph pan and zoom on their own")

            // Names stay clear of panels.
            _ = c.renderImage(size: CGSize(width: 900, height: 700))
            c.offscreen.occluders = [CGRect(x: 0, y: 0, width: 900, height: 700)]
            let covered = c.makeFrame(size: CGSize(width: 900, height: 700), pixelRatio: 2, appearance: nil).labels.count
            c.offscreen.occluders = []
            var open = 0
            for _ in 0..<10 { open = c.makeFrame(size: CGSize(width: 900, height: 700), pixelRatio: 2, appearance: nil).labels.count }
            check(covered == 0 && open > 0, "names never sit under the hover card or the panels", "\(covered) under a panel, \(open) in the open")
            c.sim.stop()
        }

        // Positions are saved and come back.
        let pos: [String: SIMD2<Float>] = ["d:1": SIMD2(10, -4), "d:2": SIMD2(3.5, 8)]
        store.savePositionsNow(scope: "test", pos)
        let back = store.loadPositions(scope: "test")
        check(back == pos, "layout positions survive a relaunch", "\(back.count) of \(pos.count)")

        // Spaces: open items and notes folders set it, connections pass it on.
        var ctx = GraphBuildContext()
        ctx.spaceColors = ["#4C8DF6", "#E0A030"]
        let planKey = GraphTests.key(GraphTests.plan), breadKey = GraphTests.key(GraphTests.bread)
        ctx.spaceOfKey = [planKey: 0, breadKey: 1]
        let l = GraphBuilder.build(snap, GraphSettings(), ctx)
        func space(_ f: GraphTests.Fix) -> Int? { l.nodes.first { $0.key == GraphTests.key(f) }?.space }
        check(space(GraphTests.plan) == 0 && space(GraphTests.bread) == 1, "items open in a space take its colour")
        check(space(GraphTests.webkitBlog) == 0 && space(GraphTests.starter) == 1,
              "items without a space take the space of what they connect to", "\(String(describing: space(GraphTests.webkitBlog))) \(String(describing: space(GraphTests.starter)))")

        // Blended positions sit between the last two ticks.
        let sim = ForceSimulation()
        sim.setGraph(count: 2, links: [(0, 1)], start: [SIMD2(0, 0), SIMD2(100, 0)], params: ForceSimulation.Params(), alpha: 1)
        sim.stop()
        sim.run(ticks: 1)
        let snapA = sim.positions()
        sim.stop()
        var blended = [SIMD2<Float>](repeating: .zero, count: 2)
        _ = blended.withUnsafeMutableBufferPointer { sim.copyBlended(into: $0.baseAddress!, count: 2, now: CACurrentMediaTime() + 1) }
        check(blended == snapA, "a frame long after the last tick shows that tick exactly")

        // Wikilinks come from notes only.
        let page = LinkExtractor.extract(body: "Born in [[Tokyo]], see [[Japan]].", ownKey: "https://x.org/a", ownURL: "https://x.org/a", wikilinks: false)
        check(page.isEmpty, "[[markup]] in page text isn't read as a link to a note")
    }
}
