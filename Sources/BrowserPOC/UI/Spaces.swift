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

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(model.spaces.enumerated()), id: \.element.id) { i, sp in
                SpaceButton(space: sp, index: i)
                    .transition(Motion.Transitions.tabRow)
            }
            SmallIconButton(symbol: "plus", help: "New space") { model.promptNewSpace() }
        }
    }
}

struct SpaceButton: View {
    let space: Space
    let index: Int
    @EnvironmentObject var model: BrowserModel
    @State private var hovering = false

    var current: Bool { model.currentSpaceID == space.id }

    var body: some View {
        // Only the current space shows its colour. The others are grey until you hover them, like Zen.
        SpaceIcon(icon: space.icon)
            .foregroundStyle(current || hovering ? Theme.Palette.accent(space.color) : Color.secondary)
            .saturation(current || hovering ? 1 : 0)
            .opacity(current || hovering ? 1 : 0.7)
            .frame(width: 26, height: 24)
            .background(Theme.Radius.shape(Theme.Radius.button)
                .fill(current ? Theme.Palette.tint(space.color).opacity(0.16) : (hovering ? Theme.Palette.rowHover : .clear)))
            .motion(Motion.hover, value: hovering, fadeOnly: true)
            .motion(Motion.spaceSwitch, value: current, fadeOnly: true)
            .contentShape(Rectangle())
            .onTapGesture { model.switchSpace(to: space.id) }
            .onHover { hovering = $0 }
            .help(index < 9 ? "\(space.name)  (Ctrl-\(index + 1))" : space.name)
            .onDrop(of: [ItemDrag.type], isTargeted: nil) { providers in
                ItemDrag.load(providers) { ids in
                    for id in ids { if let t = model.tab(id) { model.move(t, toSpace: space.id) } }
                }
            }
            .contextMenu {
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
                Divider()
                Button("Move left") { model.moveSpace(space.id, by: -1) }.disabled(index == 0)
                Button("Move right") { model.moveSpace(space.id, by: 1) }.disabled(index == model.spaces.count - 1)
                Divider()
                Button("Delete space...") { model.promptDeleteSpace(space) }.disabled(model.spaces.count < 2)
            }
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

/// Two-finger horizontal swipes over the sidebar move between spaces. Mostly vertical
/// scrolls are left alone so the sidebar still scrolls normally.
struct SpaceSwipeCatcher: NSViewRepresentable {
    let onSwipe: (Int) -> Void

    final class CatcherView: NSView {
        var onSwipe: ((Int) -> Void)?
        private var monitor: Any?
        private var dx: CGFloat = 0
        private var dy: CGFloat = 0
        private var fired = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
                guard let self, let w = self.window, e.window === w, e.hasPreciseScrollingDeltas else { return e }
                let p = self.convert(e.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return e }
                if e.phase == .began { self.dx = 0; self.dy = 0; self.fired = false }
                self.dx += e.scrollingDeltaX
                self.dy += e.scrollingDeltaY
                if !self.fired && abs(self.dx) > 90 && abs(self.dx) > 3 * abs(self.dy) {
                    self.fired = true
                    self.onSwipe?(self.dx > 0 ? -1 : 1)
                }
                if e.phase == .ended || e.phase == .cancelled { self.dx = 0; self.dy = 0 }
                return e
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onSwipe = onSwipe
        return v
    }
    func updateNSView(_ v: CatcherView, context: Context) { v.onSwipe = onSwipe }
}
