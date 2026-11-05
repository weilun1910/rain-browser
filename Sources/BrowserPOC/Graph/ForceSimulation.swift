import Foundation
import QuartzCore

/// A force-directed layout in the style of d3-force: velocity Verlet with alpha cooling,
/// Barnes-Hut repulsion, springy links whose strength falls with degree, and a pull toward
/// the middle. Runs on its own queue at 60 ticks a second and publishes positions. The renderer
/// blends the last two ticks, so motion stays smooth at 120 Hz.
final class ForceSimulation: @unchecked Sendable {
    struct Params: Equatable {
        /// Obsidian's sliders. Center 0 to 1, repel 0 to 20, link force 0 to 1, distance in world units.
        var center: Float = 0.45
        var repel: Float = 10
        var linkForce: Float = 1
        var linkDistance: Float = 40
        var theta: Float = 0.9
        var velocityKeep: Float = 0.6
        var alphaMin: Float = 0.001
        var alphaDecay: Float = 1 - powf(0.001, 1 / 300)
        /// Repulsion stops past this distance, which keeps far clusters from drifting apart.
        var distanceMax: Float = 900
        /// How warm the layout stays while a node is dragged. Low, so neighbours follow gently.
        var dragAlpha: Float = 0.1
        /// A gentle pull of each node toward its space's spot on a ring, so spaces read as
        /// regions and the things that bridge them sit in between. 0 turns it off.
        var spacePull: Float = 0.5

        init() {}
        init(_ s: GraphSettings) {
            center = Float(s.centerForce)
            repel = Float(s.repelForce)
            linkForce = Float(s.linkForce)
            linkDistance = Float(s.linkDistance)
            spacePull = Float(s.spacePull)
        }
    }

    private let queue = DispatchQueue(label: "local.browserpoc.graph.sim", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var timerRunning = false
    static let tickInterval: Double = 1.0 / 60

    // Simulation state, touched only on `queue`.
    private(set) var count = 0
    private var x: [Float] = [], y: [Float] = [], vx: [Float] = [], vy: [Float] = []
    private var pinned: [Bool] = [], px: [Float] = [], py: [Float] = []
    private var active: [Bool] = []
    private var charge: [Float] = []
    private var linkS: [Int32] = [], linkT: [Int32] = []
    private var linkStrength: [Float] = [], linkDist: [Float] = [], linkBias: [Float] = []
    /// Per-node pull toward the middle. Items with no links get more, so they ring the graph
    /// instead of drifting off.
    private var pull: [Float] = []
    /// Each node's space anchor, or NaN for none.
    private var anchorX: [Float] = [], anchorY: [Float] = []
    private var params = Params()
    private var alpha: Float = 1
    private var alphaTarget: Float = 0
    private var tree = QuadTree()
    private var rng = SplitMix(seed: 42)

    // Published positions: the last two ticks, so frames between ticks can blend them.
    private let lock = NSLock()
    private var published: [SIMD2<Float>] = []
    private var previous: [SIMD2<Float>] = []
    private var publishedAt: CFTimeInterval = 0
    private var publishedVersion = 0
    private var publishedAlpha: Float = 0

    /// Called on the simulation queue after each tick.
    var onTick: (@Sendable () -> Void)?

    init() {}

    // MARK: Commands

    /// Replaces the graph. `start` gives positions for nodes that had one. The rest start next to a
    /// placed neighbour, or near their group's spot on a ring (one group per space), or near the
    /// middle. `warmup` ticks run before anything is shown, so the first frame is already calm.
    func setGraph(count n: Int, links: [(Int, Int)], start: [SIMD2<Float>?], groups: [Int?] = [], active mask: [Bool]? = nil,
                  params p: Params, alpha a: Float, warmup: Int = 0) {
        queue.async { [self] in
            count = n
            params = p
            x = .init(repeating: 0, count: n); y = x; vx = x; vy = x
            pinned = .init(repeating: false, count: n); px = x; py = x
            active = mask?.count == n ? mask! : .init(repeating: true, count: n)
            charge = .init(repeating: -p.repel * 6, count: n)
            var placed = [Bool](repeating: false, count: n)
            for i in 0..<n { if let s = start[i] { x[i] = s.x; y[i] = s.y; placed[i] = true } }
            var deg = [Int](repeating: 0, count: n)
            linkS = []; linkT = []
            linkS.reserveCapacity(links.count); linkT.reserveCapacity(links.count)
            for (s, t) in links where s != t && s < n && t < n {
                linkS.append(Int32(s)); linkT.append(Int32(t)); deg[s] += 1; deg[t] += 1
            }
            // Inactive nodes (ones fading out) hold still where they are.
            for i in 0..<n where !active[i] { pinned[i] = true; px[i] = x[i]; py[i] = y[i] }
            seedUnplaced(placed: placed, groups: groups)
            setupLinks(deg: deg)
            alpha = a
            alphaTarget = 0
            for _ in 0..<warmup { tick() }
            publish(snap: true)
            startTimer()
        }
    }

    private func seedUnplaced(placed: [Bool], groups: [Int?]) {
        let n = count
        // Next to a placed neighbour, so new items appear where they belong.
        var neighbour = [Int](repeating: -1, count: n)
        for k in 0..<linkS.count {
            let s = Int(linkS[k]), t = Int(linkT[k])
            if placed[s] && !placed[t] { neighbour[t] = s }
            if placed[t] && !placed[s] { neighbour[s] = t }
        }
        let groupIDs = Array(Set(groups.compactMap { $0 })).sorted()
        let unplacedCount = Float(placed.filter { !$0 }.count)
        let ring = params.linkDistance * max(2, unplacedCount.squareRoot() * 0.55)
        var anchors: [Int: SIMD2<Float>] = [:]
        for (k, g) in groupIDs.enumerated() {
            let ang = Float(k) / Float(max(1, groupIDs.count)) * 2 * .pi - .pi / 2
            anchors[g] = groupIDs.count == 1 ? .zero : SIMD2(cos(ang), sin(ang)) * ring
        }
        // The same spots, for the space pull. The ring is sized for the whole graph.
        let allRing = params.linkDistance * max(2, Float(n).squareRoot() * 0.5)
        anchorX = .init(repeating: .nan, count: n); anchorY = anchorX
        if groupIDs.count > 1 {
            for i in 0..<n {
                guard i < groups.count, let g = groups[i], let k = groupIDs.firstIndex(of: g) else { continue }
                let ang = Float(k) / Float(groupIDs.count) * 2 * .pi - .pi / 2
                anchorX[i] = cos(ang) * allRing; anchorY[i] = sin(ang) * allRing
            }
        }
        let spread = params.linkDistance * max(1.5, (unplacedCount / Float(max(1, groupIDs.count))).squareRoot() * 0.45)
        for i in 0..<n where !placed[i] {
            if neighbour[i] >= 0 {
                let j = neighbour[i]
                x[i] = x[j] + Float(rng.next(-1, 1)) * params.linkDistance * 0.5
                y[i] = y[j] + Float(rng.next(-1, 1)) * params.linkDistance * 0.5
            } else {
                let g = i < groups.count ? groups[i] : nil
                let c = g.flatMap { anchors[$0] } ?? .zero
                let r = Float(rng.next(0, 1)).squareRoot() * (g == nil ? spread * 0.8 : spread)
                let ang = Float(rng.next(0, 2 * Double.pi))
                x[i] = c.x + r * cos(ang); y[i] = c.y + r * sin(ang)
            }
        }
    }

    /// Drops every node from `n` on, keeping the rest exactly where and how they're moving.
    /// Used once nodes that were fading out are gone.
    func truncate(to n: Int, links: [(Int, Int)]) {
        queue.async { [self] in
            guard n <= count else { return }
            count = n
            x = Array(x.prefix(n)); y = Array(y.prefix(n)); vx = Array(vx.prefix(n)); vy = Array(vy.prefix(n))
            pinned = Array(pinned.prefix(n)); px = Array(px.prefix(n)); py = Array(py.prefix(n))
            active = Array(active.prefix(n)); charge = Array(charge.prefix(n))
            anchorX = Array(anchorX.prefix(n)); anchorY = Array(anchorY.prefix(n))
            var deg = [Int](repeating: 0, count: n)
            linkS = []; linkT = []
            for (s, t) in links where s != t && s < n && t < n {
                linkS.append(Int32(s)); linkT.append(Int32(t)); deg[s] += 1; deg[t] += 1
            }
            setupLinks(deg: deg)
            publish(snap: true)
        }
    }

    private func setupLinks(deg: [Int]) {
        let m = linkS.count
        pull = deg.map { $0 == 0 ? 3 : 1 }
        linkStrength = .init(repeating: 0, count: m)
        linkDist = .init(repeating: params.linkDistance, count: m)
        linkBias = .init(repeating: 0.5, count: m)
        for k in 0..<m {
            let ds = Float(deg[Int(linkS[k])]), dt = Float(deg[Int(linkT[k])])
            linkStrength[k] = params.linkForce / max(1, min(ds, dt))
            linkBias[k] = ds / max(1, ds + dt)
        }
    }

    func setParams(_ p: Params) {
        queue.async { [self] in
            guard p != params else { return }
            let relink = p.linkForce != params.linkForce || p.linkDistance != params.linkDistance
            params = p
            for i in 0..<count { charge[i] = -p.repel * 6 }
            if relink {
                var deg = [Int](repeating: 0, count: count)
                for k in 0..<linkS.count { deg[Int(linkS[k])] += 1; deg[Int(linkT[k])] += 1 }
                setupLinks(deg: deg)
            }
            alpha = max(alpha, 0.3)
            startTimer()
        }
    }

    func reheat(_ a: Float = 0.3) {
        queue.async { [self] in alpha = max(alpha, a); startTimer() }
    }

    /// Pins a node under the pointer while it's dragged. The layout stays just warm enough for
    /// neighbours to follow.
    func drag(_ i: Int, to p: SIMD2<Float>) {
        queue.async { [self] in
            guard i < count else { return }
            pinned[i] = true; px[i] = p.x; py[i] = p.y
            x[i] = p.x; y[i] = p.y
            alphaTarget = params.dragAlpha
            alpha = max(alpha, params.dragAlpha)
            startTimer()
        }
    }

    func release(_ i: Int) {
        queue.async { [self] in
            guard i < count else { return }
            if active[i] { pinned[i] = false }
            alphaTarget = 0
        }
    }

    /// Nodes that aren't active take no part in the layout. Used by the timelapse.
    func setActive(_ mask: [Bool], placeNear: Bool = true) {
        queue.async { [self] in
            guard mask.count == count else { return }
            for i in 0..<count where mask[i] && !active[i] && placeNear {
                // Join next to an active neighbour.
                var placedNear = false
                for k in 0..<linkS.count {
                    let s = Int(linkS[k]), t = Int(linkT[k])
                    let o = s == i ? t : (t == i ? s : -1)
                    if o >= 0 && active[o] && mask[o] {
                        x[i] = x[o] + Float(rng.next(-1, 1)) * 8; y[i] = y[o] + Float(rng.next(-1, 1)) * 8
                        placedNear = true
                        break
                    }
                }
                if !placedNear { x[i] = Float(rng.next(-1, 1)) * 20; y[i] = Float(rng.next(-1, 1)) * 20 }
                vx[i] = 0; vy[i] = 0
                pinned[i] = false
            }
            active = mask
            alpha = max(alpha, 0.25)
            startTimer()
        }
    }

    /// Runs ticks right away on the calling thread's behalf. For tests and warmup.
    func run(ticks: Int) {
        queue.sync { [self] in
            for _ in 0..<ticks { tick() }
            publish(snap: true)
        }
    }

    /// Waits for queued commands. For tests.
    func flush() { queue.sync {} }

    func stop() {
        queue.sync { [self] in
            timer?.cancel(); timer = nil; timerRunning = false
        }
    }

    // MARK: Reading

    func withPositions<R>(_ body: (UnsafeBufferPointer<SIMD2<Float>>, Int) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return published.withUnsafeBufferPointer { body($0, publishedVersion) }
    }

    /// The latest tick's positions.
    func positions() -> [SIMD2<Float>] {
        lock.lock(); defer { lock.unlock() }
        return published
    }

    /// Positions blended between the last two ticks for a frame drawn at `now`, so a 120 Hz
    /// display sees motion every frame, not every other one. Writes `count` positions into `dst`
    /// and returns how many it wrote.
    func copyBlended(into dst: UnsafeMutablePointer<SIMD2<Float>>, count want: Int, now: CFTimeInterval) -> Int {
        lock.lock(); defer { lock.unlock() }
        let n = published.count
        guard n >= want else { return 0 }
        let f = Float(min(1, max(0, (now - publishedAt) / Self.tickInterval)))
        if previous.count != n || f >= 1 {
            published.withUnsafeBufferPointer { dst.update(from: $0.baseAddress!, count: want) }
        } else {
            for i in 0..<want { dst[i] = previous[i] + (published[i] - previous[i]) * f }
        }
        return want
    }

    func blended(now: CFTimeInterval) -> [SIMD2<Float>] {
        let n = positions().count
        var out = [SIMD2<Float>](repeating: .zero, count: n)
        _ = out.withUnsafeMutableBufferPointer { copyBlended(into: $0.baseAddress!, count: n, now: now) }
        return out
    }

    /// True while the layout is still moving.
    var isMoving: Bool {
        lock.lock(); defer { lock.unlock() }
        return publishedAlpha >= params.alphaMin || CACurrentMediaTime() - publishedAt < Self.tickInterval
    }

    var currentAlpha: Float {
        lock.lock(); defer { lock.unlock() }
        return publishedAlpha
    }

    // MARK: Loop

    private func startTimer() {
        if timer == nil {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: Self.tickInterval, leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in self?.step() }
            timer = t
            t.resume()
            timerRunning = true
        } else if !timerRunning {
            timer?.resume()
            timerRunning = true
        }
    }

    private func step() {
        if alpha < params.alphaMin && alphaTarget == 0 {
            if timerRunning { timer?.suspend(); timerRunning = false }
            publish(snap: true)
            return
        }
        tick()
        publish(snap: false)
        onTick?()
    }

    /// `snap` makes both published buffers the same, for jumps that shouldn't be blended.
    private func publish(snap: Bool) {
        lock.lock()
        if published.count != count || snap {
            if published.count != count { published = .init(repeating: .zero, count: count) }
            for i in 0..<count { published[i] = SIMD2(x[i], y[i]) }
            previous = published
        } else {
            swap(&previous, &published)
            for i in 0..<count { published[i] = SIMD2(x[i], y[i]) }
        }
        publishedAt = CACurrentMediaTime()
        publishedVersion &+= 1
        publishedAlpha = (alpha < params.alphaMin && alphaTarget == 0) ? 0 : alpha
        lock.unlock()
    }

    /// One step of the simulation.
    func tick() {
        let n = count
        guard n > 0 else { return }
        alpha += (alphaTarget - alpha) * params.alphaDecay
        let a = alpha
        x.withUnsafeMutableBufferPointer { X in
        y.withUnsafeMutableBufferPointer { Y in
        vx.withUnsafeMutableBufferPointer { VX in
        vy.withUnsafeMutableBufferPointer { VY in
            // Links.
            linkS.withUnsafeBufferPointer { LS in
            linkT.withUnsafeBufferPointer { LT in
                for k in 0..<LS.count {
                    let s = Int(LS[k]), t = Int(LT[k])
                    if !active[s] || !active[t] { continue }
                    var dx = X[t] + VX[t] - X[s] - VX[s]
                    var dy = Y[t] + VY[t] - Y[s] - VY[s]
                    if dx == 0 { dx = Float(rng.next(-1e-6, 1e-6)) }
                    if dy == 0 { dy = Float(rng.next(-1e-6, 1e-6)) }
                    var l = (dx * dx + dy * dy).squareRoot()
                    l = (l - linkDist[k]) / l * a * linkStrength[k]
                    dx *= l; dy *= l
                    let b = linkBias[k]
                    VX[t] -= dx * b; VY[t] -= dy * b
                    VX[s] += dx * (1 - b); VY[s] += dy * (1 - b)
                }
            }
            }

            // Repulsion through a Barnes-Hut quadtree.
            if params.repel > 0 {
                tree.build(X, Y, active, charge)
                let theta2 = params.theta * params.theta
                let dmax2 = params.distanceMax * params.distanceMax
                for i in 0..<n where active[i] {
                    let (fx, fy) = tree.force(on: i, X, Y, charge, alpha: a, theta2: theta2, distanceMax2: dmax2, rng: &rng)
                    VX[i] += fx; VY[i] += fy
                }
            }

            // A pull toward the middle: Obsidian's center force makes the graph rounder and tighter.
            let k = params.center * 0.04
            for i in 0..<n where active[i] {
                let pk = i < pull.count ? pull[i] : 1
                VX[i] -= X[i] * k * a * pk
                VY[i] -= Y[i] * k * a * pk
            }
            // The space pull.
            let kg = params.spacePull * 0.1
            if kg > 0 && anchorX.count == n {
                for i in 0..<n where active[i] && !anchorX[i].isNaN {
                    VX[i] += (anchorX[i] - X[i]) * kg * a
                    VY[i] += (anchorY[i] - Y[i]) * kg * a
                }
            }

            // Move. The pull above keeps the graph centred, so there's no whole-graph shift each
            // tick (d3's mean centring), which reads as drift while dragging. Damping grows a little
            // as the layout cools, so the last moves settle instead of shimmering.
            let keep = params.velocityKeep * (0.8 + 0.2 * min(1, a / 0.05))
            for i in 0..<n {
                if !active[i] { continue }
                if pinned[i] {
                    X[i] = px[i]; Y[i] = py[i]; VX[i] = 0; VY[i] = 0
                } else {
                    VX[i] *= keep; VY[i] *= keep
                    X[i] += VX[i]; Y[i] += VY[i]
                }
            }
        }
        }
        }
        }
    }
}

private extension Double {
    var float: Float { Float(self) }
}

/// A small deterministic random source, so layouts and tests repeat.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func nextUInt() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func next(_ lo: Double, _ hi: Double) -> Double {
        lo + (hi - lo) * Double(nextUInt() >> 11) / Double(1 << 53)
    }
}

/// A Barnes-Hut quadtree on flat arrays, rebuilt every tick. Children always come after their
/// parent, so totals are summed by walking the arrays backwards.
struct QuadTree {
    private var child: [Int32] = []     // 4 per quad, -1 for none
    private var point: [Int32] = []     // first point of a leaf, -1 for an inner or empty quad
    private var mass: [Float] = []
    private var cx: [Float] = []
    private var cy: [Float] = []
    private var size: [Float] = []
    private var ox: [Float] = []        // quad origin
    private var oy: [Float] = []
    private var next: [Int32] = []      // per point: the next point at the same spot
    private var used = 0
    private var stack: [Int32] = []

    private mutating func newQuad(_ x0: Float, _ y0: Float, _ s: Float, point p: Int32) -> Int32 {
        if used == point.count {
            let grow = max(64, point.count)
            child.append(contentsOf: repeatElement(-1, count: grow * 4))
            point.append(contentsOf: repeatElement(-1, count: grow))
            mass.append(contentsOf: repeatElement(0, count: grow))
            cx.append(contentsOf: repeatElement(0, count: grow))
            cy.append(contentsOf: repeatElement(0, count: grow))
            size.append(contentsOf: repeatElement(0, count: grow))
            ox.append(contentsOf: repeatElement(0, count: grow))
            oy.append(contentsOf: repeatElement(0, count: grow))
        }
        let q = used
        used += 1
        child[q * 4] = -1; child[q * 4 + 1] = -1; child[q * 4 + 2] = -1; child[q * 4 + 3] = -1
        point[q] = p
        mass[q] = 0; cx[q] = 0; cy[q] = 0
        size[q] = s; ox[q] = x0; oy[q] = y0
        return Int32(q)
    }

    mutating func build(_ X: UnsafeMutableBufferPointer<Float>, _ Y: UnsafeMutableBufferPointer<Float>, _ active: [Bool], _ charge: [Float]) {
        let n = X.count
        used = 0
        if next.count != n { next = .init(repeating: -1, count: n) }
        var minX = Float.infinity, minY = Float.infinity, maxX = -Float.infinity, maxY = -Float.infinity
        for i in 0..<n where active[i] {
            minX = min(minX, X[i]); maxX = max(maxX, X[i]); minY = min(minY, Y[i]); maxY = max(maxY, Y[i])
        }
        guard minX.isFinite else { _ = newQuad(0, 0, 1, point: -1); return }
        let s = max(maxX - minX, maxY - minY, 1) * 1.0001
        _ = newQuad(minX, minY, s, point: -1)
        for i in 0..<n where active[i] {
            next[i] = -1
            insert(Int32(i), X[i], Y[i], X, Y)
        }
        // Totals and centroids, children first.
        for q in stride(from: used - 1, through: 0, by: -1) {
            let p = point[q]
            if p >= 0 {
                var m: Float = 0
                var j = p
                while j >= 0 { m += charge[Int(j)]; j = next[Int(j)] }
                mass[q] = m; cx[q] = X[Int(p)]; cy[q] = Y[Int(p)]
            } else {
                var m: Float = 0, w: Float = 0, sx: Float = 0, sy: Float = 0
                for c in 0..<4 {
                    let ch = child[q * 4 + c]
                    if ch < 0 { continue }
                    let cm = mass[Int(ch)]
                    let aw = abs(cm)
                    if aw == 0 { continue }
                    m += cm; w += aw; sx += aw * cx[Int(ch)]; sy += aw * cy[Int(ch)]
                }
                mass[q] = m
                if w > 0 { cx[q] = sx / w; cy[q] = sy / w }
            }
        }
    }

    private mutating func insert(_ p: Int32, _ px: Float, _ py: Float, _ X: UnsafeMutableBufferPointer<Float>, _ Y: UnsafeMutableBufferPointer<Float>) {
        var q = 0
        var depth = 0
        while true {
            let lp = point[q]
            if lp >= 0 {
                // A leaf: points at the same spot (or a quad too small to split) share it.
                let qx = X[Int(lp)], qy = Y[Int(lp)]
                if (qx == px && qy == py) || size[q] < 1e-3 || depth > 48 {
                    next[Int(p)] = next[Int(lp)]
                    next[Int(lp)] = p
                    return
                }
                // Split: the old point moves down a level, then keep placing the new one.
                point[q] = -1
                let h = size[q] / 2
                let c = (qx >= ox[q] + h ? 1 : 0) + (qy >= oy[q] + h ? 2 : 0)
                let nq = newQuad(ox[q] + (c & 1 == 1 ? h : 0), oy[q] + (c & 2 == 2 ? h : 0), h, point: lp)
                child[q * 4 + c] = nq
                continue
            }
            let hasChildren = child[q * 4] >= 0 || child[q * 4 + 1] >= 0 || child[q * 4 + 2] >= 0 || child[q * 4 + 3] >= 0
            if !hasChildren && q == 0 && used == 1 {
                point[0] = p
                return
            }
            let h = size[q] / 2
            let c = (px >= ox[q] + h ? 1 : 0) + (py >= oy[q] + h ? 2 : 0)
            let ch = child[q * 4 + c]
            if ch < 0 {
                child[q * 4 + c] = newQuad(ox[q] + (c & 1 == 1 ? h : 0), oy[q] + (c & 2 == 2 ? h : 0), h, point: p)
                return
            }
            q = Int(ch)
            depth += 1
        }
    }

    mutating func force(on i: Int, _ X: UnsafeMutableBufferPointer<Float>, _ Y: UnsafeMutableBufferPointer<Float>, _ charge: [Float],
                        alpha: Float, theta2: Float, distanceMax2: Float, rng: inout SplitMix) -> (Float, Float) {
        let xi = X[i], yi = Y[i]
        var fx: Float = 0, fy: Float = 0
        stack.removeAll(keepingCapacity: true)
        stack.append(0)
        let distanceMin2: Float = 1
        while let qi = stack.popLast() {
            let q = Int(qi)
            let m = mass[q]
            if m == 0 { continue }
            var dx = cx[q] - xi, dy = cy[q] - yi
            var l = dx * dx + dy * dy
            let w = size[q]
            let p = point[q]
            if p >= 0 {
                // A leaf: each point acts on its own. Points at our exact spot get a tiny nudge.
                if l >= distanceMax2 { continue }
                var j = p
                while j >= 0 {
                    if Int(j) != i {
                        var ddx = dx, ddy = dy, ll = l
                        if ddx == 0 { ddx = Float(rng.next(-1e-6, 1e-6)); ll += ddx * ddx }
                        if ddy == 0 { ddy = Float(rng.next(-1e-6, 1e-6)); ll += ddy * ddy }
                        if ll < distanceMin2 { ll = (distanceMin2 * ll).squareRoot() }
                        let s = charge[Int(j)] * alpha / ll
                        fx += ddx * s; fy += ddy * s
                    }
                    j = next[Int(j)]
                }
                continue
            }
            if w * w / theta2 < l {
                // Far enough to treat the whole quad as one body.
                if l < distanceMax2 {
                    if dx == 0 { dx = Float(rng.next(-1e-6, 1e-6)); l += dx * dx }
                    if dy == 0 { dy = Float(rng.next(-1e-6, 1e-6)); l += dy * dy }
                    if l < distanceMin2 { l = (distanceMin2 * l).squareRoot() }
                    let s = m * alpha / l
                    fx += dx * s; fy += dy * s
                }
                continue
            }
            for c in 0..<4 {
                let ch = child[q * 4 + c]
                if ch >= 0 { stack.append(ch) }
            }
        }
        return (fx, fy)
    }
}
