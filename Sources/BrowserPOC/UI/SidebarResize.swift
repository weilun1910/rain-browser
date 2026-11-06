import AppKit
import SwiftUI

// The sidebar's width. Drag its inner edge to make it wider or narrower. Past the narrowest width
// with titles it snaps to one column of icons, and dragging back out brings the titles back at
// the width you drag to. Double-click the edge to go back to the default width. This follows
// Chrome's vertical tabs, whose collapsed strip is the same 56 pt and snaps at the same halfway
// point, and Zen's double-click (notes/research/2026-11-06-sidebar-width.md).

/// Where the sidebar lands for a given drag. Pure, so the tests can walk it.
enum SidebarWidth {
    static let min = Theme.Space.sidebarMinWidth
    static let max = Theme.Space.sidebarMaxWidth
    static let icons = Theme.Space.sidebarIconWidth
    /// The edge dragged in past this snaps to icons, and dragged out past it brings titles back.
    /// Halfway between the two widths, so the snap happens where the edge is nearer the icons.
    static var snap: CGFloat { (icons + min) / 2 }

    struct Layout: Equatable {
        var iconsOnly: Bool
        /// The width on screen: the icon column's, or the width with titles.
        var width: CGFloat
    }

    static let standard = Theme.Space.sidebarWidth
    /// Within this of the default width, the edge settles on it, like Chrome's, so it's easy to
    /// get back to.
    static let detent: CGFloat = 15

    static func clamp(_ w: CGFloat) -> CGFloat { Swift.min(max, Swift.max(min, w)) }

    /// The sidebar for an edge dragged to `proposed` points from the window's side.
    static func layout(proposed: CGFloat) -> Layout {
        if proposed < snap { return Layout(iconsOnly: true, width: icons) }
        let w = clamp(proposed)
        return Layout(iconsOnly: false, width: abs(w - standard) <= detent ? standard : w)
    }

    /// The sidebar as saved.
    static func saved(_ p: BrowserPrefsValue) -> Layout {
        p.sidebarIconsOnly ? Layout(iconsOnly: true, width: icons) : Layout(iconsOnly: false, width: clamp(CGFloat(p.sidebarWidth)))
    }
}

/// The width while you drag the edge. It's saved when you let go, so a drag doesn't write the
/// preferences file every frame.
@MainActor
final class SidebarResize: ObservableObject {
    static let shared = SidebarResize()

    /// The layout under the pointer while the edge is dragged.
    @Published private(set) var live: SidebarWidth.Layout?
    private var start: CGFloat = 0

    var isDragging: Bool { live != nil }

    /// What the sidebar shows now: the drag's layout, or the saved one.
    var current: SidebarWidth.Layout { live ?? SidebarWidth.saved(BrowserPrefs.shared.value) }

    /// `distance` is how far the edge has moved toward the page since the drag began.
    func drag(by distance: CGFloat) {
        if live == nil {
            start = current.width
            // The edge stops at the narrowest and widest widths while the pointer goes on, so
            // the resize pointer is held for the whole drag rather than only over the edge.
            if !Self.headless { NSCursor.columnResize(directions: [.left, .right]).push() }
        }
        let next = SidebarWidth.layout(proposed: start + distance)
        let was = current
        guard next != was else { return }
        if next.iconsOnly != was.iconsOnly {
            // Snapping between titles and icons is a jump, so it moves on its own spring.
            // Anything else follows the pointer exactly.
            Motion.run(Motion.sidebarSnap) { live = next }
        } else {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { live = next }
        }
    }

    func endDrag() {
        guard let l = live else { return }
        if !Self.headless { NSCursor.pop() }
        BrowserPrefs.shared.update { p in
            // The width with titles is kept while you're on icons, so they come back at it.
            if !l.iconsOnly { p.sidebarWidth = Double(l.width) }
            p.sidebarIconsOnly = l.iconsOnly
        }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { live = nil }
    }

    /// Icons only on or off, from the menu, the command bar, the edge or the icon column's button.
    func setIconsOnly(_ on: Bool) {
        guard BrowserPrefs.shared.value.sidebarIconsOnly != on else { return }
        Motion.run(Motion.sidebarToggle) { BrowserPrefs.shared.update { $0.sidebarIconsOnly = on } }
    }

    func toggleIconsOnly() { setIconsOnly(!BrowserPrefs.shared.value.sidebarIconsOnly) }

    /// Double-click on the edge: titles at the default width, as Zen does.
    func resetWidth() {
        let p = BrowserPrefs.shared.value
        guard p.sidebarIconsOnly || p.sidebarWidth != Double(SidebarWidth.standard) else { return }
        Motion.run(Motion.sidebarSnap) {
            BrowserPrefs.shared.update { $0.sidebarIconsOnly = false; $0.sidebarWidth = Double(SidebarWidth.standard) }
        }
    }

    /// Tests and offscreen shots drive drags with no pointer to change.
    nonisolated(unsafe) static var headless = false
}

/// The strip along the sidebar's inner edge that you drag. It's an AppKit view, so it gets the
/// press itself rather than through SwiftUI's gestures, which didn't reliably see a drag that
/// began there. It never moves the window, it works in a window that isn't in front, and its
/// resize pointer only offers the directions the sidebar can still go. Rest on it for a moment,
/// or drag it, and a thin bar in the space's colour fades in along the edge, the way Zen shows
/// its splitter.
struct SidebarResizeHandle: View {
    /// The sidebar is on the right, so its inner edge is its leading one.
    let onRight: Bool
    @ObservedObject private var resize = SidebarResize.shared
    @ObservedObject private var prefs = BrowserPrefs.shared
    @Environment(\.spaceAccent) private var accent

    /// The whole gap between the rows and the page, so the edge is easy to find.
    static let width: CGFloat = Theme.Space.sidebarInset

    var body: some View {
        let l = resize.current
        let outward: NSHorizontalDirection.Set = onRight ? .left : .right
        let inward: NSHorizontalDirection.Set = onRight ? .right : .left
        let directions: NSHorizontalDirection.Set = l.iconsOnly ? outward : (l.width >= SidebarWidth.max ? inward : [.left, .right])
        SidebarEdge(onRight: onRight, directions: directions, accent: NSColor(accent))
            .frame(width: Self.width)
            .frame(maxHeight: .infinity)
    }
}

struct SidebarEdge: NSViewRepresentable {
    let onRight: Bool
    let directions: NSHorizontalDirection.Set
    let accent: NSColor

    func makeNSView(context: Context) -> SidebarEdgeView { SidebarEdgeView(frame: .zero) }

    func updateNSView(_ v: SidebarEdgeView, context: Context) {
        v.onRight = onRight
        v.directions = directions
        v.accent = accent
    }
}

final class SidebarEdgeView: NSView {
    var onRight = false
    var directions: NSHorizontalDirection.Set = [.left, .right] {
        didSet { if directions != oldValue { window?.invalidateCursorRects(for: self) } }
    }
    var accent: NSColor = .controlAccentColor {
        didSet { if accent != oldValue { paintBar() } }
    }

    /// How long the pointer rests on the edge before the bar shows, Zen's 0.2 s.
    static let dwell: TimeInterval = 0.2

    private let bar = CALayer()
    private var tracking: NSTrackingArea?
    private var hoverWork: DispatchWorkItem?
    private var startX: CGFloat = 0
    private(set) var dragging = false
    private var inside = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        bar.cornerRadius = 1.5
        bar.opacity = 0
        layer?.addSublayer(bar)
        paintBar()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let inset = Theme.Space.l
        bar.frame = CGRect(x: (bounds.width - 3) / 2, y: inset, width: 3, height: max(0, bounds.height - 2 * inset))
        CATransaction.commit()
    }

    private func paintBar() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.backgroundColor = accent.withAlphaComponent(0.8).cgColor
        CATransaction.commit()
    }

    private func light(_ on: Bool) {
        let target: Float = on ? 1 : 0
        guard bar.opacity != target else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.reduceMotion ? 0 : 0.15)
        bar.opacity = target
        CATransaction.commit()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .columnResize(directions: directions))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        inside = true
        hoverWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { if self?.inside == true { self?.light(true) } } }
        hoverWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dwell, execute: w)
    }

    override func mouseExited(with event: NSEvent) {
        inside = false
        hoverWork?.cancel()
        if !dragging { light(false) }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            dragging = false
            SidebarResize.shared.resetWidth()
            return
        }
        startX = event.locationInWindow.x
        dragging = true
        light(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        let dx = event.locationInWindow.x - startX
        SidebarResize.shared.drag(by: onRight ? -dx : dx)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        SidebarResize.shared.endDrag()
        if !inside { light(false) }
    }
}

private struct SidebarIconsOnlyKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The sidebar shows one column of icons, so rows draw as icon chips.
    var sidebarIconsOnly: Bool {
        get { self[SidebarIconsOnlyKey.self] }
        set { self[SidebarIconsOnlyKey.self] = newValue }
    }
}
