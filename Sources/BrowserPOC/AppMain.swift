import AppKit
import SwiftUI

enum AppMain {
    @MainActor
    static func run() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static weak var shared: AppDelegate?

    var window: NSWindow!
    var model: BrowserModel!
    private var settingsWindow: NSWindow?
    private var termSource: DispatchSourceSignal?
    private var pendingURLs: [URL] = []
    private var keyMonitor: Any?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Paths.ensure(Paths.root)
        do {
            IndexStore.shared = try IndexStore(url: Paths.indexFile)
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn't open the index"
            a.informativeText = "\(error)"
            a.runModal()
            NSApp.terminate(nil)
            return
        }

        appLog.notice("Foundation Models: \(ReasonWriter.availabilityText, privacy: .public)")
        appLog.notice("Sentence embedding: \(Embedder.shared.isAvailable ? "available" : "not available", privacy: .public)")

        model = BrowserModel()
        CurrentContextWriter.shared.start(model: model)
        buildMenu()

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1380, height: 880),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Browser POC"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = false
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.minSize = NSSize(width: 900, height: 560)
        w.contentView = MainView.host(model)
        w.delegate = self
        w.setFrameAutosaveName("BrowserPOCMain")
        if !w.setFrameUsingName("BrowserPOCMain") { w.center() }
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()

        // Ctrl-Shift-= reports "+" on most layouts, so match the key itself too.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if e.keyCode == 24 && mods == [.control, .shift] {
                MainActor.assumeIsolated { self?.splitNewTabAction() }
                return nil
            }
            // Ctrl-1 to Ctrl-9 jump to a space.
            let digits: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8]
            if mods == [.control], let i = digits[e.keyCode] {
                MainActor.assumeIsolated { self?.model.switchSpace(index: i) }
                return nil
            }
            return e
        }

        // Graceful quit on SIGTERM so state and notes get saved.
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        src.resume()
        termSource = src

        // Background upkeep: scan and watch the notes folders.
        model.notes.reload()

        if model.currentTab == nil && model.document == nil {
            model.focusAddress()
        }
        if !pendingURLs.isEmpty { model.openFromSystem(pendingURLs); pendingURLs = [] }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let model { model.openFromSystem(urls) } else { pendingURLs.append(contentsOf: urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        model?.prepareForQuit()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model?.notes.reload()
        model?.checkNotesOnDisk()
    }

    // MARK: Settings window

    func openSettings() {
        if let w = settingsWindow {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 620),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Settings"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: SettingsView())
        w.center()
        settingsWindow = w
        w.makeKeyAndOrderFront(nil)
    }

    // MARK: Menu

    private func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = target
        return i
    }

    private func buildMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(item("About Browser POC", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings...", #selector(settingsAction), ",", target: self))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Hide Browser POC", #selector(NSApplication.hide(_:)), "h", target: NSApp))
        appMenu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp))
        appMenu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit Browser POC", #selector(NSApplication.terminate(_:)), "q", target: NSApp))
        addSubmenu(main, "Browser POC", appMenu)

        let file = NSMenu(title: "File")
        file.addItem(item("New Tab", #selector(newTabAction), "t", target: self))
        file.addItem(item("New Note", #selector(newNoteAction), "n", [.command, .shift], target: self))
        file.addItem(item("Split with New Tab", #selector(splitNewTabAction), "=", [.control, .shift], target: self))
        file.addItem(item("Open Location", #selector(openLocationAction), "l", target: self))
        file.addItem(.separator())
        file.addItem(item("Close Tab", #selector(closeTabAction), "w", target: self))
        file.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]))
        addSubmenu(main, "File", file)

        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), "z"))
        edit.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]))
        edit.addItem(item("Delete", #selector(NSText.delete(_:)), ""))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        addSubmenu(main, "Edit", edit)

        let view = NSMenu(title: "View")
        view.addItem(item("Reload Page", #selector(reloadAction), "r", target: self))
        view.addItem(.separator())
        view.addItem(item("Show or Hide Related Panel", #selector(togglePanelAction), "r", [.command, .shift], target: self))
        view.addItem(item("Toggle Note Preview", #selector(togglePreviewAction), "p", [.command, .shift], target: self))
        view.addItem(.separator())
        view.addItem(item("Actual Size", #selector(zoomResetAction), "0", target: self))
        view.addItem(item("Zoom In", #selector(zoomInAction), "=", target: self))
        view.addItem(item("Zoom Out", #selector(zoomOutAction), "-", target: self))
        view.addItem(.separator())
        view.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        addSubmenu(main, "View", view)

        let history = NSMenu(title: "History")
        history.addItem(item("Back", #selector(backAction), "[", target: self))
        history.addItem(item("Forward", #selector(forwardAction), "]", target: self))
        addSubmenu(main, "History", history)

        let win = NSMenu(title: "Window")
        win.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        win.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        win.addItem(.separator())
        win.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), target: NSApp))
        addSubmenu(main, "Window", win)
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }

    private func addSubmenu(_ main: NSMenu, _ title: String, _ menu: NSMenu) {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        holder.submenu = menu
        main.addItem(holder)
    }

    @objc func settingsAction() { openSettings() }
    @objc func newTabAction() { showMain(); model.newTabCommand() }
    @objc func newNoteAction() { showMain(); model.newNote() }
    @objc func splitNewTabAction() { showMain(); model.splitWithNewTab() }
    @objc func openLocationAction() { showMain(); model.focusAddress() }
    @objc func closeTabAction() {
        if NSApp.keyWindow === settingsWindow { settingsWindow?.performClose(nil); return }
        model.closeCurrent()
    }
    @objc func reloadAction() { model.reload() }
    @objc func backAction() { model.goBack() }
    @objc func forwardAction() { model.goForward() }
    @objc func togglePanelAction() { Settings.shared.update { $0.rightPanelOpen.toggle() } }
    @objc func togglePreviewAction() { model.document?.showPreview.toggle() }
    @objc func zoomResetAction() { model.zoom(nil) }
    @objc func zoomInAction() { model.zoom(0.1) }
    @objc func zoomOutAction() { model.zoom(-0.1) }

    private func showMain() {
        if !window.isVisible { window.makeKeyAndOrderFront(nil) }
    }
}
