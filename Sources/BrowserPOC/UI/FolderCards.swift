import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The folder popup's grid: folders first, then pages with a picture of the top of the page,
// notes drawn from their first lines, and other files with their icon. Pictures load as cards
// scroll into view, shrunk to card size, and nothing renders a page.

enum FolderGridMetrics {
    static let minCard: CGFloat = 168
    static let gap: CGFloat = 16
    static let rowGap: CGFloat = 20
    static let inset: CGFloat = 20
    /// How many cards fit across `width`.
    static func columns(_ width: CGFloat) -> Int { max(1, Int((width - 2 * inset + gap) / (minCard + gap))) }
}

struct FolderGrid: View {
    @ObservedObject var popup = FolderPopup.shared
    @EnvironmentObject var model: BrowserModel
    @State private var targeted = false
    @Environment(\.spaceAccent) private var accent

    var body: some View {
        GeometryReader { g in
            let cols = FolderGridMetrics.columns(g.size.width)
            ZStack {
                content(cols: cols)
                    .id((popup.current?.path ?? "") + (popup.results == nil ? "" : "?search"))
                    .transition(slide)
            }
            .frame(width: g.size.width, height: g.size.height)
            .clipped()
            .overlay {
                if targeted {
                    Theme.Radius.shape(Theme.Radius.card).strokeBorder(accent.opacity(0.7), lineWidth: 1.5)
                        .padding(6).allowsHitTesting(false)
                }
            }
            .onAppear { popup.columns = cols }
            .onChange(of: cols) { _, c in popup.columns = c }
            // Dropped on the grid itself: into the folder you're looking at.
            .onDrop(of: [ItemDrag.type], isTargeted: $targeted) { providers in
                guard let dir = popup.current, popup.results == nil else { return false }
                return ItemDrag.loadItems(providers) { items in FolderDropActions.drop(items, into: dir, model: model) }
            }
        }
    }

    /// Going into a folder slides the grid sideways, and going back slides it the other way.
    private var slide: AnyTransition {
        if Motion.suppressed || popup.direction == 0 { return .opacity }
        if Motion.reduceMotion { return .opacity }
        let d: CGFloat = popup.direction > 0 ? 48 : -48
        return .asymmetric(insertion: .offset(x: d).combined(with: .opacity), removal: .offset(x: -d).combined(with: .opacity))
    }

    @ViewBuilder func content(cols: Int) -> some View {
        let list = popup.shown
        if list.isEmpty {
            FolderEmptyView(searching: popup.results != nil, query: popup.query)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { popup.selection = nil }
        } else {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: FolderGridMetrics.gap, alignment: .top), count: cols),
                          alignment: .leading, spacing: FolderGridMetrics.rowGap) {
                    ForEach(list) { e in
                        FolderCard(entry: e, selected: popup.selection == e.id, showsPlace: popup.results != nil,
                                   dimmed: popup.isPicking && e.kind != .folder)
                    }
                }
                .padding(FolderGridMetrics.inset)
                .background(Color.clear.contentShape(Rectangle()).onTapGesture { popup.selection = nil })
            }
            .scrollIndicators(.automatic)
        }
    }
}

struct FolderEmptyView: View {
    let searching: Bool
    let query: String

    var body: some View {
        VStack(spacing: 10) {
            if searching {
                Image(systemName: "magnifyingglass").font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
                Text("Nothing here matches \u{201C}\(query)\u{201D}").font(Theme.Font.heading)
                Text("Search looks in this folder and every folder inside it.").font(Theme.Font.secondary).foregroundStyle(.secondary)
            } else {
                FolderGlyph(isOpen: true, size: 40, ground: Theme.Palette.card, stroke: Color.secondary.opacity(0.7))
                Text("This folder is empty").font(Theme.Font.heading)
                Text("Drag a tab here to save it, or make a new folder.").font(Theme.Font.secondary).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(40)
    }
}

// MARK: - A card

struct FolderCard: View {
    let entry: FolderEntry
    var selected = false
    /// In search results, where it is.
    var showsPlace = false
    /// While picking a folder, everything but folders steps back.
    var dimmed = false
    @ObservedObject var popup = FolderPopup.shared
    @EnvironmentObject var model: BrowserModel
    @State private var hovering = false
    @State private var targeted = false
    @Environment(\.spaceAccent) private var accent

    static let aspect: CGFloat = 16.0 / 10.0

    var body: some View {
        let shape = Theme.Radius.shape(Theme.Radius.card)
        VStack(alignment: .leading, spacing: 8) {
            FolderCardPreview(entry: entry)
                .aspectRatio(Self.aspect, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Theme.Palette.hairline, lineWidth: 0.5).allowsHitTesting(false))
                .overlay {
                    if selected || targeted {
                        shape.strokeBorder(accent.opacity(targeted ? 0.9 : 0.75), lineWidth: targeted ? 2 : 1.5).allowsHitTesting(false)
                    }
                }
                // Cards lift a little on hover.
                .themeShadow(hovering && !dimmed ? .floating : .row)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(Theme.Font.rowEmphasis)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .opacity(dimmed ? 0.4 : 1)
        .scaleEffect(hovering && !dimmed && !Motion.reduceMotion ? 1.012 : 1, anchor: .bottom)
        .offset(y: hovering && !dimmed && !Motion.reduceMotion ? -2 : 0)
        .motion(Motion.hover, value: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { click() }
        .contextMenu { FolderEntryMenu(entry: entry) }
        .onDrag {
            SidebarDrag.shared.begin(items: [.entry(entry.url)])
            return ItemDrag.provider(entries: [entry.url])
        }
        .modifier(FolderCardDrop(entry: entry, targeted: $targeted))
        .help(entry.kind == .page ? "\(entry.name)\n\(entry.page.map { Snippet.prettyURL($0.absoluteString) } ?? "")" : entry.name)
    }

    var subtitle: String {
        let place = showsPlace ? model.displayPath(entry.url.deletingLastPathComponent()).components(separatedBy: " / ").last : nil
        let base: String
        switch entry.kind {
        case .folder:
            if entry.isBroken { base = "Can't find the original" } else {
                let n = SpaceFolders.count(entry.target)
                let count = n == 1 ? "1 item" : "\(n) items"
                base = entry.isLink ? "Linked, \(count)" : count
            }
        case .page: base = entry.site ?? "Page"
        case .note: base = entry.isLink ? "Linked note" : "Note"
        case .file:
            base = entry.isBroken ? "Can't find the original" : (UTType(filenameExtension: entry.target.pathExtension)?.localizedDescription ?? "File")
        }
        return place.map { "\(base), in \($0)" } ?? base
    }

    func click() {
        popup.selection = entry.id
        guard !dimmed else { return }
        let mods = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        popup.activate(entry, background: mods.contains(.command))
    }
}

/// Folders take drops: tabs are saved or filed there, and cards move there.
struct FolderCardDrop: ViewModifier {
    let entry: FolderEntry
    @Binding var targeted: Bool
    @EnvironmentObject var model: BrowserModel

    func body(content: Content) -> some View {
        if entry.kind == .folder && !entry.isBroken {
            content.onDrop(of: [ItemDrag.type], isTargeted: $targeted) { providers in
                ItemDrag.loadItems(providers) { items in
                    let filtered = items.filter { if case .entry(let u) = $0 { return u.path != entry.url.path }; return true }
                    FolderDropActions.drop(filtered, into: entry.target, model: model)
                }
            }
        } else {
            content
        }
    }
}

struct FolderEntryMenu: View {
    let entry: FolderEntry
    @ObservedObject var popup = FolderPopup.shared
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        if entry.kind == .folder {
            Button("Open") { popup.enter(entry) }
        } else {
            Button("Open") { popup.activate(entry) }
            Button("Open in Split") { popup.openInSplit(entry) }
                .disabled(model.currentTab == nil)
            Button("Open in Background") { popup.activate(entry, background: true) }
        }
        Divider()
        Button("Rename...") { model.promptRenameEntry(entry) }
        Button("Move to...") { popup.startMove([entry.url]) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
        if let u = entry.page {
            Button("Copy Link") {
                BrowserModel.copyText(CleanURL.strip(u).absoluteString)
                model.toast("Copied link")
            }
        }
        Divider()
        Button("Move to Trash") { model.trashEntries([entry]) }
    }
}

// MARK: - Previews

struct FolderCardPreview: View {
    let entry: FolderEntry

    var body: some View {
        switch entry.kind {
        case .page: PagePreview(entry: entry)
        case .note: NotePreview(entry: entry)
        case .folder: FolderTile(entry: entry)
        case .file: FileTile(entry: entry)
        }
    }
}

/// A page: the picture of its top, or its icon and site until there is one.
struct PagePreview: View {
    let entry: FolderEntry
    @State private var image: CGImage?
    @State private var tried = false

    var body: some View {
        ZStack {
            Theme.Palette.sheet
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .clipped()
                    .transition(.opacity)
            } else {
                VStack(spacing: 8) {
                    FaviconView(url: entry.page, fallback: "globe", size: 22)
                    Text(entry.site ?? "").font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(12)
            }
        }
        .motion(Motion.favicon, value: image != nil, fadeOnly: true)
        .task(id: entry.id) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .thumbnailSaved)) { n in
            guard let page = entry.page, n.object as? String == URLKey.key(for: page) else { return }
            Task { await load() }
        }
    }

    func load() async {
        guard let page = entry.page else { return }
        if let img = await ThumbnailCache.shared.image(for: page, pixels: 480) {
            image = img
        } else if !tried {
            tried = true
            // Never shown here: its share image, fetched later in the background.
            Thumbnails.shared.wantShareImage(for: page)
        }
    }
}

/// A note: its title and first few lines, drawn from the file. Reading never writes.
struct NotePreview: View {
    let entry: FolderEntry
    @State private var preview: NotePreviewCache.Preview?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.Palette.sheet
            VStack(alignment: .leading, spacing: 6) {
                Text(preview?.title ?? entry.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                Text(preview?.body ?? "")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .lineLimit(6)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            if entry.isLink { LinkBadge().padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing) }
        }
        .task(id: entry.id) { preview = await NotePreviewCache.shared.preview(entry.target) }
    }
}

struct FolderTile: View {
    let entry: FolderEntry

    var body: some View {
        ZStack {
            Theme.Palette.sheet
            ZStack(alignment: .bottomTrailing) {
                FolderGlyph(isOpen: false, size: 46, ground: Theme.Palette.sheet, stroke: Color.secondary.opacity(entry.isBroken ? 0.35 : 0.75))
                if entry.isLink { LinkBadge().offset(x: 8, y: 6) }
            }
        }
    }
}

struct FileTile: View {
    let entry: FolderEntry

    var body: some View {
        ZStack {
            Theme.Palette.sheet
            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.target.path))
                .resizable()
                .frame(width: 48, height: 48)
                .opacity(entry.isBroken ? 0.4 : 1)
            if entry.isLink { LinkBadge().padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing) }
        }
    }
}

/// The small arrow on something linked from elsewhere.
struct LinkBadge: View {
    var body: some View {
        Image(systemName: "arrow.up.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 15, height: 15)
            .background(Circle().fill(Theme.Palette.card))
            .overlay(Circle().strokeBorder(Theme.Palette.hairline, lineWidth: 0.5))
    }
}

/// A note's title and first lines, read once per change to the file.
final class NotePreviewCache: @unchecked Sendable {
    static let shared = NotePreviewCache()
    struct Preview: Sendable { let title: String; let body: String }
    private let lock = NSLock()
    private var cache: [String: (mtime: Double, preview: Preview)] = [:]

    func preview(_ url: URL) async -> Preview? {
        let path = url.path
        return await Task.detached(priority: .userInitiated) { () -> Preview? in
            let mtime = NotesScan.mtime(url) ?? 0
            if let hit = self.lookup(path, mtime) { return hit }
            guard let h = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? h.close() }
            let data = (try? h.read(upToCount: 4096)) ?? Data()
            let p = Self.make(String(decoding: data, as: UTF8.self), fallback: url.deletingPathExtension().lastPathComponent)
            self.store(path, mtime, p)
            return p
        }.value
    }

    private func lookup(_ path: String, _ mtime: Double) -> Preview? {
        lock.lock(); defer { lock.unlock() }
        guard let hit = cache[path], hit.mtime == mtime else { return nil }
        return hit.preview
    }

    private func store(_ path: String, _ mtime: Double, _ p: Preview) {
        lock.lock(); defer { lock.unlock() }
        cache[path] = (mtime, p)
    }

    /// The first heading as the title, then the next few lines of text without Markdown marks.
    static func make(_ text: String, fallback: String) -> Preview {
        var title: String?
        var lines: [String] = []
        var inFront = false
        for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if i == 0 && line == "---" { inFront = true; continue }
            if inFront { if line == "---" { inFront = false }; continue }
            if line.isEmpty { continue }
            if title == nil, line.hasPrefix("#") {
                title = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                continue
            }
            var l = line
            for p in ["- [ ] ", "- [x] ", "- ", "* ", "> ", "### ", "## ", "# "] where l.hasPrefix(p) { l = String(l.dropFirst(p.count)); break }
            l = l.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            if !l.isEmpty { lines.append(l) }
            if lines.count >= 6 { break }
        }
        return Preview(title: Fmt.clean(title ?? fallback), body: Fmt.clean(lines.joined(separator: "\n")))
    }
}
