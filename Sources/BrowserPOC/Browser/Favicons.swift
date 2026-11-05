import AppKit
import SwiftUI
import WebKit

/// Site icons for the sidebar, Essentials and the command bar. The page's own icon links are read
/// in an isolated script world, the icon is fetched with an ephemeral session (no cookies), and a
/// 64 pt PNG is cached in `favicons/` by host.
@MainActor
final class Favicons: ObservableObject {
    static let shared = Favicons()
    /// Bumped when an icon arrives, so rows redraw.
    @Published private(set) var generation = 0
    private var memory: [String: NSImage] = [:]
    private var missing: Set<String> = []
    private var inFlight: Set<String> = []
    private var cacheRoot: String?

    static var dir: URL { Paths.root.appendingPathComponent("favicons", isDirectory: true) }
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 8
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    static func key(_ url: URL?) -> String? {
        guard let url, let h = url.host?.lowercased(), !h.isEmpty else { return nil }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    static func file(_ key: String) -> URL { dir.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_") + ".png") }

    private func checkRoot() {
        if cacheRoot != Paths.root.path { memory = [:]; missing = []; cacheRoot = Paths.root.path }
    }

    func image(for url: URL?) -> NSImage? {
        checkRoot()
        guard let k = Self.key(url) else { return nil }
        if let i = memory[k] { return i }
        if missing.contains(k) { return nil }
        if let i = NSImage(contentsOf: Self.file(k)) { memory[k] = i; return i }
        missing.insert(k)
        return nil
    }

    func hasIcon(for url: URL?) -> Bool { image(for: url) != nil }

    static let linksJS = """
    (() => {
      const out = [];
      document.querySelectorAll('link[rel]').forEach(l => {
        const rel = (l.getAttribute('rel') || '').toLowerCase();
        if (rel.split(/\\s+/).some(r => r === 'icon' || r === 'apple-touch-icon' || r === 'shortcut' || r === 'mask-icon'))
          out.push({ href: l.href, rel: rel, sizes: l.getAttribute('sizes') || '', type: l.getAttribute('type') || '' });
      });
      return out;
    })()
    """

    /// Looks for the page's icon once it has loaded, unless the host already has one.
    func capture(from tab: Tab) {
        checkRoot()
        guard let wv = tab.webView, let u = wv.url, URLKey.isIndexableWeb(u), let k = Self.key(u) else { return }
        if memory[k] != nil || inFlight.contains(k) { return }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: Self.file(k).path), let d = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(d) < 7 * 86400 {
            _ = image(for: u)
            return
        }
        inFlight.insert(k)
        wv.evaluateJavaScript(Self.linksJS, in: nil, in: .defaultClient) { [weak self] r in
            MainActor.assumeIsolated {
                var links: [[String: Any]] = []
                if case .success(let v) = r, let a = v as? [[String: Any]] { links = a }
                let candidates = Self.rank(links, page: u)
                self?.fetch(candidates, key: k)
            }
        }
    }

    /// Best first: sized PNG or ICO icons near 64 pt, then touch icons, then SVG, then /favicon.ico.
    static func rank(_ links: [[String: Any]], page: URL) -> [URL] {
        func score(_ l: [String: Any]) -> Int {
            let rel = (l["rel"] as? String) ?? ""
            let type = ((l["type"] as? String) ?? "").lowercased()
            let href = ((l["href"] as? String) ?? "").lowercased()
            let sizes = ((l["sizes"] as? String) ?? "").lowercased()
            var s = 0
            if rel.contains("mask-icon") { return -100 }
            if type.contains("svg") || href.hasSuffix(".svg") { s -= 30 }
            if rel.contains("apple-touch-icon") { s += 10 }
            if let px = sizes.split(separator: "x").first.flatMap({ Int($0) }) { s += px >= 32 ? 40 - abs(px - 64) / 8 : px / 2 } else { s += 15 }
            return s
        }
        var out = links.sorted { score($0) > score($1) }.compactMap { ($0["href"] as? String).flatMap(URL.init(string:)) }
        if let scheme = page.scheme, let host = page.host, let ico = URL(string: "\(scheme)://\(host)/favicon.ico") { out.append(ico) }
        return out
    }

    private func fetch(_ urls: [URL], key: String) {
        guard let first = urls.first else { inFlight.remove(key); return }
        let rest = Array(urls.dropFirst())
        Self.session.dataTask(with: first) { data, response, _ in
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? (data != nil)
            let bytes = ok && (data?.count ?? 0) < 400_000 ? data : nil
            Task { @MainActor in
                if let bytes, let png = Self.normalized(bytes) {
                    Paths.ensure(Self.dir)
                    try? png.write(to: Self.file(key), options: .atomic)
                    self.memory[key] = NSImage(data: png)
                    self.missing.remove(key)
                    self.inFlight.remove(key)
                    self.generation += 1
                } else {
                    self.fetch(rest, key: key)
                }
            }
        }.resume()
    }

    /// Any image WebKit or AppKit can read, drawn into a 64 pt square PNG.
    static func normalized(_ data: Data) -> Data? {
        guard let img = NSImage(data: data), img.size.width > 0, img.size.height > 0 else { return nil }
        let side = 64
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        img.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

/// A site's icon, or a quiet symbol until one arrives.
struct FaviconView: View {
    let url: URL?
    var fallback: String = "globe"
    var size: CGFloat = 14
    @ObservedObject private var icons = Favicons.shared

    var body: some View {
        let _ = icons.generation
        if let img = icons.image(for: url) {
            Image(nsImage: img).resizable().interpolation(.high).frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
        } else {
            Image(systemName: fallback).font(.system(size: size * 0.8)).foregroundStyle(.secondary).frame(width: size, height: size)
        }
    }
}
