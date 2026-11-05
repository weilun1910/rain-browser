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
        /// A command, by its BarAction id.
        case action(String)
        case folder(UUID)
        case space(UUID)
        case closed(UUID)
    }
    enum Group: String {
        case top = "", tabs = "Tabs", commands = "Actions", folders = "Folders", notes = "Notes",
             searches = "Searches", history = "History", actions = " "
    }

    let id = UUID()
    let kind: Kind
    let group: Group
    let title: String
    let subtitle: String
    let icon: String
    /// A keyboard shortcut shown on the right, for actions.
    var shortcut: String? = nil
    /// The page this row stands for, for its favicon.
    var url: URL? = nil

    static func == (a: Suggestion, b: Suggestion) -> Bool { a.kind == b.kind && a.title == b.title }
}

/// Builds the bar's rows from what's open, the local index and the commands. No network.
enum Suggest {
    struct TabInfo {
        let id: UUID
        let title: String
        let url: URL?
        let isNote: Bool
        /// Set for items in another space.
        var spaceName: String? = nil
        var inSplit = false
        var isPinned = false
        var isEssential = false
        var isApp = false
        var isCurrent = false
    }
    struct FolderInfo { let id: UUID; let name: String; let path: String }
    struct ActionInfo { let id: String; let title: String; let icon: String; let shortcut: String?; let score: Int; let learned: Int }

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

    /// Zen's tab score: how much of the label the typed words cover, so short exact titles win.
    static func coverage(_ text: String, words: [String]) -> Double {
        let f = TextAnalysis.fold(Substring(text))
        guard !f.isEmpty, words.allSatisfy({ f.contains($0) }) else { return 0 }
        return Double(words.reduce(0) { $0 + $1.count }) / Double(f.count)
    }

    static func hostOf(_ u: URL?) -> String? {
        guard let h = u?.host?.lowercased() else { return nil }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    static func build(_ raw: String, tabs: [TabInfo], store: IndexStore, actions: [ActionInfo] = [], folders: [FolderInfo] = [],
                      completion: String? = nil) -> [Suggestion] {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let words = TextAnalysis.rawWords(q).map { TextAnalysis.fold($0) }.filter { !$0.isEmpty }
        var out: [Suggestion] = []
        var tabKeys = Set<String>()
        func key(_ u: URL) -> String { u.isFileURL ? u.standardizedFileURL.path : URLKey.key(for: u) }
        func tabRow(_ t: TabInfo, group: Suggestion.Group) -> Suggestion {
            var sub = t.isNote ? "Switch to note" : "Switch to tab"
            if t.inSplit { sub += ", in split view" }
            if let s = t.spaceName { sub += ", in \(s)" } else if t.isEssential { sub += ", Essentials" } else if t.isPinned { sub += ", pinned" }
            return Suggestion(kind: .tab(t.id), group: group, title: t.title, subtitle: sub,
                              icon: t.isNote ? "note.text" : (t.isApp ? "square.grid.2x2" : "square.on.square"), url: t.isNote ? nil : t.url)
        }

        // 0. The top hit. An autocompleted domain switches to a tab already on it, pinned and
        //    Essentials first, like typing "gmail" in Arc. Otherwise it opens the address.
        if let host = completion {
            func rank(_ t: TabInfo) -> Int {
                let pinned = t.isEssential || t.isPinned ? 0 : 2
                let here = t.spaceName == nil ? 0 : 1
                return pinned + here
            }
            let onIt = tabs.filter { !$0.isCurrent && hostOf($0.url) == host }.sorted { rank($0) < rank($1) }
            if let t = onIt.first {
                out.append(tabRow(t, group: .top))
                if let u = t.url { tabKeys.insert(key(u)) }
            }
            if let u = URL(string: "https://\(host)") {
                out.append(Suggestion(kind: .openURL(u), group: .top, title: host, subtitle: "Open", icon: "arrow.up.right.square", url: u))
            }
        } else if let u = looksLikeURL(q) {
            out.append(Suggestion(kind: .openURL(u), group: .top, title: "Open \(u.absoluteString)", subtitle: "", icon: "arrow.up.right.square", url: u))
        }
        // Actions you use a lot come right after, like Zen's learned commands.
        let learned = actions.filter { $0.learned > 0 }.sorted { $0.learned > $1.learned }.prefix(1)
        for a in learned {
            out.append(Suggestion(kind: .action(a.id), group: .top, title: a.title, subtitle: "", icon: a.icon, shortcut: a.shortcut))
        }

        // 1. Open tabs and notes, this space first, then Essentials and other spaces.
        struct RankedTab { let t: TabInfo; let here: Int; let score: Double }
        var ranked: [RankedTab] = []
        for t in tabs where !t.isCurrent {
            let byTitle = coverage(t.title, words: words)
            let byURL = t.url.map { coverage($0.absoluteString, words: words) * 0.5 } ?? 0
            let s = Swift.max(byTitle, byURL)
            if s > 0 { ranked.append(RankedTab(t: t, here: t.spaceName == nil ? 1 : 0, score: s)) }
        }
        ranked.sort { a, b in a.here != b.here ? a.here > b.here : a.score > b.score }
        for r in ranked where !words.isEmpty {
            let t = r.t
            if out.filter({ $0.group == .tabs }).count >= 4 { break }
            if out.contains(where: { $0.kind == .tab(t.id) }) { continue }
            if let u = t.url { tabKeys.insert(key(u)) }
            out.append(tabRow(t, group: .tabs))
        }

        // 2. Commands that match what's typed, like Zen. Only past two letters and not for addresses.
        if q.count > 2 && looksLikeURL(q) == nil {
            let learnedIDs = Set(learned.map { $0.id })
            var pool = actions.filter { $0.score >= Fuzzy.mixedMinimum && !learnedIDs.contains($0.id) }
            pool.sort { a, b in a.score != b.score ? a.score > b.score : a.learned > b.learned }
            let shown = pool.prefix(3)
            for a in shown {
                out.append(Suggestion(kind: .action(a.id), group: .commands, title: a.title, subtitle: "", icon: a.icon, shortcut: a.shortcut))
            }
        }

        // 3. Folders, with their space.
        let fr = folders.map { ($0, coverage($0.name, words: words)) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(2)
        for (f, _) in fr {
            out.append(Suggestion(kind: .folder(f.id), group: .folders, title: f.name, subtitle: f.path, icon: "folder"))
        }

        // 4. Notes, from every space.
        for n in store.searchNotes(q, limit: 4) {
            guard let u = URL(string: n.url), !tabKeys.contains(u.standardizedFileURL.path) else { continue }
            out.append(Suggestion(kind: .note(u), group: .notes, title: u.deletingPathExtension().lastPathComponent,
                                  subtitle: n.line, icon: "note.text"))
        }
        // 5. Past searches.
        for p in store.searchPastSearches(q, limit: 3) {
            out.append(Suggestion(kind: .pastSearch(p.query), group: .searches, title: p.query,
                                  subtitle: "Searched " + Fmt.onDay(Date(timeIntervalSince1970: p.at)), icon: "clock"))
        }
        // 6. Visited pages and Chrome history.
        for h in store.searchHistory(q, limit: 4) {
            guard let u = URL(string: h.url), !tabKeys.contains(URLKey.key(for: u)) else { continue }
            if out.contains(where: { if case .openURL(let o) = $0.kind { return URLKey.key(for: o) == URLKey.key(for: u) }; return false }) { continue }
            out.append(Suggestion(kind: .history(u), group: .history, title: h.title.isEmpty ? Snippet.prettyURL(h.url) : h.title,
                                  subtitle: Snippet.prettyURL(h.url), icon: h.source == .chrome ? "clock.arrow.circlepath" : "globe", url: u))
        }
        // 7. Search and new note.
        out.append(Suggestion(kind: .google(q), group: .actions, title: "Search Google for \(q)", subtitle: "", icon: "magnifyingglass"))
        out.append(Suggestion(kind: .newNote(q), group: .actions, title: "New note: \(q)", subtitle: "", icon: "square.and.pencil"))
        return out
    }

    /// Actions mode: every command that applies, best match first, learned ones on top when
    /// nothing is typed.
    @MainActor
    static func actionRows(_ q: String, actions: [BarAction], learner: CommandLearner) -> [Suggestion] {
        let query = q.trimmingCharacters(in: .whitespaces)
        struct Scored { let a: BarAction; let fuzzy: Int; let learned: Int }
        var scored: [Scored] = actions.map { a in Scored(a: a, fuzzy: query.isEmpty ? 1 : Fuzzy.best(a, query), learned: learner.score(a.id)) }
        if !query.isEmpty { scored = scored.filter { $0.fuzzy > Fuzzy.actionsMinimum } }
        scored.sort { x, y in
            if query.isEmpty {
                if x.learned != y.learned { return x.learned > y.learned }
                return x.a.title < y.a.title
            }
            if x.fuzzy != y.fuzzy { return x.fuzzy > y.fuzzy }
            return x.learned > y.learned
        }
        return scored.map { Suggestion(kind: .action($0.a.id), group: .commands, title: $0.a.title, subtitle: "", icon: $0.a.icon, shortcut: $0.a.shortcut) }
    }
}

/// Inline autocomplete: the most likely domain for what's typed, from open tabs, visits and the index.
@MainActor
enum Autofill {
    /// The full host to fill in, or nil. Only for a plain start of a domain, two letters or more.
    static func complete(_ typed: String, tabs: [Suggest.TabInfo], store: IndexStore?, history: HistoryStore?) -> String? {
        var t = typed.lowercased()
        guard t.count >= 2, !t.contains(" "), !t.contains("/"), !t.contains(":"), t.range(of: "^[a-z0-9.-]+$", options: .regularExpression) != nil else { return nil }
        if t.hasPrefix("www.") { t.removeFirst(4) }
        guard !t.isEmpty else { return nil }
        var score: [String: Double] = [:]
        for tab in tabs {
            guard let h = Suggest.hostOf(tab.url), h.hasPrefix(t) else { continue }
            score[h, default: 0] += tab.isEssential || tab.isPinned ? 1000 : 200
        }
        for (h, n) in history?.hosts(prefix: t) ?? [] { score[h, default: 0] += Double(n) * 10 }
        for hit in store?.searchHistory(t, limit: 8) ?? [] {
            guard let h = Suggest.hostOf(URL(string: hit.url)), h.hasPrefix(t) else { continue }
            score[h, default: 0] += Double(max(1, hit.visits))
        }
        guard let best = score.max(by: { ($0.value, -$0.key.count) < ($1.value, -$1.key.count) })?.key, best.count > t.count else { return nil }
        return best
    }
}

/// The floating bar for Cmd-T, Cmd-L and Ctrl-Shift-=.
@MainActor
final class CommandBar: ObservableObject {
    enum Mode: Equatable {
        case newTab
        /// The pick opens as a new pane of a split with what's on screen.
        case split
        /// Cmd-L: the pick loads in this tab, in place.
        case navigate(UUID)
    }

    @Published private(set) var isOpen = false
    @Published private(set) var mode: Mode = .newTab
    /// What's typed. The autocompleted part isn't in here.
    @Published var query = "" { didSet { if query != oldValue { refresh() } } }
    @Published private(set) var results: [Suggestion] = []
    @Published var selected = 0
    /// Bumped to ask the field to select all of its text.
    @Published private(set) var selectAllToken = 0
    /// Actions mode: only commands. Tab on an empty bar or "/ " turns it on.
    @Published private(set) var actionsOnly = false
    /// The domain being filled in after what's typed.
    @Published private(set) var completion: String?
    /// The filled-in part after what's typed, as shown and selected in the field.
    var completionSuffix: String {
        guard let c = completion else { return "" }
        let typed = query.hasPrefix("www.") ? String(query.dropFirst(4)) : query
        guard c.lowercased().hasPrefix(typed.lowercased()), c.count > typed.count else { return "" }
        return String(c.dropFirst(typed.count))
    }
    weak var model: BrowserModel?
    let learner = CommandLearner()
    /// Action rows currently shown, for the learner.
    private(set) var shownActionIDs: Set<String> = []
    /// Set by the field: the last edit added text, so autocomplete may fill in.
    var lastEditWasInsertion = false
    /// Text typed before a close, offered again for a while, like Zen.
    private(set) var lastQuery = ""
    private(set) var lastClosedAt: Date?
    static let keepQueryFor: TimeInterval = 45

    func open(_ mode: Mode, text: String = "") {
        self.mode = mode
        actionsOnly = false
        completion = nil
        lastEditWasInsertion = false
        isOpen = true
        var t = text
        if t.isEmpty, mode == .newTab, let at = lastClosedAt, Date().timeIntervalSince(at) < Self.keepQueryFor { t = lastQuery }
        query = t
        refresh()
        selectAllToken += 1
    }

    /// Closes without picking. Typed text is kept for a while for the next Cmd-T.
    func close() {
        if isOpen, mode == .newTab, !query.trimmingCharacters(in: .whitespaces).isEmpty, !actionsOnly {
            lastQuery = query
            lastClosedAt = Date()
        }
        reset()
    }

    private func reset() {
        isOpen = false
        actionsOnly = false
        completion = nil
        query = ""
        results = []
        selected = 0
        shownActionIDs = []
    }

    func setActionsOnly(_ on: Bool) {
        guard actionsOnly != on else { return }
        actionsOnly = on
        completion = nil
        refresh()
    }

    func tabInfos() -> [Suggest.TabInfo] {
        guard let model else { return [] }
        let names = Dictionary(uniqueKeysWithValues: model.spaces.map { ($0.id, $0.name) })
        let inSplit = model.splitTabIDs
        let cur = model.currentTab?.id
        let mine = model.tabs.filter { $0.spaceID == model.currentSpaceID || $0.isEssential }
        let others = model.tabs.filter { $0.spaceID != model.currentSpaceID && !$0.isEssential }
        return (mine + others).filter { !$0.isBlank }.map { t in
            Suggest.TabInfo(id: t.id, title: t.displayTitle, url: t.url, isNote: t.isNote,
                            spaceName: t.isEssential || t.spaceID == model.currentSpaceID ? nil : t.spaceID.flatMap { names[$0] },
                            inSplit: inSplit.contains(t.id), isPinned: t.isPinned, isEssential: t.isEssential, isApp: t.isApp,
                            isCurrent: t.id == cur && mode != .split)
        }
    }

    func refresh() {
        guard let model else { return }
        // "/ " at the start means commands, like Arc's slash.
        if !actionsOnly, query.hasPrefix("/ ") {
            actionsOnly = true
            query = String(query.dropFirst(2))
            return
        }
        let available = BarActions.available(model)
        if actionsOnly {
            results = Suggest.actionRows(query, actions: available, learner: learner)
            shownActionIDs = query.count >= 2 ? Set(results.compactMap { if case .action(let id) = $0.kind { return id }; return nil }) : []
            completion = nil
            selected = 0
            return
        }
        let infos = tabInfos()
        if lastEditWasInsertion, case .newTab = mode {
            completion = Autofill.complete(query, tabs: infos, store: IndexStore.shared, history: HistoryStore.shared)
        } else if lastEditWasInsertion, case .split = mode {
            completion = Autofill.complete(query, tabs: infos, store: IndexStore.shared, history: HistoryStore.shared)
        } else {
            completion = nil
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        let actionInfos = q.count > 2 ? available.map { a in
            Suggest.ActionInfo(id: a.id, title: a.title, icon: a.icon, shortcut: a.shortcut, score: Fuzzy.best(a, q), learned: learner.score(a.id))
        }.filter { $0.score >= Fuzzy.mixedMinimum } : []
        let folderInfos: [Suggest.FolderInfo] = model.folders.map { f in
            let space = model.spaces.first { $0.id == f.spaceID }?.name ?? ""
            return Suggest.FolderInfo(id: f.id, name: f.name, path: space.isEmpty ? "Open folder" : "Open folder in \(space)")
        }
        results = Suggest.build(query, tabs: infos, store: IndexStore.shared, actions: actionInfos, folders: folderInfos, completion: completion)
        shownActionIDs = Set(results.compactMap { if case .action(let id) = $0.kind { return id }; return nil })
        selected = 0
    }

    /// Accepts the filled-in domain as typed text.
    func acceptCompletion() {
        guard let c = completion else { return }
        lastEditWasInsertion = false
        completion = nil
        query = c
    }

    /// Backspace over the filled-in part: drop it and keep what's typed.
    func dismissCompletion() {
        guard completion != nil else { return }
        completion = nil
        lastEditWasInsertion = false
        refresh()
    }

    func move(_ step: Int) {
        guard !results.isEmpty else { return }
        selected = (selected + step + results.count) % results.count
    }

    /// Enter. Option opens in split view, Shift in Peek, Cmd in a background tab.
    func submit(flags: NSEvent.ModifierFlags = []) {
        guard isOpen else { return }
        if results.indices.contains(selected) {
            pick(results[selected], flags: flags)
        } else if !query.isEmpty, let u = AddressParser.url(for: query) {
            pick(Suggestion(kind: .openURL(u), group: .top, title: "", subtitle: "", icon: ""), flags: flags)
        } else {
            close()
        }
    }

    static func route(_ flags: NSEvent.ModifierFlags) -> LinkRouting.Route? {
        if flags.contains(.option) { return .split }
        if flags.contains(.shift) { return .peek }
        if flags.contains(.command) { return .backgroundTab }
        return nil
    }

    func pick(_ s: Suggestion, flags: NSEvent.ModifierFlags = []) {
        let m = mode
        reset()
        lastQuery = ""
        lastClosedAt = nil
        model?.commandPick(s.kind, mode: m, route: Self.route(flags))
    }
}

struct CommandBarView: View {
    @ObservedObject var bar: CommandBar
    /// The sidebar's width on each side, left clear so the sidebar still takes clicks.
    var leadingClear: CGFloat = 0
    var trailingClear: CGFloat = 0

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .top) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: leadingClear).allowsHitTesting(false)
                    Color.black.opacity(0.12)
                        .contentShape(Rectangle())
                        .onTapGesture { bar.close() }
                    Color.clear.frame(width: trailingClear).allowsHitTesting(false)
                }
                .ignoresSafeArea()
                CommandPanel(bar: bar)
                    .frame(width: min(g.size.width / 1.5, 680).clamped(lower: 460))
                    // Zen puts the top a little above the middle so results grow downward.
                    .padding(.top, max(60, g.size.height / 2 - 220))
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
    }
}

extension CGFloat {
    func clamped(lower: CGFloat) -> CGFloat { Swift.max(self, lower) }
}

/// The floating panel: the field, the rows and a hint line.
struct CommandPanel: View {
    @ObservedObject var bar: CommandBar

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if bar.actionsOnly {
                    Text("Actions")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.2)))
                } else {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                }
                CommandField(bar: bar)
                    .frame(height: 26)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            if !bar.results.isEmpty {
                Divider().opacity(0.6)
                ScrollViewReader { proxy in
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
                                    .id(s.id)
                                    .onTapGesture { bar.pick(s, flags: NSEvent.modifierFlags) }
                                    .onHover { if $0 { bar.selected = i } }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .frame(maxHeight: 400)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: bar.selected) { _, i in
                        if bar.results.indices.contains(i) { proxy.scrollTo(bar.results[i].id) }
                    }
                }
                Divider().opacity(0.4)
                CommandHint(actionsOnly: bar.actionsOnly)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.28), radius: 40, y: 18)
    }
}

/// The keys, in one quiet line under the results.
struct CommandHint: View {
    let actionsOnly: Bool
    var body: some View {
        HStack(spacing: 14) {
            if actionsOnly {
                hint("↵", "run")
                hint("⌫", "back to search")
            } else {
                hint("↵", "open")
                hint("⌥↵", "split view")
                hint("⇧↵", "Peek")
                hint("⌘↵", "background tab")
                hint("⇥", "actions")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 16)
        .frame(height: 26)
    }

    func hint(_ key: String, _ what: String) -> some View {
        HStack(spacing: 4) {
            Text(key).foregroundStyle(.secondary)
            Text(what)
        }
    }
}

struct SuggestionRow: View {
    let s: Suggestion
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let u = s.url, Favicons.shared.hasIcon(for: u) {
                    FaviconView(url: u, size: 15)
                } else {
                    Image(systemName: s.icon)
                        .font(.system(size: 12))
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                }
            }
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
            if let k = s.shortcut {
                Text(k).font(.system(size: 11)).foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor : .clear))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }
}

/// An NSTextField so arrow keys, Enter, Tab and Esc work while typing, and so the autocompleted
/// part can sit selected after the cursor.
struct CommandField: NSViewRepresentable {
    @ObservedObject var bar: CommandBar

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var bar: CommandBar
        var lastToken = -1
        weak var field: NSTextField?
        init(_ bar: CommandBar) { self.bar = bar }

        func controlTextDidChange(_ n: Notification) {
            guard let f = n.object as? NSTextField else { return }
            let new = f.stringValue
            MainActor.assumeIsolated {
                let typed = bar.query
                if new == typed {
                    // Only the filled-in part went away (Backspace over the selection).
                    bar.dismissCompletion()
                    return
                }
                bar.lastEditWasInsertion = new.count > typed.count && new.lowercased().hasPrefix(typed.lowercased())
                bar.query = new
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            MainActor.assumeIsolated {
                switch sel {
                case #selector(NSResponder.moveUp(_:)): bar.move(-1); return true
                case #selector(NSResponder.moveDown(_:)): bar.move(1); return true
                case #selector(NSResponder.insertNewline(_:)):
                    bar.submit(flags: NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? [])
                    return true
                case #selector(NSResponder.cancelOperation(_:)): bar.close(); return true
                case #selector(NSResponder.insertTab(_:)):
                    if bar.query.isEmpty { bar.setActionsOnly(!bar.actionsOnly); return true }
                    if !bar.completionSuffix.isEmpty { bar.acceptCompletion(); return true }
                    bar.move(1)
                    return true
                case #selector(NSResponder.insertBacktab(_:)): bar.move(-1); return true
                case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveToEndOfLine(_:)), #selector(NSResponder.moveToEndOfDocument(_:)):
                    if !bar.completionSuffix.isEmpty { bar.acceptCompletion() }
                    return false
                case #selector(NSResponder.deleteBackward(_:)):
                    if bar.actionsOnly && bar.query.isEmpty { bar.setActionsOnly(false); return true }
                    return false
                default: return false
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(bar) }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: 18)
        f.placeholderString = "Search, enter an address, or press Tab for actions"
        f.delegate = context.coordinator
        f.stringValue = bar.query
        f.cell?.lineBreakMode = .byTruncatingTail
        context.coordinator.field = f
        DispatchQueue.main.async {
            f.window?.makeFirstResponder(f)
            f.currentEditor()?.selectAll(nil)
        }
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.bar = bar
        f.placeholderString = bar.actionsOnly ? "Type a command" : "Search, enter an address, or press Tab for actions"
        let suffix = bar.completionSuffix
        let shown = bar.query + suffix
        if f.stringValue != shown {
            f.stringValue = shown
            if !suffix.isEmpty, let ed = f.currentEditor() {
                let start = (bar.query as NSString).length
                ed.selectedRange = NSRange(location: start, length: (suffix as NSString).length)
            }
        }
        if context.coordinator.lastToken != bar.selectAllToken {
            context.coordinator.lastToken = bar.selectAllToken
            DispatchQueue.main.async {
                f.window?.makeFirstResponder(f)
                f.currentEditor()?.selectAll(nil)
            }
        }
    }
}
