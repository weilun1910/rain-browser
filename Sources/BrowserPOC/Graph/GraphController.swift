import AppKit
import Combine
import MetalKit
import SwiftUI

/// What the hover card shows.
struct GraphHover: Equatable {
    let title: String
    let kind: String
    let subtitle: String
    let reasons: [String]
    /// Node centre in view points, y down.
    let point: CGPoint
    let radius: CGFloat
}

enum GraphOpenMode { case normal, split }

/// One graph on screen: the layout, the simulation, the camera and the pointer. The global graph
/// and the right panel's local graph each have one.
@MainActor
final class GraphController: ObservableObject {
    enum Mode { case global, local }

    static let global = GraphController(mode: .global)
    static let local = GraphController(mode: .local)

    let mode: Mode
    let sim = ForceSimulation()
    @Published private(set) var layout = GraphLayout()
    @Published private(set) var hover: GraphHover?
    @Published private(set) var isBuilding = false
    @Published private(set) var hasLoaded = false
    /// The node the global graph is focused on, like a local graph inside the big view.
    @Published var focusID: String? { didSet { if focusID != oldValue { userMovedCamera = false; reload() } } }
    /// The browser item the local graph follows.
    @Published private(set) var centerKey: String?
    @Published private(set) var timelapse: Float?

    weak var model: BrowserModel?
    weak var view: GraphMetalView?
    private(set) var renderer: GraphRenderer?
    var expandedSites = Set<String>()
    /// The item focused in the browser gets a ring.
    var youAreHereKey: String? { didSet { if youAreHereKey != oldValue { wake() } } }

    // Camera: the world point at the middle of the view, and points per world unit.
    private(set) var camCenter = SIMD2<Float>(0, 0)
    private(set) var camScale: Float = 1
    private var viewSize = CGSize(width: 800, height: 600)
    private var userMovedCamera = false

    private var highlight: [Float] = []
    private var hovered: Int?
    private var pressed: Int?
    private var pressPoint: CGPoint = .zero
    private var lastDrag: CGPoint = .zero
    private var didDrag = false
    private var panning = false
    private var edgesDirty = true
    private var edgeData: [EdgeGPU] = []
    private var labelsPending = false
    private var buildGeneration = 0
    private var lastStructure = ""
    private var bag: Set<AnyCancellable> = []
    private var lastFrameTime = CACurrentMediaTime()
    private var timelapseMask: [Bool] = []

    init(mode: Mode) {
        self.mode = mode
        sim.onTick = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.wake() } }
        }
        NotificationCenter.default.publisher(for: .graphChanged)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.reload() } }
            .store(in: &bag)
        GraphSettingsStore.shared.$value
            .dropFirst()
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
            .sink { [weak self] s in MainActor.assumeIsolated { self?.settingsChanged(s) } }
            .store(in: &bag)
    }

    var settings: GraphSettings { GraphSettingsStore.shared.value }

    // MARK: Building

    /// The local graph follows the focused item.
    func follow(key: String?) {
        guard mode == .local, key != centerKey else { return }
        centerKey = key
        youAreHereKey = key
        userMovedCamera = false
        reload()
    }

    private func settingsChanged(_ s: GraphSettings) {
        sim.setParams(ForceSimulation.Params(s))
        if s.structureKey != lastStructure { reload() }
        wake()
    }

    /// Rebuilds the layout off the main thread, syncing the store first.
    func reload(sync: Bool = false) {
        buildGeneration += 1
        let gen = buildGeneration
        let s = settings
        lastStructure = s.structureKey
        var ctx = GraphBuildContext()
        ctx.expandedSites = expandedSites
        ctx.isLocal = mode == .local
        if mode == .local {
            ctx.focusDepth = max(1, min(3, s.localDepth))
        } else {
            ctx.focusID = focusID
            ctx.focusDepth = max(1, min(3, s.localDepth))
            if let sid = s.spaceID, let model {
                ctx.spaceKeys = Set(model.tabs.filter { $0.spaceID == sid }.compactMap(GraphRecorder.key))
            }
        }
        let centerKey = self.centerKey
        let local = mode == .local
        if local && centerKey == nil {
            apply(GraphLayout(), gen: gen)
            return
        }
        isBuilding = true
        Task.detached(priority: .userInitiated) {
            let store = GraphStore.shared
            if sync { store.sync() }
            let snap = store.snapshot()
            var c = ctx
            if local, let k = centerKey {
                guard let i = snap.indexByKey[k] else {
                    await MainActor.run { self.apply(GraphLayout(), gen: gen) }
                    return
                }
                c.focusID = snap.nodes[i].id
            }
            let layout = GraphBuilder.build(snap, s, c)
            await MainActor.run { self.apply(layout, gen: gen) }
        }
    }

    /// Shows a layout built elsewhere. For tests and the performance check.
    func load(_ layout: GraphLayout) {
        buildGeneration += 1
        apply(layout, gen: buildGeneration)
    }

    private func apply(_ new: GraphLayout, gen: Int) {
        guard gen == buildGeneration else { return }
        isBuilding = false
        hasLoaded = true
        let oldPositions = sim.positions()
        var oldByID: [String: SIMD2<Float>] = [:]
        var groupPos: [Int: SIMD2<Float>] = [:]
        for (i, n) in layout.nodes.enumerated() where i < oldPositions.count {
            oldByID[n.id] = oldPositions[i]
            if n.kind == .siteGroup { for m in n.members { groupPos[m] = oldPositions[i] } }
        }
        var rng = SplitMix(seed: UInt64(new.nodes.count) &+ 7)
        var start: [SIMD2<Float>?] = []
        var known = 0
        for n in new.nodes {
            if let p = oldByID[n.id] { start.append(p); known += 1 }
            else if let m = n.members.first, let p = groupPos[m] {
                start.append(p + SIMD2(Float(rng.next(-12, 12)), Float(rng.next(-12, 12))))
                known += 1
            } else {
                start.append(nil)
            }
        }
        // Keep the hover across a rebuild, as long as the node is still there.
        let hoveredID = hovered.flatMap { $0 < layout.nodes.count ? layout.nodes[$0].id : nil }
        layout = new
        hovered = nil
        hover = nil
        highlight = Array(repeating: 1, count: new.nodes.count)
        edgeData = new.edges.map { e in
            EdgeGPU(a: UInt32(e.a), b: UInt32(e.b),
                    type: UInt32(GraphRenderer.colorIndex(e.type)) | (e.type.directed ? 0x100 : 0), weight: e.weight)
        }
        edgesDirty = true
        let fresh = new.nodes.isEmpty ? 1 : Float(new.nodes.count - known) / Float(new.nodes.count)
        sim.setGraph(count: new.nodes.count, links: new.edges.map { ($0.a, $0.b) }, radii: new.nodes.map(\.radius),
                     start: start, params: ForceSimulation.Params(settings), alpha: fresh > 0.5 ? 1 : max(0.12, fresh))
        if timelapse != nil { timelapse = nil }
        if let id = hoveredID, let ni = new.indexByID[id] {
            sim.flush()
            setHover(ni)
        }
        wake()
    }

    // MARK: Frame

    func attach(_ v: GraphMetalView) {
        view = v
        if renderer == nil || renderer?.device !== v.device {
            renderer = GraphRenderer(device: v.device, pixelRatio: v.window?.backingScaleFactor ?? 2,
                                     theme: GraphTheme.current(for: v.effectiveAppearance))
            edgesDirty = true
        }
        if !hasLoaded { reload(sync: true) }
        if mode == .global { GraphMotionScript.start(self, view: v) }
        wake()
    }

    func themeChanged() {
        guard let v = view else { return }
        renderer?.setTheme(GraphTheme.current(for: v.effectiveAppearance))
        wake()
    }

    func wake() {
        guard let v = view else { return }
        if v.isPaused { v.isPaused = false }
    }

    var needsRedraw: Bool {
        sim.isMoving || labelsPending || timelapse != nil || highlightMoving || !userMovedCamera && fitDistance > 0.01
    }

    private var highlightMoving = false
    /// Frames drawn on screen, for the debug log.
    private(set) var framesDrawn = 0
    /// Frame pacing, measured while the motion script runs.
    let pacer = GraphFramePacer()
    private var fitDistance: Float = 0

    /// Builds what to draw this frame and advances the small animations.
    func makeFrame(size: CGSize, pixelRatio: CGFloat, appearance: NSAppearance?) -> GraphFrame {
        viewSize = size
        let now = CACurrentMediaTime()
        let dt = Float(min(0.05, now - lastFrameTime))
        lastFrameTime = now
        let theme = GraphTheme.current(for: appearance)
        let s = settings
        let layout = self.layout
        let n = layout.nodes.count
        let positions = sim.positions()
        let have = positions.count == n

        if timelapse != nil { advanceTimelapse(dt) }
        if have && !userMovedCamera { stepFit(positions, dt: dt) } else { fitDistance = 0 }

        // Hover dimming eases in and out.
        var targets = [Float](repeating: 1, count: n)
        if let h = hovered, h < n {
            let nb = layout.neighbours(h)
            for i in 0..<n { targets[i] = (i == h || nb.contains(i)) ? 1 : theme.dimAlpha }
        } else if mode == .local || focusID != nil {
            for i in 0..<n where i < layout.depth.count && layout.depth[i] >= 2 { targets[i] = 0.75 }
        }
        if highlight.count != n { highlight = Array(repeating: 1, count: n) }
        var moving = false
        let k = min(1, dt * 14)
        for i in 0..<n {
            let d = targets[i] - highlight[i]
            if abs(d) > 0.004 { highlight[i] += d * k; moving = true } else { highlight[i] = targets[i] }
        }
        highlightMoving = moving

        var frame = GraphFrame()
        frame.background = theme.background
        frame.arrows = s.arrows
        frame.uniforms = GraphUniforms(viewSize: SIMD2(Float(size.width), Float(size.height)), center: camCenter, scale: camScale,
                                       lineWidth: theme.lineWidth * Float(s.linkThickness), arrowSize: theme.arrowSize,
                                       hovered: Int32(hovered ?? -1), ringColor: theme.ring, hoverRingColor: theme.hoverRing,
                                       labelColor: theme.label)
        var styles: [NodeStyleGPU] = []
        styles.reserveCapacity(n)
        for (i, node) in layout.nodes.enumerated() {
            var alpha = highlight[i]
            if !timelapseMask.isEmpty && i < timelapseMask.count && !timelapseMask[i] { alpha = 0 }
            let isHere = (youAreHereKey != nil && node.key == youAreHereKey) || layout.center == i
            styles.append(NodeStyleGPU(color: node.groupColor ?? theme.color(node.kind), radius: node.radius, alpha: alpha,
                                       ring: isHere ? 1 : 0, hollow: node.kind == .unresolved ? 1 : 0))
        }
        frame.styles = styles
        if have, let atlas = renderer?.atlas {
            frame.labels = makeLabels(positions, styles: styles, atlas: atlas, pixelRatio: pixelRatio, theme: theme, s: s)
        }
        return frame
    }

    private func makeLabels(_ pos: [SIMD2<Float>], styles: [NodeStyleGPU], atlas: LabelAtlas, pixelRatio: CGFloat,
                            theme: GraphTheme, s: GraphSettings) -> [LabelGPU] {
        atlas.beginFrame(pixelRatio: pixelRatio)
        labelsPending = false
        let layout = self.layout
        let n = layout.nodes.count
        let w = Float(viewSize.width), h = Float(viewSize.height)
        let lo = 1.5 + Float(s.textFade) * 8, hi = lo + 3
        let nb = hovered.map { layout.neighbours($0) } ?? []
        let smallLocal = (mode == .local || focusID != nil) && n <= 40
        var cands: [(Int, Float, Float)] = [] // index, alpha, priority
        for i in 0..<n {
            let st = styles[i]
            if st.alpha < 0.05 { continue }
            let sp = (pos[i] - camCenter) * camScale + SIMD2(w / 2, h / 2)
            if sp.x < -150 || sp.x > w + 150 || sp.y < -40 || sp.y > h + 40 { continue }
            let r = max(layout.nodes[i].radius * camScale, 1.6)
            var a = min(1, max(0, (r - lo) / (hi - lo)))
            var prio = Float(layout.nodes[i].degree) * 10 + r
            if smallLocal || (layout.center != nil && i < layout.depth.count && layout.depth[i] <= 1 && mode == .local) { a = 1 }
            if let hv = hovered {
                if i == hv { a = 1; prio += 1e7 } else if nb.contains(i) { a = max(a, 0.95); prio += 1e6 } else { a *= theme.dimAlpha }
            }
            if layout.center == i { prio += 1e5 }
            a *= st.alpha > 0.5 ? 1 : st.alpha * 1.6
            if a > 0.03 { cands.append((i, min(1, a), prio)) }
        }
        cands.sort { $0.2 > $1.2 }
        var out: [LabelGPU] = []
        var placed: [Int: [CGRect]] = [:]
        let cellW: CGFloat = 80, cellH: CGFloat = 18
        for (i, a, _) in cands {
            if out.count >= 260 { break }
            guard let e = atlas.entry(id: layout.nodes[i].id, text: layout.nodes[i].title) else { labelsPending = true; continue }
            let sp = (pos[i] - camCenter) * camScale + SIMD2(w / 2, h / 2)
            let r = max(layout.nodes[i].radius * camScale, 1.6)
            let rect = CGRect(x: CGFloat(sp.x - e.size.x / 2), y: CGFloat(sp.y + r + 3), width: CGFloat(e.size.x), height: CGFloat(e.size.y))
            let x0 = Int(floor(rect.minX / cellW)), x1 = Int(floor(rect.maxX / cellW))
            let y0 = Int(floor(rect.minY / cellH)), y1 = Int(floor(rect.maxY / cellH))
            var clash = false
            outer: for cx in x0...x1 { for cy in y0...y1 {
                for other in placed[cx &* 7919 &+ cy] ?? [] where other.intersects(rect.insetBy(dx: 2, dy: 1)) { clash = true; break outer }
            } }
            if clash && hovered != i { continue }
            for cx in x0...x1 { for cy in y0...y1 { placed[cx &* 7919 &+ cy, default: []].append(rect) } }
            out.append(LabelGPU(world: pos[i], offset: SIMD2(0, r + 3), size: e.size, uv: e.uv, alpha: a))
        }
        return out
    }

    /// Eases the camera toward a view that fits everything, until Felix moves it himself.
    private func stepFit(_ pos: [SIMD2<Float>], dt: Float) {
        guard !pos.isEmpty, viewSize.width > 10, viewSize.height > 10 else { fitDistance = 0; return }
        let layout = self.layout
        var lo = SIMD2<Float>(repeating: .infinity), hi = SIMD2<Float>(repeating: -.infinity)
        for (i, p) in pos.enumerated() {
            if !timelapseMask.isEmpty && i < timelapseMask.count && !timelapseMask[i] { continue }
            lo = simd_min(lo, p); hi = simd_max(hi, p)
        }
        guard lo.x.isFinite else { fitDistance = 0; return }
        let pad: Float = mode == .local ? 36 : 60
        let size = simd_max(hi - lo, SIMD2(1, 1))
        var target = min((Float(viewSize.width) - pad * 2) / size.x, (Float(viewSize.height) - pad * 2) / size.y)
        target = min(max(target, 0.04), mode == .local ? 2.2 : 2.5)
        var c = (lo + hi) / 2
        if mode == .local, let ci = layout.center, ci < pos.count { c = c * 0.5 + pos[ci] * 0.5 }
        let k = min(1, dt * 6)
        let ds = target - camScale
        let dc = c - camCenter
        camScale += ds * k
        camCenter += dc * k
        fitDistance = abs(ds) / max(target, 0.01) + simd_length(dc) * camScale / 400
    }

    func fit() {
        userMovedCamera = false
        wake()
    }

    /// Draws into the view. Called from the view's draw.
    func drawFrame(in v: GraphMetalView) {
        guard let renderer else { return }
        let t0 = CACurrentMediaTime()
        if edgesDirty { renderer.setEdges(edgeData); edgesDirty = false }
        let frame = makeFrame(size: v.bounds.size, pixelRatio: v.window?.backingScaleFactor ?? 2, appearance: v.effectiveAppearance)
        let n = frame.styles.count
        let pacer = self.pacer
        let sim = self.sim
        var onPresented: (@Sendable (CFTimeInterval) -> Void)?
        if pacer.isMeasuring { onPresented = { (t: CFTimeInterval) in pacer.presented(t) } }
        renderer.draw(in: v, frame, onPresented: onPresented) { dst, want in
            sim.withPositions { (src, _) -> Int in
                guard src.count >= want, want == n else { return 0 }
                dst.copyMemory(from: UnsafeRawPointer(src.baseAddress!), byteCount: want * MemoryLayout<SIMD2<Float>>.stride)
                return want
            }
        }
        pacer.prepared(ms: (CACurrentMediaTime() - t0) * 1000)
        framesDrawn += 1
        if !needsRedraw {
            v.isPaused = true
            if IndexStore.debug {
                print("graph \(mode == .global ? "global" : "local"): paused after \(framesDrawn) frames, \(n) nodes, GPU \(String(format: "%.2f", renderer.lastGPUTime)) ms")
            }
        }
    }

    /// Renders offscreen. For snapshots and the performance check.
    func renderImage(size: CGSize, pixelRatio: CGFloat = 2, appearance: NSAppearance? = nil) -> CGImage? {
        if renderer == nil {
            renderer = GraphRenderer(pixelRatio: pixelRatio, theme: GraphTheme.current(for: appearance))
            edgesDirty = true
        }
        guard let renderer else { return nil }
        if edgesDirty { renderer.setEdges(edgeData); edgesDirty = false }
        var frame = makeFrame(size: size, pixelRatio: pixelRatio, appearance: appearance)
        // Names may need a few frames to fill the atlas.
        var tries = 0
        while labelsPending && tries < 40 {
            frame = makeFrame(size: size, pixelRatio: pixelRatio, appearance: appearance)
            tries += 1
        }
        let n = frame.styles.count
        return renderer.renderImage(width: Int(size.width * pixelRatio), height: Int(size.height * pixelRatio), frame) { dst, want in
            sim.withPositions { src, _ in
                guard src.count >= want, want == n else { return 0 }
                dst.copyMemory(from: UnsafeRawPointer(src.baseAddress!), byteCount: want * MemoryLayout<SIMD2<Float>>.stride)
                return want
            }
        }
    }

    /// Settles the layout right away and fits the camera. For snapshots and tests.
    func settle(ticks: Int = 300, size: CGSize) {
        sim.flush()
        sim.run(ticks: ticks)
        viewSize = size
        userMovedCamera = false
        let pos = sim.positions()
        for _ in 0..<200 { stepFit(pos, dt: 0.05) }
        highlight = Array(repeating: 1, count: layout.nodes.count)
    }

    // MARK: Timelapse

    func startTimelapse() {
        guard !layout.nodes.isEmpty else { return }
        timelapse = 0
        timelapseMask = layout.nodes.map { $0.appear <= 0 }
        sim.setActive(timelapseMask, placeNear: true)
        userMovedCamera = false
        wake()
    }

    func stopTimelapse() {
        timelapse = nil
        timelapseMask = []
        sim.setActive(Array(repeating: true, count: layout.nodes.count), placeNear: true)
        wake()
    }

    private func advanceTimelapse(_ dt: Float) {
        guard var t = timelapse else { return }
        let duration = min(12, max(4, Float(layout.nodes.count) * 0.006))
        t += dt / duration
        if t >= 1 { stopTimelapse(); return }
        timelapse = t
        let mask = layout.nodes.map { $0.appear <= t }
        if mask != timelapseMask {
            timelapseMask = mask
            sim.setActive(mask, placeNear: true)
        }
    }

    // MARK: Pointer

    func world(_ p: CGPoint) -> SIMD2<Float> {
        SIMD2(Float(p.x - viewSize.width / 2), Float(p.y - viewSize.height / 2)) / camScale + camCenter
    }

    func screen(_ w: SIMD2<Float>) -> CGPoint {
        let s = (w - camCenter) * camScale
        return CGPoint(x: CGFloat(s.x) + viewSize.width / 2, y: CGFloat(s.y) + viewSize.height / 2)
    }

    func node(at p: CGPoint) -> Int? {
        let pos = sim.positions()
        let layout = self.layout
        guard pos.count == layout.nodes.count else { return nil }
        let w = world(p)
        var best: Int?
        var bestD = Float.infinity
        for (i, q) in pos.enumerated() {
            if !timelapseMask.isEmpty && i < timelapseMask.count && !timelapseMask[i] { continue }
            let r = max(layout.nodes[i].radius, 1.6 / camScale) + 4 / camScale
            let d = simd_length(q - w)
            if d <= r && d < bestD { bestD = d; best = i }
        }
        return best
    }

    func pointerMoved(_ p: CGPoint) {
        let hit = node(at: p)
        guard hit != hovered else { return }
        setHover(hit)
    }

    private func setHover(_ hit: Int?) {
        hovered = hit
        if let h = hit {
            let n = layout.nodes[h]
            let pos = sim.positions()
            let pt = h < pos.count ? screen(pos[h]) : .zero
            var reasons: [String]
            if mode == .local, let c = layout.center, c != h, layout.neighbours(h).contains(c) {
                reasons = layout.reasons(for: h, to: c)
            } else if mode == .local, layout.center == h {
                reasons = ["The item you're on"]
            } else {
                reasons = layout.reasons(for: h)
            }
            if reasons.isEmpty { reasons = ["No connections yet"] }
            hover = GraphHover(title: Fmt.clean(n.title), kind: n.kind.singular, subtitle: n.subtitle, reasons: reasons.map(Fmt.clean),
                               point: pt, radius: CGFloat(n.radius * camScale))
            NSCursor.pointingHand.set()
        } else {
            hover = nil
            NSCursor.arrow.set()
        }
        wake()
    }

    func pointerExited() {
        if hovered != nil { setHover(nil) }
    }

    func pointerDown(_ p: CGPoint) {
        pressed = node(at: p)
        pressPoint = p
        lastDrag = p
        didDrag = false
        panning = pressed == nil
    }

    func pointerDragged(_ p: CGPoint) {
        if hypot(p.x - pressPoint.x, p.y - pressPoint.y) > 3 { didDrag = true }
        guard didDrag else { return }
        if let i = pressed {
            sim.drag(i, to: world(p))
            if hover != nil { hover = nil }
        } else if panning {
            camCenter -= SIMD2(Float(p.x - lastDrag.x), Float(p.y - lastDrag.y)) / camScale
            userMovedCamera = true
        }
        lastDrag = p
        wake()
    }

    func pointerUp(_ p: CGPoint, modifiers: NSEvent.ModifierFlags) {
        defer { pressed = nil; panning = false }
        if let i = pressed {
            if didDrag { sim.release(i); return }
            activate(i, mode: modifiers.contains(.option) ? .split : .normal)
        }
    }

    func scroll(_ e: NSEvent, at p: CGPoint) {
        if e.hasPreciseScrollingDeltas && !e.modifierFlags.contains(.command) {
            camCenter -= SIMD2(Float(-e.scrollingDeltaX), Float(-e.scrollingDeltaY)) / camScale
        } else {
            let dy = Float(e.scrollingDeltaY) * (e.hasPreciseScrollingDeltas ? 0.01 : 0.1)
            zoom(by: exp(dy), at: p)
        }
        userMovedCamera = true
        if hover != nil { setHover(nil) }
        wake()
    }

    func zoom(by f: Float, at p: CGPoint) {
        let w = world(p)
        camScale = min(8, max(0.03, camScale * f))
        camCenter = w - SIMD2(Float(p.x - viewSize.width / 2), Float(p.y - viewSize.height / 2)) / camScale
        userMovedCamera = true
        wake()
    }

    func pan(_ dx: Float, _ dy: Float) {
        camCenter += SIMD2(dx, dy) / camScale
        userMovedCamera = true
        wake()
    }

    var viewMiddle: CGPoint { CGPoint(x: viewSize.width / 2, y: viewSize.height / 2) }

    // MARK: Actions

    func activate(_ i: Int, mode open: GraphOpenMode) {
        guard i < layout.nodes.count else { return }
        let n = layout.nodes[i]
        switch n.kind {
        case .siteGroup:
            expandedSites.insert(n.host)
            reload()
        case .topic:
            if mode == .global { focusID = n.id } else { model?.openGraph(focusID: n.id) }
        case .unresolved:
            guard let model, let url = model.notes.create(in: model.newNotesFolder, title: n.title) else { return }
            if open == .split { model.openInSplit(model.openNote(url, select: false), side: .right) } else { model.openNote(url) }
        default:
            model?.openFromGraph(n, mode: open)
        }
    }

    func menu(for i: Int) -> NSMenu {
        let m = NSMenu()
        let n = layout.nodes[i]
        func add(_ title: String, _ action: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, action: action)
            m.addItem(item)
        }
        switch n.kind {
        case .siteGroup:
            add("Show each page") { [weak self] in self?.activate(i, mode: .normal) }
        case .topic, .unresolved:
            add(n.kind == .topic ? "Focus here" : "Create note") { [weak self] in self?.activate(i, mode: .normal) }
        default:
            add("Open") { [weak self] in self?.activate(i, mode: .normal) }
            add("Open in split view") { [weak self] in self?.activate(i, mode: .split) }
            if mode == .global {
                add("Focus here") { [weak self] in self?.focusID = n.id }
            } else {
                add("Show in the full graph") { [weak self] in self?.model?.openGraph(focusID: n.id) }
            }
            m.addItem(.separator())
            add("Copy link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(n.url, forType: .string)
            }
            if n.kind == .note, let u = URL(string: n.url) {
                add("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) }
            }
        }
        return m
    }
}

/// View-addressed calls, used by the motion script.
extension GraphController {
    func screen(_ w: SIMD2<Float>, in v: GraphMetalView) -> CGPoint { screen(w) }
    func pointerMoved(_ p: CGPoint, in v: GraphMetalView) { pointerMoved(p) }
    func pointerExited(in v: GraphMetalView) { pointerExited() }
    func pan(_ dx: Float, _ dy: Float, in v: GraphMetalView) { pan(dx, dy) }
    func zoom(by f: Float, at p: CGPoint, in v: GraphMetalView) { zoom(by: f, at: p) }
    func pointerDown(_ p: CGPoint, in v: GraphMetalView) { pointerDown(p) }
    func pointerDragged(_ p: CGPoint, in v: GraphMetalView) { pointerDragged(p) }
    func pointerUp(_ p: CGPoint, modifiers: NSEvent.ModifierFlags, in v: GraphMetalView) { pointerUp(p, modifiers: modifiers) }
    func focusClick(_ i: Int, in v: GraphMetalView) { focusID = layout.nodes[i].id }
    func clearSelection(in v: GraphMetalView) { focusID = nil }
    func fit(in v: GraphMetalView) { fit() }
    func wakeAll() { wake() }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, action: @escaping () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}
