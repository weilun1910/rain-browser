import AppKit
import SwiftUI

/// Links from other apps open in a small window with no sidebar, like Little Arc. Cmd-O moves the
/// page into the main window as a tab in the current space, without reloading it.
@MainActor
final class LittleArc: NSObject, NSWindowDelegate {
    static let shared = LittleArc()
    private(set) var tabs: [Tab] = []
    private var windows: [UUID: NSWindow] = [:]
    /// Set while a page moves to the main window, so closing its window doesn't close the page.
    private var moving: Set<UUID> = []

    /// Opens a link in a new small window. `show` is false in tests, so nothing reaches the screen.
    @discardableResult
    func open(_ url: URL?, model: BrowserModel, show: Bool = true) -> Tab {
        // Clicking the same link again brings its window back, like Arc.
        if let url, let t = tabs.first(where: { $0.url.map { Tab.samePage($0, url) } ?? false }), let w = windows[t.id] {
            if show { w.makeKeyAndOrderFront(nil) }
            return t
        }
        let t = Tab(url: url)
        t.model = model
        t.spaceID = model.currentSpaceID
        tabs.append(t)
        if url != nil { _ = t.ensureWebView() }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.collectionBehavior.insert(.fullScreenAuxiliary)
        w.contentView = NSHostingView(rootView: LittleArcView(tab: t).environmentObject(model))
        w.delegate = self
        w.center()
        let offset = CGFloat(windows.count % 6) * 24
        w.setFrameOrigin(NSPoint(x: w.frame.minX + offset, y: w.frame.minY - offset))
        windows[t.id] = w
        if show {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        return t
    }

    /// Cmd-Opt-N: an empty little window with a field to type in.
    func openBlank(model: BrowserModel) { open(nil, model: model) }

    func window(for tab: Tab) -> NSWindow? { windows[tab.id] }

    /// Cmd-O: the page joins the main window as a tab, at the top of Tabs in the current space.
    func moveToMain(_ tab: Tab, model: BrowserModel, space: UUID? = nil) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        moving.insert(tab.id)
        let w = windows[tab.id]
        windows[tab.id] = nil
        tabs.removeAll { $0 === tab }
        w?.contentView = nil
        w?.close()
        moving.remove(tab.id)
        if let space, space != model.currentSpaceID { model.switchSpace(to: space) }
        tab.spaceID = model.currentSpaceID
        tab.order = model.topOrder(today: model.currentSpaceID)
        model.tabs.append(tab)
        model.select(tab)
        AppDelegate.shared?.window.makeKeyAndOrderFront(nil)
        model.focusWeb(tab)
        model.scheduleSave()
    }

    func close(_ tab: Tab) {
        windows[tab.id]?.close()
    }

    func windowWillClose(_ n: Notification) {
        guard let w = n.object as? NSWindow, let (id, _) = windows.first(where: { $0.value === w }) else { return }
        windows[id] = nil
        guard !moving.contains(id), let t = tabs.first(where: { $0.id == id }) else { return }
        tabs.removeAll { $0.id == id }
        // Closed little windows can come back from Recently Closed.
        t.model?.recordClosed([t], reason: .closed)
        t.unload()
    }
}

struct LittleArcView: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var model: BrowserModel
    @State private var typed = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Spacer().frame(width: 64)
                if tab.url != nil {
                    ItemIcon(tab: tab, size: 13)
                    Text(tab.displayTitle).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if let h = tab.url?.host { Text(h).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                if tab.url != nil {
                    Menu {
                        ForEach(model.spaces) { sp in
                            Button(sp.name) { LittleArc.shared.moveToMain(tab, model: model, space: sp.id) }
                        }
                    } label: {
                        Text("Open in \(model.currentSpace?.name ?? "browser")").font(.system(size: 12))
                    } primaryAction: {
                        LittleArc.shared.moveToMain(tab, model: model)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Move this page into the main window (Cmd-O)")
                    .keyboardShortcut("o", modifiers: .command)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(WindowDragArea())
            if tab.url == nil && !tab.isLoaded {
                VStack(spacing: 10) {
                    TextField("Search or enter an address", text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 15))
                        .frame(maxWidth: 460)
                        .onSubmit {
                            if let u = AddressParser.url(for: typed) { tab.load(u) }
                        }
                    Text("Cmd-O moves a page from here into the main window.").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                WebArea(tab: tab)
                    .paneCard()
                    .padding([.horizontal, .bottom], 8)
            }
        }
        .background(VisualEffect().ignoresSafeArea())
    }
}
