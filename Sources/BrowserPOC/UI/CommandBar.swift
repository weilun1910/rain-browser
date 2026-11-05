import AppKit
import SwiftUI

struct Suggestion: Identifiable, Equatable {
    enum Kind: Equatable {
        case openURL(URL)
        case tab(UUID)
        case note(URL)
        case pastSearch(String)
        case history(URL)
        case google(String)
        case newNote(String)
    }
    enum Group: String { case top = "", tabs = "Tabs", notes = "Notes", searches = "Searches", history = "History", actions = " " }

    let id = UUID()
    let kind: Kind
    let group: Group
    let title: String
    let subtitle: String
    let icon: String

    static func == (a: Suggestion, b: Suggestion) -> Bool { a.kind == b.kind && a.title == b.title }
}

/// Builds the bar's rows from what's open and the local index. No network.
enum Suggest {
    struct TabInfo { let id: UUID; let title: String; let url: URL?; let isNote: Bool }

    static func looksLikeURL(_ q: String) -> URL? {
        let s = q.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        guard let u = AddressParser.url(for: s), u.host != "www.google.com" || s.lowercased().contains("google.com") else { return nil }
        return u
    }

    static func matches(_ text: String, words: [String]) -> Bool {
        let f = TextAnalysis.fold(Substring(text))
        return words.allSatisfy { f.contains($0) }
    }

    static func build(_ raw: String, tabs: [TabInfo], store: IndexStore) -> [Suggestion] {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let words = TextAnalysis.rawWords(q).map { TextAnalysis.fold($0) }.filter { !$0.isEmpty }
        var out: [Suggestion] = []
        if let u = looksLikeURL(q) {
            out.append(Suggestion(kind: .openURL(u), group: .top, title: "Open \(u.absoluteString)", subtitle: "", icon: "arrow.up.right.square"))
        }
        // 1. Open tabs and notes in this space.
        var tabKeys = Set<String>()
        for t in tabs where !words.isEmpty && (matches(t.title, words: words) || (t.url.map { matches($0.absoluteString, words: words) } ?? false)) {
            if out.filter({ $0.group == .tabs }).count >= 3 { break }
            if let u = t.url { tabKeys.insert(u.isFileURL ? u.standardizedFileURL.path : URLKey.key(for: u)) }
            out.append(Suggestion(kind: .tab(t.id), group: .tabs, title: t.title,
                                  subtitle: t.isNote ? "Switch to note" : (t.url.map { Snippet.prettyURL($0.absoluteString) } ?? ""),
                                  icon: t.isNote ? "note.text" : "square.on.square"))
        }
        // 2. Notes, from every space.
        for n in store.searchNotes(q, limit: 4) {
            guard let u = URL(string: n.url), !tabKeys.contains(u.standardizedFileURL.path) else { continue }
            out.append(Suggestion(kind: .note(u), group: .notes, title: u.deletingPathExtension().lastPathComponent,
                                  subtitle: n.line, icon: "note.text"))
        }
        // 3. Past searches.
        for p in store.searchPastSearches(q, limit: 3) {
            out.append(Suggestion(kind: .pastSearch(p.query), group: .searches, title: p.query,
                                  subtitle: "Searched " + Fmt.onDay(Date(timeIntervalSince1970: p.at)), icon: "clock"))
        }
        // 4. Visited pages and Chrome history.
        for h in store.searchHistory(q, limit: 4) {
            guard let u = URL(string: h.url), !tabKeys.contains(URLKey.key(for: u)) else { continue }
            out.append(Suggestion(kind: .history(u), group: .history, title: h.title.isEmpty ? Snippet.prettyURL(h.url) : h.title,
                                  subtitle: Snippet.prettyURL(h.url), icon: h.source == .chrome ? "clock.arrow.circlepath" : "globe"))
        }
        // 5. Search and new note.
        out.append(Suggestion(kind: .google(q), group: .actions, title: "Search Google for \(q)", subtitle: "", icon: "magnifyingglass"))
        out.append(Suggestion(kind: .newNote(q), group: .actions, title: "New note: \(q)", subtitle: "", icon: "square.and.pencil"))
        return out
    }
}

/// The floating bar for Cmd-T, Cmd-L and Ctrl-Shift-=.
@MainActor
final class CommandBar: ObservableObject {
    enum Mode: Equatable {
        case newTab
        /// The pick opens as the second pane of a split with what's on screen.
        case split
        /// Cmd-L: the pick loads in this tab, in place.
        case navigate(UUID)
    }

    @Published private(set) var isOpen = false
    @Published private(set) var mode: Mode = .newTab
    @Published var query = "" { didSet { if query != oldValue { refresh() } } }
    @Published private(set) var results: [Suggestion] = []
    @Published var selected = 0
    /// Bumped to ask the field to select all of its text.
    @Published private(set) var selectAllToken = 0
    weak var model: BrowserModel?

    func open(_ mode: Mode, text: String = "") {
        self.mode = mode
        isOpen = true
        query = text
        refresh()
        selectAllToken += 1
    }

    func close() {
        isOpen = false
        query = ""
        results = []
        selected = 0
    }

    func refresh() {
        guard let model else { return }
        let infos = model.spaceTabs.map { Suggest.TabInfo(id: $0.id, title: $0.displayTitle, url: $0.url, isNote: $0.kind == .note) }
        results = Suggest.build(query, tabs: infos, store: IndexStore.shared)
        // When the text is just the current page's address, Enter should reload it rather than search.
        selected = 0
    }

    func move(_ step: Int) {
        guard !results.isEmpty else { return }
        selected = (selected + step + results.count) % results.count
    }

    func submit() {
        guard isOpen else { return }
        if results.indices.contains(selected) { pick(results[selected]) } else if !query.isEmpty, let u = AddressParser.url(for: query) {
            pick(Suggestion(kind: .openURL(u), group: .top, title: "", subtitle: "", icon: ""))
        } else {
            close()
        }
    }

    func pick(_ s: Suggestion) {
        let m = mode
        close()
        model?.commandPick(s.kind, mode: m)
    }
}

struct CommandBarView: View {
    @ObservedObject var bar: CommandBar
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .top) {
                Theme.Palette.scrim
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { bar.close() }
                VStack(spacing: 0) {
                    HStack(spacing: Theme.Space.l) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                        CommandField(text: $bar.query, selectAllToken: bar.selectAllToken,
                                     onUp: { bar.move(-1) }, onDown: { bar.move(1) },
                                     onEnter: { bar.submit() }, onEscape: { bar.close() })
                            .frame(height: 28)
                    }
                    .padding(.horizontal, Theme.Space.xxl - 2)
                    .frame(height: 58)
                    if !bar.results.isEmpty {
                        Rectangle().fill(Theme.Palette.hairline).frame(height: 1)
                        ScrollView {
                            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                                ForEach(Array(bar.results.enumerated()), id: \.element.id) { i, s in
                                    if i == 0 || bar.results[i - 1].group != s.group, !s.group.rawValue.trimmingCharacters(in: .whitespaces).isEmpty {
                                        Text(s.group.rawValue)
                                            .font(Theme.Font.label)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, Theme.Space.xxl - 2)
                                            .padding(.top, i == 0 ? Theme.Space.s : Theme.Space.l)
                                            .padding(.bottom, Theme.Space.xxs)
                                    }
                                    SuggestionRow(s: s, selected: i == bar.selected)
                                        .onTapGesture { bar.pick(s) }
                                        .onHover { if $0 { bar.selected = i } }
                                }
                            }
                            .padding(.vertical, Theme.Space.m)
                        }
                        .frame(maxHeight: 440)
                        .fixedSize(horizontal: false, vertical: true)
                        // Results swap instantly as you type.
                        .transaction { $0.animation = nil }
                    }
                }
                .frame(width: min(680, max(520, g.size.width * 0.6)))
                .floatingSheet()
                .appearEffect(scale: 0.98, y: -6, animation: Motion.barIn)
                .padding(.top, max(72, g.size.height * 0.15))
            }
        }
    }
}

struct SuggestionRow: View {
    let s: Suggestion
    let selected: Bool
    @Environment(\.spaceAccent) private var accent

    /// The site behind a row, for its icon. Searches, notes and actions keep their symbols.
    var siteURL: URL? {
        switch s.kind {
        case .openURL(let u), .history(let u): return u.scheme?.hasPrefix("http") == true ? u : nil
        default: return nil
        }
    }

    var body: some View {
        HStack(spacing: Theme.Space.l) {
            Group {
                if let u = siteURL {
                    FaviconView(image: FaviconLookup.image(for: u), size: 16, fallback: .site(u))
                } else {
                    Image(systemName: s.icon)
                        .font(.system(size: 13))
                        .foregroundStyle(selected ? .primary : .secondary)
                }
            }
            .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.title).font(Theme.Font.row).lineLimit(1)
                    .foregroundStyle(.primary)
                if !s.subtitle.isEmpty {
                    Text(s.subtitle).font(Theme.Font.caption).lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "return")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .opacity(selected ? 1 : 0)
        }
        .padding(.horizontal, Theme.Space.m + 2)
        .frame(minHeight: 36)
        .padding(.vertical, 2)
        // The selected row is tinted with the space's colour, quietly, with the text left as it is.
        .background(Theme.Radius.shape(Theme.Radius.row).fill(selected ? accent.opacity(0.16) : .clear))
        .padding(.horizontal, Theme.Space.m)
        .contentShape(Rectangle())
    }
}

/// An NSTextField so arrow keys, Enter and Esc work while typing.
struct CommandField: NSViewRepresentable {
    @Binding var text: String
    let selectAllToken: Int
    let onUp: () -> Void
    let onDown: () -> Void
    let onEnter: () -> Void
    let onEscape: () -> Void

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommandField
        var lastToken = -1
        init(_ p: CommandField) { parent = p }

        func controlTextDidChange(_ n: Notification) {
            if let f = n.object as? NSTextField { parent.text = f.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.moveUp(_:)): parent.onUp(); return true
            case #selector(NSResponder.moveDown(_:)): parent.onDown(); return true
            case #selector(NSResponder.insertNewline(_:)): parent.onEnter(); return true
            case #selector(NSResponder.cancelOperation(_:)): parent.onEscape(); return true
            default: return false
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = Theme.Font.fieldNS
        f.placeholderString = "Search or enter address"
        f.delegate = context.coordinator
        f.stringValue = text
        DispatchQueue.main.async {
            f.window?.makeFirstResponder(f)
            f.currentEditor()?.selectAll(nil)
        }
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text { f.stringValue = text }
        if context.coordinator.lastToken != selectAllToken {
            context.coordinator.lastToken = selectAllToken
            DispatchQueue.main.async {
                f.window?.makeFirstResponder(f)
                f.currentEditor()?.selectAll(nil)
            }
        }
    }
}
