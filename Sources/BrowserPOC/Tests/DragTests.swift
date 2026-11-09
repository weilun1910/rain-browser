import AppKit
import Foundation

/// Dragging tabs around: folders inside folders, where a drag over a folder lands, what a drag
/// says it carries, where a tab dragged over the page would go, and the split divider's detent.
enum DragTests {
    static func check(_ ok: Bool, _ label: String, _ detail: String = "") { SelfTest.check(ok, label, detail) }

    static func run(dir: URL) {
        MainActor.assumeIsolated {
            BrowserModel.useEphemeralStore = true
            BrowserPrefs.shared.reload()
            nesting()
            deleting()
            closedAndKeyboard()
            savingAndRepair()
            folderZones()
            dragItems()
            pageDrop()
            divider()
            SidebarDrag.shared.end()
            try? FileManager.default.removeItem(at: Paths.stateFile)
        }
    }

    @MainActor static func page(_ m: BrowserModel, _ url: String, select: Bool = false) -> Tab { ArcZenTests.page(m, url, url, select: select) }

    // MARK: Folders inside folders

    @MainActor static func nesting() {
        let m = ArcZenTests.freshModel()
        let work = m.createFolder(named: "Work")
        let q3 = m.createFolder(named: "Q3", in: work.id)
        let reading = m.createFolder(named: "Reading", in: q3.id)
        let later = m.createFolder(named: "Later")
        check(m.childFolders(of: nil).map(\.id) == [later.id, work.id] && m.childFolders(of: work.id).map(\.id) == [q3.id],
              "a subfolder sits inside its parent, not at the top")
        check(m.folderTree().map { "\($0.folder.name)\($0.depth)" } == ["Later0", "Work0", "Q31", "Reading2"],
              "the tree lists each folder under its parent with its depth")
        check(m.folderDepth(reading.id) == 2 && m.ancestors(of: reading.id) == [q3.id, work.id] && Set(m.descendants(of: work.id)) == [q3.id, reading.id],
              "a folder knows the folders it's in and the folders in it")
        check(m.folderPath(m.folder(reading.id)!) == "Work / Q3 / Reading", "menus name a subfolder by its path")

        // Into and beside.
        check(m.nestFolder(later.id, into: work.id) && m.folder(later.id)?.parentID == work.id
              && m.childFolders(of: work.id).map(\.id) == [q3.id, later.id],
              "a folder dropped on another goes inside it, after its other subfolders")
        check(m.placeFolder(later.id, next: work.id, after: false) && m.folder(later.id)?.parentID == nil
              && m.childFolders(of: nil).map(\.id) == [later.id, work.id],
              "a folder dropped beside a top folder comes back out to the top")
        check(m.placeFolder(later.id, next: reading.id, after: true) && m.folder(later.id)?.parentID == q3.id
              && m.childFolders(of: q3.id).map(\.id) == [reading.id, later.id],
              "beside a subfolder means inside that subfolder's parent")

        // Never inside itself.
        check(!m.nestFolder(work.id, into: work.id) && !m.nestFolder(work.id, into: reading.id) && m.folder(work.id)?.parentID == nil,
              "a folder can't go inside itself or anything inside it")
        check(!m.placeFolder(work.id, next: reading.id, after: true) && m.folder(work.id)?.parentID == nil,
              "or beside something inside it")

        // The depth limit.
        var chain = [m.createFolder(named: "L0")]
        for n in 1..<Folder.maxDepth { chain.append(m.createFolder(named: "L\(n)", in: chain[n - 1].id)) }
        check(m.folderDepth(chain.last!.id) == Folder.maxDepth - 1, "folders nest \(Folder.maxDepth) levels deep")
        let tooDeep = m.createFolder(named: "Too deep", in: chain.last!.id)
        check(tooDeep.parentID == nil, "a new subfolder past the limit goes at the top instead")
        m.toastState = nil
        check(!m.nestFolder(tooDeep.id, into: chain.last!.id) && m.toastState?.message.contains("levels deep") == true,
              "dropping a folder past the limit says why and does nothing")
        check(!m.canNest(work.id, in: chain[Folder.maxDepth - 3].id), "a folder with subfolders can't go where they'd pass the limit",
              "Work holds 2 levels")
        check(m.canNest(work.id, in: chain[0].id), "but can where they fit")

        // Tabs in subfolders.
        let a = page(m, "https://a.example/")
        m.place([.tab(a.id)], in: .folder(reading.id), at: 0)
        check(a.folderID == reading.id && m.tabCount(inTree: m.folder(work.id)!) == 1,
              "a tab dragged into a subfolder files there, and the top folder counts it")
        m.setFolder(work.id, open: false)
        m.setFolder(q3.id, open: false)
        let b = page(m, "https://b.example/")
        m.move(b, to: reading.id)
        check(m.folder(work.id)?.isExpanded == true && m.folder(q3.id)?.isExpanded == true && m.folder(reading.id)?.isExpanded == true,
              "filing a tab in a subfolder opens every folder above it, so it's on screen")
    }

    @MainActor static func deleting() {
        let m = ArcZenTests.freshModel()
        let top = m.createFolder(named: "Top")
        let mid = m.createFolder(named: "Mid", in: top.id)
        let x = m.createFolder(named: "X", in: mid.id)
        let y = m.createFolder(named: "Y", in: mid.id)
        let sibling = m.createFolder(named: "Sibling", in: top.id)
        let a = page(m, "https://a.example/")
        m.move(a, to: mid.id)
        m.placeFolder(sibling.id, in: top.id, at: Int.max)
        check(m.childFolders(of: top.id).map(\.id) == [mid.id, sibling.id], "setup: Mid then Sibling inside Top")
        m.deleteFolder(m.folder(mid.id)!)
        check(m.folder(mid.id) == nil && m.childFolders(of: top.id).map(\.id) == [y.id, x.id, sibling.id],
              "deleting a subfolder moves its subfolders up into its place")
        check(a.folderID == top.id && m.folder(top.id) != nil, "and its tabs into the folder it was in")
        m.deleteFolder(m.folder(top.id)!)
        check(a.folderID == nil && m.looseTabs.contains { $0.id == a.id } && m.childFolders(of: nil).map(\.id).starts(with: [y.id, x.id, sibling.id]),
              "deleting a top folder sends its tabs to Tabs and its subfolders to the top")
    }

    @MainActor static func closedAndKeyboard() {
        let m = ArcZenTests.freshModel()
        let top = m.createFolder(named: "Top")
        let sub = m.createFolder(named: "Sub", in: top.id)
        let inSub = page(m, "https://sub.example/")
        let inTop = page(m, "https://top.example/")
        m.move(inSub, to: sub.id)
        m.move(inTop, to: top.id)
        let loose = page(m, "https://loose.example/")
        check(m.sidebarStops == [.folder(top.id), .folder(sub.id), .row(.tab(inSub.id)), .row(.tab(inTop.id)), .row(.tab(loose.id))],
              "the keyboard walks a folder's subfolders before its tabs")
        check(m.visibleRowOrder == [.tab(inSub.id), .tab(inTop.id), .tab(loose.id)], "Cmd-1 to 9 count rows in subfolders in the order they show")
        m.select(inSub)
        m.setFolder(top.id, open: false)
        check(m.shownInClosedFolder(m.folder(top.id)!) == [.tab(inSub.id)],
              "a closed folder still shows the page on screen from a folder inside it")
        check(m.sidebarStops == [.folder(top.id), .row(.tab(inSub.id)), .row(.tab(loose.id))], "and the keyboard skips what's hidden")
        m.setFolder(top.id, open: true)
        m.sidebarCursor = .folder(top.id)
        m.sidebarCursorRight()
        check(m.sidebarCursor == .folder(sub.id), "Right on an open folder goes to its first subfolder")
        m.sidebarCursorLeft()
        check(m.folder(sub.id)?.isExpanded == false, "Left closes it")
        m.sidebarCursorLeft()
        check(m.sidebarCursor == .folder(top.id), "and Left again on a closed subfolder goes up to its parent")
        m.sidebarCursor = nil
    }

    @MainActor static func savingAndRepair() {
        let m = ArcZenTests.freshModel()
        let top = m.createFolder(named: "Top")
        let sub = m.createFolder(named: "Sub", in: top.id)
        m.saveNow()
        let re = BrowserModel()
        check(re.folder(sub.id)?.parentID == top.id && re.childFolders(of: top.id).map(\.id) == [sub.id], "subfolders survive a relaunch")

        // A file from before subfolders, and a damaged one.
        let s = re.currentSpaceID
        let a = UUID(), b = UUID(), c = UUID(), gone = UUID()
        let chain: [UUID] = (0...Folder.maxDepth).map { _ in UUID() }
        let deep = chain.enumerated().map { i, id in
            "{\"id\":\"\(id)\",\"spaceID\":\"\(s)\",\"name\":\"D\(i)\",\"order\":\(i)" + (i > 0 ? ",\"parentID\":\"\(chain[i - 1])\"" : "") + "}"
        }.joined(separator: ",")
        let json = """
        {"version":3,"spaces":[{"id":"\(s.uuidString)","name":"Home","icon":"house","color":"#7A8CA8"}],"currentSpace":"\(s.uuidString)",
         "tabs":[],"folders":[
          {"id":"\(a)","spaceID":"\(s)","name":"Old","order":0},
          {"id":"\(b)","spaceID":"\(s)","name":"Orphan","order":1,"parentID":"\(gone)"},
          {"id":"\(c)","spaceID":"\(s)","name":"LoopA","order":2,"parentID":"\(c)"},
          \(deep)]}
        """
        try? Data(json.utf8).write(to: Paths.stateFile)
        let old = BrowserModel()
        check(old.folder(a)?.parentID == nil && old.childFolders(of: nil).contains { $0.id == a }, "folders from before subfolders load at the top")
        check(old.folder(b)?.parentID == nil, "a folder whose parent is gone moves to the top")
        check(old.folder(c)?.parentID == nil, "a folder inside itself moves to the top")
        check(chain.allSatisfy { old.folderDepth($0) < Folder.maxDepth } && old.folder(chain.last!)?.parentID != nil,
              "folders nested past the limit move up to fit")
        try? FileManager.default.removeItem(at: Paths.stateFile)
    }

    // MARK: Where a drag over a folder lands

    @MainActor static func folderZones() {
        let m = ArcZenTests.freshModel()
        let target = m.createFolder(named: "Target")
        let other = m.createFolder(named: "Other")
        let sub = m.createFolder(named: "Sub", in: other.id)
        let h: CGFloat = 32
        func zone(_ y: CGFloat, _ items: [DragItem], on f: Folder? = nil) -> FolderDropZone? {
            FolderDropMath.zone(at: y, length: h, folder: f ?? m.folder(target.id)!, dragging: items, model: m)
        }
        m.setFolder(target.id, open: false)
        check(zone(4, [.folder(other.id)]) == .before && zone(16, [.folder(other.id)]) == .into && zone(29, [.folder(other.id)]) == .after
              && zone(8, [.folder(other.id)]) == .into,
              "a folder dragged over another lands before it on the top fifth, inside in the middle and after on the bottom fifth")
        let a = page(m, "https://a.example/")
        m.move(a, to: target.id)
        check(zone(29, [.folder(other.id)]) == .after, "under an open folder with one thing in it, the bottom edge still lands after it")
        let a2 = page(m, "https://a2.example/")
        m.move(a2, to: target.id)
        check(zone(29, [.folder(other.id)]) == .into, "with two or more, the bottom edge goes inside, where its first row is")
        check(zone(16, [.folder(target.id)]) == nil, "a folder dragged over itself has nowhere to go")
        check(zone(16, [.folder(other.id)], on: m.folder(sub.id)!) == nil && zone(4, [.folder(other.id)], on: m.folder(sub.id)!) == nil,
              "nor over anything inside it")
        check(zone(4, [.tab(a.id)]) == .into && zone(29, [.tab(a.id)]) == .into && zone(16, []) == .into,
              "tabs dropped anywhere on a folder go inside")
        check(zone(16, [.split(UUID())]) == nil, "splits stay out of folders")
    }

    @MainActor static func dragItems() {
        let d = SidebarDrag.shared
        let t = UUID(), f = UUID()
        d.begin([t])
        check(d.draggedTab == t && d.draggingFolder == nil, "a tab drag says which tab it carries as soon as it starts")
        d.begin(items: [.folder(f)])
        check(d.draggedTab == nil && d.draggingFolder == f, "so does a folder drag")
        d.end()
        check(d.items.isEmpty, "and forgets once the drag ends")

        // Undeclared, the drag type resolves to no type and no drop target takes Rain's drags
        // (2026-11-08). The app's Info.plist has to declare it as data. `--drag-probe` checks the
        // drops themselves, from the built app.
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Info.plist")
        let info = NSDictionary(contentsOf: plist) as? [String: Any]
        let declared = (info?["UTExportedTypeDeclarations"] as? [[String: Any]])?.first { $0["UTTypeIdentifier"] as? String == ItemDrag.identifier }
        check((declared?["UTTypeConformsTo"] as? [String])?.contains("public.data") == true,
              "Info.plist declares the drag type as data, so drop targets take Rain's drags", plist.path)

        // What a drag puts on the pasteboard reads back as the same items.
        let s = UUID(), a = UUID(), b = UUID()
        var read: [DragItem]?
        ItemDrag.loadItems([ItemDrag.provider(split: s), ItemDrag.provider(ids: [a, b]), ItemDrag.provider(folder: f)]) { read = $0 }
        _ = SmokeTest.wait(2) { read != nil }
        let got = Set((read ?? []).map { "\($0)" }), want = Set([DragItem.split(s), .tab(a), .tab(b), .folder(f)].map { "\($0)" })
        check(got == want, "a drag's bytes read back as the split, tabs and folder it carries", "\(read?.count ?? 0) items")
    }

    // MARK: A tab dragged over the page

    @MainActor static func pageDrop() {
        let r = CGRect(x: 0, y: 0, width: 1000, height: 600)
        check(DropMath.side(at: CGPoint(x: 480, y: 300), in: r) == .left && DropMath.side(at: CGPoint(x: 520, y: 300), in: r) == .right,
              "over the page, left of the middle drops on the left and right of it on the right")
        check(DropMath.side(at: CGPoint(x: 500, y: 40), in: r) == .top && DropMath.side(at: CGPoint(x: 500, y: 580), in: r) == .bottom,
              "near the top or bottom edge it stacks")
        check(DropMath.side(at: CGPoint(x: 30, y: 40), in: r) == .left, "in a corner the nearer edge wins")
        let h = DropMath.halves(.left, in: r, gap: 8)
        check(h.incoming == CGRect(x: 0, y: 0, width: 496, height: 600) && h.staying == CGRect(x: 504, y: 0, width: 496, height: 600),
              "the preview splits the page with the split's gap, where the panes will be")

        let m = ArcZenTests.freshModel()
        let a = page(m, "https://a.example/", select: true)
        let b = page(m, "https://b.example/")
        let one = ContentDropDelegate.compute(CGPoint(x: 100, y: 300), frames: [:], bounds: r, model: m, dragged: [.tab(b.id)])
        check(one?.single == true && one?.side == .left && one?.pane == a.id && one?.tab == b.id, "a tab over a single page makes room on that side")
        check(ContentDropDelegate.compute(CGPoint(x: 100, y: 300), frames: [:], bounds: r, model: m, dragged: [.tab(a.id)]) == nil,
              "the page's own tab dragged over it does nothing")
        check(ContentDropDelegate.compute(CGPoint(x: 100, y: 300), frames: [:], bounds: r, model: m, dragged: [.folder(UUID())]) == nil
              && ContentDropDelegate.compute(CGPoint(x: 100, y: 300), frames: [:], bounds: r, model: m, dragged: [.split(UUID())]) == nil,
              "folders and splits don't drop on the page")

        m.drop(tabID: b.id, side: one!.side, onPane: one!.pane)
        check(m.currentSplit?.items == [b.id, a.id], "dropping it there makes the split on that side")
        let c = page(m, "https://c.example/")
        let frames: [UUID: CGRect] = [b.id: CGRect(x: 0, y: 0, width: 496, height: 600), a.id: CGRect(x: 504, y: 0, width: 496, height: 600)]
        let over = ContentDropDelegate.compute(CGPoint(x: 900, y: 300), frames: frames, bounds: r, model: m, dragged: [.tab(c.id)])
        check(over?.single == false && over?.pane == a.id && over?.side == .right && over?.incoming.minX == 504 + 248 + 4,
              "over a split, the card takes half of the pane under the pointer")
        check(ContentDropDelegate.compute(CGPoint(x: 900, y: 300), frames: frames, bounds: r, model: m, dragged: [.tab(a.id)]) == nil,
              "a pane dragged over itself does nothing")
        check(ContentDropDelegate.compute(CGPoint(x: 500, y: 300), frames: frames, bounds: r, model: m, dragged: [.tab(c.id)]) == nil,
              "the gap between panes isn't a target")
    }

    // MARK: The divider

    @MainActor static func divider() {
        let avail: CGFloat = 1000
        let even = SplitBranch.resized([0.5, 0.5], at: 0, by: 0.2, avail: avail)
        check(abs(even[0] - 0.7) < 1e-9 && abs(even[1] - 0.3) < 1e-9, "dragging the divider moves room from one pane to the other")
        let near = SplitBranch.resized([0.7, 0.3], at: 0, by: -0.19, avail: avail)
        check(abs(near[0] - near[1]) < 1e-9, "within 12 points of an even split it settles there", "\(near)")
        let past = SplitBranch.resized([0.7, 0.3], at: 0, by: -0.18 + 0.03, avail: avail)
        check(abs(past[0] - 0.55) < 1e-9, "farther off it follows the pointer")
        let squeezed = SplitBranch.resized([0.5, 0.5], at: 0, by: 0.6, avail: avail)
        check(abs(squeezed[1] - Double(SplitBranch.minPane / avail)) < 1e-9, "neither pane goes under the narrowest width")
    }
}
