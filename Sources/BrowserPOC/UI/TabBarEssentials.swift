import AppKit
import SwiftUI

// Essentials in the tab bar: a box at the start of the row of tabs that holds three, and grows
// straight down into a grid of all of them while the pointer rests on it. Only its height
// changes: the three stay where they are and the rest come into view as its bottom edge passes
// them, so it reads as the same box getting taller. A count of the rest sits just outside it.
// The icon column's box (IconEssentials.swift) does the same sideways, and both use the tile and
// the surface here.

enum EssentialsBoxGeometry {
    static var tileWidth: CGFloat { TabBarMetrics.tileWidth }
    static var tileHeight: CGFloat { TabBarMetrics.itemHeight - 2 * TabBarMetrics.boxPadding }
    static var gap: CGFloat { TabBarMetrics.tileGap }
    static var pad: CGFloat { TabBarMetrics.boxPadding }

    /// The "+N" after the box when there are more.
    static let countWidth: CGFloat = 26

    /// The box's width for `columns` tiles.
    static func width(_ columns: Int) -> CGFloat {
        let n = CGFloat(max(1, columns))
        return 2 * pad + n * tileWidth + (n - 1) * gap
    }

    /// The box itself, at rest and open: up to three tiles across.
    static func restWidth(_ count: Int) -> CGFloat { width(min(count, TabBarRules.essentialsShown)) }

    /// The box and the count beside it, in the row of tabs.
    static func slotWidth(_ count: Int) -> CGFloat {
        restWidth(count) + (count > TabBarRules.essentialsShown ? gap + countWidth : 0)
    }

    /// The open grid's height for `count` Essentials.
    static func openHeight(_ count: Int) -> CGFloat {
        let rows = CGFloat(TabBarRules.essentialRows(count))
        return 2 * pad + rows * tileHeight + (rows - 1) * gap
    }

    /// Where the tile at `index` sits in the open grid, from the box's top left.
    static func gridOrigin(_ index: Int) -> CGPoint {
        let c = TabBarRules.essentialsColumns
        return CGPoint(x: pad + CGFloat(index % c) * (tileWidth + gap), y: pad + CGFloat(index / c) * (tileHeight + gap))
    }
}

/// Holds the box's place in the row of tabs and says where it is. The box itself is drawn over
/// everything by `TabBarLayout`, so it can grow over the page.
struct EssentialsBoxSlot: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject private var drag = SidebarDrag.shared
    @State private var targeted = false

    @ObservedObject private var state = TabBarState.shared

    var body: some View {
        let n = model.essentials.count
        if n > 0 {
            HStack(spacing: EssentialsBoxGeometry.gap) {
                Color.clear
                    .frame(width: EssentialsBoxGeometry.restWidth(n), height: TabBarMetrics.itemHeight)
                    .anchorPreference(key: TabBarAnchors.self, value: .bounds) { ["essentials": $0] }
                if n > TabBarRules.essentialsShown { count(n) }
            }
            .padding(.trailing, Theme.Space.m)
        } else if !drag.dragging.isEmpty {
            // With no Essentials yet, a drag shows where one would go.
            Text("Essentials")
                .font(Theme.Font.action)
                .foregroundStyle(targeted ? .primary : .secondary)
                .padding(.horizontal, Theme.Space.m)
                .frame(height: TabBarMetrics.itemHeight)
                .background(Theme.Radius.shape(Theme.Radius.row)
                    .strokeBorder(Theme.Palette.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .background(Theme.Radius.shape(Theme.Radius.row).fill(targeted ? Theme.Palette.rowHover : .clear)))
                .padding(.trailing, Theme.Space.m)
                .onDrop(of: [ItemDrag.type], isTargeted: $targeted) { providers in
                    ItemDrag.load(providers) { ids in model.place(ids.map { .tab($0) }, in: .essentials, at: Int.max) }
                }
                .transition(.opacity)
        }
    }

    /// "+5" just outside the box, in the selected chip's style when the page you're on is one of
    /// the hidden ones, like the icon column's. It fades while the box is open.
    private func count(_ n: Int) -> some View {
        let ids = model.essentials.map(\.id)
        let onScreen = Set(model.essentials.filter { model.isSelected($0) || model.isVisible($0) }.map(\.id))
        let hiddenOpen = TabBarRules.openIsHidden(ids, open: onScreen)
        return Text("+\(n - TabBarRules.essentialsShown)")
            .font(Theme.Font.caption.monospacedDigit())
            .foregroundStyle(hiddenOpen ? .primary : .secondary)
            .frame(width: EssentialsBoxGeometry.countWidth, height: EssentialsBoxGeometry.tileHeight)
            .background(Theme.Radius.shape(Theme.Radius.row - 1)
                .fill(hiddenOpen ? Theme.Palette.rowSelected : .clear)
                .themeShadow(hiddenOpen ? .row : .mark))
            .opacity(state.essentialsOpen ? 0 : 1)
            .motion(state.essentialsOpen ? Motion.reveal : Motion.conceal, value: state.essentialsOpen, fadeOnly: true)
            .contentShape(Rectangle())
            .onHover { state.pointerInEssentials($0) }
            .help("\(n - TabBarRules.essentialsShown) more Essentials. Rest the pointer here or on the box to see them all.")
    }
}

/// The box: three Essentials at rest, all of them in a grid while it's open.
struct EssentialsBox: View {
    /// The box's size at rest, from its slot in the row of tabs.
    let rest: CGSize
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var state = TabBarState.shared
    @State private var targeted = false
    @State private var frame: CGRect = .zero

    var body: some View {
        let items = model.essentials
        let ids = items.map(\.id)
        let more = items.count > TabBarRules.essentialsShown
        let open = state.essentialsOpen && more
        let slots = Set(TabBarRules.essentialSlots(ids))
        let height = open ? EssentialsBoxGeometry.openHeight(items.count) : rest.height
        let shape = Theme.Radius.shape(Theme.Radius.card)
        ZStack(alignment: .topLeading) {
            EssentialsSurface(open: open, targeted: targeted)
            ZStack(alignment: .topLeading) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, tab in
                    // The first three keep their places. The rest wait in their grid places below
                    // the box's edge until it grows down over them.
                    let at = EssentialsBoxGeometry.gridOrigin(i)
                    let hiddenAtRest = !open && !slots.contains(tab.id)
                    EssentialBoxTile(tab: tab, vertical: false) { state.closeEssentials() }
                        .frame(width: EssentialsBoxGeometry.tileWidth, height: EssentialsBoxGeometry.tileHeight)
                        .offset(x: at.x, y: at.y)
                        .opacity(hiddenAtRest ? 0 : 1)
                        .allowsHitTesting(!hiddenAtRest)
                }
            }
            .frame(width: rest.width, height: height, alignment: .topLeading)
            .clipShape(shape)
        }
        .frame(width: rest.width, height: height, alignment: .topLeading)
        .contentShape(shape)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        // Tiles show their card under the box, so it never covers the next row.
        .environment(\.hoverCardBounds, frame == .zero ? nil : frame)
        .onHover { inside in if more { state.pointerInEssentials(inside) } }
        .onDrop(of: [ItemDrag.type], isTargeted: $targeted) { providers in
            ItemDrag.load(providers) { ids in model.place(ids.map { .tab($0) }, in: .essentials, at: Int.max) }
        }
        .motion(open ? Motion.reveal : Motion.conceal, value: open)
        .motion(Motion.insert, value: ids)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Essentials")
    }
}

/// The Essentials box's surface, the same at rest and open so it reads as one box changing size.
/// At rest it's a quiet well like the sidebar's Essentials. It sits on the space's own colour,
/// so the page doesn't show through where it grows over it. Open, a hairline and a floating
/// shadow fade in to lift it off the page.
struct EssentialsSurface: View {
    let open: Bool
    var targeted = false
    @Environment(\.spaceTintHex) private var tintHex
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        let shape = Theme.Radius.shape(Theme.Radius.card)
        let active = SpaceTintBackground.forceActive || activeState == .key || activeState == .active
        let base = Theme.Palette.sidebarColor(tintHex, active: active)
        ZStack {
            shape.fill(base)
            GrainOverlay().clipShape(shape)
            shape.fill(targeted ? Theme.Palette.fieldHover : Theme.Palette.field)
        }
        .overlay(shape.strokeBorder(Theme.Palette.hairline, lineWidth: 0.5).opacity(open ? 1 : 0))
        .background(shape.fill(base).themeShadow(.floating).opacity(open ? 1 : 0))
    }
}

/// One Essential in a box, in the tab bar or the icon column: its icon on a tile, the selected
/// chip when it's the page you're on. `vertical` is the icon column's box, whose tiles run down
/// in columns, so a drop lands above or below a tile rather than beside it.
struct EssentialBoxTile: View {
    @ObservedObject var tab: Tab
    var vertical = false
    /// After a click: the box shrinks back.
    var onPick: () -> Void = {}
    @EnvironmentObject var model: BrowserModel
    @State private var hovering = false
    @State private var indicator: TabBarDropIndicator?

    var body: some View {
        let selected = model.isSelected(tab) || model.isVisible(tab)
        ZStack(alignment: .topTrailing) {
            ItemIcon(tab: tab, size: 16)
                .opacity(tab.isLoaded || tab.isNote || tab.isApp || selected ? 1 : 0.7)
                .opacity(tab.isLoading ? 0.45 : 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.Radius.shape(Theme.Radius.row - 1)
                    .fill(selected ? Theme.Palette.rowSelected : (hovering || indicator != nil ? Theme.Palette.rowHover : .clear))
                    .themeShadow(selected ? .row : .mark))
            if tab.isAwayFromPin {
                Circle().fill(Color.secondary).frame(width: 4, height: 4).padding(4)
            }
            if tab.mediaPlaying || tab.isMuted {
                Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 7)).foregroundStyle(.secondary).padding(3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .overlay(alignment: overlayAlignment) {
            // Where a dragged Essential would land.
            if indicator == .before || indicator == .after {
                let sign: CGFloat = indicator == .after ? 2 : -2
                if vertical {
                    Capsule().fill(Color.accentColor).frame(height: 2).padding(.horizontal, 4).offset(y: sign)
                } else {
                    Capsule().fill(Color.accentColor).frame(width: 2).padding(.vertical, 4).offset(x: sign)
                }
            }
        }
        .motion(Motion.hover, value: hovering, fadeOnly: true)
        .motion(Motion.hover, value: selected, fadeOnly: true)
        .contentShape(Rectangle())
        .onTapGesture {
            HoverCards.shared.hide()
            TabClick.perform(tab, model: model)
            onPick()
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { if tab.isAwayFromPin { model.resetPinned(tab) } })
        .onHover { hovering = $0 }
        .onDrag {
            HoverCards.shared.hide()
            SidebarDrag.shared.begin([tab.id])
            return ItemDrag.provider(tab.id)
        }
        .onDrop(of: [ItemDrag.type], delegate: EssentialDropDelegate(tab: tab, vertical: vertical, model: model, indicator: $indicator))
        .contextMenu { TabMenu(tab: tab) }
        .hoverCard(tab)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var overlayAlignment: Alignment {
        if vertical { return indicator == .after ? .bottom : .top }
        return indicator == .after ? .trailing : .leading
    }
}

/// Drops on an Essential reorder Essentials: the left or top half lands before it, the right or
/// bottom half after.
struct EssentialDropDelegate: DropDelegate {
    let tab: Tab
    var vertical = false
    let model: BrowserModel
    @Binding var indicator: TabBarDropIndicator?

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [ItemDrag.type]) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        indicator = vertical
            ? (info.location.y < IconEssentials.tileHeight / 2 ? .before : .after)
            : (info.location.x < EssentialsBoxGeometry.tileWidth / 2 ? .before : .after)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { indicator = nil }

    func performDrop(info: DropInfo) -> Bool {
        let after = indicator == .after
        indicator = nil
        let target = tab.id
        return ItemDrag.load(info.itemProviders(for: [ItemDrag.type])) { ids in
            let refs = ids.filter { $0 != target }.map { SidebarRef.tab($0) }
            guard !refs.isEmpty else { return }
            // A tab from elsewhere becomes an Essential on the way in.
            SidebarDrag.shared.land(refs.first) { model.place(refs, next: .tab(target), after: after) }
        }
    }
}
