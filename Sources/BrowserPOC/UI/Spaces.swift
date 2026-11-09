import AppKit
import SwiftUI

extension Color {
    init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// An emoji or an SF Symbol name.
struct SpaceIcon: View {
    let icon: String
    var size: CGFloat = 13
    var isEmoji: Bool { icon.unicodeScalars.contains { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x2000) } }
    var body: some View {
        if isEmoji { Text(icon).font(.system(size: size)) } else { Image(systemName: icon).font(.system(size: size - 1)) }
    }
}

struct SpaceBar: View {
    @EnvironmentObject var model: BrowserModel
    var showsNewSpace = true

    var body: some View { SpaceBarIcons(strip: SpaceStrip.of(model), showsNewSpace: showsNewSpace) }
}

/// The space icons, with one highlight that slides between them in step with the sidebar's strip,
/// so a swipe moves it under the fingers too, like Arc's icon transition.
private struct SpaceBarIcons: View {
    @ObservedObject var strip: SpaceStrip
    @EnvironmentObject var model: BrowserModel
    var showsNewSpace = true
    /// In the icon column the spaces stack, and New space moves to the column's menu.
    @Environment(\.sidebarIconsOnly) private var vertical

    static let iconWidth: CGFloat = 26
    static let iconHeight: CGFloat = 24
    static let gap: CGFloat = 3

    var body: some View {
        let at = strip.spacePosition
        let lo = Int(at.rounded(.down))
        let frac = at - Double(lo)
        let colours = model.spaces.map { Theme.Palette.tint($0.color).opacity(0.16) }
        let stack = vertical ? AnyLayout(VStackLayout(spacing: Self.gap)) : AnyLayout(HStackLayout(spacing: Self.gap))
        stack {
            ForEach(Array(model.spaces.enumerated()), id: \.element.id) { i, sp in
                SpaceButton(space: sp, index: i, lit: max(0, 1 - abs(at - Double(i))))
                    .transition(Motion.Transitions.tabRow)
            }
            if !vertical && showsNewSpace {
                SmallIconButton(symbol: "plus", help: "New space") { model.promptNewSpace() }
            }
        }
        .background(alignment: vertical ? .top : .leading) {
            if colours.indices.contains(lo) {
                let next = colours.indices.contains(lo + 1) ? colours[lo + 1] : colours[lo]
                let step = CGFloat(at) * ((vertical ? Self.iconHeight : Self.iconWidth) + Self.gap)
                Theme.Radius.shape(Theme.Radius.button)
                    .fill(colours[lo].mix(with: next, by: frac))
                    .frame(width: Self.iconWidth, height: Self.iconHeight)
                    .offset(x: vertical ? 0 : step, y: vertical ? step : 0)
                    .allowsHitTesting(false)
            }
        }
    }
}

struct SpaceButton: View {
    let space: Space
    let index: Int
    /// How close the strip is to this space, from 0 to 1. It's 1 on the current space.
    var lit: Double = 0
    @EnvironmentObject var model: BrowserModel
    @State private var hovering = false

    var body: some View {
        // Only the current space shows its colour. The others are grey until you hover them, like Zen.
        // While the strip moves, the colour follows it from one icon to the next.
        let on = hovering ? 1 : lit
        SpaceIcon(icon: space.icon)
            .foregroundStyle(on > 0.5 ? Theme.Palette.accent(space.color) : Color.secondary)
            .saturation(on)
            .opacity(0.7 + 0.3 * on)
            .frame(width: 26, height: 24)
            .background(Theme.Radius.shape(Theme.Radius.button).fill(hovering && lit < 0.5 ? Theme.Palette.rowHover : .clear))
            .motion(Motion.hover, value: hovering, fadeOnly: true)
            .contentShape(Rectangle())
            .onTapGesture { model.switchSpace(to: space.id) }
            .onHover { hovering = $0 }
            .hoverCard(id: space.id, title: space.name, detail: index < 9 ? "Ctrl-\(index + 1)" : nil)
            .onDrop(of: [ItemDrag.type], isTargeted: nil) { providers in
                ItemDrag.loadItems(providers) { items in
                    for item in items {
                        switch item {
                        case .tab(let id): if let t = model.tab(id) { model.move(t, toSpace: space.id) }
                        case .split(let id): if let s = model.split(id) { model.move(split: s, toSpace: space.id) }
                        case .folder, .entry: break
                        }
                    }
                }
            }
            .contextMenu { SpaceContextMenu(space: space, index: index) }
    }
}

/// A space's own menu: rename, icon, colour, notes folder, profile, order and delete. On the
/// space icons in the sidebar and the rows of the tab bar's space menu.
struct SpaceContextMenu: View {
    let space: Space
    let index: Int
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Button("Rename...") { model.promptRenameSpace(space) }
        Menu("Icon") {
            ForEach(Space.icons, id: \.self) { ic in
                Button { model.updateSpace(space.id) { $0.icon = ic } } label: { Label(ic, systemImage: ic) }
            }
            Divider()
            Button("Emoji...") { model.promptSpaceEmoji(space) }
        }
        Menu("Color") {
            ForEach(Space.palette, id: \.1) { name, hex in
                Button(name) { model.updateSpace(space.id) { $0.color = hex } }
            }
        }
        Menu("New notes go in") {
            Button("App default (\(Settings.shared.value.defaultNewNotesFolder.lastPathComponent))") {
                model.updateSpace(space.id) { $0.newNotesFolder = nil }
            }
            Button("Choose folder...") { SpaceActions.pickNotesFolder(for: space, model: model) }
        }
        // Each profile keeps its own cookies and logins, like Arc's profiles.
        Menu("Profile") {
            Button(space.profile == nil ? "Default (current)" : "Default") { model.updateSpace(space.id) { $0.profile = nil } }
            ForEach(model.profiles, id: \.self) { p in
                Button(space.profile == p ? "\(p) (current)" : p) { model.updateSpace(space.id) { $0.profile = p } }
            }
            Divider()
            Button("New profile...") { model.promptNewProfile(for: space) }
        }
        Divider()
        Button("Move left") { model.moveSpace(space.id, by: -1) }.disabled(index == 0)
        Button("Move right") { model.moveSpace(space.id, by: 1) }.disabled(index == model.spaces.count - 1)
        Divider()
        Button("Delete space...") { model.promptDeleteSpace(space) }.disabled(model.spaces.count < 2)
    }
}

@MainActor
enum SpaceActions {
    static func pickNotesFolder(for space: Space, model: BrowserModel) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Use folder"
        p.message = "New notes made in \(space.name) go in this folder."
        p.directoryURL = model.newNotesFolder
        guard p.runModal() == .OK, let u = p.url else { return }
        let roots = Settings.shared.value.notesRoots
        guard roots.contains(where: { FileSafety.isInside(u, $0) || $0.standardizedFileURL.path == u.standardizedFileURL.path }) else {
            Prompt.info(title: "Pick a folder inside your notes folders", message: "New notes have to go somewhere the app shows as notes.")
            return
        }
        model.updateSpace(space.id) { $0.newNotesFolder = u.standardizedFileURL.path }
    }
}

/// "Move to space" for tabs, notes and splits.
struct MoveToSpaceMenu: View {
    let action: (UUID) -> Void
    @EnvironmentObject var model: BrowserModel
    var body: some View {
        if model.spaces.count > 1 {
            Menu("Move to space") {
                ForEach(model.spaces.filter { $0.id != model.currentSpaceID }) { sp in
                    Button(sp.name) { action(sp.id) }
                }
            }
        }
    }
}
