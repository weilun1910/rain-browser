import AppKit
import ImageIO
import WebKit

/// `--thumbnail-check [page.html]`: loads a local test page in a window offscreen, on a throwaway
/// profile, and checks the thumbnail comes from the top of the page, that nothing is captured
/// once the page has scrolled, and that a page loaded in a background tab waits until it's shown.
/// The page has a red band across its top and blue below it. Without a page it writes its own.
@MainActor
enum ThumbnailCheck {
    static let page = """
    <!doctype html><html><head><meta charset="utf-8"><title>Thumbnail test page</title>
    <style>html,body{margin:0;background:#2050e0}#top{height:900px;background:#e03020;color:#fff;font:600 48px -apple-system;padding:40px}
    #rest{height:4000px}</style></head>
    <body><div id="top">The top of the page</div><div id="rest"></div></body></html>
    """

    static func commandLine(_ args: [String]) -> Int32 {
        let given = args.firstIndex(of: "--thumbnail-check").flatMap { $0 + 1 < args.count && !args[$0 + 1].hasPrefix("--") ? args[$0 + 1] : nil }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("BrowserPOC-thumbnail-check-\(UUID().uuidString)", isDirectory: true)
        Paths.ensure(tmp)
        defer { try? fm.removeItem(at: tmp) }
        var pageURL: URL
        if let given {
            pageURL = URL(fileURLWithPath: (given as NSString).expandingTildeInPath)
            if !fm.fileExists(atPath: pageURL.path) {
                // Writes the test page there, so the check can be rerun on the same file.
                Paths.ensure(pageURL.deletingLastPathComponent())
                try? Data(page.utf8).write(to: pageURL)
            }
        } else {
            pageURL = tmp.appendingPathComponent("thumbnail-test.html")
            try? Data(page.utf8).write(to: pageURL)
        }
        Paths.overrideRoot = tmp
        Settings.shared.reloadFromDisk()
        BrowserPrefs.shared.reload()
        RelatedPrefs.shared.reload()
        RelatedPrefs.shared.update { $0.shelfHidden = true }
        Settings.shared.update { $0.firstRunDone = true }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        guard let store = try? IndexStore(url: tmp.appendingPathComponent("index.sqlite")) else { print("Couldn't open an index"); return 1 }
        IndexStore.shared = store
        BrowserModel.useEphemeralStore = true
        BrowserModel.keepPaintingWhenHidden = true
        Motion.forceReduce = true
        MotionSuppression.set(.launch, true)
        SidebarResize.headless = true
        SpaceFolders.enabled = true
        SpaceFolders.overrideRoot = tmp.appendingPathComponent("Space Folders", isDirectory: true)
        let model = BrowserModel()
        let window = SmokeTest.offscreenWindow(MainView.host(model), size: NSSize(width: 1280, height: 820))
        WindowChrome.configure(window)
        var failed = 0
        func check(_ ok: Bool, _ label: String, _ detail: String = "") {
            print("  \(ok ? "ok  " : "FAIL") \(label)\(detail.isEmpty ? "" : " (\(detail))")")
            if !ok { failed += 1 }
        }
        func wait(_ s: Double, _ done: () -> Bool = { false }) -> Bool { SmokeTest.wait(s, until: done) }

        print("Checking thumbnails on \(pageURL.lastPathComponent)")
        let t = model.newTab(url: pageURL, select: true)
        _ = wait(10) { t.webView?.url != nil && !(t.webView?.isLoading ?? true) }
        check(wait(Thumbnails.delay + 4) { t.thumbnail != nil }, "a page on screen gets a thumbnail about a second after it loads")
        let top = t.thumbnail.flatMap { colour(of: $0, x: 0.5, y: 0.3) }
        check(top.map(isRed) == true, "the thumbnail shows the top of the page", top.map(describe) ?? "no picture")
        check(t.thumbnail.flatMap(size).map { $0.width <= Int(Thumbnails.width) && abs(Double($0.height) / Double($0.width) - Thumbnails.aspect) < 0.03 } == true,
              "it's card size, 16:10", t.thumbnail.flatMap(size).map { "\($0.width)x\($0.height)" } ?? "")

        // Saving writes it to the profile's Thumbnails folder, named from the page's address.
        if let dir = model.currentSpace.flatMap({ model.ensureSpaceFolder($0.id) }), model.savePage(t, in: dir) != nil {
            let file = Thumbnails.file(for: pageURL)
            check(wait(3) { fm.fileExists(atPath: file.path) }, "saving the page writes its thumbnail to disk", file.lastPathComponent)
            let saved = (try? Data(contentsOf: file)).flatMap { colour(of: $0, x: 0.5, y: 0.3) }
            check(saved.map(isRed) == true, "the saved thumbnail is the top of the page", saved.map(describe) ?? "none")
            let before = (try? fm.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date

            // Scrolled down, nothing is captured, and the saved picture stays as it was.
            var scrolled = false
            t.webView?.evaluateJavaScript("window.scrollTo(0, 2400); window.scrollY") { _, _ in scrolled = true }
            _ = wait(3) { scrolled }
            _ = wait(0.5)
            t.thumbnail = nil
            var took: Bool?
            Thumbnails.shared.capture(t) { took = $0 }
            _ = wait(3) { took != nil }
            check(took == false && t.thumbnail == nil, "nothing is captured once the page has scrolled")
            _ = wait(1)
            let after = (try? fm.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
            check(before != nil && before == after, "the saved thumbnail isn't replaced by a scrolled view")
        } else {
            check(false, "the page saves into the space's folder")
        }

        // A page that loads in a background tab waits until it's shown.
        let other = pageURL.deletingLastPathComponent().appendingPathComponent("thumbnail-test-2.html")
        try? Data(page.replacingOccurrences(of: "Thumbnail test page", with: "Second page").utf8).write(to: other)
        let b = model.newTab(url: other, select: false)
        _ = wait(10) { b.webView?.url != nil && !(b.webView?.isLoading ?? true) }
        _ = wait(Thumbnails.delay + 1)
        check(b.thumbnail == nil && b.thumbnailPending, "a page that loads off screen isn't captured yet")
        model.select(b)
        check(wait(Thumbnails.delay + 4) { b.thumbnail != nil }, "it's captured once it's shown, still at the top")
        try? fm.removeItem(at: other)

        print(failed == 0 ? "Thumbnails work." : "\(failed) thumbnail checks failed.")
        window.close()
        return failed == 0 ? 0 : 1
    }

    /// The colour at a point given as a share of the width and height from the top left.
    static func colour(of jpeg: Data, x: Double, y: Double) -> (r: Int, g: Int, b: Int)? {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let w = CGFloat(img.width), h = CGFloat(img.height)
        // Core Graphics counts up from the bottom.
        ctx.draw(img, in: CGRect(x: -w * CGFloat(x), y: -h * CGFloat(1 - y), width: w, height: h))
        return (Int(px[0]), Int(px[1]), Int(px[2]))
    }

    static func size(of jpeg: Data) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return (img.width, img.height)
    }

    static func isRed(_ c: (r: Int, g: Int, b: Int)) -> Bool { c.r > 170 && c.g < 110 && c.b < 110 }
    static func describe(_ c: (r: Int, g: Int, b: Int)) -> String { "rgb \(c.r) \(c.g) \(c.b)" }
}
