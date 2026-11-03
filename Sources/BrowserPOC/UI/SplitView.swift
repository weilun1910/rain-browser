import AppKit
import SwiftUI

/// Sidebar items drag as an app-only pasteboard type, so web pages and text views don't take the drop.
enum ItemDrag {
    static let type = "local.browserpoc.item"

    static func provider(_ id: UUID) -> NSItemProvider {
        NSItemProvider(item: id.uuidString as NSString, typeIdentifier: type)
    }

    @discardableResult
    static func load(_ providers: [NSItemProvider], _ done: @escaping @MainActor ([UUID]) -> Void) -> Bool {
        let ps = providers.filter { $0.hasItemConformingToTypeIdentifier(type) }
        guard !ps.isEmpty else { return false }
        let lock = NSLock()
        var ids: [UUID] = []
        let group = DispatchGroup()
        for p in ps {
            group.enter()
            p.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                var s = (item as? NSString) as String?
                if s == nil, let d = item as? Data { s = String(data: d, encoding: .utf8) }
                if let s, let id = UUID(uuidString: s) { lock.lock(); ids.append(id); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { done(ids) } }
        return true
    }
}

extension View {
    /// Rounded card for a page or note pane. A split's focused pane gets a quiet ring.
    func paneCard(focusRing: Bool = false) -> some View {
        self
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(focusRing ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: focusRing ? 1.5 : 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
    }
}

/// One pane: a page, a note, or the start view.
struct PaneView: View {
    let tab: Tab?
    var body: some View {
        if let tab, tab.kind != .web {
            NotePane(tab: tab)
        } else if let tab {
            TabContent(tab: tab)
        } else {
            StartView()
        }
    }
}

struct SplitPanes: View {
    let split: SplitRecord
    let left: Tab
    let right: Tab
    let width: CGFloat
    @EnvironmentObject var model: BrowserModel
    @State private var dragStart: Double?

    static let gap: CGFloat = 8
    static let minPane: CGFloat = 320

    var leftWidth: CGFloat {
        let avail = max(0, width - Self.gap)
        let lo = min(Self.minPane, avail / 2), hi = max(avail - Self.minPane, avail / 2)
        return min(hi, max(lo, avail * split.ratio))
    }

    var body: some View {
        HStack(spacing: 0) {
            PaneView(tab: left)
                .paneCard(focusRing: !split.focusRight)
                .background(PaneClickCatcher { model.focusPane(.left) })
                .frame(width: leftWidth)
            divider
            PaneView(tab: right)
                .paneCard(focusRing: split.focusRight)
                .background(PaneClickCatcher { model.focusPane(.right) })
        }
    }

    var divider: some View {
        Color.clear
            .frame(width: Self.gap)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        let start = dragStart ?? split.ratio
                        if dragStart == nil { dragStart = start }
                        let avail = max(1, width - Self.gap)
                        let minR = Double(min(0.5, Self.minPane / avail)), maxR = 1 - minR
                        model.setSplitRatio(min(maxR, max(minR, start + Double(v.translation.width / avail))), save: false)
                    }
                    .onEnded { _ in dragStart = nil; model.setSplitRatio(split.ratio, save: true) }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { model.setSplitRatio(0.5, save: true) })
            .help("Drag to resize. Double-click for half and half.")
    }
}

/// Watches clicks inside a pane, including clicks that land in a web page or a text view.
struct PaneClickCatcher: NSViewRepresentable {
    let onClick: () -> Void

    final class CatcherView: NSView {
        var onClick: (() -> Void)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
                guard let self, let w = self.window, e.window === w else { return e }
                let p = self.convert(e.locationInWindow, from: nil)
                if self.bounds.contains(p) { self.onClick?() }
                return e
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onClick = onClick
        return v
    }

    func updateNSView(_ v: CatcherView, context: Context) { v.onClick = onClick }
}

/// Dropping a sidebar item on the left or right half of the content area opens a split.
struct PaneDropDelegate: DropDelegate {
    let width: CGFloat
    @Binding var side: PaneSide?
    let model: BrowserModel

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [ItemDrag.type]) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        side = info.location.x < width / 2 ? .left : .right
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { side = nil }

    func performDrop(info: DropInfo) -> Bool {
        let s = side ?? .right
        side = nil
        return ItemDrag.load(info.itemProviders(for: [ItemDrag.type])) { ids in
            if let id = ids.first { model.drop(tabID: id, side: s) }
        }
    }
}

/// A split in the sidebar: one joined row with both items.
struct SplitRow: View {
    let split: SplitRecord
    @EnvironmentObject var model: BrowserModel
    @State private var hovering = false

    var selected: Bool { model.currentSplit?.id == split.id }

    var body: some View {
        HStack(spacing: 0) {
            half(model.tab(split.left), focused: selected && !split.focusRight)
            Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1, height: 16)
            half(model.tab(split.right), focused: selected && split.focusRight)
        }
        .frame(height: 28)
        .modifier(RowBackground(selected: selected, hovering: hovering))
        .contentShape(Rectangle())
        .onTapGesture { model.selectSplit(split) }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Separate") { model.separate(split) }
            Button("Swap sides") { model.swap(split) }
            MoveToSpaceMenu { id in model.move(split: split, toSpace: id) }
        }
    }

    func half(_ t: Tab?, focused: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: t?.kind == .web ? "globe" : "note.text")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Text(t?.displayTitle ?? "")
                .font(.system(size: 12, weight: focused ? .medium : .regular))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
