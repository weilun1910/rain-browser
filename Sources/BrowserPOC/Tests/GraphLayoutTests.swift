import Foundation
import QuartzCore
import simd

/// The builder's filters, the simulation, the Metal renderer and the 5,000 node performance check.
enum GraphLayoutTests {
    static func check(_ ok: Bool, _ label: String, _ detail: String = "") { SelfTest.check(ok, label, detail) }

    static var isDebug: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    static func builderTests(_ store: GraphStore) {
        let snap = store.snapshot()
        var s = GraphSettings()
        let ctx = GraphBuildContext()
        var l = GraphBuilder.build(snap, s, ctx)
        func titles(_ l: GraphLayout) -> Set<String> { Set(l.nodes.map(\.title)) }
        check(l.nodes.contains { $0.kind == .unresolved } && !l.nodes.contains { $0.kind == .topic },
              "the default graph shows unresolved links and hides topics", "\(l.nodes.count) nodes, \(l.edges.count) lines")

        s.existingOnly = true
        l = GraphBuilder.build(snap, s, ctx)
        check(!l.nodes.contains { $0.kind == .unresolved }, "Existing notes only hides links to notes that don't exist")

        s = GraphSettings()
        s.edgeTypes.remove(.navigation)
        l = GraphBuilder.build(snap, s, ctx)
        check(!l.edges.contains { $0.types.contains(.navigation) }, "edge types can be filtered out")

        s = GraphSettings()
        s.showTopics = true
        l = GraphBuilder.build(snap, s, ctx)
        let topicNodes = l.nodes.filter { $0.kind == .topic }
        check(topicNodes.allSatisfy { n in l.adjacency[l.indexByID[n.id]!].count >= 2 }, "topic nodes appear when turned on, each tying two or more items",
              topicNodes.map(\.title).joined(separator: ", "))

        s = GraphSettings()
        s.search = "sourdough"
        l = GraphBuilder.build(snap, s, ctx)
        let docs = l.nodes.filter { $0.docID != nil }
        check(!docs.isEmpty && docs.allSatisfy { $0.title.lowercased().contains("sourdough") || $0.url.lowercased().contains("sourdough") },
              "search keeps only matching items", docs.map(\.title).joined(separator: ", "))
        s.search = "type:note"
        l = GraphBuilder.build(snap, s, ctx)
        check(l.nodes.filter { $0.docID != nil }.allSatisfy { $0.kind == .note }, "type:note keeps only notes")

        s = GraphSettings()
        s.siteGrouping = .always
        l = GraphBuilder.build(snap, s, ctx)
        let gh = l.nodes.first { $0.kind == .siteGroup && $0.host == "github.com" }
        check(gh?.members.count == 3 && !l.nodes.contains { $0.kind == .site && $0.host == "github.com" },
              "pages from one site fold into one node", gh.map { "\($0.title), \($0.subtitle)" } ?? "none")
        var ctx2 = ctx
        ctx2.expandedSites = ["github.com"]
        l = GraphBuilder.build(snap, s, ctx2)
        check(l.nodes.filter { $0.host == "github.com" && $0.kind == .site }.count == 3, "clicking a site group unfolds it")

        s = GraphSettings()
        s.showOrphans = false
        l = GraphBuilder.build(snap, s, ctx)
        check(l.nodes.allSatisfy { l.adjacency[l.indexByID[$0.id]!].count > 0 }, "Orphans off hides items with no connections")

        s = GraphSettings()
        s.groups = [GraphGroup(query: "project:notes", color: "#E57A3C")]
        l = GraphBuilder.build(snap, s, ctx)
        check(l.nodes.filter { $0.kind == .note }.allSatisfy { $0.groupColor != nil } && l.nodes.filter { $0.kind == .site }.allSatisfy { $0.groupColor == nil },
              "a colour group colours the items its query matches")

        // A local graph.
        let planKey = GraphTests.key(GraphTests.plan)
        if let pi = snap.indexByKey[planKey] {
            var lc = GraphBuildContext()
            lc.isLocal = true
            lc.focusID = snap.nodes[pi].id
            lc.focusDepth = 1
            let l1 = GraphBuilder.build(snap, GraphSettings(), lc)
            let c = l1.center
            check(c != nil && l1.nodes[c!].title == GraphTests.plan.title && l1.depth.allSatisfy { $0 >= 0 && $0 <= 1 },
                  "a local graph holds the item and what it connects to", titles(l1).sorted().joined(separator: ", "))
            lc.focusDepth = 2
            let l2 = GraphBuilder.build(snap, GraphSettings(), lc)
            check(l2.nodes.count > l1.nodes.count && l2.depth.contains(2), "depth 2 reaches one step further", "\(l1.nodes.count) -> \(l2.nodes.count)")
            if let c2 = l2.center, let other = l2.neighbours(c2).first {
                let r = l2.reasons(for: other, to: c2)
                check(!r.isEmpty && r.allSatisfy { Fmt.clean($0) == $0 }, "hover says why a node connects to the centre", r.joined(separator: " | "))
            }
        } else {
            check(false, "the plan note is in the graph")
        }
    }

    static func simulationTests() {
        // Two clusters of ten with no links between them.
        var links: [(Int, Int)] = []
        for c in 0..<2 { for i in 0..<10 { for j in (i + 1)..<10 where (i + j) % 3 != 0 { links.append((c * 10 + i, c * 10 + j)) } } }
        let sim = ForceSimulation()
        sim.setGraph(count: 20, links: links, radii: Array(repeating: 3, count: 20), start: Array(repeating: nil, count: 20),
                     params: ForceSimulation.Params(), alpha: 1)
        sim.stop()
        sim.run(ticks: 300)
        let p = sim.positions()
        check(p.count == 20 && p.allSatisfy { $0.x.isFinite && $0.y.isFinite }, "the simulation settles without NaN")
        func mean(_ pairs: [(Int, Int)]) -> Float { pairs.map { simd_distance(p[$0.0], p[$0.1]) }.reduce(0, +) / Float(max(1, pairs.count)) }
        var inside: [(Int, Int)] = [], across: [(Int, Int)] = []
        for i in 0..<20 { for j in (i + 1)..<20 { if (i < 10) == (j < 10) { inside.append((i, j)) } else { across.append((i, j)) } } }
        let a = mean(inside), b = mean(across)
        check(a * 1.5 < b, "connected nodes end up closer than unconnected ones", String(format: "inside %.0f, across %.0f", a, b))
        sim.drag(3, to: SIMD2(500, 500))
        sim.flush()
        sim.stop()
        sim.run(ticks: 30)
        check(simd_distance(sim.positions()[3], SIMD2(500, 500)) < 0.01, "a dragged node stays under the pointer")
        sim.release(3)
        var mask = Array(repeating: true, count: 20)
        mask[15] = false
        sim.setActive(mask)
        sim.flush()
        sim.stop()
        let before = sim.positions()[15]
        sim.run(ticks: 20)
        check(sim.positions()[15] == before, "inactive nodes sit out the layout during the timelapse")
    }

    /// A clustered graph shaped like a real history: notes linking inside topics, pages tied by navigation.
    static func syntheticSnapshot(nodes n: Int, linksPerNode: Double) -> GraphSnapshot {
        var snap = GraphSnapshot()
        var rng = SplitMix(seed: 99)
        let clusters = max(1, n / 50)
        let kinds: [GraphNodeKind] = [.site, .site, .site, .note, .doc, .site, .meeting]
        for i in 0..<n {
            let k = kinds[i % kinds.count]
            snap.nodes.append(GraphNode(id: "d:\(i)", docID: Int64(i + 1), kind: k, title: "Item \(i) about topic \(i % clusters)", key: "k\(i)",
                                        url: "https://site\(i % 40).example/p\(i)", host: "site\(i % 40).example", project: nil, source: "web",
                                        firstSeen: Double(i), lastSeen: Double(i), visits: 1, hasText: true))
        }
        let m = Int(Double(n) * linksPerNode)
        let types = GraphEdgeType.allCases.filter { $0 != .topic }
        for e in 0..<m {
            let a = Int(rng.nextUInt() % UInt64(n))
            let sameCluster = rng.next(0, 1) < 0.85
            var b: Int
            if sameCluster {
                let c = a % clusters
                b = c + clusters * Int(rng.nextUInt() % UInt64(max(1, n / clusters)))
                if b >= n { b = (a + 1) % n }
            } else {
                b = Int(rng.nextUInt() % UInt64(n))
            }
            if a == b { continue }
            snap.links.append(GraphLink(a: a, b: b, type: types[e % types.count], weight: 0.8, count: 1, detail: "", last: 0))
        }
        snap.finish()
        return snap
    }

    static func performanceTests() {
        let snap = syntheticSnapshot(nodes: 5000, linksPerNode: 2.4)
        var s = GraphSettings()
        s.siteGrouping = .never
        let t0 = CACurrentMediaTime()
        let layout = GraphBuilder.build(snap, s, GraphBuildContext())
        let buildMS = (CACurrentMediaTime() - t0) * 1000
        print(String(format: "      5,000 node graph: %d nodes, %d lines, built in %.0f ms", layout.nodes.count, layout.edges.count, buildMS))
        let sim = ForceSimulation()
        sim.setGraph(count: layout.nodes.count, links: layout.edges.map { ($0.a, $0.b) }, radii: layout.nodes.map(\.radius),
                     start: Array(repeating: nil, count: layout.nodes.count), params: ForceSimulation.Params(s), alpha: 1)
        sim.stop()
        sim.run(ticks: 5)
        let t1 = CACurrentMediaTime()
        let ticks = isDebug ? 20 : 120
        sim.run(ticks: ticks)
        let tickMS = (CACurrentMediaTime() - t1) * 1000 / Double(ticks)
        // Debug builds run this code many times slower, so the bar there only catches blowups.
        let limit = isDebug ? 300.0 : 8.0
        check(tickMS < limit, "a simulation tick at 5,000 nodes stays under \(Int(limit)) ms (\(isDebug ? "debug build" : "release build"))",
              String(format: "%.2f ms per tick", tickMS))

        MainActor.assumeIsolated {
            let c = GraphController(mode: .global)
            c.load(layout)
            c.settle(ticks: isDebug ? 10 : 200, size: CGSize(width: 1400, height: 900))
            var img = c.renderImage(size: CGSize(width: 1400, height: 900), pixelRatio: 2)
            // The per-frame CPU work on screen: node styles, hover easing and labels.
            let frames = isDebug ? 3 : 30
            let t2 = CACurrentMediaTime()
            for _ in 0..<frames { _ = c.makeFrame(size: CGSize(width: 1400, height: 900), pixelRatio: 2, appearance: nil) }
            let cpuMS = (CACurrentMediaTime() - t2) * 1000 / Double(frames)
            img = c.renderImage(size: CGSize(width: 1400, height: 900), pixelRatio: 2)
            let gpu = c.renderer?.lastGPUTime ?? -1
            check(img != nil && gpu >= 0 && gpu < 16, "a 2x frame of 5,000 nodes draws on the GPU in under 16 ms", String(format: "GPU %.2f ms", gpu))
            let cpuLimit = isDebug ? 600.0 : 8.0
            check(cpuMS < cpuLimit, "preparing a frame of 5,000 nodes takes under \(Int(cpuLimit)) ms of CPU", String(format: "%.2f ms", cpuMS))
            c.sim.stop()
        }
    }
}

/// `--graph-bench`: the 5,000 node checks on their own, for a release build.
enum GraphBench {
    static func run() -> Int32 {
        print("Graph benchmark (\(GraphLayoutTests.isDebug ? "debug" : "release") build)")
        SelfTest.failures = 0
        GraphLayoutTests.performanceTests()
        return SelfTest.failures == 0 ? 0 : 1
    }
}
