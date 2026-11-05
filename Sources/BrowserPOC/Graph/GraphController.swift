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

/// One view's camera, pointer and drawing state. Each Metal view has its own, so two panes on the
/// same graph pan and zoom on their own.
@MainActor
final class GraphViewState {
    let id: UUID
    init(id: UUID = UUID()) { self.id = id }
    var center = SIMD2<Float>(0, 0)
    var scale: Float = 1
    var size = CGSize(width: 800, height: 600)
    var userMoved = false
    var fitDistance: Float = 1
    /// A camera move in progress.
    struct Glide { let fromC: SIMD2<Float>; let fromS: Float; let toC: SIMD2<Float>; let toS: Float; let start: CFTimeInterval; let duration: Double }
    var glide: Glide?
    /// A mouse wheel zoom easing toward its target, around a point.
    var wheelTarget: Float?
    var wheelAnchor = CGPoint.zero
    /// A flung background drag, in points per second.
    var momentum = SIMD2<Float>.zero
    var lastActivity: CFTimeInterval = 0
    var lastFrame: CFTimeInterval = CACurrentMediaTime()
    /// Places names must not go: the toolbar, the hover card, the settings panel.
    var occluders: [CGRect] = []
    var renderer: GraphRenderer?
    var edgeVersion = -1
    var labelsPending = false
    // Pointer.
    var pressed: Int?
    var pressPoint = CGPoint.zero
    var lastDrag = CGPoint.zero
    var didDrag = false
    var panning = false
    var samples: [(CGPoint, CFTimeInterval)] = []

    func world(_ p: CGPoint) -> SIMD2<Float> {
        SIMD2(Float(p.x - size.width / 2), Float(p.y - size.height / 2)) / scale + center
    }

    func screen(_ w: SIMD2<Float>) -> CGPoint {
        let s = (w - center) * scale
        return CGPoint(x: CGFloat(s.x) + size.width / 2, y: CGFloat(s.y) + size.height / 2)
    }

    func touch() { lastActivity = CACurrentMediaTime() }
}

/// One graph: the layout, the simulation, hover and selection, and the views showing it. The
/// global graph and the right panel's local graph each have one.
@MainActor
final class GraphController: ObservableObject {
    enum Mode { case global, local }

    static let global = GraphController(mode: .global)
    static let local = GraphController(mode: .local)

    let mode: Mode
    let sim = ForceSimulation()
    /// What's drawn. While nodes fade out after a change, they sit at the end of this list.
    @Published private(set) var layout = GraphLayout()
    /// How many nodes at the front of `layout` are live. The rest are fading out.
    private(set) var liveCount = 0
    @Published private(set) var hover: GraphHover?
    /// The view the hover card belongs to.
    @Published private(set) var hoverViewID: UUID?
    @Published private(set) var isBuilding = false
    @Published private(set) var hasLoaded = false
    /// The node the global graph is focused on, like a local graph inside the big view.
    @Published var focusID: String? { didSet { if focusID != oldValue { selected = nil; resetCameras(); reload() } } }
    /// A clicked node in the global graph: lit with its neighbours, with its card showing.
    @Published private(set) var selected: Int?
    /// The browser item the local graph follows.
    @Published private(set) var centerKey: String?
    @Published private(set) var timelapse: Float?

    weak var model: BrowserModel?
    private let views = NSHashTable<GraphMetalView>.weakObjects()
    var expandedSites = Set<String>()
    /// The item focused in the browser gets a ring.
    var youAreHereKey: String? { didSet { if youAreHereKey != oldValue { wakeAll() } } }

    private var highlight: [Float] = []
    private var presence: [Float] = []
    private var presenceTarget: [Float] = []
    private var hovered: Int?
    private var dragIndex: Int?
    private var dragWorld = SIMD2<Float>.zero
    private var edgeData: [EdgeGPU] = []
    private var edgeVersion = 0
    private var buildGeneration = 0
    private var lastStructure = ""
    private var bag: Set<AnyCancellable> = []
    private var lastShared: CFTimeInterval = 0
    private var sharedMoving = false
    private var timelapseMask: [Bool] = []
    private var compactWork: DispatchWorkItem?
    private var savedPositions: [String: SIMD2<Float>]?
    private var positionsDirty = false
    private var saveWork: DispatchWorkItem?
    /// State for offscreen renders and tests.
    let offscreen = GraphViewState()

    /// Frames drawn on screen, for the debug log.
    private(set) var framesDrawn = 0
    /// Frame pacing, measured while the motion script runs.
    let pacer = GraphFramePacer()

    init(mode: Mode) {
        self.mode = mode
        sim.onTick = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.simTicked() } }
        }
        NotificationCenter.default.publisher(for: .graphChanged)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.reload() } }
            .store(in: &bag)
        GraphSettingsStore.shared.$value
            .dropFirst()
            .debounce(for: .milliseconds(90), scheduler: DispatchQueue.main)
            .sink { [weak self] s in MainActor.assumeIsolated { self?.settingsChanged(s) } }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.savePositions(now: true) } }
            .store(in: &bag)
    }

    var settings: GraphSettings { GraphSettingsStore.shared.value }

    /// The most recently attached view.
    var view: GraphMetalView? { views.allObjects.last }

    // MARK: Building

    /// The local graph follows the focused item.
    func follow(key: String?) {
        guard mode == .local, key != centerKey else { return }
        centerKey = key
        youAreHereKey = key
        resetCameras()
        reload()
    }

    private func resetCameras() {
        for v in views.allObjects { v.state.userMoved = false; v.state.glide = nil }
        offscreen.userMoved = false
    }

    private func settingsChanged(_ s: GraphSettings) {
        sim.setParams(ForceSimulation.Params(s))
        if s.structureKey != lastStructure { reload() }
        wakeAll()
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
        ctx.focusDepth = max(1, min(3, s.localDepth))
        if mode == .global {
            ctx.focusID = focusID
            if let sid = s.spaceID, let model {
                ctx.spaceKeys = Set(model.tabs.filter { $0.spaceID == sid }.compactMap(GraphRecorder.key))
            }
        }
        if let model { fillSpaces(&ctx, model) }
        let centerKey = self.centerKey
        let local = mode == .local
        if local && centerKey == nil {
            apply(GraphLayout(), gen: gen)
            return
        }
        let needSaved = mode == .global && savedPositions == nil
        isBuilding = true
        Task.detached(priority: .userInitiated) {
            let store = GraphStore.shared
            if sync { store.sync() }
            let snap = store.snapshot()
            let saved = needSaved ? store.loadPositions(scope: "global") : nil
            var c = ctx
            if local, let k = centerKey {
                guard let i = snap.indexByKey[k] else {
                    await MainActor.run { self.apply(GraphLayout(), gen: gen) }
                    return
                }
                c.focusID = snap.nodes[i].id
            }
            let layout = GraphBuilder.build(snap, s, c)
            await MainActor.run {
                if let saved, self.savedPositions == nil { self.savedPositions = saved }
                self.apply(layout, gen: gen)
            }
        }
    }

    /// Spaces for colouring and seeding: what's open, pinned or filed where, and notes folders.
    private func fillSpaces(_ ctx: inout GraphBuildContext, _ model: BrowserModel) {
        var index: [UUID: Int] = [:]
        for (i, sp) in model.spaces.enumerated() {
            index[sp.id] = i
            ctx.spaceColors.append(sp.color)
            if let f = sp.newNotesFolder {
                var p = URL(fileURLWithPath: f, isDirectory: true).standardizedFileURL.path
                if !p.hasSuffix("/") { p += "/" }
                ctx.spaceFolders.append((p, i))
            }
        }
        for t in model.tabs {
            if let sid = t.spaceID, let i = index[sid], let k = GraphRecorder.key(t), ctx.spaceOfKey[k] == nil { ctx.spaceOfKey[k] = i }
        }
    }

    /// Shows a layout built elsewhere. For tests and the performance check.
    func load(_ layout: GraphLayout) {
        buildGeneration += 1
        apply(layout, gen: buildGeneration)
    }

    /// Puts a new layout on screen. Nodes in both keep their place. New ones fade and grow in next
    /// to their neighbours. Ones that are gone stay where they were and fade out, then drop away.
    private func apply(_ new: GraphLayout, gen: Int) {
        guard gen == buildGeneration else { return }
        isBuilding = false
        let firstLoad = !hasLoaded
        hasLoaded = true
        compactWork?.cancel()

        let old = layout
        let oldLive = liveCount
        let oldPositions = sim.positions()
        var oldPos: [String: SIMD2<Float>] = [:]
        var oldPresence: [String: Float] = [:]
        var groupPos: [Int: SIMD2<Float>] = [:]
        for (i, n) in old.nodes.enumerated() where i < oldPositions.count && i < oldLive {
            oldPos[n.id] = oldPositions[i]
            oldPresence[n.id] = i < presence.count ? presence[i] : 1
            if n.kind == .siteGroup { for m in n.members { groupPos[m] = oldPositions[i] } }
        }
        let hoveredID = hovered.flatMap { $0 < old.nodes.count ? old.nodes[$0].id : nil }
        let selectedID = selected.flatMap { $0 < old.nodes.count ? old.nodes[$0].id : nil }

        // Merge: the new nodes first, then the old live ones that left.
        var merged = new
        let newIDs = Set(new.nodes.map(\.id))
        var leavingIndex: [Int: Int] = [:] // old index -> merged index
        for i in 0..<min(oldLive, old.nodes.count) where !newIDs.contains(old.nodes[i].id) {
            leavingIndex[i] = merged.nodes.count
            merged.nodes.append(old.nodes[i])
            merged.depth.append(-1)
        }
        if !leavingIndex.isEmpty {
            for e in old.edges {
                guard e.a < oldLive, e.b < oldLive else { continue }
                let a = leavingIndex[e.a] ?? new.indexByID[old.nodes[e.a].id]
                let b = leavingIndex[e.b] ?? new.indexByID[old.nodes[e.b].id]
                guard let a, let b, leavingIndex[e.a] != nil || leavingIndex[e.b] != nil else { continue }
                merged.edges.append(LayoutEdge(a: a, b: b, type: e.type, types: e.types, weight: e.weight, links: []))
            }
            merged.adjacency = Array(repeating: [], count: merged.nodes.count)
            for (ei, e) in merged.edges.enumerated() { merged.adjacency[e.a].append(ei); merged.adjacency[e.b].append(ei) }
        }

        var rng = SplitMix(seed: UInt64(new.nodes.count) &+ 7)
        var start: [SIMD2<Float>?] = []
        var groups: [Int?] = []
        var known = 0, fromSaved = 0
        let saved = savedPositions ?? [:]
        for (i, n) in merged.nodes.enumerated() {
            if i >= new.nodes.count {
                let oi = leavingIndex.first { $0.value == i }!.key
                start.append(oi < oldPositions.count ? oldPositions[oi] : nil)
            } else if let p = oldPos[n.id] {
                start.append(p); known += 1
            } else if let p = saved[n.id] {
                start.append(p); known += 1; fromSaved += 1
            } else if let m = n.members.first, let p = groupPos[m] {
                start.append(p + SIMD2(Float(rng.next(-12, 12)), Float(rng.next(-12, 12))))
                known += 1
            } else {
                start.append(nil)
            }
            groups.append(n.space)
        }

        presence = merged.nodes.indices.map { i in
            if i >= new.nodes.count { return oldPresence[merged.nodes[i].id] ?? 1 }
            return oldPresence[merged.nodes[i].id] ?? 0
        }
        presenceTarget = merged.nodes.indices.map { $0 < new.nodes.count ? 1 : 0 }
        layout = merged
        liveCount = new.nodes.count
        highlight = Array(repeating: 1, count: merged.nodes.count)
        hovered = nil
        hover = nil
        selected = selectedID.flatMap { new.indexByID[$0] }
        dragIndex = nil
        edgeData = merged.edges.map { e in
            EdgeGPU(a: UInt32(e.a), b: UInt32(e.b),
                    type: UInt32(GraphRenderer.colorIndex(e.type)) | (e.type.directed ? 0x100 : 0), weight: e.weight)
        }
        edgeVersion += 1

        // A calm start: mostly known positions barely move. A fresh layout warms up offscreen
        // first and then fades in, instead of exploding out of the middle.
        let n = max(1, new.nodes.count)
        let freshShare = Float(n - known) / Float(n)
        var alpha: Float
        var warmup = 0
        if freshShare < 0.05 {
            alpha = fromSaved > n / 2 ? 0.02 : 0.12
        } else if freshShare < 0.5 {
            alpha = mode == .local ? 0.35 : 0.3
        } else {
            alpha = mode == .local ? 0.6 : 1
            warmup = mode == .local ? 40 : max(15, min(220, 1_200_000 / max(1, n * 25)))
        }
        if firstLoad && freshShare >= 0.5 { for i in presence.indices { presence[i] = 0 } }
        let active = merged.nodes.indices.map { $0 < new.nodes.count }
        sim.setGraph(count: merged.nodes.count, links: merged.edges.map { ($0.a, $0.b) }, start: start, groups: groups,
                     active: active, params: ForceSimulation.Params(settings), alpha: alpha, warmup: warmup)
        if timelapse != nil { timelapse = nil; timelapseMask = [] }
        if let id = hoveredID, let ni = new.indexByID[id], let v = view {
            sim.flush()
            setHover(ni, in: v)
        } else if selected != nil {
            refreshCard()
        }
        if merged.nodes.count > new.nodes.count {
            let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.compact() } }
            compactWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + GraphTheme.exit + 0.05, execute: w)
        }
        wakeAll()
    }

    /// Drops the nodes that finished fading out.
    private func compact() {
        guard layout.nodes.count > liveCount else { return }
        var l = layout
        let n = liveCount
        l.nodes = Array(l.nodes.prefix(n))
        l.depth = Array(l.depth.prefix(n))
        l.edges = l.edges.filter { $0.a < n && $0.b < n }
        l.adjacency = Array(repeating: [], count: n)
        for (ei, e) in l.edges.enumerated() { l.adjacency[e.a].append(ei); l.adjacency[e.b].append(ei) }
        layout = l
        presence = Array(presence.prefix(n)); presenceTarget = Array(presenceTarget.prefix(n)); highlight = Array(highlight.prefix(n))
        if let h = hovered, h >= n { hovered = nil; hover = nil }
        edgeData = l.edges.map { e in
            EdgeGPU(a: UInt32(e.a), b: UInt32(e.b), type: UInt32(GraphRenderer.colorIndex(e.type)) | (e.type.directed ? 0x100 : 0), weight: e.weight)
        }
        edgeVersion += 1
        sim.truncate(to: n, links: l.edges.map { ($0.a, $0.b) })
        wakeAll()
    }

    // MARK: Views

    func attach(_ v: GraphMetalView) {
        views.add(v)
        let st = v.state
        if st.renderer == nil || st.renderer?.device !== v.device {
            st.renderer = GraphRenderer(device: v.device, pixelRatio: v.window?.backingScaleFactor ?? 2,
                                        theme: GraphTheme.current(for: v.effectiveAppearance))
            st.edgeVersion = -1
        }
        if !hasLoaded { reload(sync: true) }
        if mode == .global { GraphMotionScript.start(self, view: v) }
        wake(v)
    }

    func detach(_ v: GraphMetalView) { views.remove(v) }

    func themeChanged(_ v: GraphMetalView) {
        v.state.renderer?.setTheme(GraphTheme.current(for: v.effectiveAppearance))
        wake(v)
    }

    func wake(_ v: GraphMetalView) {
        if v.isPaused { v.isPaused = false }
    }

    func wakeAll() { for v in views.allObjects { wake(v) } }

    private func simTicked() {
        positionsDirty = true
        wakeAll()
    }

    func needsRedraw(_ st: GraphViewState, now: CFTimeInterval) -> Bool {
        if sim.isMoving || sharedMoving || timelapse != nil || st.glide != nil || st.wheelTarget != nil || st.labelsPending { return true }
        if simd_length(st.momentum) > 2 { return true }
        if !st.userMoved && st.fitDistance > 0.004 { return true }
        return now - st.lastActivity < GraphTheme.activityGrace
    }

    // MARK: Frames

    /// Advances the animations every view shares (hover easing, fades, the timelapse), once per
    /// frame time however many views draw.
    private func advanceShared(_ now: CFTimeInterval) {
        let dt = Float(min(0.05, max(0, now - lastShared)))
        if dt < 0.001 { return }
        lastShared = now
        let n = layout.nodes.count
        if timelapse != nil { advanceTimelapse(dt) }
        var targets = [Float](repeating: 1, count: n)
        let theme = GraphTheme.dark
        if let h = hovered ?? selected, h < n {
            let nb = layout.neighbours(h)
            for i in 0..<n { targets[i] = (i == h || nb.contains(i)) ? 1 : theme.dimAlpha }
        } else if mode == .local || focusID != nil {
            for i in 0..<n where i < layout.depth.count && layout.depth[i] >= 2 { targets[i] = 0.75 }
        }
        if highlight.count != n { highlight = Array(repeating: 1, count: n) }
        if presence.count != n { presence = Array(repeating: 1, count: n); presenceTarget = presence }
        var moving = false
        // Exponential easing that's 95% of the way there after `hoverFade`.
        let k = 1 - exp(-dt * 3 / Float(GraphTheme.hoverFade))
        for i in 0..<n {
            let d = targets[i] - highlight[i]
            if abs(d) > 0.003 { highlight[i] += d * k; moving = true } else { highlight[i] = targets[i] }
            let pt = presenceTarget[i]
            if presence[i] != pt {
                let step = dt / Float(pt > presence[i] ? GraphTheme.enter : GraphTheme.exit)
                presence[i] = pt > presence[i] ? min(pt, presence[i] + step) : max(pt, presence[i] - step)
                moving = true
            }
        }
        sharedMoving = moving
    }

    /// Steps one view's camera: glides, wheel zoom, momentum, and following the layout until moved.
    private func stepCamera(_ st: GraphViewState, _ pos: [SIMD2<Float>], now: CFTimeInterval, dt: Float) {
        if let g = st.glide {
            let t = (now - g.start) / g.duration
            let e = Float(graphEaseOut(t))
            st.center = g.fromC + (g.toC - g.fromC) * e
            st.scale = exp(log(g.fromS) + (log(g.toS) - log(g.fromS)) * e)
            if t >= 1 { st.glide = nil }
        }
        if let target = st.wheelTarget {
            let k = 1 - exp(-dt * 3 / Float(GraphTheme.wheelZoom))
            let w = st.world(st.wheelAnchor)
            st.scale += (target - st.scale) * k
            st.center = w - SIMD2(Float(st.wheelAnchor.x - st.size.width / 2), Float(st.wheelAnchor.y - st.size.height / 2)) / st.scale
            if abs(target - st.scale) / target < 0.002 { st.wheelTarget = nil }
        }
        if simd_length(st.momentum) > 2 {
            st.center -= st.momentum * dt / st.scale
            st.momentum *= exp(-dt / Float(GraphTheme.momentumTime))
        } else {
            st.momentum = .zero
        }
        if !st.userMoved && st.glide == nil { stepFit(st, pos, dt: dt) } else { st.fitDistance = 0 }
    }

    private func fitTarget(_ st: GraphViewState, _ pos: [SIMD2<Float>]) -> (SIMD2<Float>, Float)? {
        guard !pos.isEmpty, st.size.width > 10, st.size.height > 10 else { return nil }
        var lo = SIMD2<Float>(repeating: .infinity), hi = SIMD2<Float>(repeating: -.infinity)
        for i in 0..<min(pos.count, liveCount) {
            if !timelapseMask.isEmpty && i < timelapseMask.count && !timelapseMask[i] { continue }
            lo = simd_min(lo, pos[i]); hi = simd_max(hi, pos[i])
        }
        guard lo.x.isFinite else { return nil }
        let pad: Float = mode == .local ? 30 : 64
        let size = simd_max(hi - lo, SIMD2(1, 1))
        var s = min((Float(st.size.width) - pad * 2) / size.x, (Float(st.size.height) - pad * 2) / size.y)
        s = min(max(s, 0.04), mode == .local ? 2.2 : 2.5)
        var c = (lo + hi) / 2
        if mode == .local, let ci = layout.center, ci < pos.count { c = c * 0.5 + pos[ci] * 0.5 }
        return (c, s)
    }

    /// Eases the camera toward a view that fits everything, until Felix moves it himself.
    private func stepFit(_ st: GraphViewState, _ pos: [SIMD2<Float>], dt: Float) {
        guard let (c, target) = fitTarget(st, pos) else { st.fitDistance = 0; return }
        let k = 1 - exp(-dt * 4)
        let ds = target - st.scale
        let dc = c - st.center
        st.scale += ds * k
        st.center += dc * k
        st.fitDistance = abs(ds) / max(target, 0.01) + simd_length(dc) * st.scale / 400
    }

    /// Glides to fit everything, then keeps following the layout.
    func fit(in v: GraphMetalView) {
        let st = v.state
        if let (c, s) = fitTarget(st, sim.positions()) { glide(st, to: c, scale: s) }
        st.userMoved = false
        wake(v)
    }

    private func glide(_ st: GraphViewState, to c: SIMD2<Float>, scale s: Float, duration: Double = GraphTheme.glide) {
        st.momentum = .zero
        st.wheelTarget = nil
        st.glide = GraphViewState.Glide(fromC: st.center, fromS: st.scale, toC: c, toS: s, start: CACurrentMediaTime(), duration: duration)
        st.touch()
    }

    /// Builds what to draw this frame for one view and advances its animations.
    func makeFrame(_ st: GraphViewState, pixelRatio: CGFloat, appearance: NSAppearance?, now: CFTimeInterval = CACurrentMediaTime()) -> GraphFrame {
        let dt = Float(min(0.05, max(0, now - st.lastFrame)))
        st.lastFrame = now
        advanceShared(now)
        let theme = GraphTheme.current(for: appearance)
        let s = settings
        let layout = self.layout
        let n = layout.nodes.count
        let pos = sim.blended(now: now)
        let have = pos.count == n
        if have { stepCamera(st, pos, now: now, dt: dt) }

        var frame = GraphFrame()
        frame.background = theme.background
        frame.arrows = s.arrows
        let ringHex = model?.currentSpace?.color
        frame.uniforms = GraphUniforms(viewSize: SIMD2(Float(st.size.width), Float(st.size.height)), center: st.center, scale: st.scale,
                                       lineWidth: theme.lineWidth * Float(s.linkThickness), arrowSize: theme.arrowSize,
                                       hovered: Int32(hovered ?? selected ?? -1), ringColor: ringHex.map { theme.accent($0) } ?? theme.ring,
                                       hoverRingColor: theme.hoverRing, labelColor: theme.label)
        var styles: [NodeStyleGPU] = []
        styles.reserveCapacity(n)
        let bySpace = s.colorBy == .space
        for (i, node) in layout.nodes.enumerated() {
            let p = graphEase(i < presence.count ? presence[i] : 1)
            var alpha = (i < highlight.count ? highlight[i] : 1) * p
            if !timelapseMask.isEmpty && i < timelapseMask.count && !timelapseMask[i] { alpha = 0 }
            let isHere = (youAreHereKey != nil && node.key == youAreHereKey) || layout.center == i
            var color = theme.color(node.kind)
            if let g = node.groupColor { color = g } else if bySpace, let sp = node.space, sp < layout.spaceColors.count {
                color = theme.spaceColor(layout.spaceColors[sp], kind: node.kind)
            } else if bySpace && !layout.spaceColors.isEmpty {
                color = theme.neutral(node.kind)
            }
            styles.append(NodeStyleGPU(color: color, radius: node.radius * (0.55 + 0.45 * p), alpha: alpha,
                                       ring: isHere ? 1 : 0, hollow: node.kind == .unresolved ? 1 : 0))
        }
        frame.styles = styles
        if have, let atlas = st.renderer?.atlas {
            let tl = CACurrentMediaTime()
            frame.labels = makeLabels(st, pos, styles: styles, atlas: atlas, pixelRatio: pixelRatio, theme: theme, s: s)
            pacer.part("labels", ms: (CACurrentMediaTime() - tl) * 1000)
        }
        return frame
    }

    private func makeLabels(_ st: GraphViewState, _ pos: [SIMD2<Float>], styles: [NodeStyleGPU], atlas: LabelAtlas, pixelRatio: CGFloat,
                            theme: GraphTheme, s: GraphSettings) -> [LabelGPU] {
        atlas.beginFrame(pixelRatio: pixelRatio)
        st.labelsPending = false
        let layout = self.layout
        let n = layout.nodes.count
        let w = Float(st.size.width), h = Float(st.size.height)
        let focus = hovered ?? selected
        let nb = focus.map { layout.neighbours($0) } ?? []
        let smallLocal = (mode == .local || focusID != nil) && n <= 40
        // Node discs on screen, so names can keep off other nodes.
        let cell: Float = 48
        var discs: [Int: [(SIMD2<Float>, Float, Int)]] = [:]
        var screenPos = [SIMD2<Float>](repeating: .zero, count: n)
        var screenR = [Float](repeating: 0, count: n)
        var cands: [(Int, Float, Float)] = [] // index, alpha, priority
        for i in 0..<n {
            let sp = (pos[i] - st.center) * st.scale + SIMD2(w / 2, h / 2)
            let r = max(styles[i].radius * st.scale, 1.6)
            screenPos[i] = sp; screenR[i] = r
            if styles[i].alpha < 0.05 { continue }
            if sp.x < -150 || sp.x > w + 150 || sp.y < -40 || sp.y > h + 40 { continue }
            // Only lit nodes keep names off them. Dimmed ones sit behind.
            if styles[i].alpha > 0.5 { discs[Int(floor(sp.x / cell)) &* 7919 &+ Int(floor(sp.y / cell)), default: []].append((sp, r, i)) }
            // Names fade in as nodes grow on screen: bigger, better connected nodes first.
            let lo = 1.5 + Float(s.textFade) * 8 - min(2, log2(1 + Float(layout.nodes[i].degree)) * 0.5)
            var a = min(1, max(0, (r - lo) / 3))
            var prio = Float(layout.nodes[i].degree) * 10 + r
            if smallLocal || (mode == .local && i < layout.depth.count && layout.depth[i] >= 0 && layout.depth[i] <= 1) { a = 1 }
            if let f = focus {
                if i == f { a = 1; prio += 1e7 } else if nb.contains(i) { a = max(a, 0.95); prio += 1e6 } else { a *= theme.dimAlpha }
            }
            if layout.center == i { prio += 1e5 }
            a *= styles[i].alpha > 0.5 ? 1 : styles[i].alpha * 1.6
            if a > 0.03 { cands.append((i, min(1, a), prio)) }
        }
        cands.sort { $0.2 > $1.2 }
        var out: [LabelGPU] = []
        var placed: [Int: [CGRect]] = [:]
        let cellW: CGFloat = 80, cellH: CGFloat = 18
        let occluders = st.occluders
        for (i, a, _) in cands {
            if out.count >= 260 { break }
            guard let e = atlas.entry(id: layout.nodes[i].id, text: layout.nodes[i].title) else { st.labelsPending = true; continue }
            let sp = screenPos[i], r = screenR[i]
            let rect = CGRect(x: CGFloat(sp.x - e.size.x / 2), y: CGFloat(sp.y + r + 3), width: CGFloat(e.size.x), height: CGFloat(e.size.y))
            if occluders.contains(where: { $0.intersects(rect) }) { continue }
            let important = i == focus
            // Other labels.
            let x0 = Int(floor(rect.minX / cellW)), x1 = Int(floor(rect.maxX / cellW))
            let y0 = Int(floor(rect.minY / cellH)), y1 = Int(floor(rect.maxY / cellH))
            var clash = false
            outer: for cx in x0...x1 { for cy in y0...y1 {
                // A little air around each name, so two never run into each other.
                for other in placed[cx &* 7919 &+ cy] ?? [] where other.intersects(rect.insetBy(dx: -6, dy: -1)) { clash = true; break outer }
            } }
            if clash && !important { continue }
            // Other nodes.
            if !important {
                let inner = rect.insetBy(dx: 3, dy: 2)
                let gx0 = Int(floor(Float(inner.minX) / cell)) - 1, gx1 = Int(floor(Float(inner.maxX) / cell)) + 1
                let gy0 = Int(floor(Float(inner.minY) / cell)) - 1, gy1 = Int(floor(Float(inner.maxY) / cell)) + 1
                var hitsNode = false
                nodes: for gx in gx0...gx1 { for gy in gy0...gy1 {
                    for (c, rr, j) in discs[gx &* 7919 &+ gy] ?? [] where j != i && rr >= 2 {
                        let nx = min(max(CGFloat(c.x), inner.minX), inner.maxX), ny = min(max(CGFloat(c.y), inner.minY), inner.maxY)
                        if hypot(nx - CGFloat(c.x), ny - CGFloat(c.y)) < CGFloat(rr) { hitsNode = true; break nodes }
                    }
                } }
                if hitsNode { continue }
            }
            for cx in x0...x1 { for cy in y0...y1 { placed[cx &* 7919 &+ cy, default: []].append(rect) } }
            out.append(LabelGPU(world: pos[i], offset: SIMD2(0, r + 3), size: e.size, uv: e.uv, alpha: a))
        }
        return out
    }

    /// Draws into the view. Called from the view's draw.
    func drawFrame(in v: GraphMetalView) {
        let st = v.state
        guard let renderer = st.renderer else { return }
        let t0 = CACurrentMediaTime()
        st.size = v.bounds.size
        if st.edgeVersion != edgeVersion { renderer.setEdges(edgeData); st.edgeVersion = edgeVersion }
        let frame = makeFrame(st, pixelRatio: v.window?.backingScaleFactor ?? 2, appearance: v.effectiveAppearance, now: t0)
        let t1 = CACurrentMediaTime()
        pacer.part("make", ms: (t1 - t0) * 1000)
        let n = frame.styles.count
        let pacer = self.pacer
        let sim = self.sim
        let drag = dragIndex.map { ($0, dragWorld) }
        var onPresented: (@Sendable (CFTimeInterval) -> Void)?
        if pacer.isMeasuring { onPresented = { (t: CFTimeInterval) in pacer.presented(t) } }
        renderer.draw(in: v, frame, onPresented: onPresented) { dst, want in
            let p = dst.bindMemory(to: SIMD2<Float>.self, capacity: want)
            let copied = want == n ? sim.copyBlended(into: p, count: want, now: t0) : 0
            // The dragged node sits right under the pointer, with no tick of lag.
            if copied > 0, let (i, w) = drag, i < want { p[i] = w }
            return copied
        }
        pacer.part("draw", ms: (CACurrentMediaTime() - t1) * 1000)
        pacer.prepared(ms: (CACurrentMediaTime() - t0) * 1000)
        framesDrawn += 1
        if !needsRedraw(st, now: t0) {
            v.isPaused = true
            pacer.markPause()
            if positionsDirty && mode == .global { scheduleSave() }
            if IndexStore.debug {
                print("graph \(mode == .global ? "global" : "local"): paused after \(framesDrawn) frames, \(n) nodes, GPU \(String(format: "%.2f", renderer.lastGPUTime)) ms")
            }
        }
    }

    /// Renders offscreen with a view's camera, or the offscreen one. For snapshots and checks.
    func renderImage(size: CGSize, pixelRatio: CGFloat = 2, appearance: NSAppearance? = nil, state: GraphViewState? = nil) -> CGImage? {
        let st = state ?? offscreen
        st.size = size
        if st.renderer == nil {
            st.renderer = GraphRenderer(pixelRatio: pixelRatio, theme: GraphTheme.current(for: appearance))
            st.edgeVersion = -1
        }
        guard let renderer = st.renderer else { return nil }
        renderer.setTheme(GraphTheme.current(for: appearance))
        if st.edgeVersion != edgeVersion { renderer.setEdges(edgeData); st.edgeVersion = edgeVersion }
        var frame = makeFrame(st, pixelRatio: pixelRatio, appearance: appearance)
        // Names may need a few frames to fill the atlas.
        var tries = 0
        while st.labelsPending && tries < 40 {
            frame = makeFrame(st, pixelRatio: pixelRatio, appearance: appearance)
            tries += 1
        }
        let n = frame.styles.count
        let sim = self.sim
        let now = CACurrentMediaTime()
        return renderer.renderImage(width: Int(size.width * pixelRatio), height: Int(size.height * pixelRatio), frame) { dst, want in
            want == n ? sim.copyBlended(into: dst.bindMemory(to: SIMD2<Float>.self, capacity: want), count: want, now: now + 1) : 0
        }
    }

    /// Ends every animation and settles the layout right away. For snapshots and tests.
    func settle(ticks: Int = 300, size: CGSize) {
        sim.flush()
        compact()
        sim.flush()
        sim.run(ticks: ticks)
        for i in presence.indices { presence[i] = presenceTarget[i] }
        highlight = Array(repeating: 1, count: layout.nodes.count)
        sharedMoving = false
        let pos = sim.positions()
        offscreen.size = size
        for st in [offscreen] + views.allObjects.map(\.state) {
            st.userMoved = false
            st.glide = nil
            if let (c, s) = fitTarget(st, pos) { st.center = c; st.scale = s }
            st.fitDistance = 0
        }
    }

    // MARK: Positions

    private func scheduleSave() {
        guard mode == .global else { return }
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.savePositions(now: false) } }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: w)
    }

    private func savePositions(now: Bool) {
        guard mode == .global, positionsDirty, liveCount > 0 else { return }
        let pos = sim.positions()
        var out: [String: SIMD2<Float>] = [:]
        for i in 0..<min(liveCount, pos.count, layout.nodes.count) { out[layout.nodes[i].id] = pos[i] }
        positionsDirty = false
        savedPositions = out
        if now { GraphStore.shared.savePositionsNow(scope: "global", out) } else { GraphStore.shared.savePositions(scope: "global", out) }
    }

    // MARK: Timelapse

    func startTimelapse() {
        guard !layout.nodes.isEmpty else { return }
        compact()
        timelapse = 0
        timelapseMask = layout.nodes.map { $0.appear <= 0 }
        sim.setActive(timelapseMask, placeNear: true)
        resetCameras()
        wakeAll()
    }

    func stopTimelapse() {
        timelapse = nil
        timelapseMask = []
        sim.setActive(Array(repeating: true, count: layout.nodes.count), placeNear: true)
        wakeAll()
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

    func node(at p: CGPoint, in st: GraphViewState) -> Int? {
        let pos = sim.positions()
        let layout = self.layout
        guard pos.count == layout.nodes.count else { return nil }
        let w = st.world(p)
        var best: Int?
        var bestD = Float.infinity
        for i in 0..<min(liveCount, pos.count) {
            if !timelapseMask.isEmpty && i < timelapseMask.count && !timelapseMask[i] { continue }
            let r = max(layout.nodes[i].radius, 1.6 / st.scale) + 4 / st.scale
            let d = simd_length(pos[i] - w)
            if d <= r && d < bestD { bestD = d; best = i }
        }
        return best
    }

    func node(at p: CGPoint, in v: GraphMetalView) -> Int? { node(at: p, in: v.state) }

    func screen(_ w: SIMD2<Float>, in v: GraphMetalView) -> CGPoint { v.state.screen(w) }

    func pointerMoved(_ p: CGPoint, in v: GraphMetalView) {
        v.state.touch()
        guard v.state.pressed == nil || !v.state.didDrag else { return }
        let hit = node(at: p, in: v.state)
        guard hit != hovered || hoverViewID != v.state.id else { return }
        setHover(hit, in: v)
    }

    private func card(for h: Int, point: CGPoint, radius: CGFloat) -> GraphHover {
        let n = layout.nodes[h]
        var reasons: [String]
        if mode == .local, let c = layout.center, c != h, layout.neighbours(h).contains(c) {
            reasons = layout.reasons(for: h, to: c)
        } else if mode == .local, layout.center == h {
            reasons = ["The item you're on"]
        } else {
            reasons = layout.reasons(for: h)
        }
        if reasons.isEmpty { reasons = ["No connections yet"] }
        return GraphHover(title: Fmt.clean(n.title), kind: n.kind.singular, subtitle: n.subtitle, reasons: reasons.map(Fmt.clean),
                          point: point, radius: radius)
    }

    private func setHover(_ hit: Int?, in v: GraphMetalView) {
        hovered = hit
        hoverViewID = v.state.id
        if let h = hit {
            let pos = sim.positions()
            let pt = h < pos.count ? v.state.screen(pos[h]) : .zero
            hover = card(for: h, point: pt, radius: CGFloat(layout.nodes[h].radius * v.state.scale))
            NSCursor.pointingHand.set()
        } else {
            refreshCard()
            NSCursor.arrow.set()
        }
        wakeAll()
    }

    /// With nothing hovered, the card shows the selected node.
    private func refreshCard() {
        if let s = selected, s < layout.nodes.count {
            hover = card(for: s, point: .zero, radius: 0)
        } else {
            hover = nil
        }
    }

    func pointerExited(in v: GraphMetalView) {
        if hovered != nil { setHover(nil, in: v) }
    }

    func pointerDown(_ p: CGPoint, in v: GraphMetalView) {
        let st = v.state
        st.touch()
        st.pressed = node(at: p, in: st)
        st.pressPoint = p
        st.lastDrag = p
        st.didDrag = false
        st.panning = st.pressed == nil
        st.momentum = .zero
        st.glide = nil
        st.wheelTarget = nil
        st.samples = [(p, CACurrentMediaTime())]
        wake(v)
    }

    func pointerDragged(_ p: CGPoint, in v: GraphMetalView) {
        let st = v.state
        st.touch()
        if hypot(p.x - st.pressPoint.x, p.y - st.pressPoint.y) > 3 { st.didDrag = true }
        guard st.didDrag else { return }
        if let i = st.pressed {
            let w = st.world(p)
            dragIndex = i
            dragWorld = w
            sim.drag(i, to: w)
            if hover != nil && hovered != nil { hover = nil }
        } else if st.panning {
            st.center -= SIMD2(Float(p.x - st.lastDrag.x), Float(p.y - st.lastDrag.y)) / st.scale
            st.userMoved = true
            let now = CACurrentMediaTime()
            st.samples.append((p, now))
            st.samples.removeAll { now - $0.1 > 0.1 }
        }
        st.lastDrag = p
        wake(v)
    }

    func pointerUp(_ p: CGPoint, modifiers: NSEvent.ModifierFlags, clickCount: Int = 1, in v: GraphMetalView) {
        let st = v.state
        st.touch()
        defer { st.pressed = nil; st.panning = false }
        if let i = st.pressed {
            if st.didDrag {
                sim.release(i)
                dragIndex = nil
                return
            }
            if modifiers.contains(.option) { activate(i, mode: .split); return }
            // In the local graph a click opens. In the big graph a click focuses and a second
            // click, or a double click, opens.
            if mode == .local || clickCount >= 2 || modifiers.contains(.command) || selected == i {
                activate(i, mode: .normal)
            } else {
                select(i, in: v)
            }
            return
        }
        if st.panning && st.didDrag {
            // A fling keeps going and slows down.
            if let first = st.samples.first, let last = st.samples.last, last.1 - first.1 > 0.01, CACurrentMediaTime() - last.1 < 0.06 {
                let dt = Float(last.1 - first.1)
                st.momentum = SIMD2(Float(last.0.x - first.0.x), Float(last.0.y - first.0.y)) / dt
            }
        } else if st.panning {
            clearSelection(in: v)
        }
        wake(v)
    }

    /// Lights a node and its neighbours, shows its card, and glides the camera to it.
    func select(_ i: Int, in v: GraphMetalView) {
        guard i < liveCount else { return }
        selected = i
        refreshCard()
        let st = v.state
        let pos = sim.positions()
        guard i < pos.count else { return }
        let c = pos[i]
        // Zoom so its neighbours fit around it, without zooming out of a closer look.
        var reach: Float = layout.nodes[i].radius * 6
        for j in layout.neighbours(i) where j < pos.count { reach = max(reach, simd_length(pos[j] - c)) }
        let half = Float(min(st.size.width, st.size.height)) / 2 - 70
        let fitScale = min(2.4, max(0.08, half / max(reach, 1)))
        glide(st, to: c, scale: max(st.scale, min(fitScale, st.scale * 2.2)))
        st.userMoved = true
        wakeAll()
    }

    func focusClick(_ i: Int, in v: GraphMetalView) { select(i, in: v) }

    func clearSelection(in v: GraphMetalView) {
        guard selected != nil else { return }
        selected = nil
        if hovered == nil { hover = nil }
        wakeAll()
    }

    func scroll(_ e: NSEvent, at p: CGPoint, in v: GraphMetalView) {
        let st = v.state
        st.touch()
        if e.hasPreciseScrollingDeltas && !e.modifierFlags.contains(.command) {
            // Trackpad: two fingers pan, and the system's momentum events carry the fling.
            st.glide = nil
            st.center -= SIMD2(Float(-e.scrollingDeltaX), Float(-e.scrollingDeltaY)) / st.scale
        } else if e.hasPreciseScrollingDeltas {
            zoom(by: exp(Float(e.scrollingDeltaY) * 0.01), at: p, in: v)
        } else {
            // A mouse wheel steps, and each step eases in.
            let base = st.wheelTarget ?? st.scale
            st.wheelTarget = min(8, max(0.03, base * exp(Float(e.scrollingDeltaY) * 0.12)))
            st.wheelAnchor = p
            st.glide = nil
        }
        st.userMoved = true
        if hovered != nil { setHover(nil, in: v) }
        wake(v)
    }

    func zoom(by f: Float, at p: CGPoint, in v: GraphMetalView) {
        let st = v.state
        st.touch()
        st.glide = nil
        st.wheelTarget = nil
        let w = st.world(p)
        st.scale = min(8, max(0.03, st.scale * f))
        st.center = w - SIMD2(Float(p.x - st.size.width / 2), Float(p.y - st.size.height / 2)) / st.scale
        st.userMoved = true
        wake(v)
    }

    /// Keyboard zoom: eased, like a wheel step.
    func zoomStep(_ f: Float, in v: GraphMetalView) {
        let st = v.state
        st.touch()
        st.wheelTarget = min(8, max(0.03, (st.wheelTarget ?? st.scale) * f))
        st.wheelAnchor = CGPoint(x: st.size.width / 2, y: st.size.height / 2)
        st.userMoved = true
        wake(v)
    }

    func pan(_ dx: Float, _ dy: Float, in v: GraphMetalView) {
        let st = v.state
        st.touch()
        st.center += SIMD2(dx, dy) / st.scale
        st.userMoved = true
        wake(v)
    }

    /// Keyboard pan: a short glide.
    func panStep(_ dx: Float, _ dy: Float, in v: GraphMetalView) {
        let st = v.state
        let base = st.glide?.toC ?? st.center
        glide(st, to: base + SIMD2(dx, dy) / st.scale, scale: st.glide?.toS ?? st.scale, duration: 0.18)
        st.userMoved = true
        wake(v)
    }

    /// Esc: drop the selection, then the focus, then fit.
    func escape(in v: GraphMetalView) {
        if selected != nil { clearSelection(in: v) } else if focusID != nil { focusID = nil } else { fit(in: v) }
    }

    // MARK: Compatibility for tests and snapshots

    func screen(_ w: SIMD2<Float>) -> CGPoint { (view?.state ?? offscreen).screen(w) }

    func pointerMoved(_ p: CGPoint) {
        if let v = view { pointerMoved(p, in: v) }
    }

    func pointerExited() {
        if let v = view { pointerExited(in: v) }
    }

    func makeFrame(size: CGSize, pixelRatio: CGFloat, appearance: NSAppearance?) -> GraphFrame {
        offscreen.size = size
        return makeFrame(offscreen, pixelRatio: pixelRatio, appearance: appearance)
    }

    func fit() {
        for v in views.allObjects { fit(in: v) }
    }

    func wake() { wakeAll() }

    func themeChanged() { for v in views.allObjects { themeChanged(v) } }

    var renderer: GraphRenderer? { offscreen.renderer }

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

    func menu(for i: Int, in v: GraphMetalView) -> NSMenu {
        let m = NSMenu()
        let n = layout.nodes[i]
        func add(_ title: String, _ action: @escaping () -> Void) {
            m.addItem(ClosureMenuItem(title: title, action: action))
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
