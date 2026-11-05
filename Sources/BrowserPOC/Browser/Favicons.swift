import AppKit
import SwiftUI
import WebKit

/// Site icons for every place a page shows: sidebar rows, pins, Essentials, folders, split rows,
/// the command bar and Related cards.
///
/// The page's own icon links are read in an isolated script world: `link rel=icon`,
/// `apple-touch-icon`, then the web app manifest's icons, then `/favicon.ico`. Icons are fetched
/// with an ephemeral session (no cookies), drawn into a PNG at the source's own resolution
/// (32 to 128 px, so 16 pt rows stay crisp at 2x), and cached in `favicons/` under the app's
/// support folder by host. `favicons/index.json` remembers which address each icon came from, so a
/// page that changes its icon (an unread badge, a new logo) is fetched again, and icons show at
/// once after a relaunch. A small script reports icon changes while a page is open.
@MainActor
final class Favicons: ObservableObject {
    static let shared = Favicons()
    /// Bumped when an icon arrives, so rows redraw.
    @Published private(set) var generation = 0
    private var memory: [String: NSImage] = [:]
    private var missing: Set<String> = []
    private var inFlight: Set<String> = []
    private var cacheRoot: String?
    /// Host to the address its cached icon came from, and when it was checked.
    private var index: [String: Entry] = [:]
    /// Hosts asked for without a page (Related cards), so each is tried once per session.
    private var probed: Set<String> = []

    struct Entry: Codable { var source: String; var checked: Date }

    static var dir: URL { Paths.root.appendingPathComponent("favicons", isDirectory: true) }
    static var indexFile: URL { dir.appendingPathComponent("index.json") }
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.httpCookieStorage = nil
        c.timeoutIntervalForRequest = 8
        c.urlCache = nil
        return URLSession(configuration: c)
    }()
    nonisolated static let maxBytes = 400_000

    static func key(_ url: URL?) -> String? {
        guard let url, let h = url.host?.lowercased(), !h.isEmpty else { return nil }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    static func file(_ key: String) -> URL { dir.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_") + ".png") }

    private func checkRoot() {
        guard cacheRoot != Paths.root.path else { return }
        memory = [:]; missing = []; probed = []
        cacheRoot = Paths.root.path
        if let d = try? Data(contentsOf: Self.indexFile), let i = try? JSONDecoder.iso.decode([String: Entry].self, from: d) { index = i } else { index = [:] }
    }

    private func saveIndex() {
        Paths.ensure(Self.dir)
        if let d = try? JSONEncoder.pretty.encode(index) { try? d.write(to: Self.indexFile, options: .atomic) }
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

    /// The page's icon links and its manifest, read without touching the page's own scripts.
    static let linksJS = """
    (() => {
      const out = [];
      let manifest = null;
      document.querySelectorAll('link[rel]').forEach(l => {
        const rels = (l.getAttribute('rel') || '').toLowerCase().split(/\\s+/);
        if (rels.includes('manifest')) { manifest = l.href; return; }
        if (rels.some(r => r === 'icon' || r === 'apple-touch-icon' || r === 'apple-touch-icon-precomposed' || r === 'mask-icon'))
          out.push({ href: l.href, rel: rels.join(' '), sizes: l.getAttribute('sizes') || '', type: l.getAttribute('type') || '' });
      });
      return { links: out, manifest: manifest };
    })()
    """

    /// Reports when a page swaps its icon, for live icons like unread counts.
    static let watchJS = """
    (() => {
      if (window.__bpocIcon) return; window.__bpocIcon = true;
      let t = null;
      const ping = () => { clearTimeout(t); t = setTimeout(() => { try { window.webkit.messageHandlers.bpocIcon.postMessage(1); } catch (_) {} }, 1500); };
      const watch = () => {
        if (!document.head) return;
        new MutationObserver(muts => {
          for (const m of muts) {
            const nodes = [m.target, ...m.addedNodes, ...m.removedNodes];
            if (nodes.some(n => n && n.tagName === 'LINK' && /icon/i.test(n.getAttribute('rel') || ''))) { ping(); return; }
          }
        }).observe(document.head, { childList: true, subtree: true, attributes: true, attributeFilter: ['href', 'rel'] });
      };
      if (document.head) watch(); else document.addEventListener('DOMContentLoaded', watch);
    })();
    """

    static func install(on controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: watchJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: MediaWatch.world))
        controller.add(IconWatch.shared, contentWorld: MediaWatch.world, name: "bpocIcon")
    }

    /// Reads the page's icon once it has loaded. A host whose icon came from the same address in
    /// the last day is left alone. `force` checks again, for a page that changed its icon.
    func capture(from tab: Tab, force: Bool = false) {
        checkRoot()
        guard let wv = tab.webView, let u = wv.url, URLKey.isIndexableWeb(u), let k = Self.key(u) else { return }
        if inFlight.contains(k) { return }
        inFlight.insert(k)
        wv.evaluateJavaScript(Self.linksJS, in: nil, in: .defaultClient) { [weak self] r in
            MainActor.assumeIsolated {
                guard let self else { return }
                var links: [[String: Any]] = []
                var manifest: URL?
                if case .success(let v) = r, let d = v as? [String: Any] {
                    links = (d["links"] as? [[String: Any]]) ?? []
                    manifest = (d["manifest"] as? String).flatMap(URL.init(string:))
                }
                let candidates = Self.rank(links.map(Self.candidate), page: u)
                if !force, let best = candidates.first, let e = self.index[k], e.source == best.url.absoluteString,
                   Date().timeIntervalSince(e.checked) < 86400, FileManager.default.fileExists(atPath: Self.file(k).path) {
                    self.inFlight.remove(k)
                    _ = self.image(for: u)
                    return
                }
                let hasLinks = links.contains { l in let rel = (l["rel"] as? String) ?? ""; return rel.contains("icon") && !rel.contains("mask") }
                if let manifest, !hasLinks {
                    // Pages without icon links get the manifest's icons, then /favicon.ico.
                    self.manifestIcons(manifest) { extra in self.fetch(Self.rank(extra, page: u), key: k) }
                } else {
                    self.fetch(candidates, key: k)
                }
            }
        }
    }

    /// For places with no page open, like a Related card for something read in Chrome: asks the
    /// site for /favicon.ico once, cookie-free. Hosts on the excluded list are skipped.
    func ensure(_ url: URL?) {
        checkRoot()
        // The tests run on throwaway stores and stay off the network.
        guard !BrowserModel.useEphemeralStore else { return }
        guard let url, url.scheme == "https", let k = Self.key(url), memory[k] == nil, !probed.contains(k), !inFlight.contains(k),
              !Settings.shared.value.isExcluded(host: url.host) else { return }
        if hasIcon(for: url) { return }
        probed.insert(k)
        inFlight.insert(k)
        fetch(Self.rank([], page: url), key: k)
    }

    struct Candidate: Sendable { let url: URL; let rel: String; let type: String; let px: Int? }

    nonisolated static func candidate(_ l: [String: Any]) -> Candidate? {
        guard let href = l["href"] as? String, let u = URL(string: href) else { return nil }
        let sizes = ((l["sizes"] as? String) ?? "").lowercased()
        let px = sizes.split(separator: " ").compactMap { $0.split(separator: "x").first.flatMap { Int($0) } }.max()
        return Candidate(url: u, rel: (l["rel"] as? String) ?? "", type: ((l["type"] as? String) ?? "").lowercased(), px: sizes == "any" ? 512 : px)
    }

    /// Best first. The target is 32 px, a 16 pt row at 2x: the smallest icon at least that big
    /// wins, then bigger ones, then smaller ones. Touch icons come after sized icons, SVG and mask
    /// icons last, and /favicon.ico closes the list.
    static func rank(_ list: [Candidate?], page: URL) -> [Candidate] {
        func score(_ c: Candidate) -> Int {
            if c.rel.contains("mask-icon") { return -1000 }
            var s = 0
            let svg = c.type.contains("svg") || c.url.path.lowercased().hasSuffix(".svg")
            if svg { s -= 200 }
            if c.rel.contains("apple-touch-icon") { s -= 20 }
            if let px = c.px {
                s += px >= 32 ? 100 - min(90, (px - 32) / 4) : px
            } else {
                s += 40
            }
            return s
        }
        var out = list.compactMap { $0 }.filter { ["http", "https", "data"].contains($0.url.scheme?.lowercased() ?? "") }.sorted { score($0) > score($1) }
        if let scheme = page.scheme, let host = page.host, let ico = URL(string: "\(scheme)://\(host)/favicon.ico"), !out.contains(where: { $0.url == ico }) {
            out.append(Candidate(url: ico, rel: "icon", type: "image/x-icon", px: nil))
        }
        return out
    }

    /// The icons a web app manifest lists, with their sizes, resolved against the manifest.
    private func manifestIcons(_ manifest: URL, _ done: @escaping @MainActor ([Candidate?]) -> Void) {
        Self.session.dataTask(with: manifest) { data, _, _ in
            var out: [Candidate?] = []
            if let data, data.count < 200_000, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let icons = json["icons"] as? [[String: Any]] {
                for i in icons {
                    guard let src = i["src"] as? String, let u = URL(string: src, relativeTo: manifest)?.absoluteURL else { continue }
                    if ((i["purpose"] as? String) ?? "").contains("monochrome") { continue }
                    out.append(Favicons.candidate(["href": u.absoluteString, "rel": "icon", "sizes": i["sizes"] ?? "", "type": i["type"] ?? ""]))
                }
            }
            Task { @MainActor in done(out) }
        }.resume()
    }

    private func fetch(_ list: [Candidate], key: String) {
        guard let first = list.first else { inFlight.remove(key); return }
        let rest = Array(list.dropFirst())
        // Tests only read icons embedded in the page.
        if BrowserModel.useEphemeralStore && first.url.scheme != "data" { fetch(rest, key: key); return }
        Self.session.dataTask(with: first.url) { data, response, _ in
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? (data != nil)
            let bytes = ok && (data?.count ?? 0) < Self.maxBytes ? data : nil
            Task { @MainActor in
                if let bytes, let png = Self.normalized(bytes) {
                    Paths.ensure(Self.dir)
                    try? png.write(to: Self.file(key), options: .atomic)
                    self.memory[key] = NSImage(data: png)
                    self.missing.remove(key)
                    self.inFlight.remove(key)
                    self.index[key] = Entry(source: first.url.absoluteString, checked: Date())
                    self.saveIndex()
                    self.generation += 1
                } else {
                    self.fetch(rest, key: key)
                }
            }
        }.resume()
    }

    /// Any image AppKit can read, drawn into a square PNG at its own resolution, 32 to 128 px.
    static func normalized(_ data: Data) -> Data? {
        guard let img = NSImage(data: data), img.size.width > 0, img.size.height > 0 else { return nil }
        let natural = img.representations.map { max($0.pixelsWide, $0.pixelsHigh) }.filter { $0 > 0 }.max() ?? Int(max(img.size.width, img.size.height))
        let side = min(128, max(32, natural))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        img.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// The letter a site's monogram shows: the first letter of its name, without www or a subdomain
    /// like docs. or mail.
    static func monogram(_ url: URL?) -> String {
        guard let h = key(url) else { return "" }
        let parts = h.split(separator: ".").map(String.init)
        var at = max(0, parts.count - 2)
        // bbc.co.uk is "B", not "C".
        if parts.count >= 3, parts[parts.count - 1].count == 2, ["co", "com", "org", "net", "ac", "gov", "edu"].contains(parts[parts.count - 2]) { at = parts.count - 3 }
        let name = parts.isEmpty ? h : parts[at]
        return name.first.map { String($0).uppercased() } ?? ""
    }
}

/// Hears icon changes from pages and asks for the new icon.
@MainActor
final class IconWatch: NSObject, WKScriptMessageHandler {
    static let shared = IconWatch()
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let wv = message.webView, let t = MediaWatch.shared.tab(for: wv) else { return }
        Favicons.shared.capture(from: t, force: true)
    }
}

/// A site's icon, or a quiet monogram for a site without one. `fetch` asks the site for its icon
/// when nothing is cached yet, for pages that aren't open (Related cards).
struct FaviconView: View {
    let url: URL?
    var fallback: String = "globe"
    var size: CGFloat = 14
    var fetch = false
    @ObservedObject private var icons = Favicons.shared

    var body: some View {
        let _ = icons.generation
        // The look (rounding, the backing for dark icons, the monogram and the fade-in) is the
        // theme's FaviconImage. This view supplies the image.
        let letter = Favicons.monogram(url)
        FaviconImage(image: icons.image(for: url), size: size,
                     fallback: letter.isEmpty ? .symbol(fallback) : .monogram(letter))
            .onAppear { if fetch { icons.ensure(url) } }
    }
}

/// The icon for a Related card: the site's favicon for pages, its own symbol for notes.
struct SourceIcon: View {
    let url: String
    let isPage: Bool
    let symbol: String
    var size: CGFloat = 15
    var body: some View {
        if isPage, let u = URL(string: url), Favicons.key(u) != nil {
            FaviconView(url: u, fallback: symbol, size: size, fetch: true)
        } else {
            Image(systemName: symbol).font(.system(size: size * 0.75)).foregroundStyle(.secondary).frame(width: size, height: size)
        }
    }
}

/// A letter for sites with no icon, drawn by the theme's FaviconImage.
struct Monogram: View {
    let letter: String
    let size: CGFloat
    var body: some View {
        FaviconImage(image: nil, size: size, fallback: .monogram(letter))
    }
}
