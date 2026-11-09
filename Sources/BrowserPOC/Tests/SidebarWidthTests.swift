import AppKit
import Foundation

/// The sidebar's width: where a drag of its edge lands, the snap to icons and back, the detent at
/// the default width, what's saved when you let go, and saved widths out of range.
enum SidebarWidthTests {
    static func check(_ ok: Bool, _ label: String, _ detail: String = "") { SelfTest.check(ok, label, detail) }

    static func run(dir: URL) {
        MainActor.assumeIsolated {
            BrowserPrefs.shared.reload()
            let before = BrowserPrefs.shared.value
            SidebarResize.headless = true
            layout()
            dragging()
            essentialsBloom()
            columnBox()
            tabModes()
            hoverCards()
            BrowserPrefs.shared.update { $0 = before }
            SidebarResize.headless = false
        }
    }

    static func layout() {
        typealias L = SidebarWidth.Layout
        let icons = SidebarWidth.icons, lo = SidebarWidth.min, hi = SidebarWidth.max, std = SidebarWidth.standard
        check(SidebarWidth.layout(proposed: 300) == L(iconsOnly: false, width: 300), "an edge dragged to 300 pt sits at 300 pt")
        check(SidebarWidth.layout(proposed: std - 12) == L(iconsOnly: false, width: std)
              && SidebarWidth.layout(proposed: std + 15) == L(iconsOnly: false, width: std),
              "within 15 pt of the default width the edge settles on it")
        check(SidebarWidth.layout(proposed: std + 16).width == std + 16, "past the detent the edge follows the pointer again")
        check(SidebarWidth.layout(proposed: 2000) == L(iconsOnly: false, width: hi), "the edge stops at the widest width")
        check(SidebarWidth.layout(proposed: lo - 30) == L(iconsOnly: false, width: lo), "short of the snap point the edge stops at the narrowest width with titles")
        check(SidebarWidth.layout(proposed: SidebarWidth.snap) == L(iconsOnly: false, width: lo)
              && SidebarWidth.layout(proposed: SidebarWidth.snap - 1) == L(iconsOnly: true, width: icons),
              "the edge snaps to icons halfway between the icon column and the narrowest width",
              "snap at \(SidebarWidth.snap) pt")
        check(SidebarWidth.layout(proposed: -50) == L(iconsOnly: true, width: icons), "dragging past the window's edge stays on icons")

        var p = BrowserPrefsValue()
        check(SidebarWidth.saved(p) == L(iconsOnly: false, width: std), "a new profile starts at the default width with titles")
        p.sidebarWidth = 9999
        check(SidebarWidth.saved(p).width == hi, "a saved width past the widest opens at the widest")
        p.sidebarWidth = 10
        check(SidebarWidth.saved(p).width == lo, "a saved width under the narrowest opens at the narrowest")
        p.sidebarIconsOnly = true
        check(SidebarWidth.saved(p) == L(iconsOnly: true, width: icons), "icons only opens as the icon column")
    }

    /// The icon column's Essentials: the box grows after the pointer rests, stays open while the
    /// pointer moves from the column onto the grown box, and shrinks after it leaves both.
    @MainActor
    static func essentialsBloom() {
        // Its own instance: a window an earlier test left open can drop an icon column at any
        // moment, and that closes the shared box.
        let b = EssentialsBloom()
        b.hover(column: true)
        check(!b.isOpen, "passing over the column's Essentials doesn't grow the box at once")
        _ = SelfTest.spin(1) { b.isOpen }
        check(b.isOpen, "resting on them grows it")
        b.hover(column: false)
        b.hover(grid: true)
        _ = SelfTest.spin(Motion.Timing.concealDelay + 0.2) { !b.isOpen }
        check(b.isOpen, "moving from the column onto the grown box keeps it open")
        b.hover(grid: false)
        check(b.isOpen, "it lingers a moment after the pointer leaves")
        _ = SelfTest.spin(1) { !b.isOpen }
        check(!b.isOpen, "then it shrinks back")
        b.hover(column: true)
        b.hover(column: false)
        _ = SelfTest.spin(Motion.Timing.revealDwell + 0.2) { b.isOpen }
        check(!b.isOpen, "a pointer that only passes through never opens it")
        b.hover(column: true)
        _ = SelfTest.spin(1) { b.isOpen }
        check(b.isShown && b.isOpen, "the copy over the page is up while the box is grown")
        b.close()
        _ = SelfTest.spin(1) { !b.isShown }
        check(!b.isOpen && !b.isShown, "picking a tile shrinks the box and hands it back to the column")
        b.reset()
    }

    /// The icon column's box grows sideways only: the same height at rest and grown, and the
    /// first three tiles in one column where they always are.
    @MainActor
    static func columnBox() {
        let e = IconEssentials.self
        check(e.height(8) == e.height(3) && e.height(2) < e.height(3), "the box is three tiles tall whether it's at rest or grown")
        check(e.openWidth(3) == e.boxWidth && e.openWidth(4) > e.boxWidth && e.openWidth(7) > e.openWidth(6),
              "it grows a column per three Essentials, and not at all with three")
        check((0..<3).allSatisfy { e.origin($0).x == e.pad } && e.origin(3).x > e.pad && e.origin(3).y == e.origin(0).y,
              "the first three keep their column, and the fourth starts the next one at the top")
        check(e.tileWidth + 2 * e.pad == e.boxWidth && e.boxWidth == Theme.Space.sidebarIconWidth - 2 * Theme.Space.sidebarInset,
              "at rest the box fills the column between its insets")
    }

    /// The three ways to show tabs, as the right-click menu lists them.
    @MainActor
    static func tabModes() {
        var p = BrowserPrefsValue()
        check(TabMode.of(p) == .sidebar, "a new profile shows the sidebar")
        p.sidebarIconsOnly = true
        check(TabMode.of(p) == .icons, "icons only is its own mode")
        p.sidebarHidden = true
        check(TabMode.of(p) == .sidebar, "compact mode's floating sidebar has titles, so it counts as the sidebar")
        p.tabLayout = .horizontal
        check(TabMode.of(p) == .bar, "the tab bar wins over the sidebar's own settings")

        let before = BrowserPrefs.shared.value
        BrowserPrefs.shared.update { $0.tabLayout = .horizontal; $0.sidebarIconsOnly = false; $0.sidebarHidden = true }
        TabMode.set(.icons)
        let v = BrowserPrefs.shared.value
        check(v.tabLayout == .sidebar && v.sidebarIconsOnly && !v.sidebarHidden && TabMode.current == .icons,
              "picking icons from the tab bar brings back the sidebar as the icon column")
        TabMode.set(.sidebar)
        check(TabMode.current == .sidebar && !BrowserPrefs.shared.value.sidebarIconsOnly, "picking the sidebar brings titles back")
        TabMode.set(.bar)
        check(TabMode.current == .bar, "picking the tab bar moves tabs to the top")
        BrowserPrefs.shared.update { $0 = before }
    }

    /// Hover cards wait the first time, then follow the pointer from icon to icon at once.
    @MainActor
    static func hoverCards() {
        let c = HoverCards.shared
        c.hide()
        _ = SelfTest.spin(HoverCards.warm + 0.1) { false }
        func item(_ id: String) -> HoverCardItem {
            HoverCardItem(id: id, title: id, detail: nil, frame: .zero, bounds: .zero, side: .trailing)
        }
        c.enter(item("a"))
        check(c.item == nil, "a card doesn't show the moment the pointer arrives")
        _ = SelfTest.spin(1) { c.item != nil }
        check(c.item?.id == AnyHashable("a"), "it shows once the pointer rests")
        c.leave("a")
        c.enter(item("b"))
        check(c.item?.id == AnyHashable("b"), "moving to the next icon swaps the card at once")
        c.leave("b")
        _ = SelfTest.spin(1) { c.item == nil }
        check(c.item == nil, "it goes when the pointer leaves")
        c.enter(item("c"))
        check(c.item?.id == AnyHashable("c"), "coming back to another icon within 300 ms shows its card at once")
        c.leave("c")
        c.enter(item("d"))
        c.leave("d")
        _ = SelfTest.spin(HoverCards.delay + 0.2) { false }
        c.hide()
        _ = SelfTest.spin(HoverCards.warm + 0.1) { false }
        c.enter(item("e"))
        c.leave("e")
        _ = SelfTest.spin(HoverCards.delay + 0.2) { c.item != nil }
        check(c.item == nil, "passing over an icon without resting never shows its card")
    }

    @MainActor
    static func dragging() {
        let r = SidebarResize.shared
        BrowserPrefs.shared.update { $0.sidebarIconsOnly = false; $0.sidebarWidth = 300 }
        check(r.current == .init(iconsOnly: false, width: 300) && !r.isDragging, "the sidebar opens at its saved width")

        r.drag(by: 40)
        check(r.current.width == 340 && BrowserPrefs.shared.value.sidebarWidth == 300, "a drag moves the edge without saving yet")
        r.drag(by: -400)
        check(r.current.iconsOnly, "the same drag carried past the snap point turns to icons")
        r.endDrag()
        check(!r.isDragging && BrowserPrefs.shared.value.sidebarIconsOnly && BrowserPrefs.shared.value.sidebarWidth == 300,
              "letting go on icons saves icons and keeps the width with titles for later")

        r.drag(by: 20)
        check(r.current.iconsOnly, "a short drag out of icons stays on icons")
        r.drag(by: 250)
        check(r.current == .init(iconsOnly: false, width: SidebarWidth.icons + 250), "dragging further brings titles back under the pointer")
        r.endDrag()
        check(BrowserPrefs.shared.value.sidebarWidth == Double(SidebarWidth.icons + 250) && !BrowserPrefs.shared.value.sidebarIconsOnly,
              "letting go with titles saves the width")

        r.setIconsOnly(true)
        check(r.current.iconsOnly, "the menu and command bar turn icons only on")
        r.toggleIconsOnly()
        check(r.current == .init(iconsOnly: false, width: SidebarWidth.icons + 250), "and off again, back at the width from before")
        r.resetWidth()
        check(r.current == .init(iconsOnly: false, width: SidebarWidth.standard), "double-clicking the edge goes back to the default width")
        r.setIconsOnly(true)
        r.resetWidth()
        check(r.current == .init(iconsOnly: false, width: SidebarWidth.standard), "double-clicking the icon column's edge brings titles back at the default width")
    }
}
