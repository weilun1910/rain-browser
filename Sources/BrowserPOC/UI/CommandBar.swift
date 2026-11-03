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
        ZStack(alignment: .top) {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { bar.close() }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    CommandField(text: $bar.query, selectAllToken: bar.selectAllToken,
                                 onUp: { bar.move(-1) }, onDown: { bar.move(1) },
                                 onEnter: { bar.submit() }, onEscape: { bar.close() })
                        .frame(height: 26)
                }
                .padding(.horizontal, 16)
                .frame(height: 52)
                if !bar.results.isEmpty {
                    Divider().opacity(0.6)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(bar.results.enumerated()), id: \.element.id) { i, s in
                                if i == 0 || bar.results[i - 1].group != s.group, !s.group.rawValue.trimmingCharacters(in: .whitespaces).isEmpty {
                                    Text(s.group.rawValue)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                        .padding(.horizontal, 16)
                                        .padding(.top, i == 0 ? 6 : 10)
                                        .padding(.bottom, 2)
                                }
                                SuggestionRow(s: s, selected: i == bar.selected)
                                    .onTapGesture { bar.pick(s) }
                                    .onHover { if $0 { bar.selected = i } }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .frame(maxHeight: 420)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 640)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.25), radius: 30, y: 10)
            .padding(.top, 110)
        }
        .transaction { $0.animation = nil }
    }
}

struct SuggestionRow: View {
    let s: Suggestion
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: s.icon)
                .font(.system(size: 12))
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.title).font(.system(size: 13)).lineLimit(1)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                if !s.subtitle.isEmpty {
                    Text(s.subtitle).font(.system(size: 11)).lineLimit(1)
                        .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor : .clear))
        .padding(.horizontal, 6)
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
        f.font = .systemFont(ofSize: 18)
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
