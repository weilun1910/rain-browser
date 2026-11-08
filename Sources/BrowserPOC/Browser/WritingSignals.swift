import Foundation
import WebKit

/// Counts characters Felix types into text areas and editable regions. Only the count leaves
/// the page, never the text. Search boxes, address-like fields and every <input> are ignored.
final class TypingCounter: NSObject, WKScriptMessageHandler {
    static let name = "bpocTyping"

    static let script = """
    (() => {
      if (window.__bpocTyping) return; window.__bpocTyping = true;
      let n = 0;
      const skip = /search|address|url|password|login|email/;
      const writable = (el) => {
        if (!el || el.nodeType !== 1) return false;
        const role = (el.getAttribute('role') || '').toLowerCase();
        if (role === 'combobox' || role === 'searchbox') return false;
        const label = ((el.getAttribute('aria-label') || '') + ' ' + (el.getAttribute('name') || '') + ' ' + (el.getAttribute('placeholder') || '')).toLowerCase();
        if (skip.test(label)) return false;
        if (el.tagName === 'TEXTAREA') return !el.readOnly && !el.disabled;
        if (el.tagName === 'INPUT') return false;
        return el.isContentEditable === true;
      };
      document.addEventListener('keydown', (e) => {
        // Only real keys count. A page could fake keydowns to get itself filed under Notes / Docs.
        if (!e.isTrusted || e.metaKey || e.ctrlKey || !e.key || e.key.length !== 1) return;
        const t = (e.composedPath && e.composedPath()[0]) || e.target;
        if (writable(t) || writable(document.activeElement)) n += 1;
      }, true);
      const flush = () => {
        if (n > 0) { try { window.webkit.messageHandlers.bpocTyping.postMessage(n); } catch (_) {} n = 0; }
      };
      setInterval(flush, 3000);
      window.addEventListener('pagehide', flush);
      document.addEventListener('visibilitychange', () => { if (document.hidden) flush(); });
    })();
    """

    static func install(on controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: .defaultClient))
        controller.add(TypingCounter(), contentWorld: .defaultClient, name: name)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let n = (message.body as? NSNumber)?.intValue, n > 0, n < 100_000,
              let url = message.webView?.url, URLKey.isIndexableWeb(url),
              !Settings.shared.value.isExcluded(host: url.host) else { return }
        let key = WritingKey.key(url)
        Indexer.work.async { IndexStore.shared.addTyping(key: key, chars: n) }
    }
}

extension Tab {
    /// For a Google Doc, Sheet or Slides deck open in this tab: asks Google for the plain export,
    /// from the page itself, with Felix's own session. GET only, once per load.
    func fetchDocsExport(_ done: @escaping @MainActor (String?) -> Void) {
        guard let wv = webView, let u = wv.url, let export = DocsExport.url(for: u) else { done(nil); return }
        wv.callAsyncJavaScript("""
            const r = await fetch(path, { method: 'GET', credentials: 'include' });
            if (!r.ok) return null;
            const t = await r.text();
            return t.slice(0, 20000);
            """, arguments: ["path": export.absoluteString], in: nil, in: .defaultClient) { result in
            MainActor.assumeIsolated {
                if case .success(let v) = result, let s = v as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    done(s)
                } else {
                    done(nil)
                }
            }
        }
    }

    /// "Plan - Google Docs" reads better as "Plan".
    static func cleanDocsTitle(_ t: String) -> String {
        for suffix in [" - Google Docs", " - Google Sheets", " - Google Slides"] where t.hasSuffix(suffix) {
            return String(t.dropLast(suffix.count))
        }
        return t
    }
}
