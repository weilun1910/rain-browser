import AppKit
import SwiftUI

// Essentials in the tab bar: a box at the start of the row of tabs that shows three, and grows
// straight down into a grid of all of them while the pointer rests on it. The box itself grows,
// over the page, so the tabs beside it never move. At rest it's a quiet well like the sidebar's
// Essentials. Open, it takes the sidebar's own surface, the same as the icon column's grown box,
// so the two read as one feature.

enum EssentialsBoxGeometry {
    static var tileWidth: CGFloat { TabBarMetrics.tileWidth }
    static var tileHeight: CGFloat { TabBarMetrics.itemHeight - 2 * TabBarMetrics.boxPadding }
    static var gap: CGFloat { TabBarMetrics.tileGap }
    static var pad: CGFloat { TabBarMetrics.boxPadding }

    /// The "+N" after the three when there are more.
    static let countWidth: CGFloat = 26

    /// The box's width for `columns` tiles.
    static func width(_ columns: Int) -> CGFloat {
        let n = CGFloat(max(1, columns))
        return 2 * pad + n * tileWidth + (n - 1) * gap
    }

    /// The box at rest: up to three tiles, and the count when there are more.
    static func restWidth(_ count: Int) -> CGFloat {
        width(min(count, TabBarRules.essentialsShown)) + (count > TabBarRules.essentialsShown ? countWidth + gap : 0)
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

    var body: some View {
        let n = model.essentials.count
        if n > 0 {
            Color.clear
                .frame(width: EssentialsBoxGeometry.restWidth(n), height: TabBarMetrics.itemHeight)
                .anchorPreference(key: TabBarAnchors.self, value: .bounds) { ["essentials": $0] }
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
}

/// The box: three Essentials at rest, all of them in a grid while it's open.
struct EssentialsBox: View {
    /// The box's size at rest, from its slot in the row of tabs.
    let rest: CGSize
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var state = TabBarState.shared
    @State private var targeted = false
    @Environment(\.spaceTintHex) private var tintHex

    var body: some View {
        let items = model.essentials
        let ids = items.map(\.id)
        let more = items.count > TabBarRules.essentialsShown
        let open = state.essentialsOpen && more
        let slots = TabBarRules.essentialSlots(ids)
        let onScreen = Set(items.filter { model.isSelected($0) || model.isVisible($0) }.map(\.id))
        let hiddenOpen = TabBarRules.openIsHidden(ids, open: onScreen)
        let height = open ? EssentialsBoxGeometry.openHeight(items.count) : rest.height
        // Open, the grid sits in the middle of the box, which keeps its width so the pointer never
        // falls off its edge as it opens.
        let inset = open ? (rest.width - EssentialsBoxGeometry.width(TabBarRules.essentialsColumns)) / 2 : 0
        let shape = Theme.Radius.shape(Theme.Radius.card)
        ZStack(alignment: .topLeading) {
            // At rest a quiet well on the bar. Open, the space's own surface with its grain, a
            // hairline and a floating shadow, like the icon column's grown box.
            shape.fill(targeted ? Theme.Palette.fieldHover : Theme.Palette.field)
                .opacity(open ? 0 : 1)
            ZStack {
                Theme.Palette.sidebarColor(tintHex)
                GrainOverlay()
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.Palette.hairline, lineWidth: 0.5))
            .background(shape.fill(Theme.Palette.sidebarColor(tintHex)).themeShadow(.floating))
            .opacity(open ? 1 : 0)
            ZStack(alignment: .topLeading) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, tab in
                    // The first three keep their places. The rest wait in their grid places below
                    // the box's edge until it grows down over them.
                    let at = EssentialsBoxGeometry.gridOrigin(i)
                    let hiddenAtRest = !open && !slots.contains(tab.id)
                    BarEssentialTile(tab: tab)
                        .frame(width: EssentialsBoxGeometry.tileWidth, height: EssentialsBoxGeometry.tileHeight)
                        .offset(x: at.x + inset, y: at.y)
                        .opacity(hiddenAtRest ? 0 : 1)
                        .allowsHitTesting(!hiddenAtRest)
                }
                if more {
                    // "+5" after the three, in the selected chip's style when the page you're on is
                    // one of the hidden ones, like the sidebar's icon column.
                    Text("+\(items.count - TabBarRules.essentialsShown)")
                        .font(Theme.Font.caption.monospacedDigit())
                        .foregroundStyle(hiddenOpen ? .primary : .secondary)
                        .frame(width: EssentialsBoxGeometry.countWidth, height: EssentialsBoxGeometry.tileHeight)
                        .background(Theme.Radius.shape(Theme.Radius.row - 1)
                            .fill(hiddenOpen ? Theme.Palette.rowSelected : .clear)
                            .themeShadow(hiddenOpen ? .row : .mark))
                        .offset(x: EssentialsBoxGeometry.width(TabBarRules.essentialsShown) - EssentialsBoxGeometry.pad + EssentialsBoxGeometry.gap,
                                y: EssentialsBoxGeometry.pad)
                        .opacity(open ? 0 : 1)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: rest.width, height: height, alignment: .topLeading)
            .clipShape(shape)
        }
        .frame(width: rest.width, height: height, alignment: .topLeading)
        .contentShape(shape)
        .onHover { inside in if more { state.pointerInEssentials(inside) } }
        .onDrop(of: [ItemDrag.type], isTargeted: $targeted) { providers in
            ItemDrag.load(providers) { ids in model.place(ids.map { .tab($0) }, in: .essentials, at: Int.max) }
        }
        .motion(open ? Motion.reveal : Motion.conceal, value: open)
        .motion(Motion.insert, value: ids)
        .help(more && !open ? "\(items.count - TabBarRules.essentialsShown) more Essentials. Rest the pointer here to see them all." : "")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Essentials")
    }
}

/// One Essential in the box: its icon on a tile, the selected chip when it's open.
struct BarEssentialTile: View {
    @ObservedObject var tab: Tab
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
        .overlay(alignment: indicator == .after ? .trailing : .leading) {
            // Where a dragged Essential would land.
            if indicator == .before || indicator == .after {
                Capsule().fill(Color.accentColor).frame(width: 2).padding(.vertical, 4)
                    .offset(x: indicator == .after ? 2 : -2)
            }
        }
        .motion(Motion.hover, value: hovering, fadeOnly: true)
        .motion(Motion.hover, value: selected, fadeOnly: true)
        .contentShape(Rectangle())
        .onTapGesture {
            TabClick.perform(tab, model: model)
            TabBarState.shared.closeEssentials()
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { if tab.isAwayFromPin { model.resetPinned(tab) } })
        .onHover { hovering = $0 }
        .onDrag {
            SidebarDrag.shared.begin([tab.id])
            return ItemDrag.provider(tab.id)
        }
        .onDrop(of: [ItemDrag.type], delegate: EssentialDropDelegate(tab: tab, model: model, indicator: $indicator))
        .contextMenu { TabMenu(tab: tab) }
        .help(tab.displayTitle)
        .accessibilityLabel(tab.displayTitle)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Drops on an Essential reorder Essentials: the left half lands before it, the right half after.
struct EssentialDropDelegate: DropDelegate {
    let tab: Tab
    let model: BrowserModel
    @Binding var indicator: TabBarDropIndicator?

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [ItemDrag.type]) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        indicator = info.location.x < EssentialsBoxGeometry.tileWidth / 2 ? .before : .after
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
