import AppKit
import SwiftUI

// Dragging onto folders, in the sidebar, the icon column and the tab bar. Tabs dropped anywhere
// on a folder's row go inside it. A folder dropped on the middle of another goes inside it, and on
// its top or bottom fifth (left or right in the tab bar) goes beside it, Zen's bands
// (notes/research/2026-11-08-drag-and-split.md). Resting on a closed folder during a drag springs
// it open, like Finder, so you can reach the folders inside it. Arc and Zen keep closed folders
// shut during a drag, but neither has a way into a subfolder of a closed folder without it.

/// Where a drag over a folder would land.
enum FolderDropZone: Equatable { case before, into, after }

/// Opens a closed folder after a drag rests on it.
final class SpringOpen {
    /// macOS opens a spring-loaded folder in Finder after about this long by default.
    static let delay: TimeInterval = 0.6
    private var work: DispatchWorkItem?
    private(set) var target: UUID?

    func arm(_ id: UUID, _ open: @escaping @MainActor () -> Void) {
        guard target != id else { return }
        cancel()
        target = id
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard self?.target == id else { return }
                self?.target = nil
                open()
            }
        }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: w)
    }

    func cancel() {
        work?.cancel()
        work = nil
        target = nil
    }
}

/// The zone a drag at `offset` points along a folder's row of `length` points would land in, or
/// nil where it can't land. Pure, so the tests can walk it.
enum FolderDropMath {
    /// The share of a folder's row at each end that drops beside it rather than inside.
    static let edgeShare: CGFloat = 0.2
    @MainActor
    static func zone(at offset: CGFloat, length: CGFloat, folder: Folder, dragging: [DragItem], model: BrowserModel) -> FolderDropZone? {
        // Files and folders from the popup go inside a folder on disk.
        if case .entry? = dragging.first { return folder.path != nil ? .into : nil }
        if case .folder(let fid)? = dragging.first {
            guard fid != folder.id else { return nil }
            let edge = length * edgeShare
            // Under an open folder with a couple of things in it, the bottom edge is where its
            // first child goes, so it counts as inside, as in Zen.
            let inside = model.childFolders(of: folder.id).count + model.refs(in: .folder(folder.id)).count
            let openBelow = folder.isExpanded && inside >= 2
            if offset < edge { return model.canNest(fid, in: folder.parentID) ? .before : nil }
            if offset > length - edge && !openBelow { return model.canNest(fid, in: folder.parentID) ? .after : nil }
            return model.canNest(fid, in: folder.id) ? .into : nil
        }
        // Splits stay out of folders. Anything else, or a drag that didn't say what it carries,
        // goes inside.
        if !dragging.isEmpty && dragging.allSatisfy({ if case .split = $0 { return true }; return false }) { return nil }
        return .into
    }

    /// Carries out a drop in a zone.
    @MainActor
    static func perform(_ items: [DragItem], zone: FolderDropZone, on folder: Folder, model: BrowserModel) {
        let entries = items.compactMap { if case .entry(let u) = $0 { return u }; return nil }
        if !entries.isEmpty {
            if let dir = model.folderDirectory(folder) {
                Motion.run(Motion.insert) {
                    model.fileEntries(entries.filter { $0.standardizedFileURL.path != dir.path }, into: dir)
                    model.syncPinnedFolders()
                    model.setFolder(folder.id, open: true)
                }
            }
            SidebarDrag.shared.end()
            return
        }
        if case .folder(let fid)? = items.first {
            Motion.run(Motion.insert) {
                switch zone {
                case .before: model.placeFolder(fid, next: folder.id, after: false)
                case .after: model.placeFolder(fid, next: folder.id, after: true)
                case .into: model.nestFolder(fid, into: folder.id)
                }
            }
            SidebarDrag.shared.end()
            return
        }
        let refs = items.compactMap(\.sidebarRef)
        SidebarDrag.shared.land(refs.first) { model.place(refs, in: .folder(folder.id), at: Int.max) }
    }
}

struct FolderDropDelegate: DropDelegate {
    let folder: Folder
    /// The row's height, or the chip's width in the tab bar.
    let length: CGFloat
    var horizontal = false
    let model: BrowserModel
    @Binding var zone: FolderDropZone?
    let spring: SpringOpen

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [ItemDrag.type]) }

    @MainActor private func compute(_ info: DropInfo) -> FolderDropZone? {
        // With a gap open before the folder, the folder itself starts after it.
        let gap = zone == .before ? (horizontal ? TabBarMetrics.dropGap : SidebarDrag.gap) : 0
        let offset = (horizontal ? info.location.x : info.location.y) - gap
        return FolderDropMath.zone(at: offset, length: length, folder: folder, dragging: SidebarDrag.shared.items, model: model)
    }

    func dropEntered(info: DropInfo) { _ = dropUpdated(info: info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let z = MainActor.assumeIsolated { compute(info) }
        if z != zone { zone = z }
        if z == .into, !folder.isExpanded {
            let f = folder.id, m = model
            spring.arm(f) { withAnimation(FolderMotion.toggle) { m.setFolder(f, open: true) } }
        } else {
            spring.cancel()
        }
        return DropProposal(operation: z == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) {
        zone = nil
        spring.cancel()
    }

    func performDrop(info: DropInfo) -> Bool {
        let z = zone ?? MainActor.assumeIsolated { compute(info) }
        zone = nil
        spring.cancel()
        guard let z else { return false }
        let f = folder, m = model
        return ItemDrag.loadItems(info.itemProviders(for: [ItemDrag.type])) { items in
            FolderDropMath.perform(items, zone: z, on: f, model: m)
        }
    }
}

/// A folder and, while it's open, its subfolders and items under it. Closed, it keeps showing
/// what's on screen from anywhere inside it. In the full sidebar each level steps in under the
/// folder's name. In the icon column nothing steps in, and a line in the space's colour runs down
/// the edge of an open folder.
struct FolderTree: View {
    let folder: Folder
    var depth = 0
    /// Draws a tab or split row, matched across sections by the space's page.
    let row: (SidebarRef) -> AnyView
    @EnvironmentObject var model: BrowserModel
    @Environment(\.sidebarIconsOnly) private var iconsOnly
    @Environment(\.spaceAccent) private var spaceAccent

    var body: some View {
        let subs = model.childFolders(of: folder.id)
        let rows = model.refs(in: .folder(folder.id))
        VStack(alignment: .leading, spacing: Theme.Space.rowGap) {
            FolderRow(folder: folder)
            FolderReveal(isOpen: folder.isExpanded) {
                VStack(spacing: Theme.Space.rowGap) {
                    ForEach(subs) { sub in
                        AnyView(FolderTree(folder: sub, depth: depth + 1, row: row))
                    }
                    ForEach(rows, id: \.self) { row($0).transition(Motion.Transitions.tabRow) }
                    if rows.isEmpty && subs.isEmpty && !iconsOnly {
                        Text("Empty")
                            .font(Theme.Font.secondary).foregroundStyle(.secondary)
                            .padding(.leading, Theme.Space.rowInset).frame(height: 24)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, Theme.Space.rowGap)
                // Child icons line up under the folder's name.
                .padding(.leading, iconsOnly ? 0 : Theme.Space.folderIndent)
            }
            if !folder.isExpanded {
                // A closed folder still shows what's on screen, like Arc and Zen.
                let shown = model.shownInClosedFolder(folder)
                if !shown.isEmpty {
                    VStack(spacing: Theme.Space.rowGap) { ForEach(shown, id: \.self) { row($0) } }
                        .padding(.leading, iconsOnly ? 0 : Theme.Space.folderIndent)
                        .transition(.opacity)
                }
            }
        }
        .background(alignment: .leading) {
            if iconsOnly && depth == 0 {
                Capsule()
                    .fill(spaceAccent.opacity(0.6))
                    .frame(width: 2)
                    .padding(.vertical, Theme.Space.s)
                    // 6 pt in from the sidebar's edge, where Chrome draws its open group's line.
                    .offset(x: -(Theme.Space.sidebarInset - 6))
                    .opacity(folder.isExpanded && model.tabCount(inTree: folder) + subs.count > 0 ? 1 : 0)
                    .motion(Motion.expand, value: folder.isExpanded, fadeOnly: true)
            }
        }
    }
}

extension BrowserModel {
    /// Changes whenever any folder in the space moves, opens, closes or gains or loses an item, so
    /// the sidebar can animate it.
    func folderSignature(space: UUID) -> [String] {
        folderTree(space: space).map { e in
            "\(e.folder.id)|\(e.depth)|\(e.folder.isExpanded)|" + refs(in: .folder(e.folder.id), space: space).map { "\($0.id)" }.joined(separator: ",")
        }
    }
}
