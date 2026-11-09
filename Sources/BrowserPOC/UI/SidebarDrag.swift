import AppKit
import SwiftUI

// Dragging rows in the sidebar (notes/plans/2026-11-05-motion.md, section 4). While you drag, the
// rows part to make room where the row would land, and the row you picked up waits in its old
// place at 35 percent. SwiftUI says when a drag starts but not when it ends, so the end is noticed
// by watching for the mouse button to come up.

@MainActor
final class SidebarDrag: ObservableObject {
    static let shared = SidebarDrag()

    /// The items being dragged, dimmed in place until the drag ends.
    @Published private(set) var dragging: Set<UUID> = []
    /// What's being dragged, known as soon as the drag starts. Drop targets read it to decide
    /// what to show before the drop hands over the items: a folder can't make a split, and only
    /// a folder goes beside another folder.
    private(set) var items: [DragItem] = []
    /// The item a drop just placed. It lands in the gap instead of gliding from where it was.
    @Published private(set) var landing: SidebarRef?
    /// For the motion tour, which can't start a real drag: a row that shows a gap as if hovered.
    @Published var preview: (ref: SidebarRef, at: RowDropIndicator)?
    /// The same for a folder: the zone it shows as if a drag were over it.
    @Published var folderPreview: (folder: UUID, zone: FolderDropZone)?
    private var timer: Timer?

    /// The height of the gap rows part by.
    static let gap: CGFloat = Theme.Space.rowHeight + Theme.Space.rowGap
    static let dimmed: Double = 0.35

    /// Tabs picked up, by id.
    func begin(_ ids: [UUID]) { begin(items: ids.map { .tab($0) }) }

    func begin(items: [DragItem]) {
        self.items = items
        let ids = items.map { i -> UUID in
            switch i { case .tab(let id), .split(let id), .folder(let id): return id }
        }
        // Set on the next turn: SwiftUI asks for the drag's item while it builds the drag image.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                Motion.run(Motion.hover, fadeOnly: true) { self.dragging = Set(ids) }
                self.watch()
            }
        }
    }

    private func watch() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); return }
                if NSEvent.pressedMouseButtons & 1 == 0 { self.end() }
            }
        }
    }

    /// For the motion tour: dims `ids` as if they were being dragged, until `end()`.
    func pretend(_ ids: [UUID]) { Motion.run(Motion.hover, fadeOnly: true) { dragging = Set(ids) } }

    /// The one tab being dragged, if that's what it is.
    var draggedTab: UUID? {
        guard items.count == 1, case .tab(let id) = items[0] else { return nil }
        return id
    }

    var draggingFolder: UUID? {
        guard case .folder(let id)? = items.first else { return nil }
        return id
    }

    func end() {
        timer?.invalidate()
        timer = nil
        preview = nil
        folderPreview = nil
        items = []
        guard !dragging.isEmpty else { return }
        Motion.run(Motion.hover, fadeOnly: true) { dragging = [] }
    }

    /// Runs a drop's model change so the dropped row lands in its gap.
    func land(_ ref: SidebarRef?, _ change: () -> Void) {
        landing = ref
        Motion.run(Motion.insert) { change() }
        end()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            MainActor.assumeIsolated { if self.landing == ref { self.landing = nil } }
        }
    }
}
