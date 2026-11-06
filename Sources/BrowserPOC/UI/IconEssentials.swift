import SwiftUI

// Essentials in the icon column. At most three show, one under the other, with a count of the
// rest under them. Resting on them grows the box sideways over the page into a grid of every
// Essential, three to a column, so the first three stay exactly where they were and the box
// reads as growing rather than a menu opening. It shrinks back a moment after the pointer
// leaves. The horizontal tab bar's Essentials follow the same rule, growing downward.
//
// The grown box is drawn by the main view, over the whole window, at the place the column
// reports. Drawn inside the sidebar, it went under the page, since the page's web view sits
// after the sidebar.

/// Whether the grown box is open, shared by the column and the layer that draws the box.
@MainActor
final class EssentialsBloom: ObservableObject {
    static let shared = EssentialsBloom()
    @Published private(set) var open = false
    private var overColumn = false
    private var overGrid = false
    private var pending: DispatchWorkItem?

    /// Offscreen shots open the box without a pointer.
    @Published var forced = false

    var isOpen: Bool { open || forced }

    func hover(column: Bool? = nil, grid: Bool? = nil) {
        if let column { overColumn = column }
        if let grid { overGrid = grid }
        pending?.cancel()
        let want = overColumn || overGrid
        guard want != open else { return }
        // The pointer rests a moment before it grows, so passing over on the way to a tab
        // doesn't open it, and it lingers a moment so a slow move into the box keeps it open.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = self.overColumn || self.overGrid
                guard now != self.open else { return }
                Motion.run(now ? Motion.reveal : Motion.conceal) { self.open = now }
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (want ? Motion.Timing.revealDwell : Motion.Timing.concealDelay), execute: work)
    }

    /// The column went away, say for titles.
    func reset() {
        pending?.cancel()
        overColumn = false
        overGrid = false
        open = false
    }
}

/// Where the column's three tiles are, for the main view to grow the box from.
struct EssentialsColumnKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

/// The column: three Essentials and a count of the rest.
struct IconEssentials: View {
    let items: [Tab]
    @EnvironmentObject var model: BrowserModel
    @ObservedObject private var bloom = EssentialsBloom.shared

    /// How many show before the box has to grow.
    static let shown = 3
    static let tileWidth: CGFloat = Theme.Space.sidebarIconWidth - 2 * Theme.Space.sidebarInset
    static let gap: CGFloat = Theme.Space.s
    /// The grown box's padding, so its first column sits on the tiles it grew from.
    static let pad: CGFloat = Theme.Space.s

    var body: some View {
        let rest = items.count - min(items.count, Self.shown)
        VStack(spacing: Self.gap) {
            VStack(spacing: Self.gap) {
                ForEach(items.prefix(Self.shown)) { EssentialTile(tab: $0).transition(Motion.Transitions.tabRow) }
            }
            .anchorPreference(key: EssentialsColumnKey.self, value: .bounds) { rest > 0 ? $0 : nil }
            if rest > 0 { more(rest) }
        }
        .contentShape(Rectangle())
        .onHover { bloom.hover(column: $0) }
        .onDisappear { bloom.reset() }
        .motion(Motion.insert, value: items.map { $0.id })
    }

    /// "+5" under the three, in the selected chip's style when the page you're on is one of the
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
            .help("\(n) more Essentials. Rest the pointer here to see them all.")
    }
}

/// The grown box, drawn over the window at the column's place. It grows toward the page:
/// rightward from a sidebar on the left, leftward from one on the right.
struct EssentialsBloomLayer: View {
    let column: Anchor<CGRect>?
    let onRight: Bool
    @EnvironmentObject var model: BrowserModel
    @ObservedObject private var bloom = EssentialsBloom.shared

    var body: some View {
        GeometryReader { g in
            if let column, bloom.isOpen, model.essentials.count > IconEssentials.shown {
                let r = g[column]
                let items = model.essentials
                let width = Self.width(for: items.count)
                EssentialsGrid3(items: items, onRight: onRight)
                    .onHover { bloom.hover(grid: $0) }
                    .offset(x: onRight ? r.maxX + IconEssentials.pad - width : r.minX - IconEssentials.pad,
                            y: r.minY - IconEssentials.pad)
                    .transition(grow)
            }
        }
    }

    static func width(for count: Int) -> CGFloat {
        let columns = CGFloat((count + IconEssentials.shown - 1) / IconEssentials.shown)
        return columns * IconEssentials.tileWidth + (columns - 1) * IconEssentials.gap + 2 * IconEssentials.pad
    }

    private var grow: AnyTransition {
        if Motion.suppressed { return .identity }
        if Motion.reduceMotion { return .opacity }
        return .opacity.combined(with: .scale(scale: 0.92, anchor: onRight ? .topTrailing : .topLeading))
    }
}

/// Every Essential, three to a column, the first column nearest the sidebar.
private struct EssentialsGrid3: View {
    let items: [Tab]
    let onRight: Bool

    var body: some View {
        let ordered = stride(from: 0, to: items.count, by: IconEssentials.shown).map { Array(items[$0 ..< min(items.count, $0 + IconEssentials.shown)]) }
        let columns = onRight ? Array(ordered.reversed()) : ordered
        HStack(alignment: .top, spacing: IconEssentials.gap) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                VStack(spacing: IconEssentials.gap) {
                    ForEach(column) { EssentialTile(tab: $0).frame(width: IconEssentials.tileWidth) }
                }
            }
        }
        .padding(IconEssentials.pad)
        .background(GrownBox())
        .fixedSize()
        .environment(\.sidebarIconsOnly, true)
    }
}

/// The grown box: the sidebar's own surface, lifted over the page like compact mode's floating
/// sidebar, so the tiles look the same as they did in the column.
private struct GrownBox: View {
    @EnvironmentObject var model: BrowserModel
    var body: some View {
        let shape = Theme.Radius.shape(Theme.Radius.card)
        ZStack {
            Theme.Palette.sidebarColor(model.currentSpace?.color)
            GrainOverlay()
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.Palette.hairline, lineWidth: 0.5))
        .themeShadow(.floating)
    }
}
