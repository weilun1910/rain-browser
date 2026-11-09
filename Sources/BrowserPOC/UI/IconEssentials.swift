import SwiftUI

// Essentials in the icon column: a box holding at most three, one under the other, with a count
// of the rest under it. Resting on the box grows it sideways over the page into a grid of every
// Essential, three to a column. Only its width changes: the first three stay exactly where they
// were, and the rest come into view as its far edge passes them, so it reads as the same box
// getting wider. It shrinks back a moment after the pointer leaves. The tab bar's box does the
// same downward (TabBarEssentials.swift), with the same tiles and surface.
//
// At rest the box is drawn in the column. While it's grown, a copy is drawn by the main view over
// the whole window, at the place the column reports, since anything drawn inside the sidebar goes
// under the page's web view. The copy takes over at the box's resting size, so the hand-off
// doesn't show, and hands back once it has shrunk.

/// Whether the box is grown, shared by the column and the layer that draws the grown copy.
@MainActor
final class EssentialsBloom: ObservableObject {
    static let shared = EssentialsBloom()
    /// The copy over the window is up, at rest or grown.
    @Published private(set) var shown = false
    /// The copy is grown, or growing.
    @Published private(set) var open = false
    private var overColumn = false
    private var overGrid = false
    private var pending: DispatchWorkItem?

    /// Offscreen shots open the box without a pointer.
    @Published var forced = false

    var isShown: Bool { shown || forced }
    var isOpen: Bool { open || forced }

    func hover(column: Bool? = nil, grid: Bool? = nil) {
        if let column { overColumn = column }
        if let grid { overGrid = grid }
        pending?.cancel()
        let want = overColumn || overGrid
        guard want != open else { return }
        // The pointer rests a moment before it grows, so passing over on the way to a tab
        // doesn't open it, and it lingers a moment so a slow move onto the grown box keeps it open.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = self.overColumn || self.overGrid
                guard now != self.open else { return }
                now ? self.grow() : self.shrink()
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (want ? Motion.Timing.revealDwell : Motion.Timing.concealDelay), execute: work)
    }

    private func grow() {
        if shown {
            Motion.run(Motion.reveal) { open = true }
            return
        }
        // The copy first appears at rest over the column's box, then grows from there.
        shown = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.shown, self.overColumn || self.overGrid else { return }
                Motion.run(Motion.reveal) { self.open = true }
            }
        }
    }

    private func shrink() {
        guard let anim = Motion.animation(Motion.conceal) else {
            open = false
            shown = false
            return
        }
        withAnimation(anim, completionCriteria: .removed) {
            open = false
        } completion: { [weak self] in
            MainActor.assumeIsolated {
                // Back at rest, the column's own box takes over again.
                if let self, !self.open { self.shown = false }
            }
        }
    }

    /// A tile was picked: the box shrinks back now.
    func close() {
        pending?.cancel()
        overColumn = false
        overGrid = false
        if open { shrink() } else { shown = false }
    }

    /// The column went away, say for titles.
    func reset() {
        pending?.cancel()
        overColumn = false
        overGrid = false
        open = false
        shown = false
    }
}

/// Where the column's box is, for the main view to draw the grown copy over it.
struct EssentialsColumnKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

/// The column: the box of three, and a count of the rest under it.
struct IconEssentials: View {
    let items: [Tab]
    @EnvironmentObject var model: BrowserModel
    @ObservedObject private var bloom = EssentialsBloom.shared
    @ObservedObject private var prefs = BrowserPrefs.shared

    /// How many show before the box has to grow.
    static let shown = 3
    /// The box at rest fills the column between its insets.
    static let boxWidth: CGFloat = Theme.Space.sidebarIconWidth - 2 * Theme.Space.sidebarInset
    static let pad: CGFloat = TabBarMetrics.boxPadding
    static let gap: CGFloat = TabBarMetrics.tileGap
    static let tileWidth: CGFloat = boxWidth - 2 * pad
    static let tileHeight: CGFloat = Theme.Space.rowHeight - 2

    /// The box's height, the same at rest and grown: three tiles, or fewer.
    static func height(_ count: Int) -> CGFloat {
        let rows = CGFloat(max(1, min(count, shown)))
        return 2 * pad + rows * tileHeight + (rows - 1) * gap
    }

    /// The grown box's width: a column of three per three Essentials.
    static func openWidth(_ count: Int) -> CGFloat {
        let columns = CGFloat(max(1, (count + shown - 1) / shown))
        return 2 * pad + columns * tileWidth + (columns - 1) * gap
    }

    /// Where the tile at `index` sits, from the box's top corner nearest the sidebar.
    static func origin(_ index: Int) -> CGPoint {
        CGPoint(x: pad + CGFloat(index / shown) * (tileWidth + gap), y: pad + CGFloat(index % shown) * (tileHeight + gap))
    }

    var body: some View {
        let rest = items.count - min(items.count, Self.shown)
        VStack(spacing: Self.gap + 2) {
            EssentialsColumnBox(items: items, open: false, onRight: prefs.value.sidebarOnRight)
                // While the copy over the window is up, this one steps aside for it.
                .opacity(bloom.isShown && rest > 0 ? 0 : 1)
                .allowsHitTesting(!(bloom.isShown && rest > 0))
                .anchorPreference(key: EssentialsColumnKey.self, value: .bounds) { rest > 0 ? $0 : nil }
                .onHover { inside in if rest > 0 { bloom.hover(column: inside) } }
            if rest > 0 { more(rest) }
        }
        .onDisappear { bloom.reset() }
        .motion(Motion.insert, value: items.map { $0.id })
    }

    /// "+5" under the box, in the selected chip's style when the page you're on is one of the
    /// hidden ones, so you can still tell where you are.
    private func more(_ n: Int) -> some View {
        let hiddenSelected = items.dropFirst(Self.shown).contains { model.isSelected($0) || model.isVisible($0) }
        return Text("+\(n)")
            .font(Theme.Font.caption.monospacedDigit())
            .foregroundStyle(hiddenSelected ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 18)
            .background(Theme.Radius.shape(Theme.Radius.button).fill(hiddenSelected ? Theme.Palette.rowSelected : .clear))
            .opacity(bloom.isOpen ? 0 : 1)
            .motion(bloom.isOpen ? Motion.reveal : Motion.conceal, value: bloom.isOpen, fadeOnly: true)
            .contentShape(Rectangle())
            .onHover { bloom.hover(column: $0) }
            .help("\(n) more Essentials. Rest the pointer here or on the box to see them all.")
    }
}

/// The box, at rest in the column or grown over the page. It grows away from the sidebar's
/// outer edge: rightward from a sidebar on the left, leftward from one on the right.
struct EssentialsColumnBox: View {
    let items: [Tab]
    let open: Bool
    let onRight: Bool
    @State private var frame: CGRect = .zero

    var body: some View {
        let width = open ? IconEssentials.openWidth(items.count) : IconEssentials.boxWidth
        let height = IconEssentials.height(items.count)
        let near: Alignment = onRight ? .topTrailing : .topLeading
        let shape = Theme.Radius.shape(Theme.Radius.card)
        ZStack(alignment: near) {
            EssentialsSurface(open: open)
            ZStack(alignment: near) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, tab in
                    let at = IconEssentials.origin(i)
                    let hiddenAtRest = !open && i >= IconEssentials.shown
                    EssentialBoxTile(tab: tab, vertical: true) { EssentialsBloom.shared.close() }
                        .frame(width: IconEssentials.tileWidth, height: IconEssentials.tileHeight)
                        .offset(x: onRight ? -at.x : at.x, y: at.y)
                        .opacity(hiddenAtRest ? 0 : 1)
                        .allowsHitTesting(!hiddenAtRest)
                }
            }
            .frame(width: width, height: height, alignment: near)
            .clipShape(shape)
        }
        .frame(width: width, height: height, alignment: near)
        .contentShape(shape)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        // A tile's card sits beyond the box's far edge, so it never covers the next column.
        .environment(\.hoverCardBounds, frame == .zero ? nil : frame)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Essentials")
    }
}

/// The grown copy, drawn over the window at the column box's place. It's laid out at its full
/// grown width from the column's outer side, so only its far edge moves.
struct EssentialsBloomLayer: View {
    let column: Anchor<CGRect>?
    let onRight: Bool
    @EnvironmentObject var model: BrowserModel
    @ObservedObject private var bloom = EssentialsBloom.shared

    var body: some View {
        GeometryReader { g in
            if let column, bloom.isShown, model.essentials.count > IconEssentials.shown {
                let r = g[column]
                let full = IconEssentials.openWidth(model.essentials.count)
                EssentialsColumnBox(items: model.essentials, open: bloom.isOpen, onRight: onRight)
                    .onHover { bloom.hover(grid: $0) }
                    .frame(width: full, height: r.height, alignment: onRight ? .topTrailing : .topLeading)
                    .offset(x: onRight ? r.maxX - full : r.minX, y: r.minY)
            }
        }
    }
}
