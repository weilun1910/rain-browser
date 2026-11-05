import SwiftUI

/// Pages the app draws itself, as items like any other: History, Archive, Downloads, and any page
/// another part of the app registers (the graph, for one). An app page item is a `Tab` with
/// kind `.app` and a `browser://<host>` URL. It can be pinned, filed, split, moved between
/// spaces and found in the command bar.
///
/// To add one:
///
///     AppPages.register(AppPage(host: "graph", title: "Graph", icon: "point.3.connected.trianglepath.dotted") { tab in
///         AnyView(GraphPane(tab: tab))
///     })
///     model.openAppPage("graph")
@MainActor
struct AppPage {
    let host: String
    let title: String
    let icon: String
    /// Shown in the command bar's actions as "Open <title>". Off for pages that need context.
    var inCommandBar = true
    let view: (Tab) -> AnyView
}

@MainActor
enum AppPages {
    static let scheme = "browser"
    private static var pages: [String: AppPage] = [:]
    private static var builtInsRegistered = false

    static func register(_ p: AppPage) { pages[p.host.lowercased()] = p }

    static func url(_ host: String) -> URL { URL(string: "\(scheme)://\(host.lowercased())")! }

    static func page(for url: URL?) -> AppPage? {
        registerBuiltIns()
        guard let url, url.scheme?.lowercased() == scheme, let h = url.host?.lowercased() else { return nil }
        return pages[h]
    }

    static var all: [AppPage] {
        registerBuiltIns()
        return pages.values.sorted { $0.title < $1.title }
    }

    static func registerBuiltIns() {
        guard !builtInsRegistered else { return }
        builtInsRegistered = true
        register(AppPage(host: "history", title: "History", icon: "clock") { _ in AnyView(HistoryPage()) })
        register(AppPage(host: "archive", title: "Archive", icon: "archivebox") { _ in AnyView(ArchivePage()) })
        register(AppPage(host: "downloads", title: "Downloads", icon: "arrow.down.circle") { _ in AnyView(DownloadsPage()) })
    }
}
