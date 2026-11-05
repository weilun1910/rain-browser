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
    private var flagsMonitor: Any?
    private var recentlyClosedMenu: NSMenu?

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

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            MainActor.assumeIsolated { (self?.handleKey(e) ?? false) ? nil : e }
        }
        // Releasing Ctrl ends the Ctrl-Tab switcher on the highlighted item.
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            MainActor.assumeIsolated {
                if let m = self?.model, m.switcher != nil, !e.modifierFlags.contains(.control) { m.commitSwitcher() }
            }
            return e
        }

        // Graceful quit on SIGTERM so state and notes get saved.
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        src.resume()
        termSource = src

        // Background upkeep: scan and watch the notes folders, and archive idle tabs.
        model.notes.reload()
        model.startUpkeep()

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
        file.addItem(item("New Little Arc Window", #selector(littleArcAction), "n", [.command, .option], target: self))
        file.addItem(item("Split with New Tab", #selector(splitNewTabAction), "=", [.control, .shift], target: self))
        file.addItem(item("Open Location", #selector(openLocationAction), "l", target: self))
        file.addItem(.separator())
        file.addItem(item("Close Tab", #selector(closeTabAction), "w", target: self))
        file.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]))
        file.addItem(item("Reopen Closed Tab", #selector(reopenClosedAction), "t", [.command, .shift], target: self))
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
        edit.addItem(.separator())
        edit.addItem(item("Copy Link", #selector(copyLinkAction), "c", [.command, .shift], target: self))
        edit.addItem(item("Copy Link as Markdown", #selector(copyMarkdownAction), "c", [.command, .shift, .option], target: self))
        edit.addItem(.separator())
        edit.addItem(item("Find...", #selector(findAction), "f", target: self))
        edit.addItem(item("Find Next", #selector(findNextAction), "g", target: self))
        edit.addItem(item("Find Previous", #selector(findPreviousAction), "g", [.command, .shift], target: self))
        addSubmenu(main, "Edit", edit)

        let view = NSMenu(title: "View")
        view.addItem(item("Reload Page", #selector(reloadAction), "r", target: self))
        view.addItem(item("Reload Without Cache", #selector(hardReloadAction), "r", [.command, .option], target: self))
        view.addItem(.separator())
        view.addItem(item("Toggle Sidebar", #selector(toggleSidebarAction), "s", target: self))
        view.addItem(item("Sidebar on the Other Side", #selector(sidebarSideAction), target: self))
        view.addItem(item("Show or Hide Related Panel", #selector(togglePanelAction), "r", [.command, .shift], target: self))
        view.addItem(item("Toggle Note Preview", #selector(togglePreviewAction), "p", [.command, .shift], target: self))
        view.addItem(.separator())
        let layout = NSMenu(title: "Split Layout")
        layout.addItem(item("Side by Side", #selector(layoutSideAction), target: self))
        layout.addItem(item("Stacked", #selector(layoutStackAction), target: self))
        layout.addItem(item("Grid", #selector(layoutGridAction), target: self))
        layout.addItem(.separator())
        layout.addItem(item("Even Out", #selector(evenOutAction), target: self))
        let layoutHolder = NSMenuItem(title: "Split Layout", action: nil, keyEquivalent: "")
        layoutHolder.submenu = layout
        view.addItem(layoutHolder)
        view.addItem(item("Unsplit", #selector(unsplitAction), "-", [.control, .shift], target: self))
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
        history.addItem(.separator())
        history.addItem(item("Show History", #selector(showHistoryAction), "y", target: self))
        history.addItem(item("Show Archive", #selector(showArchiveAction), target: self))
        history.addItem(item("Show Downloads", #selector(showDownloadsAction), "l", [.command, .option], target: self))
        let closedMenu = NSMenu(title: "Recently Closed")
        closedMenu.delegate = self
        recentlyClosedMenu = closedMenu
        let closedHolder = NSMenuItem(title: "Recently Closed", action: nil, keyEquivalent: "")
        closedHolder.submenu = closedMenu
        history.addItem(closedHolder)
        history.addItem(.separator())
        history.addItem(item("Clear Today", #selector(clearTodayAction), "k", [.command, .shift], target: self))
        addSubmenu(main, "History", history)

        let tab = NSMenu(title: "Tab")
        tab.addItem(item("Pin or Unpin Tab", #selector(togglePinAction), "d", target: self))
        tab.addItem(item("Add to or Remove from Essentials", #selector(toggleEssentialAction), target: self))
        tab.addItem(item("Back to Pinned Page", #selector(resetPinAction), target: self))
        tab.addItem(item("Duplicate Tab", #selector(duplicateAction), target: self))
        tab.addItem(item("Rename Tab...", #selector(renameAction), target: self))
        tab.addItem(item("Mute or Unmute Tab", #selector(muteAction), target: self))
        tab.addItem(item("Archive Tab", #selector(archiveAction), target: self))
        tab.addItem(.separator())
        tab.addItem(item("Next Tab", #selector(nextTabAction), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .option], target: self))
        tab.addItem(item("Previous Tab", #selector(previousTabAction), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .option], target: self))
        tab.addItem(item("Open Peek as Tab", #selector(expandPeekAction), "o", target: self))
        addSubmenu(main, "Tab", tab)

        let spacesMenu = NSMenu(title: "Spaces")
        spacesMenu.addItem(item("Next Space", #selector(nextSpaceAction), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option], target: self))
        spacesMenu.addItem(item("Previous Space", #selector(previousSpaceAction), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .option], target: self))
        spacesMenu.addItem(item("New Space...", #selector(newSpaceAction), target: self))
        addSubmenu(main, "Spaces", spacesMenu)

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
        if let w = NSApp.keyWindow, w !== window { w.performClose(nil); return }
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
    @objc func hardReloadAction() { model.reloadFromOrigin() }
    @objc func littleArcAction() { LittleArc.shared.openBlank(model: model) }
    @objc func reopenClosedAction() { showMain(); model.reopenClosed() }
    @objc func copyLinkAction() { model.copyCurrentURL() }
    @objc func copyMarkdownAction() { model.copyCurrentURL(markdown: true) }
    @objc func findAction() { model.openFind() }
    @objc func findNextAction() { model.findNext() }
    @objc func findPreviousAction() { model.findNext(backwards: true) }
    @objc func toggleSidebarAction() { BrowserPrefs.shared.update { $0.sidebarHidden.toggle() } }
    @objc func sidebarSideAction() { BrowserPrefs.shared.update { $0.sidebarOnRight.toggle() } }
    @objc func layoutSideAction() { model.setLayout(.sideBySide) }
    @objc func layoutStackAction() { model.setLayout(.stacked) }
    @objc func layoutGridAction() { model.setLayout(.grid) }
    @objc func evenOutAction() { model.evenOut() }
    @objc func unsplitAction() { model.unsplitCurrent() }
    @objc func showHistoryAction() { showMain(); model.openAppPage("history") }
    @objc func showArchiveAction() { showMain(); model.openAppPage("archive") }
    @objc func showDownloadsAction() { showMain(); model.openAppPage("downloads") }
    @objc func clearTodayAction() { _ = model.clearToday() }
    @objc func togglePinAction() { if let t = model.currentTab { model.togglePin(t) } }
    @objc func toggleEssentialAction() {
        guard let t = model.currentTab else { return }
        if t.isEssential { model.removeFromEssentials(t) } else { model.addToEssentials(t) }
    }
    @objc func resetPinAction() { if let t = model.currentTab { model.resetPinned(t) } }
    @objc func duplicateAction() { if let t = model.currentTab { model.duplicate(t) } }
    @objc func renameAction() { if let t = model.currentTab { model.promptRenameTab(t) } }
    @objc func muteAction() { if let t = model.currentWebTab { model.toggleMute(t) } }
    @objc func archiveAction() { if let t = model.currentTab { model.archive(t) } }
    @objc func nextTabAction() { model.selectAdjacentRow(1) }
    @objc func previousTabAction() { model.selectAdjacentRow(-1) }
    @objc func expandPeekAction() {
        if let w = NSApp.keyWindow, let t = LittleArc.shared.tabs.first(where: { LittleArc.shared.window(for: $0) === w }) {
            LittleArc.shared.moveToMain(t, model: model)
            return
        }
        model.expandPeek()
    }
    @objc func nextSpaceAction() { model.switchSpace(by: 1) }
    @objc func previousSpaceAction() { model.switchSpace(by: -1) }
    @objc func newSpaceAction() { model.promptNewSpace() }
    @objc func restoreClosedItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        showMain()
        model.restoreClosed([id])
    }

    private func showMain() {
        if !window.isVisible { window.makeKeyAndOrderFront(nil) }
    }

    /// Keys menus can't express well: Ctrl-Tab, the split keys, Cmd-1 to 9, Ctrl-1 to 9 and Esc for Peek.
    /// Returns true when the key was used.
    func handleKey(_ e: NSEvent) -> Bool {
        guard let model, e.window === window || e.window == nil else { return false }
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        let digit: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
        // Ctrl-Tab and Ctrl-Shift-Tab: recent tabs, like Arc.
        if e.keyCode == 48, mods == [.control] || mods == [.control, .shift] {
            let back = mods.contains(.shift)
            if model.switcher == nil { model.beginSwitcher(backwards: back) } else { model.advanceSwitcher(back ? -1 : 1) }
            return true
        }
        if e.keyCode == 53 {
            if model.switcher != nil { model.switcher = nil; return true }
            if model.peek != nil && !model.bar.isOpen && mods.isEmpty { model.closePeek(); return true }
            if model.find.visible && mods.isEmpty { model.closeFind(); return true }
            return false
        }
        // Ctrl-Shift-= reports "+" on most layouts, so match the key itself.
        if e.keyCode == 24 && mods == [.control, .shift] { splitNewTabAction(); return true }
        if e.keyCode == 27 && mods == [.control, .shift] { model.unsplitCurrent(); return true }
        if e.keyCode == 30 && mods == [.control, .shift] { model.focusNextPane(1); return true }
        if e.keyCode == 33 && mods == [.control, .shift] { model.focusNextPane(-1); return true }
        if mods == [.control, .shift], let n = digit[e.keyCode], n <= 4 { model.focusPane(index: n - 1); return true }
        // Ctrl-1 to Ctrl-9 jump to a space.
        if mods == [.control], let n = digit[e.keyCode] { model.switchSpace(index: n - 1); return true }
        // Cmd-1 to Cmd-8 pick a row, Cmd-9 the last, counting Essentials and pins first.
        if mods == [.command], let n = digit[e.keyCode], !model.bar.isOpen { model.selectRow(number: n); return true }
        return false
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Recently Closed lists the last few closed tabs, newest first.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentlyClosedMenu, let model else { return }
        menu.removeAllItems()
        let recent = model.closed.recent.prefix(15)
        if recent.isEmpty {
            let none = NSMenuItem(title: "Nothing closed yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return
        }
        for c in recent {
            let i = NSMenuItem(title: c.displayTitle, action: #selector(restoreClosedItem(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = c.id
            menu.addItem(i)
        }
    }
}
