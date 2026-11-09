import AppKit
import SwiftUI

// The horizontal tab layout, Safari's "Separate" style: a toolbar row with the space menu, back,
// forward and the address field, and under it a row of tabs: Essentials in a box, pinned tabs,
// folders, a line, then the other tabs, which scroll sideways. The sidebar layout is `MainView`.
// The research behind it is notes/research/2026-11-06-horizontal-tabs.md.

/// The window's root: the sidebar layout or the tab bar, from `browser.json`.
struct LayoutRoot: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var prefs = BrowserPrefs.shared

    /// The switch is instant. During a crossfade both layouts would be on screen, each with a pane
    /// that wants the same web view.
    var body: some View {
        if prefs.value.tabLayout == .horizontal {
            TabBarLayout()
        } else {
            MainView()
        }
    }
}

/// Sizes in the tab bar layout.
enum TabBarMetrics {
    /// The row of tabs under the toolbar.
    static let stripHeight: CGFloat = 38
    /// A tab, pinned tab, folder chip or Essential.
    static let itemHeight: CGFloat = 30
    /// Between the row of tabs and the page.
    static let contentTop: CGFloat = 2
    /// An Essentials tile in the box.
    static let tileWidth: CGFloat = 34
    static let tileGap: CGFloat = 2
    static let boxPadding: CGFloat = 2
    /// The gap that opens where a dragged tab would land.
    static let dropGap: CGFloat = 28
    /// A swipe over the toolbar moves one space per this many points of finger travel, the same
    /// feel as the sidebar's swipe.
    static let swipePage: CGFloat = Theme.Space.sidebarWidth
    /// The space menu's width.
    static let spaceMenuWidth: CGFloat = 252
}

/// What's open in the tab bar: the Essentials grid and the space menu.
@MainActor
final class TabBarState: ObservableObject {
    static let shared = TabBarState()

    @Published var essentialsOpen = false
    @Published var spaceMenuOpen = false
    /// The row the keyboard is on in the space menu.
    @Published var menuHighlight: Int?
    /// While you close tabs with the pointer in the strip, tabs keep this width so the next close
    /// button lands under the pointer, like Chrome. It lets go when the pointer leaves the strip.
    @Published var frozenTabWidth: CGFloat?

    private var hoverWork: DispatchWorkItem?
    private var keyMonitor: Any?

    func closeAll() {
        hoverWork?.cancel()
        widthWork?.cancel()
        essentialsOpen = false
        closeSpaceMenu()
        frozenTabWidth = nil
    }

    // MARK: Essentials

    /// The pointer came onto the Essentials box. It opens after a short rest, so passing over it
    /// on the way to a tab doesn't throw the grid over the page.
    func pointerInEssentials(_ inside: Bool) {
        hoverWork?.cancel()
        let open = inside
        guard open != essentialsOpen else { return }
        let w = DispatchWorkItem { [weak self] in
            // It grows on the reveal spring and goes on the quicker conceal curve, like the
            // sidebar's icon column and compact mode.
            MainActor.assumeIsolated { Motion.run(open ? Motion.reveal : Motion.conceal) { self?.essentialsOpen = open } }
        }
        hoverWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? TabBarRules.essentialsOpenDelay : TabBarRules.essentialsCloseDelay), execute: w)
    }

    // MARK: Widths while closing

    private var widthWork: DispatchWorkItem?

    /// A close button was clicked: the tabs keep `width` for now.
    func holdWidths(_ width: CGFloat) {
        widthWork?.cancel()
        frozenTabWidth = width
    }

    /// The pointer came back into the strip, or left it. A while after it leaves, the tabs ease
    /// to their new widths.
    func pointerInStrip(_ inside: Bool) {
        widthWork?.cancel()
        guard !inside, frozenTabWidth != nil else { return }
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { Motion.run(.easeOut(duration: 0.2)) { self?.frozenTabWidth = nil } }
        }
        widthWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + TabBarRules.widthHold, execute: w)
    }

    func closeEssentials() {
        hoverWork?.cancel()
        guard essentialsOpen else { return }
        Motion.run(Motion.conceal) { essentialsOpen = false }
    }

    // MARK: Space menu

    func toggleSpaceMenu(_ model: BrowserModel) {
        spaceMenuOpen ? closeSpaceMenu() : openSpaceMenu(model)
    }

    func openSpaceMenu(_ model: BrowserModel) {
        closeEssentials()
        menuHighlight = nil
        Motion.run(Motion.float) { spaceMenuOpen = true }
        installKeys(model)
    }

    func closeSpaceMenu() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        guard spaceMenuOpen else { return }
        Motion.run(Motion.float) { spaceMenuOpen = false }
    }

    /// Arrows move through the spaces, Return switches, Esc closes, like a menu.
    private func installKeys(_ model: BrowserModel) {
        if keyMonitor != nil { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak model] e in
            MainActor.assumeIsolated {
                guard let self, let model, self.spaceMenuOpen else { return e }
                let count = model.spaces.count
                switch e.keyCode {
                case 53: self.closeSpaceMenu(); return nil
                case 125: self.menuHighlight = ((self.menuHighlight ?? -1) + 1) % max(count, 1); return nil
                case 126: self.menuHighlight = ((self.menuHighlight ?? count) - 1 + count) % max(count, 1); return nil
                case 36, 76:
                    if let i = self.menuHighlight, model.spaces.indices.contains(i) { model.switchSpace(to: model.spaces[i].id) }
                    self.closeSpaceMenu()
                    return nil
                default: return e
                }
            }
        }
    }
}

/// Where the Essentials box and the space button sit, so the box can grow over the page and the
/// menu can hang under the button.
struct TabBarAnchors: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

struct TabBarLayout: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var settings = Settings.shared
    @ObservedObject var state = TabBarState.shared

    var body: some View {
        VStack(spacing: 0) {
            TabBarToolbar()
                .frame(height: Theme.Space.titleBarHeight)
            TabStrip()
                .frame(height: TabBarMetrics.stripHeight)
                .environment(\.hoverCardSide, .bottom)
            HStack(spacing: 0) {
                ContentArea()
                    .padding(.top, TabBarMetrics.contentTop)
                    .padding(.bottom, Theme.Space.windowMargin)
                    .padding(.leading, Theme.Space.windowMargin)
                    .padding(.trailing, settings.published.rightPanelOpen ? 0 : Theme.Space.windowMargin)
                if settings.published.rightPanelOpen {
                    RightPanel().frame(width: Theme.Space.panelWidth)
                        .transition(Motion.Transitions.panel(edge: .trailing))
                }
            }
        }
        // The Essentials box and the space menu float over the page, so they're drawn here, over
        // everything below the bar, at the places the bar reported.
        .overlayPreferenceValue(TabBarAnchors.self) { anchors in
            GeometryReader { g in
                ZStack(alignment: .topLeading) {
                    if let a = anchors["essentials"] {
                        let r = g[a]
                        EssentialsBox(rest: r.size)
                            .environment(\.hoverCardSide, .bottom)
                            .offset(x: r.minX, y: r.minY)
                    }
                    if state.spaceMenuOpen, let a = anchors["picker"] {
                        let r = g[a]
                        // A click anywhere else closes the menu, like a menu.
                        Color.black.opacity(0.0001)
                            .contentShape(Rectangle())
                            .onTapGesture { state.closeSpaceMenu() }
                        SpaceMenu()
                            .offset(x: r.minX - 4, y: r.maxY + 4)
                            .transition(Motion.Transitions.dropdown)
                    }
                }
                .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
            }
        }
        // The name of a pinned tab or Essential under the pointer.
        .overlay { HoverCardLayer() }
        .background(TabBarTint(strip: SpaceStrip.of(model)))
        .overlay { CommandBarOverlay(bar: model.bar) }
        .overlay { if let s = model.switcher { SwitcherOverlay(state: s).modifier(DelayedAppear(delay: Motion.Timing.switcherDelay)) } }
        .overlay { StartupOverlayHost() }
        .background(TrafficLights(hidden: false))
        .spaceTint(model.currentSpace?.color)
        .ignoresSafeArea()
        .frame(minWidth: 900, minHeight: 560)
        .motion(Motion.panel, value: settings.published.rightPanelOpen)
        // A swipe over the toolbar moves the strip a page per sidebar width of travel.
        .onAppear { SpaceStrip.of(model).width = TabBarMetrics.swipePage }
        .onChange(of: model.currentSpaceID) { _, _ in state.closeAll() }
    }
}

extension Motion.Transitions {
    /// A menu hanging off a button: it grows from the button's corner and fades.
    static var dropdown: AnyTransition {
        if Motion.suppressed { return .identity }
        if Motion.reduceMotion { return .opacity }
        return .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)),
                           removal: .opacity.animation(Motion.barOut))
    }
}

// MARK: - Toolbar

/// The top row: room for the traffic lights, the space menu, back, forward and reload, the
/// address field in the middle, and the app's own buttons on the right, as in Safari. The
/// sidebar's icon column uses it too, without the space menu, since the column lists the spaces:
/// like Chrome's collapsed tabs, the address moves up to a row across the window and the
/// traffic lights sit in it.
struct TabBarToolbar: View {
    var spaceMenu = true
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        HStack(spacing: 2) {
            Color.clear.frame(width: Theme.Space.trafficLightsWidth - Theme.Space.windowMargin)
            if spaceMenu {
                SpacePickerButton()
                    .padding(.trailing, Theme.Space.s)
            }
            // Back and forward here, and reload at the end of the address field, as in Safari.
            if let tab = model.currentTab, tab.kind == .web {
                BackForward(tab: tab)
            } else {
                NavButton(symbol: "chevron.left", help: "Back") {}.disabled(true)
                NavButton(symbol: "chevron.right", help: "Forward") {}.disabled(true)
            }
            WindowDragArea().frame(minWidth: Theme.Space.l)
            TabBarAddressField()
                .frame(minWidth: 240, maxWidth: 640)
                .layoutPriority(1)
            WindowDragArea().frame(minWidth: Theme.Space.l)
            DownloadsButton()
            RelatedToggleButton()
            NavButton(symbol: "clock", help: "History (Cmd-Y)") { model.openAppPage("history") }
            NavButton(symbol: GraphTab.icon, help: "Graph (Cmd-Option-G)") { model.openGraph() }
            NavButton(symbol: "gearshape", help: "Settings") { AppDelegate.shared?.openSettings() }
        }
        .padding(.horizontal, Theme.Space.windowMargin)
        // A two-finger swipe over the toolbar switches spaces, like the swipe over the sidebar.
        // The row of tabs keeps sideways scrolling for itself.
        .background(SpaceSwipeTracker(model: model))
    }
}

/// Shows the focused page's address. Clicking it opens the command bar, like Cmd-L.
struct TabBarAddressField: View {
    @EnvironmentObject var model: BrowserModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            if let t = model.currentTab, t.url != nil, !t.isNote {
                ItemIcon(tab: t, size: 14)
            } else {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            Text(model.addressText.isEmpty ? "Search or enter address" : Snippet.prettyURL(model.addressText))
                .font(Theme.Font.row)
                .foregroundStyle(model.addressText.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if model.currentTab?.url != nil, model.currentTab?.isApp == false {
                IconButton(symbol: "link", help: "Copy link (Shift-Cmd-C)", width: 22, height: 22, symbolSize: 10) { model.copyCurrentURL() }
                    .opacity(hovering ? 1 : 0)
                    .motion(Motion.hover, value: hovering, fadeOnly: true)
            }
            if let tab = model.currentWebTab, model.currentTab?.kind == .web { FieldReload(tab: tab) }
        }
        .padding(.leading, Theme.Space.l - 2)
        .padding(.trailing, Theme.Space.xs)
        .frame(height: TabBarMetrics.itemHeight)
        .background(Theme.Radius.shape(Theme.Radius.row).fill(hovering ? Theme.Palette.fieldHover : Theme.Palette.field))
        // The command bar grows out of here for Cmd-L.
        .background(AddressFieldFrame())
        .contentShape(Rectangle())
        .onTapGesture { model.focusAddress() }
        .onHover { hovering = $0 }
        .motion(Motion.hover, value: hovering, fadeOnly: true)
        .help(model.addressText)
    }
}

/// Back and forward for the focused page.
struct BackForward: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var model: BrowserModel
    var body: some View {
        NavButton(symbol: "chevron.left", help: "Back (Cmd-[)") { model.goBack() }.disabled(!tab.canGoBack)
        NavButton(symbol: "chevron.right", help: "Forward (Cmd-])") { model.goForward() }.disabled(!tab.canGoForward)
    }
}

/// Reload, or stop while the page loads, at the end of the address field.
struct FieldReload: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var model: BrowserModel
    var body: some View {
        IconButton(symbol: tab.isLoading ? "xmark" : "arrow.clockwise", help: tab.isLoading ? "Stop" : "Reload (Cmd-R)",
                   width: 22, height: 22, symbolSize: 10) {
            if tab.isLoading { tab.webView?.stopLoading() } else { model.reload() }
        }
        .disabled(tab.url == nil)
    }
}

// MARK: - Frame tint

/// The window frame in the tab bar layout: the space's colour full under the bar, easing toward
/// neutral down the margins. It follows the space strip, so a swipe carries the colour with it.
struct TabBarTint: View {
    @ObservedObject var strip: SpaceStrip
    @EnvironmentObject var model: BrowserModel
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        let p = strip.position
        let lo = Int(p.rounded(.down))
        let a = strip.space(atSlot: lo) ?? strip.space(atSlot: lo + 1) ?? model.currentSpaceID
        let next = strip.space(atSlot: lo + 1)
        let b = next == a ? nil : next
        let active = SpaceTintBackground.forceActive || activeState == .key || activeState == .active
        return GeometryReader { g in
            let bar = min(0.9, (Theme.Space.titleBarHeight + TabBarMetrics.stripHeight) / max(g.size.height, 1))
            ZStack {
                Theme.Palette.frame
                wash(color(a), active: active, bar: bar)
                    .id((color(a) ?? "") + (active ? "" : "-inactive"))
                    .transition(.opacity)
                if let b, p - Double(lo) > 0 {
                    wash(color(b), active: active, bar: bar).opacity(min(1, p - Double(lo)))
                }
                GrainOverlay()
            }
            .animation(strip.isMoving ? nil : Motion.animation(Motion.spaceSwitch, fadeOnly: true), value: color(a))
            .motion(Motion.hover, value: active, fadeOnly: true)
        }
        .ignoresSafeArea()
        .background(StripClock(strip: strip))
    }

    private func wash(_ hex: String?, active: Bool, bar: CGFloat) -> some View {
        let tint = Theme.Palette.sidebarColor(hex, active: active)
        return LinearGradient(stops: [
            .init(color: tint, location: 0),
            .init(color: tint.opacity(0.96), location: bar),
            .init(color: tint.opacity(0.6), location: min(1, bar + 0.3)),
            .init(color: tint.opacity(0.35), location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }

    private func color(_ id: UUID) -> String? { model.spaces.first { $0.id == id }?.color }
}

// MARK: - Menu items

extension AppDelegate: NSMenuItemValidation {
    @objc func tabLayoutAction() { TabLayoutSwitch.toggle() }

    /// The layout switch shows a check in the tab bar layout, and the sidebar's own items are off there.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(tabLayoutAction) {
            item.state = TabLayoutSwitch.isHorizontal ? .on : .off
            return true
        }
        if TabLayoutSwitch.isHorizontal, let a = item.action,
           ["toggleSidebarAction", "sidebarSideAction", "sidebarIconsAction"].contains(NSStringFromSelector(a)) {
            return false
        }
        return true
    }
}
