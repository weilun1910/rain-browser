import AppKit
import SwiftUI

/// Days, newest first, for the history and archive lists.
enum DayGroups {
    static func label(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = cal.component(.year, from: d) == cal.component(.year, from: Date()) ? "EEEE d MMMM" : "d MMMM yyyy"
        return f.string(from: d)
    }

    static func group<T>(_ items: [T], by date: (T) -> Date) -> [(String, [T])] {
        var out: [(String, [T])] = []
        for i in items {
            let l = label(date(i))
            if out.last?.0 == l { out[out.count - 1].1.append(i) } else { out.append((l, [i])) }
        }
        return out
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}

/// A plain page layout: a title, a search field and a scrolling list.
struct AppPageScaffold<Trailing: View, Content: View>: View {
    let title: String
    @Binding var query: String
    var placeholder = "Search"
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 22, weight: .semibold))
                Spacer()
                trailing()
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            TextField(placeholder, text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 420)
                .padding(.horizontal, 28)
                .padding(.top, 12)
                .padding(.bottom, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) { content() }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct DayHeader: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.top, 16).padding(.bottom, 4)
    }
}

struct PageListRow<Trailing: View>: View {
    let url: URL?
    let icon: String
    let title: String
    let detail: String
    let time: String
    @ViewBuilder var trailing: () -> Trailing
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Text(time).font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary).frame(width: 38, alignment: .leading)
            if let url, url.scheme?.hasPrefix("http") == true { FaviconView(url: url, size: 14) } else { Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14) }
            Text(title).font(.system(size: 13)).lineLimit(1)
            Text(detail).font(.system(size: 12)).foregroundStyle(.tertiary).lineLimit(1)
            Spacer(minLength: 8)
            if hovering { trailing() }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.05) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// Cmd-Y. Every visit, grouped by day, searchable. Recently closed tabs have their own view.
struct HistoryPage: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var history = HistoryStore.shared
    @State private var query = ""
    @State private var showClosed = false

    var body: some View {
        let _ = history.generation
        AppPageScaffold(title: "History", query: $query, placeholder: showClosed ? "Search recently closed" : "Search history") {
            Picker("", selection: $showClosed) {
                Text("Visits").tag(false)
                Text("Recently closed").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            Menu("Clear") {
                Button("Last hour") { history.clear(since: Date().addingTimeInterval(-3600)) }
                Button("Today") { history.clear(since: Calendar.current.startOfDay(for: Date())) }
                Button("All history") {
                    if Prompt.confirm(title: "Clear all history?", message: "This removes every visit from the history list. Pages in the Related index stay.", ok: "Clear") {
                        history.clear()
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        } content: {
            if showClosed {
                let items = model.closed.recent.filter { query.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(query) || ($0.url ?? "").localizedCaseInsensitiveContains(query) }
                if items.isEmpty { emptyText("Nothing closed recently.") }
                ForEach(DayGroups.group(items, by: { $0.closedAt }), id: \.0) { day, rows in
                    DayHeader(text: day)
                    ForEach(rows) { it in ClosedRow(item: it) }
                }
            } else {
                let visits = history.visits(matching: query, limit: 400)
                if visits.isEmpty { emptyText(query.isEmpty ? "Pages you visit show up here." : "No visits match.") }
                ForEach(DayGroups.group(visits, by: { $0.at }), id: \.0) { day, rows in
                    DayHeader(text: day)
                    ForEach(rows) { v in
                        PageListRow(url: URL(string: v.url), icon: "globe", title: v.title.isEmpty ? v.host : v.title, detail: v.host, time: DayGroups.time(v.at)) {
                            SmallIconButton(symbol: "xmark", help: "Remove from history") { history.delete(v.id) }
                        }
                        .onTapGesture { if let u = URL(string: v.url) { model.newTab(url: u, select: true) } }
                        .contextMenu {
                            if let u = URL(string: v.url) {
                                Button("Open in new tab") { model.newTab(url: u, select: true) }
                                Button("Open in split view") { model.routeLink(u, .split, from: model.currentTab ?? Tab(url: nil)) }
                                Button("Open in Peek") { model.openPeek(u, from: model.currentTab) }
                                Button("Copy link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(v.url, forType: .string) }
                            }
                            Divider()
                            Button("Remove from history") { history.delete(v.id) }
                        }
                    }
                }
            }
        }
    }

    func emptyText(_ s: String) -> some View {
        Text(s).font(.system(size: 13)).foregroundStyle(.tertiary).padding(.horizontal, 8).padding(.top, 20)
    }
}

/// A closed or archived item with Restore.
struct ClosedRow: View {
    let item: ClosedItem
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        let space = model.spaces.first { $0.id == item.spaceID }?.name ?? ""
        let detail = [item.url.flatMap { URL(string: $0)?.host }, space.isEmpty ? nil : space].compactMap { $0 }.joined(separator: " | ")
        PageListRow(url: item.url.flatMap(URL.init(string:)), icon: item.kind == .note ? "note.text" : "globe", title: item.displayTitle,
                    detail: detail, time: DayGroups.time(item.closedAt)) {
            Button("Restore") { model.restoreClosed(restoreSet()) }.buttonStyle(.link).font(.system(size: 12))
        }
        .onTapGesture { model.restoreClosed(restoreSet()) }
        .help(item.group != nil && item.splitRoot != nil ? "Restores the whole split" : "Restore to \(space.isEmpty ? "this space" : space)")
    }

    /// A split comes back whole.
    func restoreSet() -> Set<UUID> {
        if let g = item.group, item.splitRoot != nil { return Set(model.closed.members(of: g).map { $0.id }) }
        return [item.id]
    }
}

/// Tabs that sat idle and moved out of Today, or were cleared, like Arc's archive.
struct ArchivePage: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var prefs = BrowserPrefs.shared
    @State private var query = ""

    var body: some View {
        AppPageScaffold(title: "Archive", query: $query, placeholder: "Search the archive") {
            Picker("Archive after", selection: Binding(get: { prefs.value.archiveAfterHours }, set: { v in prefs.update { $0.archiveAfterHours = v } })) {
                ForEach(BrowserPrefsValue.archiveChoices, id: \.1) { Text($0.0).tag($0.1) }
            }
            .frame(width: 210)
            Button("Clear archive") {
                if Prompt.confirm(title: "Clear the archive?", message: "Archived tabs can't be restored after this.", ok: "Clear") { model.closed.clearArchive() }
            }
            .disabled(model.closed.archive.isEmpty)
        } content: {
            let items = model.closed.archive.filter { query.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(query) || ($0.url ?? "").localizedCaseInsensitiveContains(query) }
            if items.isEmpty {
                Text(prefs.value.archiveAfterHours > 0 ? "Tabs you haven't looked at for a while move here, so Tabs stays short. Pinned tabs, Essentials and filed tabs never do." : "Auto-archive is off. Cleared tabs still come here.")
                    .font(.system(size: 13)).foregroundStyle(.tertiary).padding(.horizontal, 8).padding(.top, 20)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(DayGroups.group(items, by: { $0.closedAt }), id: \.0) { day, rows in
                DayHeader(text: day)
                ForEach(rows) { ClosedRow(item: $0) }
            }
        }
    }
}

struct DownloadsPage: View {
    @State private var query = ""
    var body: some View {
        AppPageScaffold(title: "Downloads", query: $query, placeholder: "Search downloads") {
            Button("Clear finished") { Downloads.shared.clearFinished() }
        } content: {
            DownloadsList(compact: false, query: query)
        }
    }
}

struct DownloadsList: View {
    let compact: Bool
    var query = ""
    @ObservedObject var downloads = Downloads.shared
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        let items = downloads.items.reversed().filter { query.isEmpty || $0.filename.localizedCaseInsensitiveContains(query) }
        VStack(alignment: .leading, spacing: 4) {
            if compact {
                HStack {
                    Text("Downloads").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("Show all") { model.openAppPage("downloads") }.buttonStyle(.link).font(.system(size: 12))
                }
            }
            if items.isEmpty { Text("No downloads").font(.system(size: 12)).foregroundStyle(.tertiary) }
            ForEach(Array(items.prefix(compact ? 6 : 200))) { d in
                HStack(spacing: 10) {
                    Image(systemName: d.state == .failed || d.state == .cancelled ? "exclamationmark.circle" : "doc").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.filename).font(.system(size: 12)).lineLimit(1)
                        if d.state == .running {
                            ProgressView(value: d.progress).controlSize(.mini)
                        } else {
                            Text(status(d)).font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 0)
                    if d.state == .running {
                        SmallIconButton(symbol: "xmark", help: "Cancel") { downloads.cancel(d.id) }
                    } else if d.state == .done {
                        SmallIconButton(symbol: "magnifyingglass", help: "Show in Finder") { downloads.reveal(d) }
                    }
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { if d.state == .done { downloads.open(d) } }
            }
        }
    }

    func status(_ d: Downloads.Item) -> String {
        switch d.state {
        case .done: return "Done, \(DayGroups.label(d.startedAt)) at \(DayGroups.time(d.startedAt))"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .running: return ""
        }
    }
}
