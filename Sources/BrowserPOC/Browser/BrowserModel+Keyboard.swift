import Foundation

/// A place the sidebar's keyboard cursor can stop: a tab or split row, or a folder row.
enum SidebarStop: Hashable {
    case row(SidebarRef)
    case folder(UUID)
}

/// Keyboard use of the sidebar, like Arc's Cmd-. : arrows move, Return opens a row or toggles a
/// folder, Left closes a folder (or goes up to it), Right opens it, Esc leaves.
extension BrowserModel {
    /// Every stop top to bottom, as the sidebar shows them.
    var sidebarStops: [SidebarStop] {
        var out: [SidebarStop] = refs(in: .essentials).map { .row($0) } + refs(in: .pinned).map { .row($0) }
        for f in spaceFolders {
            out.append(.folder(f.id))
            let children = f.isExpanded ? refs(in: .folder(f.id)) : shownInClosedFolder(f)
            out += children.map { .row($0) }
        }
        return out + refs(in: .today).map { .row($0) }
    }

    /// Cmd-. : starts on the row on screen, or the first one. Pressing it again leaves.
    func toggleSidebarKeyboard() {
        if sidebarCursor != nil { sidebarCursor = nil; return }
        let stops = sidebarStops
        let here: SidebarStop? = {
            switch selection {
            case .tab(let id): return stops.first { $0 == .row(.tab(id)) }
            case .split(let id): return stops.first { $0 == .row(.split(id)) }
            case nil: return nil
            }
        }()
        sidebarCursor = here ?? stops.first
    }

    func moveSidebarCursor(_ step: Int) {
        let stops = sidebarStops
        guard !stops.isEmpty else { sidebarCursor = nil; return }
        guard let cur = sidebarCursor, let i = stops.firstIndex(of: cur) else { sidebarCursor = stops.first; return }
        sidebarCursor = stops[max(0, min(stops.count - 1, i + step))]
    }

    /// Return: opens the row and hands the keys back to the page, or toggles a folder.
    func activateSidebarCursor() {
        guard let cur = sidebarCursor else { return }
        switch cur {
        case .folder(let id):
            setFolder(id, open: !isFolderOpen(id))
        case .row(let r):
            sidebarCursor = nil
            select(r)
            if let t = currentWebTab { focusWeb(t) }
        }
    }

    /// Left: closes a folder, or from an item inside one, moves up to the folder.
    func sidebarCursorLeft() {
        guard let cur = sidebarCursor else { return }
        switch cur {
        case .folder(let id): setFolder(id, open: false)
        case .row(let r):
            if case .folder(let f)? = section(of: r) { sidebarCursor = .folder(f) }
        }
    }

    /// Right: opens a folder, or moves into it when it's already open.
    func sidebarCursorRight() {
        guard case .folder(let id)? = sidebarCursor else { return }
        if !isFolderOpen(id) { setFolder(id, open: true); return }
        if let first = refs(in: .folder(id)).first { sidebarCursor = .row(first) }
    }
}
