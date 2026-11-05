import Foundation

/// A force-directed layout in the style of d3-force: velocity Verlet with alpha cooling,
/// Barnes-Hut repulsion, springy links whose strength falls with degree, and a pull toward
/// the middle. Runs on its own queue and publishes positions for the renderer to copy.
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

        init() {}
        init(_ s: GraphSettings) {
            center = Float(s.centerForce)
            repel = Float(s.repelForce)
            linkForce = Float(s.linkForce)
            linkDistance = Float(s.linkDistance)
        }
    }

    private let queue = DispatchQueue(label: "local.browserpoc.graph.sim", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var timerRunning = false

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
    private var params = Params()
    private var alpha: Float = 1
    private var alphaTarget: Float = 0
    private var tree = QuadTree()
    private var rng = SplitMix(seed: 42)

    // Published positions.
    private let lock = NSLock()
    private var published: [SIMD2<Float>] = []
    private var publishedVersion = 0
    private var publishedAlpha: Float = 0

    /// Called on the simulation queue after each tick.
    var onTick: (@Sendable () -> Void)?

    init() {}

    // MARK: Commands

    /// Replaces the graph. `start` gives positions for nodes that had one; the rest start near a
    /// placed neighbour, or on a spiral.
    func setGraph(count n: Int, links: [(Int, Int)], radii: [Float], start: [SIMD2<Float>?], params p: Params, alpha a: Float) {
        queue.async { [self] in
            count = n
            params = p
            x = .init(repeating: 0, count: n); y = x; vx = x; vy = x
            pinned = .init(repeating: false, count: n); px = x; py = x
            active = .init(repeating: true, count: n)
            charge = .init(repeating: -p.repel * 6, count: n)
            var placed = [Bool](repeating: false, count: n)
            for i in 0..<n { if let s = start[i] { x[i] = s.x; y[i] = s.y; placed[i] = true } }
            var deg = [Int](repeating: 0, count: n)
            linkS = []; linkT = []
            linkS.reserveCapacity(links.count); linkT.reserveCapacity(links.count)
            for (s, t) in links where s != t && s < n && t < n {
                linkS.append(Int32(s)); linkT.append(Int32(t)); deg[s] += 1; deg[t] += 1
            }
            // Unplaced nodes go next to a placed neighbour, so new items appear where they belong.
            var neighbour = [Int](repeating: -1, count: n)
            for k in 0..<linkS.count {
                let s = Int(linkS[k]), t = Int(linkT[k])
                if placed[s] && !placed[t] { neighbour[t] = s }
                if placed[t] && !placed[s] { neighbour[s] = t }
            }
            let golden = Float.pi * (3 - 5.0.squareRoot().float)
            var spiral = 0
            for i in 0..<n where !placed[i] {
                if neighbour[i] >= 0 {
                    let j = neighbour[i]
                    x[i] = x[j] + Float(rng.next(-1, 1)) * p.linkDistance * 0.5
                    y[i] = y[j] + Float(rng.next(-1, 1)) * p.linkDistance * 0.5
                } else {
                    let r = 10 * (0.5 + Float(spiral)).squareRoot() * max(1, p.linkDistance / 30)
                    let ang = Float(spiral) * golden
                    x[i] = r * cos(ang); y[i] = r * sin(ang)
                    spiral += 1
                }
            }
            setupLinks(deg: deg)
            alpha = a
            alphaTarget = 0
            publish()
            startTimer()
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

    /// Pins a node under the pointer while it's dragged. The rest keeps moving.
    func drag(_ i: Int, to p: SIMD2<Float>) {
        queue.async { [self] in
            guard i < count else { return }
            pinned[i] = true; px[i] = p.x; py[i] = p.y
            x[i] = p.x; y[i] = p.y
            alphaTarget = 0.3
            alpha = max(alpha, 0.3)
            startTimer()
        }
    }

    func release(_ i: Int) {
        queue.async { [self] in
            guard i < count else { return }
            pinned[i] = false
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
            publish()
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

    /// Copies the latest positions. Returns the version so callers can skip unchanged frames.
    func withPositions<R>(_ body: (UnsafeBufferPointer<SIMD2<Float>>, Int) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return published.withUnsafeBufferPointer { body($0, publishedVersion) }
    }

    func positions() -> [SIMD2<Float>] {
        lock.lock(); defer { lock.unlock() }
        return published
    }

    /// True while the layout is still moving.
    var isMoving: Bool {
        lock.lock(); defer { lock.unlock() }
        return publishedAlpha >= params.alphaMin
    }

    var currentAlpha: Float {
        lock.lock(); defer { lock.unlock() }
        return publishedAlpha
    }

    // MARK: Loop

    private func startTimer() {
        if timer == nil {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
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
            publish()
            return
        }
        tick()
        publish()
        onTick?()
    }

    private func publish() {
        lock.lock()
        if published.count != count { published = .init(repeating: .zero, count: count) }
        for i in 0..<count { published[i] = SIMD2(x[i], y[i]) }
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
            var sx: Float = 0, sy: Float = 0, m: Float = 0
            for i in 0..<n where active[i] {
                let pk = i < pull.count ? pull[i] : 1
                VX[i] -= X[i] * k * a * pk
                VY[i] -= Y[i] * k * a * pk
                sx += X[i]; sy += Y[i]; m += 1
            }

            // Move, then keep the mean at the origin like d3's center force.
            let keep = params.velocityKeep
            let mx = m > 0 ? sx / m : 0, my = m > 0 ? sy / m : 0
            for i in 0..<n {
                if !active[i] { continue }
                if pinned[i] {
                    X[i] = px[i]; Y[i] = py[i]; VX[i] = 0; VY[i] = 0
                } else {
                    VX[i] *= keep; VY[i] *= keep
                    X[i] += VX[i] - mx; Y[i] += VY[i] - my
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
