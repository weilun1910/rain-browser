import AppKit
import SwiftUI

/// The main window's chrome: no visible title bar, the traffic lights in the sidebar's top row,
/// and the neutral frame colour behind everything.
@MainActor
enum WindowChrome {
    /// An empty toolbar in the compact unified style makes the title bar 40 pt tall and puts the
    /// traffic lights at 12, 13, centred on the sidebar's 40 pt top row. Clicks under the empty
    /// toolbar still reach our views, so the sidebar's buttons there keep working.
    static func configure(_ w: NSWindow) {
        w.styleMask.insert(.fullSizeContentView)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        let bar = NSToolbar(identifier: "BrowserPOC.chrome")
        bar.showsBaselineSeparator = false
        bar.allowsUserCustomization = false
        bar.displayMode = .iconOnly
        w.toolbar = bar
        w.toolbarStyle = .unifiedCompact
        w.titlebarSeparatorStyle = .none
        w.backgroundColor = Theme.Palette.frameNS
        w.isOpaque = true
    }

    /// A debug build run straight from `.build` has no bundle icon, so draw one for the Dock.
    static func setDockIconIfUnbundled() {
        guard Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") == nil else { return }
        let r = ImageRenderer(content: AppIconArt(size: 512))
        r.scale = 1
        if let img = r.nsImage { NSApp.applicationIconImage = img }
    }

    /// Where the close button sits, for tests and for lining things up.
    static func trafficLightsFrame(_ w: NSWindow) -> NSRect? {
        guard let close = w.standardWindowButton(.closeButton), let zoom = w.standardWindowButton(.zoomButton) else { return nil }
        let a = close.convert(close.bounds, to: nil), b = zoom.convert(zoom.bounds, to: nil)
        return a.union(b)
    }
}
