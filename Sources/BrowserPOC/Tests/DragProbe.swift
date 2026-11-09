import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// `--drag-probe --profile <demo profile>`: hands drops to the window the way AppKit does during a
/// real drag, on a throwaway copy of the demo profile. AppKit gives a drag to the deepest view
/// under the pointer that registered for one of the types on the drag's pasteboard, then calls
/// that view's dragging methods. The offscreen shots draw the drop previews through stand-ins and
/// skip this step, which is how drops that never reached any view went unnoticed (2026-11-08).
/// The tab's id goes on the pasteboard as the drag source puts it there.
@MainActor
enum DragProbe {
    /// A drag as AppKit hands it to a view: where the pointer is and what's on the pasteboard.
    @MainActor
    final class Drag: NSObject, @preconcurrency NSDraggingInfo {
        let window: NSWindow
        var location: NSPoint
        let pasteboard: NSPasteboard

        init(window: NSWindow, location: NSPoint, pasteboard: NSPasteboard) {
            self.window = window
            self.location = location
            self.pasteboard = pasteboard
        }

        var draggingDestinationWindow: NSWindow? { window }
        var draggingSourceOperationMask: NSDragOperation { [.move, .copy, .generic] }
        var draggingLocation: NSPoint { location }
        var draggedImageLocation: NSPoint { location }
        var draggedImage: NSImage? { nil }
        var draggingPasteboard: NSPasteboard { pasteboard }
        var draggingSource: Any? { nil }
        let draggingSequenceNumber = Int.random(in: 1000...999_999)
        func slideDraggedImage(to screenPoint: NSPoint) {}
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                    searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                    using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
    }

    static func commandLine(_ args: [String]) -> Int32 {
        // Each line as it's printed, so a crash still shows how far the probe got.
        setvbuf(stdout, nil, _IOLBF, 0)
        func arg(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        guard let p = arg("--profile") else {
            print("Usage: --drag-probe --profile <demo profile>")
            return 2
        }
        let profile = URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: profile.appendingPathComponent(DemoSeeder.marker).path) else {
            print("\(profile.path) isn't a demo profile.")
            return 1
        }
        guard let h = DragShots.open(profile: profile) else { return 1 }
        defer { h.close() }
        let code = run(h.model, h.window)
        // The probe hands SwiftUI's drop views stand-in drags that AppKit never ends. Letting the
        // window go and the run loop settle before the process exits keeps teardown from tripping
        // over them.
        h.window.orderOut(nil)
        h.window.close()
        _ = SmokeTest.wait(0.5) { false }
        fflush(stdout)
        return code
    }

    /// Whether a view takes a drag with these types. AppKit goes by type conformance: SwiftUI's
    /// drop targets register for public.data and public.item, and take any type declared as data.
    static func takes(_ view: NSView, _ types: Set<NSPasteboard.PasteboardType>) -> Bool {
        let registered = view.registeredDraggedTypes
        return types.contains { t in
            registered.contains(t) || registered.contains { r in
                guard let a = UTType(t.rawValue), let b = UTType(r.rawValue) else { return false }
                return a.conforms(to: b)
            }
        }
    }

    /// The deepest view at `p`, in window coordinates, that takes a drag with these types.
    static func destination(in view: NSView, at p: NSPoint, types: Set<NSPasteboard.PasteboardType>) -> NSView? {
        guard !view.isHidden, view.bounds.contains(view.convert(p, from: nil)) else { return nil }
        for sub in view.subviews.reversed() {
            if let d = destination(in: sub, at: p, types: types) { return d }
        }
        return takes(view, types) ? view : nil
    }

    static func allViews(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap { allViews($0) } }

    static func run(_ model: BrowserModel, _ window: NSWindow) -> Int32 {
        var failed = 0
        func check(_ ok: Bool, _ label: String, _ detail: String = "") {
            print("  \(ok ? "ok  " : "FAIL") \(label)\(detail.isEmpty ? "" : " (\(detail))")")
            if !ok { failed += 1 }
        }
        func spin(_ s: Double = 0.3) { _ = SmokeTest.wait(s) { false } }
        guard let content = window.contentView else { print("No content view"); return 1 }
        let rainType = NSPasteboard.PasteboardType(ItemDrag.identifier)

        print("Probing drops in a window on a copy of the demo profile")
        guard let school = model.spaces.first(where: { $0.name == "School" }) else { print("No School space"); return 1 }
        model.switchSpace(to: school.id)
        for f in model.folders(in: school.id) { model.setFolder(f.id, open: false) }
        spin(1)

        let takers = allViews(content).filter { takes($0, [rainType]) }
        check(UTType(ItemDrag.identifier)?.conforms(to: .data) == true, "Rain's drag type is declared as data")
        check(!takers.isEmpty, "some view in the window takes Rain's drags", "\(takers.count) drop targets")

        /// A pasteboard holding what the drag source puts there: the provider's bytes for Rain's type.
        func pasteboard(_ provider: NSItemProvider) -> NSPasteboard? {
            var bytes: Data?
            _ = provider.loadDataRepresentation(forTypeIdentifier: ItemDrag.identifier) { d, _ in DispatchQueue.main.async { bytes = d ?? Data() } }
            _ = SmokeTest.wait(2) { bytes != nil }
            guard let bytes, !bytes.isEmpty else { print("  the drag source gave no bytes"); return nil }
            let pb = NSPasteboard(name: NSPasteboard.Name("rain-drag-probe-\(UUID().uuidString)"))
            pb.clearContents()
            let item = NSPasteboardItem()
            item.setData(bytes, forType: rainType)
            pb.writeObjects([item])
            return pb
        }

        /// Moves a drag from `start` onto the view AppKit would give it at `end`. Returns that view,
        /// the drag and what the view said to the last move, or nil if no view takes it.
        func hover(_ pb: NSPasteboard, from start: NSPoint, to end: NSPoint, items: [DragItem]) -> (NSDraggingDestination, Drag, NSDragOperation)? {
            SidebarDrag.shared.begin(items: items)
            guard let view = destination(in: content, at: end, types: [rainType]) else { return nil }
            let d = Drag(window: window, location: start, pasteboard: pb)
            let dest = view as NSDraggingDestination
            _ = dest.draggingEntered?(d)
            spin(0.1)
            var op: NSDragOperation = []
            for t in stride(from: 0.25, through: 1.0, by: 0.25) {
                d.location = NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                op = dest.draggingUpdated?(d) ?? []
                spin(0.1)
            }
            return (dest, d, op)
        }

        func drop(_ dest: NSDraggingDestination, _ d: Drag) {
            if dest.prepareForDragOperation?(d) ?? true, dest.performDragOperation?(d) ?? false {
                dest.concludeDragOperation?(d)
            }
            spin(0.6)
        }

        func drag(_ provider: NSItemProvider, from start: NSPoint, to end: NSPoint, items: [DragItem]) -> NSDragOperation? {
            guard let pb = pasteboard(provider) else { return nil }
            defer { pb.releaseGlobally() }
            guard let (dest, d, op) = hover(pb, from: start, to: end, items: items) else { return nil }
            if op.isEmpty { dest.draggingExited?(d) } else { drop(dest, d) }
            return op
        }

        // A loose tab dropped on the left of the page opens a split with it on the left.
        let loose = model.refs(in: .today).compactMap { r -> Tab? in if case .tab(let id) = r { return model.tab(id) }; return nil }
        guard let page = loose.first(where: { $0.isWeb }), let incoming = loose.first(where: { $0.isWeb && $0.id != page.id }) else {
            print("The School space needs two loose pages")
            return 1
        }
        model.select(page)
        spin(1)
        if let host = allViews(content).first(where: { $0 is WebHostView }) {
            let r = host.convert(host.bounds, to: nil)
            let op = drag(ItemDrag.provider(incoming.id), from: NSPoint(x: r.midX, y: r.midY), to: NSPoint(x: r.minX + r.width * 0.25, y: r.midY), items: [.tab(incoming.id)])
            check(op != nil, "a view under the page takes a tab's drag")
            check(op?.contains(.move) == true, "the page offers to move the tab there", op.map { "\($0.rawValue)" } ?? "no view")
            let sp = model.currentSplit
            check(sp?.items.contains(incoming.id) == true && sp?.items.contains(page.id) == true, "dropping it there splits the page with it")
            check(sp?.root.leaves.first == incoming.id, "it lands on the left, where it was dropped")
        } else {
            check(false, "found the page's web view")
        }

        // A tab resting on a closed folder's row springs it open, and dropped there goes inside.
        // The probe finds the folder's row by resting the drag on each row in turn until a folder
        // opens: SwiftUI builds no accessibility tree in an offscreen window to find it by.
        model.select(page)
        spin(0.5)
        let looseNow = model.refs(in: .today).compactMap { r -> Tab? in if case .tab(let id) = r { return model.tab(id) }; return nil }
        if let tab = looseNow.first(where: { $0.id != page.id && model.currentSplit?.items.contains($0.id) != true }),
           let pb = pasteboard(ItemDrag.provider(tab.id)) {
            defer { pb.releaseGlobally() }
            var rows: [NSRect] = []
            for v in allViews(content) where takes(v, [rainType]) {
                let r: NSRect = v.convert(v.bounds, to: nil)
                if r.minX < 120 && r.width > 150 && r.height >= 28 && r.height <= 40 { rows.append(r) }
            }
            rows.sort { $0.maxY > $1.maxY }
            var opened: Folder?
            for r in rows {
                let at = NSPoint(x: r.midX, y: r.midY)
                guard let (dest, d, _) = hover(pb, from: NSPoint(x: at.x + 500, y: at.y), to: at, items: [.tab(tab.id)]) else { continue }
                spin(SpringOpen.delay + 0.3)
                if let f = model.childFolders(of: nil).first(where: { $0.isExpanded }) {
                    opened = f
                    drop(dest, d)
                    check(model.refs(in: .folder(f.id)).contains(.tab(tab.id)), "dropping a tab on a folder puts it inside", f.name)
                    break
                }
                dest.draggingExited?(d)
                spin(0.3)
            }
            check(opened != nil, "resting a tab's drag on a closed folder opens it", opened?.name ?? "\(rows.count) rows tried")
        } else {
            check(false, "found a loose tab to drag")
        }
        SidebarDrag.shared.end()

        // The folder popup: a tab dropped in it is saved in the folder it shows.
        let popup = FolderPopup.shared
        if let schoolDir = model.spaceFolderURL(school) {
            model.select(page)
            spin(0.5)
            if let tab = Optional(page), let u = tab.url {
                popup.open(model)
                spin(0.8)
                // The panel's frame counts from the top left. Drops here are in window
                // coordinates, which count from the bottom left.
                let r = popup.panelFrame
                // Low in the grid, past the cards.
                let at = NSPoint(x: r.maxX - 70, y: content.bounds.height - r.maxY + 50)
                let op = drag(ItemDrag.provider(tab.id), from: NSPoint(x: 40, y: at.y), to: at, items: [.tab(tab.id)])
                spin(0.5)
                let saved = SpaceFolders.list(schoolDir).contains { $0.page.map { URLKey.key(for: $0) == URLKey.key(for: u) } ?? false }
                check(op?.isEmpty == false && saved, "a tab dropped into the popup is saved in the folder it shows", tab.displayTitle)
                popup.close()
                spin(0.5)
            } else {
                check(false, "found a page to drop into the popup")
            }

            // Something from the popup dropped on a pinned folder moves into it.
            if let item = SpaceFolders.list(schoolDir).first(where: { $0.kind == .page }), let pb = pasteboard(ItemDrag.provider(entries: [item.url])) {
                defer { pb.releaseGlobally() }
                for f in model.childFolders(of: nil) { model.setFolder(f.id, open: false) }
                spin(0.6)
                var rows: [NSRect] = []
                for v in allViews(content) where takes(v, [rainType]) {
                    let r: NSRect = v.convert(v.bounds, to: nil)
                    if r.minX < 120 && r.width > 150 && r.height >= 28 && r.height <= 40 { rows.append(r) }
                }
                rows.sort { $0.maxY > $1.maxY }
                var into: Folder?
                for r in rows {
                    let at = NSPoint(x: r.midX, y: r.midY)
                    guard let (dest, d, _) = hover(pb, from: NSPoint(x: at.x + 500, y: at.y), to: at, items: [.entry(item.url)]) else { continue }
                    spin(SpringOpen.delay + 0.3)
                    if let f = model.childFolders(of: nil).first(where: { $0.isExpanded }) {
                        into = f
                        drop(dest, d)
                        spin(0.6)
                        let dir = model.folderDirectory(f)
                        let moved = dir.map { SpaceFolders.exists($0.appendingPathComponent(item.url.lastPathComponent)) } ?? false
                        let shown = model.tabs.contains { $0.folderID == f.id && $0.savedFile?.hasSuffix("/" + item.url.lastPathComponent) == true }
                        check(moved && !SpaceFolders.exists(item.url) && shown, "a page dragged from the popup onto a pinned folder moves into it", f.name)
                        break
                    }
                    dest.draggingExited?(d)
                    spin(0.3)
                }
                check(into != nil, "a drag from the popup resting on a closed pinned folder opens it", into?.name ?? "\(rows.count) rows tried")
            } else {
                check(false, "found a saved page to drag out of the popup")
            }

            // A folder from the popup dropped on the Folders header is pinned.
            let reading = schoolDir.appendingPathComponent("Reading", isDirectory: true)
            if SpaceFolders.isDirectory(reading), let pb = pasteboard(ItemDrag.provider(entries: [reading])) {
                defer { pb.releaseGlobally() }
                let before = model.pinnedFolders.count
                var headers: [NSRect] = []
                for v in allViews(content) where takes(v, [rainType]) {
                    let r: NSRect = v.convert(v.bounds, to: nil)
                    if r.minX < 120 && r.width > 150 && r.height >= 14 && r.height < 28 { headers.append(r) }
                }
                headers.sort { $0.maxY > $1.maxY }
                var pinned = false
                for r in headers {
                    let at = NSPoint(x: r.midX, y: r.midY)
                    guard let (dest, d, op) = hover(pb, from: NSPoint(x: at.x + 500, y: at.y), to: at, items: [.entry(reading)]) else { continue }
                    if op.isEmpty { dest.draggingExited?(d); continue }
                    drop(dest, d)
                    spin(0.5)
                    if model.pinnedFolders.count == before + 1 { pinned = true; break }
                }
                check(pinned && model.pinnedFolders.first?.path == SpaceFolders.encode(reading) && SpaceFolders.isDirectory(reading),
                      "a folder dragged from the popup into the Folders section is pinned, and stays where it is", "\(headers.count) headers tried")
            } else {
                check(false, "the School folder has a Reading folder to pin")
            }
        } else {
            check(false, "the School space has a folder")
        }
        SidebarDrag.shared.end()

        print(failed == 0 ? "All drops landed." : "\(failed) drop checks failed.")
        return failed == 0 ? 0 : 1
    }
}
