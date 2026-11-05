import AppKit
import Combine
import SwiftUI

// The sidebar's spaces as one horizontal strip with a page per space, like Arc and Zen.
// A two-finger swipe drags the strip under the fingers, and clicks and shortcuts slide it, all
// through one per-frame driver, so any of them can pick up from wherever the strip is.
// The plan is in notes/plans/2026-11-05-motion.md, section 1.

/// Where the strip is and where it's going. One per browser model.
///
/// Positions are in pages. Page `n` is the `n`th space, except while a click jumps several
/// spaces: then the target stands in next to where you are, so the slide is one page long and
/// never runs through the spaces in between.
@MainActor
final class SpaceStrip: ObservableObject {
    private static var strips: [ObjectIdentifier: SpaceStrip] = [:]

    /// The strip for `model`, made the first time it's asked for.
    static func of(_ model: BrowserModel) -> SpaceStrip {
        let key = ObjectIdentifier(model)
        // A model that has gone away can leave its address to a new one, so check it's the same.
        if let s = strips[key], s.model === model { return s }
        let s = SpaceStrip(model: model)
        strips[key] = s
        return s
    }

    /// The page the sidebar shows, fractional while it moves.
    @Published private(set) var position: Double = 0
    /// Spaces standing in at pages that aren't their own, during a jump.
    @Published private(set) var standIns: [Int: UUID] = [:]
    /// The list's opacity. It dips for a moment under Reduce Motion, which swaps the list in place.
    @Published private(set) var listOpacity: Double = 1

    /// Pages per second.
    private(set) var velocity: Double = 0
    private(set) var target: Double?
    private(set) var dragging = false
    /// The width of a page, in points.
    var width: CGFloat = Theme.Space.sidebarWidth
    /// Tests step the strip themselves with `tick`.
    var manualClock = false
    weak var clock: StripClockView?

    private enum Mode { case spring(Spring), curve(from: Double, elapsed: Double) }
    private var mode: Mode = .spring(Motion.Springs.spaceSwitch)
    private weak var model: BrowserModel?
    private var subscriptions: Set<AnyCancellable> = []
    private var committing = false
    private var dragStart = 0
    private var dragBase: Double = 0
    private var warmed: UUID?
    private var gesture = SwipeGesture()

    init(model: BrowserModel) {
        self.model = model
        position = Double(model.spaces.firstIndex { $0.id == model.currentSpaceID } ?? 0)
        // @Published sends before the value changes, so the new value comes in as the argument.
        model.$currentSpaceID.dropFirst().sink { [weak self] id in
            MainActor.assumeIsolated { self?.currentSpaceChanged(to: id) }
        }.store(in: &subscriptions)
        model.$spaces.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.spacesChanged() } }
        }.store(in: &subscriptions)
    }

    var isMoving: Bool { dragging || target != nil }

    /// The space shown at page `slot`, if there's one there.
    func space(atSlot slot: Int) -> UUID? {
        if let id = standIns[slot] { return id }
        guard let m = model, slot >= 0, slot < m.spaces.count else { return nil }
        return m.spaces[slot].id
    }

    /// The page the strip is at or heading to.
    var restingSlot: Int { Int((target ?? position).rounded()) }

    /// The pages on screen now, with their spaces.
    var visibleSlots: [(slot: Int, id: UUID)] {
        var slots: Set<Int> = [Int(position.rounded(.down)), Int(position.rounded(.up))]
        if let t = target { slots.insert(Int(t.rounded())) }
        var seen: Set<UUID> = []
        return slots.sorted().compactMap { s in
            guard let id = space(atSlot: s), seen.insert(id).inserted else { return nil }
            return (s, id)
        }
    }

    /// The strip's position counted in real spaces, for the icon highlight: during a jump it runs
    /// from the space you left to the one you're going to.
    var spacePosition: Double {
        guard let m = model, !m.spaces.isEmpty else { return 0 }
        if standIns.isEmpty { return min(max(position, 0), Double(m.spaces.count - 1)) }
        let lo = Int(position.rounded(.down))
        let frac = position - Double(lo)
        func index(_ s: Int) -> Double? { space(atSlot: s).flatMap { id in m.spaces.firstIndex { $0.id == id } }.map(Double.init) }
        guard let a = index(lo) ?? index(lo + 1) else { return 0 }
        let b = index(lo + 1) ?? a
        return a + (b - a) * frac
    }

    // MARK: Following the model

    private func currentSpaceChanged(to id: UUID) {
        guard !committing, let m = model else { return }
        let rest = restingSlot
        if space(atSlot: rest) == id { return }
        guard let g = m.spaces.firstIndex(where: { $0.id == id }) else { return }
        if Motion.suppressed || !hasClock { snap(to: g); return }
        if Motion.reduceMotion {
            // Swap the list in place with a short fade.
            snap(to: g)
            listOpacity = 0
            startClock()
            return
        }
        let fromIndex = space(atSlot: rest).flatMap { from in m.spaces.firstIndex { $0.id == from } } ?? rest
        let dir = g > fromIndex ? 1 : -1
        if standIns.isEmpty && rest == fromIndex && abs(g - fromIndex) == 1 {
            go(to: Double(g), mode: .spring(Motion.Springs.spaceSwitch))
        } else {
            standIns[rest + dir] = id
            go(to: Double(rest + dir), mode: .spring(Motion.Springs.spaceSwitch))
        }
    }

    private func spacesChanged() {
        guard let m = model, !isMoving else { return }
        // A space was added, removed or moved: put the strip back on the current one.
        if let g = m.spaces.firstIndex(where: { $0.id == m.currentSpaceID }) { snap(to: g) }
    }

    private func snap(to g: Int) {
        standIns = [:]
        target = nil
        velocity = 0
        dragging = false
        position = Double(g)
    }

    private func go(to x: Double, mode: Mode) {
        target = x
        self.mode = mode
        startClock()
    }

    // MARK: The clock

    private var hasClock: Bool { manualClock || clock?.window != nil }

    private func startClock() { clock?.run(true) }

    /// Steps the motion `dt` seconds on. The display link calls it every frame while something moves.
    func tick(_ dt: Double) {
        let dt = min(max(dt, 0), 1.0 / 30)
        if listOpacity < 1 { listOpacity = min(1, listOpacity + dt / 0.12) }
        guard !dragging, let target else {
            if listOpacity >= 1 { clock?.run(false) }
            return
        }
        switch mode {
        case .spring(let spring):
            var p = position, v = velocity
            spring.update(value: &p, velocity: &v, target: target, deltaTime: dt)
            position = p
            velocity = v
            if abs(p - target) < 0.0004 && abs(v) < 0.02 { land() }
        case .curve(let from, let elapsed):
            let e = elapsed + dt
            let k = min(1, e / Motion.Springs.reducedSettleDuration)
            position = from + (target - from) * Motion.Springs.reducedSettleCurve.value(at: k)
            mode = .curve(from: from, elapsed: e)
            if k >= 1 { land() }
        }
    }

    private func land() {
        guard let t = target, let m = model else { return }
        target = nil
        velocity = 0
        // Back to plain pages, on the same pixels.
        let id = space(atSlot: Int(t.rounded()))
        standIns = [:]
        position = Double(id.flatMap { id in m.spaces.firstIndex { $0.id == id } } ?? Int(t.rounded()))
    }

    // MARK: The swipe

    /// One scroll event from over the sidebar. Returns true if it belongs to a swipe and must not
    /// scroll anything else.
    @discardableResult
    func handle(_ sample: SwipeSample, inside: Bool) -> Bool {
        let r = gesture.feed(sample, inside: inside)
        switch r.action {
        case .began(let offset): beginDrag(); drag(offset)
        case .moved(let offset): drag(offset)
        case .ended(let offset, let v): drag(offset); endDrag(velocity: v)
        case .none: break
        }
        return r.swallow
    }

    func beginDrag() {
        // A swipe that starts while the strip is still moving picks it up where it is.
        dragStart = restingSlot
        dragBase = position
        target = nil
        velocity = 0
        dragging = true
        warmed = nil
    }

    /// The fingers have moved `offset` points since the swipe began, positive to the right.
    func drag(_ offset: CGFloat) {
        guard dragging else { return }
        let raw = dragBase - Double(offset / max(width, 1))
        let (lo, hi) = bounds(around: dragStart)
        position = SwipePhysics.banded(raw, lo: Double(lo), hi: Double(hi))
        // Get the next space's page ready before the fingers lift, like Zen's tab warm-up.
        let d = position - Double(dragStart)
        if abs(d) > 0.15, let id = space(atSlot: dragStart + (d > 0 ? 1 : -1)), id != warmed {
            warmed = id
            model?.warmUp(space: id)
        }
    }

    /// The fingers lifted, moving at `fingers` points per second.
    func endDrag(velocity fingers: CGFloat) {
        guard dragging else { return }
        dragging = false
        let v = -Double(fingers / max(width, 1))
        let (lo, hi) = bounds(around: dragStart)
        let landing = SwipePhysics.landing(start: dragStart, position: position, velocity: v, width: width, lo: lo, hi: hi)
        if landing != dragStart, let id = space(atSlot: landing) {
            // The page changes now, in one frame, while the sidebar settles.
            committing = true
            model?.switchSpace(to: id)
            committing = false
        }
        let inBand = position >= Double(lo) && position <= Double(hi)
        velocity = inBand ? v : 0
        guard hasClock, !Motion.suppressed else {
            target = Double(landing)
            land()
            return
        }
        go(to: Double(landing), mode: Motion.reduceMotion ? .curve(from: position, elapsed: 0) : .spring(Motion.Springs.settle))
    }

    private func bounds(around s: Int) -> (Int, Int) {
        (space(atSlot: s - 1) != nil ? s - 1 : s, space(atSlot: s + 1) != nil ? s + 1 : s)
    }
}

extension BrowserModel {
    /// A space's folders, in order, whichever space is current.
    func folders(in space: UUID) -> [Folder] {
        folders.filter { $0.spaceID == space }.sorted { ($0.order ?? 0) < ($1.order ?? 0) }
    }

    /// What a space showed when you last left it.
    func rememberedSelection(of space: UUID) -> SidebarRef? {
        guard let sp = spaces.first(where: { $0.id == space }) else { return nil }
        if let s = sp.selectedSplit { return .split(s) }
        return sp.selectedTab.map { .tab($0) }
    }

    /// Makes the web views for what `space` will show, so a swipe's page is ready when it lands.
    func warmUp(space: UUID) {
        var ids: [UUID] = []
        switch rememberedSelection(of: space) {
        case .tab(let id)?: ids = [id]
        case .split(let id)?: ids = split(id)?.items ?? []
        case nil: break
        }
        for id in ids { if let t = tab(id), t.isWeb, t.url != nil, t.webView == nil { _ = t.ensureWebView() } }
    }
}

// MARK: - Views

private struct PageSelectionKey: EnvironmentKey {
    static let defaultValue: SidebarRef? = nil
}

extension EnvironmentValues {
    /// On a space's page that isn't the current one, the row that space last showed, so it stays
    /// highlighted while the page slides in.
    var pageSelection: SidebarRef? {
        get { self[PageSelectionKey.self] }
        set { self[PageSelectionKey.self] = newValue }
    }
}

/// The strip itself: the pages on screen, side by side, clipped to the sidebar.
struct SpacePager<Page: View>: View {
    @ObservedObject var strip: SpaceStrip
    @ViewBuilder var page: (UUID) -> Page

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .topLeading) {
                ForEach(strip.visibleSlots, id: \.id) { item in
                    page(item.id)
                        .frame(width: w, height: g.size.height)
                        .offset(x: (CGFloat(item.slot) - CGFloat(strip.position)) * w)
                }
            }
            .frame(width: w, height: g.size.height, alignment: .topLeading)
            .clipped()
            .onAppear { strip.width = w }
            .onChange(of: w) { _, new in strip.width = new }
        }
        .opacity(strip.listOpacity)
    }
}

/// Steps the strip once a frame while it moves, on the screen's display link.
final class StripClockView: NSView {
    weak var strip: SpaceStrip?
    private var link: CADisplayLink?
    private var last: CFTimeInterval?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let l = displayLink(target: self, selector: #selector(step(_:)))
        l.add(to: .main, forMode: .common)
        l.isPaused = !(MainActor.assumeIsolated { strip?.isMoving ?? false })
        link = l
    }

    func run(_ on: Bool) {
        guard let link else { return }
        if on && link.isPaused { last = nil }
        link.isPaused = !on
    }

    @objc private func step(_ l: CADisplayLink) {
        let now = l.timestamp
        let dt = last.map { now - $0 } ?? (l.targetTimestamp - l.timestamp)
        last = now
        MainActor.assumeIsolated { strip?.tick(dt) }
    }

    deinit { link?.invalidate() }
}

struct StripClock: NSViewRepresentable {
    let strip: SpaceStrip
    func makeNSView(context: Context) -> StripClockView {
        let v = StripClockView()
        v.strip = strip
        strip.clock = v
        return v
    }
    func updateNSView(_ v: StripClockView, context: Context) {
        v.strip = strip
        if strip.clock !== v { strip.clock = v }
    }
}

/// The window's frame tint, following the strip: while it moves, the next space's colour fades in
/// as far as the strip has gone, the way Zen's gradient follows its swipe.
struct StripTintBackground: View {
    @ObservedObject var strip: SpaceStrip
    @EnvironmentObject var model: BrowserModel
    var sidebarWidth: CGFloat = Theme.Space.sidebarWidth
    var fromTrailing = false
    /// The space the last frame showed, so a colour change on the same space still crossfades.
    @State private var last = LastShown()

    final class LastShown { var id: UUID? }

    var body: some View {
        let p = strip.position
        let lo = Int(p.rounded(.down))
        let a = strip.space(atSlot: lo) ?? strip.space(atSlot: lo + 1) ?? model.currentSpaceID
        let next = strip.space(atSlot: lo + 1)
        let b = next == a ? nil : next
        let sameSpace = last.id == a
        last.id = a
        return SpaceTintBackground(hex: color(a), sidebarWidth: sidebarWidth, fromTrailing: fromTrailing,
                                   blendHex: b.flatMap(color), blend: b == nil ? 0 : p - Double(lo),
                                   animatesColour: sameSpace && !strip.isMoving)
            .background(StripClock(strip: strip))
    }

    private func color(_ id: UUID) -> String? { model.spaces.first { $0.id == id }?.color }
}

/// Turns two-finger swipes over the sidebar into the strip's drag, and mouse wheels and the back
/// and forward mouse buttons into a step. Events that belong to a swipe are swallowed, so the tab
/// list never scrolls during one. Gestures that begin anywhere else are left alone, so WebKit's
/// own back and forward swipe over the page still works.
struct SpaceSwipeTracker: NSViewRepresentable {
    let model: BrowserModel

    final class TrackerView: NSView {
        weak var model: BrowserModel?
        private var monitor: Any?
        private var lastWheel: TimeInterval = -1

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .otherMouseDown]) { [weak self] e in
                guard let self else { return e }
                return MainActor.assumeIsolated { self.handle(e) }
            }
        }

        private func inside(_ e: NSEvent) -> Bool { bounds.contains(convert(e.locationInWindow, from: nil)) }

        private func handle(_ e: NSEvent) -> NSEvent? {
            guard let w = window, e.window === w, let model else { return e }
            if e.type == .otherMouseDown {
                // Mouse buttons 4 and 5 step spaces over the sidebar, like Arc and Zen.
                guard inside(e) else { return e }
                switch e.buttonNumber {
                case 3: model.switchSpace(by: -1); return nil
                case 4: model.switchSpace(by: 1); return nil
                default: return e
                }
            }
            let s = SwipeSample(e)
            if !s.precise && s.phase == .none && !s.momentum {
                // A mouse wheel can't follow the fingers. Shift-scroll or a sideways wheel steps one
                // space, and a run of notches counts once.
                guard inside(e), abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY), e.scrollingDeltaX != 0 else { return e }
                if e.timestamp - lastWheel >= SwipeTuning.wheelCooldown { model.switchSpace(by: e.scrollingDeltaX > 0 ? -1 : 1) }
                lastWheel = e.timestamp
                return nil
            }
            return SpaceStrip.of(model).handle(s, inside: inside(e)) ? nil : e
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }

    func makeNSView(context: Context) -> TrackerView {
        let v = TrackerView()
        v.model = model
        return v
    }
    func updateNSView(_ v: TrackerView, context: Context) { v.model = model }
}
