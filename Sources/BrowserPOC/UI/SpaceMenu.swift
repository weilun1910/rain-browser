import AppKit
import SwiftUI

// Spaces in the tab bar layout: a button with the space's icon and name, and a menu under it,
// like Safari's profile and tab group picker. Ctrl-1 to 9, Option-Cmd-arrows and a two-finger
// swipe over the toolbar still switch spaces too.

/// The space button at the start of the toolbar.
struct SpacePickerButton: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var state = TabBarState.shared
    @State private var hovering = false
    @State private var targeted = false

    var body: some View {
        let sp = model.currentSpace
        HStack(spacing: Theme.Space.s) {
            SpaceIcon(icon: sp?.icon ?? "square.stack", size: 12)
                .foregroundStyle(Theme.Palette.accent(sp?.color))
                .frame(width: 16)
            Text(sp?.name ?? "Space")
                .font(Theme.Font.rowEmphasis)
                .lineLimit(1)
                .frame(maxWidth: 150, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(state.spaceMenuOpen ? 180 : 0))
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: TabBarMetrics.itemHeight)
        .background(Theme.Radius.shape(Theme.Radius.row)
            .fill(state.spaceMenuOpen || targeted ? Theme.Palette.rowPressed : (hovering ? Theme.Palette.rowHover : .clear)))
        .contentShape(Rectangle())
        .onTapGesture { state.toggleSpaceMenu(model) }
        .onHover { hovering = $0 }
        .motion(Motion.hover, value: hovering, fadeOnly: true)
        .motion(Motion.float, value: state.spaceMenuOpen)
        // Holding a dragged tab over the button opens the menu, so it can be dropped on a space.
        .onDrop(of: [ItemDrag.type], isTargeted: $targeted) { _ in false }
        .onChange(of: targeted) { _, on in
            guard on else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.Timing.springLoad) {
                if targeted && !state.spaceMenuOpen { state.openSpaceMenu(model) }
            }
        }
        .anchorPreference(key: TabBarAnchors.self, value: .bounds) { ["picker": $0] }
        .help("Spaces (Ctrl-1 to 9, or swipe over the toolbar)")
        .accessibilityLabel("Space: \(sp?.name ?? "")")
        .accessibilityAddTraits(.isButton)
    }
}

/// The menu of spaces: each space's icon in its colour, its name and profile, its shortcut, and
/// a check on the one you're in. Right-click a space for its own menu. Drop a tab on a space to
/// move it there.
struct SpaceMenu: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var state = TabBarState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(model.spaces.enumerated()), id: \.element.id) { i, sp in
                SpaceMenuRow(space: sp, index: i, highlighted: state.menuHighlight == i)
            }
            Rectangle().fill(Theme.Palette.hairline).frame(height: 1)
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.xs)
            SpaceMenuAction(symbol: "plus", title: "New space...") {
                state.closeSpaceMenu()
                DispatchQueue.main.async { model.promptNewSpace() }
            }
        }
        .padding(Theme.Space.s)
        .frame(width: TabBarMetrics.spaceMenuWidth, alignment: .leading)
        .glassPanel(radius: Theme.Radius.popover, fallbackShadow: .popover)
    }
}

private struct SpaceMenuRow: View {
    let space: Space
    let index: Int
    let highlighted: Bool
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var state = TabBarState.shared
    @State private var hovering = false
    @State private var targeted = false

    var current: Bool { model.currentSpaceID == space.id }

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            SpaceIcon(icon: space.icon, size: 12)
                .foregroundStyle(Theme.Palette.accent(space.color))
                .frame(width: 24, height: 24)
                .background(Theme.Radius.shape(Theme.Radius.button).fill(Theme.Palette.tint(space.color).opacity(current ? 0.24 : 0.14)))
            VStack(alignment: .leading, spacing: 0) {
                Text(space.name).font(current ? Theme.Font.rowEmphasis : Theme.Font.row).lineLimit(1)
                if let p = space.profile {
                    Text("\(p) profile").font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: Theme.Space.s)
            if index < 9 {
                Text("\u{2303}\(index + 1)").font(Theme.Font.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent(space.color))
                .frame(width: 12)
                .opacity(current ? 1 : 0)
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: 34)
        .background(Theme.Radius.shape(Theme.Radius.row)
            .fill(hovering || highlighted || targeted ? Theme.GlassStyle.activeFill : .clear))
        .contentShape(Rectangle())
        .onTapGesture {
            model.switchSpace(to: space.id)
            state.closeSpaceMenu()
        }
        .onHover { hovering = $0 }
        .motion(Motion.hover, value: hovering || highlighted, fadeOnly: true)
        .onDrop(of: [ItemDrag.type], isTargeted: $targeted) { providers in
            ItemDrag.loadItems(providers) { items in
                for item in items {
                    switch item {
                    case .tab(let id): if let t = model.tab(id) { model.move(t, toSpace: space.id) }
                    case .split(let id): if let s = model.split(id) { model.move(split: s, toSpace: space.id) }
                    case .folder: break
                    }
                }
                state.closeSpaceMenu()
            }
        }
        .contextMenu { SpaceContextMenu(space: space, index: index) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
    }
}

private struct SpaceMenuAction: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).frame(width: 24)
            Text(title).font(Theme.Font.row).foregroundStyle(hovering ? .primary : .secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: 30)
        .background(Theme.Radius.shape(Theme.Radius.row).fill(hovering ? Theme.GlassStyle.activeFill : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
        .motion(Motion.hover, value: hovering, fadeOnly: true)
    }
}
