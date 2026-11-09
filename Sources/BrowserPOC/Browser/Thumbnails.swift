import AppKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

// Card-size pictures of the top of each page, for the folder popup. The top of a page is on
// screen right after it loads, so about a second after a page finishes Rain checks it's still at
// the top and takes a snapshot of the web view at card size. It's kept in memory on the tab, and
// written to the profile's Thumbnails folder when the page is saved and whenever a saved page is
// visited. A page Rain has never shown gets its share image (og:image), fetched without cookies
// the way the indexer fetches text, in the background and one at a time. Nothing ever renders a
// page just to make a thumbnail.

@MainActor
final class Thumbnails {
    static let shared = Thumbnails()

    /// The snapshot's width in points, about 480 px on a card.
    nonisolated static let width: CGFloat = 480
    /// Cards are 16:10.
    nonisolated static let aspect: CGFloat = 10.0 / 16.0
    /// How far down a page can be and still count as the top.
    nonisolated static let topSlack: Double = 8
    /// The wait after a page finishes, so late images and fonts land.
    nonisolated(unsafe) static var delay: TimeInterval = 1.0

    nonisolated static var dir: URL { Paths.root.appendingPathComponent("Thumbnails", isDirectory: true) }
    nonisolated static func file(for page: URL) -> URL { dir.appendingPathComponent(PageHash.of(page) + ".jpg") }
    nonisolated static func exists(for page: URL) -> Bool { FileManager.default.fileExists(atPath: file(for: page).path) }

    /// Pages, files and the demo's pages. Not notes, not the app's own pages.
    static func capturable(_ url: URL) -> Bool {
        ["http", "https", "file", DemoScheme.scheme].contains(url.scheme?.lowercased() ?? "")
    }

    // MARK: Capture

    private var work: [UUID: DispatchWorkItem] = [:]

    /// A second after a page finishes. A page that finished off screen waits until it's shown.
    func pageFinished(_ tab: Tab, visible: Bool) {
        cancel(tab)
        guard let u = tab.webView?.url, Self.capturable(u) else { tab.thumbnailPending = false; return }
        if visible { schedule(tab) } else { tab.thumbnailPending = true }
    }

    /// The tab came on screen. If it finished loading while hidden, capture it now, if it's
    /// still at the top.
    func tabShown(_ tab: Tab) {
        guard tab.thumbnailPending else { return }
        tab.thumbnailPending = false
        schedule(tab)
    }

    func cancel(_ tab: Tab) {
        work[tab.id]?.cancel()
        work[tab.id] = nil
    }

    func schedule(_ tab: Tab, after wait: TimeInterval? = nil) {
        let delay = wait ?? Self.delay
        cancel(tab)
        let w = DispatchWorkItem { [weak self, weak tab] in
            MainActor.assumeIsolated {
                guard let self, let tab else { return }
                self.work[tab.id] = nil
                self.capture(tab)
            }
        }
        work[tab.id] = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    /// Takes the snapshot if the tab is on screen and its page is at the top. Calls back with
    /// whether it took one.
    func capture(_ tab: Tab, completion: (@MainActor (Bool) -> Void)? = nil) {
        guard let wv = tab.webView, let url = wv.url, Self.capturable(url), wv.window != nil,
              tab.model?.isVisible(tab) == true, wv.bounds.width > 60, wv.bounds.height > 60 else { completion?(false); return }
        wv.evaluateJavaScript("window.scrollY", in: nil, in: .defaultClient) { [weak self, weak tab] result in
            MainActor.assumeIsolated {
                guard let self, let tab, case .success(let v) = result, let y = (v as? NSNumber)?.doubleValue, y <= Self.topSlack,
                      tab.webView === wv, wv.url == url else { completion?(false); return }
                let cfg = WKSnapshotConfiguration()
                let w = wv.bounds.width
                let h = min(wv.bounds.height, (w * Self.aspect).rounded())
                cfg.rect = CGRect(x: 0, y: wv.isFlipped ? 0 : wv.bounds.height - h, width: w, height: h)
                cfg.snapshotWidth = NSNumber(value: Double(min(Self.width, w)))
                wv.takeSnapshot(with: cfg) { image, _ in
                    MainActor.assumeIsolated {
                        guard let image, wv.url == url, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                              let jpeg = Self.jpeg(cg, maxWidth: Int(Self.width)) else { completion?(false); return }
                        tab.thumbnail = jpeg
                        tab.thumbnailKey = URLKey.key(for: url)
                        // A saved page's picture is refreshed each time it's visited.
                        if tab.savedFile != nil || SavedPages.shared.isSaved(url) { self.write(jpeg, for: url) }
                        completion?(true)
                    }
                }
            }
        }
    }

    /// The page was just saved: its picture goes to disk now, or is taken if it hasn't been yet.
    func pageSaved(_ tab: Tab, url: URL) {
        if let jpeg = tab.thumbnail, tab.thumbnailKey == URLKey.key(for: url) {
            write(jpeg, for: url)
        } else if tab.model?.isVisible(tab) == true {
            capture(tab)
        }
    }

    /// Writes the JPEG in the background, and tells the cards it's there.
    func write(_ jpeg: Data, for page: URL) {
        let target = Self.file(for: page)
        let key = URLKey.key(for: page)
        DispatchQueue.global(qos: .utility).async {
            Paths.ensure(target.deletingLastPathComponent())
            guard (try? jpeg.write(to: target, options: .atomic)) != nil else { return }
            DispatchQueue.main.async {
                ThumbnailCache.shared.forget(page)
                NotificationCenter.default.post(name: .thumbnailSaved, object: key)
            }
        }
    }

    /// A JPEG at most `maxWidth` pixels wide. Kept on the tab like this, it's a few tens of KB
    /// instead of megabytes of pixels.
    nonisolated static func jpeg(_ image: CGImage, maxWidth: Int) -> Data? {
        var img = image
        if image.width > maxWidth {
            let w = maxWidth, h = max(1, Int((Double(image.height) * Double(maxWidth) / Double(image.width)).rounded()))
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let small = ctx.makeImage() else { return nil }
            img = small
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // MARK: Share images

    /// Pages asked for this run, so a page with no share image isn't fetched again and again.
    private var asked: Set<String> = []
    private var queue: [URL] = []
    private var running = false
    /// Between two fetches, so a big folder doesn't flood anyone's server.
    static let fetchGap: TimeInterval = 1.5
    /// The self test turns fetching off and checks the rules alone.
    nonisolated(unsafe) static var fetchesShareImages = true

    enum ShareDecision: Equatable { case fetch, skip(String) }

    /// The same rules as the indexer's cookie-free fetch: http only, no excluded domain, nothing
    /// that looks like a sign-in, a token or a logged-in app. How often you visited doesn't count.
    nonisolated static func decision(_ url: URL, settings: AppSettings = Settings.shared.value) -> ShareDecision {
        if settings.isExcluded(host: url.host) { return .skip("excluded domain") }
        if case .skip(let why) = URLFilter.fetchDecision(url, visitCount: 99) { return .skip(why) }
        return .fetch
    }

    /// A saved page with no picture yet asks for its share image. Rain fetches it later, in the
    /// background, one at a time.
    func wantShareImage(for page: URL) {
        guard Self.fetchesShareImages, Self.decision(page) == .fetch, !Self.exists(for: page) else { return }
        let key = URLKey.key(for: page)
        guard asked.insert(key).inserted else { return }
        queue.append(page)
        runQueue()
    }

    private func runQueue() {
        guard !running, !queue.isEmpty else { return }
        running = true
        let page = queue.removeFirst()
        Task.detached(priority: .utility) {
            if let image = await Self.fetchShareImage(page), let jpeg = Self.jpeg(image, maxWidth: Int(Self.width)) {
                let target = Self.file(for: page)
                Paths.ensure(target.deletingLastPathComponent())
                if (try? jpeg.write(to: target, options: .atomic)) != nil {
                    let key = URLKey.key(for: page)
                    await MainActor.run {
                        ThumbnailCache.shared.forget(page)
                        NotificationCenter.default.post(name: .thumbnailSaved, object: key)
                    }
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(Self.fetchGap * 1_000_000_000))
            await MainActor.run {
                self.running = false
                self.runQueue()
            }
        }
    }

    /// The page's og:image or twitter:image, resolved against the page.
    nonisolated static func shareImageURL(in html: String, page: URL) -> URL? {
        let head = String(html.prefix(300_000))
        let pattern = #"<meta\s+[^>]*>"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        var found: [String: String] = [:]
        for m in re.matches(in: head, range: NSRange(head.startIndex..., in: head)) {
            guard let r = Range(m.range, in: head) else { continue }
            let tag = String(head[r])
            func attr(_ name: String) -> String? {
                guard let ar = try? NSRegularExpression(pattern: "\(name)\\s*=\\s*([\"'])(.*?)\\1", options: [.caseInsensitive]),
                      let am = ar.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)), let vr = Range(am.range(at: 2), in: tag) else { return nil }
                return String(tag[vr])
            }
            guard let key = (attr("property") ?? attr("name"))?.lowercased(), let content = attr("content"), !content.isEmpty else { continue }
            if ["og:image", "og:image:url", "og:image:secure_url", "twitter:image", "twitter:image:src"].contains(key), found[key] == nil {
                found[key] = content.replacingOccurrences(of: "&amp;", with: "&")
            }
        }
        for k in ["og:image:secure_url", "og:image", "og:image:url", "twitter:image", "twitter:image:src"] {
            if let s = found[k], let u = URL(string: s, relativeTo: page)?.absoluteURL, ["http", "https"].contains(u.scheme?.lowercased() ?? "") { return u }
        }
        return nil
    }

    /// Fetches the page without cookies, finds its share image, fetches that and shrinks it to
    /// card size. Nil if anything along the way says no.
    nonisolated static func fetchShareImage(_ page: URL) async -> CGImage? {
        guard decision(page) == .fetch else { return nil }
        let session = ChromeFetcher.makeSession(delegate: ChromeFetcher())
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: page)
        req.httpShouldHandleCookies = false
        req.timeoutInterval = 10
        guard let (data, resp) = try? await session.data(for: req), let http = resp as? HTTPURLResponse, http.statusCode == 200,
              (http.mimeType ?? "").lowercased().contains("html"), data.count < 3_000_000 else { return nil }
        let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        guard let imageURL = shareImageURL(in: html, page: http.url ?? page), decision(imageURL) == .fetch else { return nil }
        var ireq = URLRequest(url: imageURL)
        ireq.httpShouldHandleCookies = false
        ireq.timeoutInterval = 10
        ireq.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (idata, iresp) = try? await session.data(for: ireq), let ih = iresp as? HTTPURLResponse, ih.statusCode == 200,
              (ih.mimeType ?? "").lowercased().hasPrefix("image/"), idata.count < 8_000_000 else { return nil }
        return ThumbnailCache.downsample(idata, maxPixels: Int(width * 2))
    }
}

extension Notification.Name {
    /// A page's picture landed on disk. The object is the page's normalized address.
    static let thumbnailSaved = Notification.Name("local.browserpoc.thumbnailSaved")
}

/// Pictures for the grid, read from disk and shrunk to card size with ImageIO, kept in an NSCache.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, CGImage>()

    init() { cache.countLimit = 300 }

    func forget(_ page: URL) { cache.removeObject(forKey: URLKey.key(for: page) as NSString) }
    func forgetAll() { cache.removeAllObjects() }

    func cached(_ page: URL) -> CGImage? { cache.object(forKey: URLKey.key(for: page) as NSString) }

    /// The page's picture at about `pixels` wide, from the cache or the disk. Read off the main thread.
    func image(for page: URL, pixels: Int) async -> CGImage? {
        let key = URLKey.key(for: page) as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let file = Thumbnails.file(for: page)
        let img: CGImage? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: file) else { return nil }
            return ThumbnailCache.downsample(data, maxPixels: pixels)
        }.value
        if let img { cache.setObject(img, forKey: key) }
        return img
    }

    static func downsample(_ data: Data, maxPixels: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
