import AppKit
import Combine
import WebKit

/// Logins and verification codes from the Passwords app (iCloud Keychain), filled into pages.
///
/// macOS doesn't offer its password AutoFill inside a web view, so Rain does what Orion does. When
/// a login or code field gets focus, a small panel under it offers the Passwords app. Choosing it
/// opens native fields where macOS's own AutoFill works, with Touch ID, and Rain copies what you
/// pick into the page. Rain never writes a password anywhere. Saving new passwords to the
/// Passwords app needs Apple's browser entitlement, which Rain doesn't have yet.
@MainActor
final class PasswordAutoFill: NSObject, WKScriptMessageHandler {
    static let shared = PasswordAutoFill()
    static let name = "rainPasswords"

    enum Kind: String { case username, password, code }

    /// A login or code field that has focus in some frame of some page.
    struct Focus {
        let kind: Kind
        let field: Int
        /// In CSS pixels of the main frame's viewport, when `converted`.
        let rect: CGRect
        let converted: Bool
        let origin: String
        let host: String
        let secure: Bool
        let frame: WKFrameInfo
        weak var webView: WKWebView?

        init?(_ b: [String: Any], frame: WKFrameInfo, webView: WKWebView) {
            guard let k = (b["kind"] as? String).flatMap(Kind.init(rawValue:)), let field = (b["field"] as? NSNumber)?.intValue,
                  let origin = b["origin"] as? String, origin.hasPrefix("https://") || origin.hasPrefix("http://"),
                  let host = b["host"] as? String, !host.isEmpty else { return nil }
            let r = b["rect"] as? [String: Any]
            func n(_ key: String) -> CGFloat { CGFloat((r?[key] as? NSNumber)?.doubleValue ?? 0) }
            kind = k
            self.field = field
            rect = CGRect(x: n("x"), y: n("y"), width: n("w"), height: n("h"))
            converted = (b["converted"] as? Bool) ?? false
            self.origin = origin
            self.host = host
            secure = (b["secure"] as? Bool) ?? false
            self.frame = frame
            self.webView = webView
        }
    }

    /// A login that went into a username-only step, kept in memory for the password step that
    /// usually follows on the same site. Never written anywhere, and gone after three minutes.
    struct Pending {
        let host: String
        let username: String
        let password: String
        let until: Date
    }

    private(set) var current: Focus?
    private var pending: Pending?
    private var openOnNextFocus = false
    private var selectionWatch: AnyCancellable?
    /// The smoke test sees every message the page script posts, with the frame it came from.
    var testHook: ((String, [String: Any], WKFrameInfo, WKWebView) -> Void)?

    /// On macOS 27, a world with WebKit's autofill scripting turned on. Filled fields then get
    /// Safari's AutoFill look and the input events count as trusted. Earlier, a plain isolated
    /// world. Either way the page can't see Rain's script or what it fills.
    static let world: WKContentWorld = {
        if #available(macOS 27, *), let cls = NSClassFromString("WKContentWorldConfiguration") as? NSObject.Type {
            let config = cls.init()
            let set = NSSelectorFromString("setAutofillScriptingEnabled:")
            let make = NSSelectorFromString("worldWithConfiguration:")
            if config.responds(to: set), (WKContentWorld.self as AnyObject).responds(to: make) {
                config.setValue(true, forKey: "autofillScriptingEnabled")
                if let w = (WKContentWorld.self as AnyObject).perform(make, with: config)?.takeUnretainedValue() as? WKContentWorld {
                    hasAutofillScripting = true
                    return w
                }
            }
        }
        return .world(name: "rainPasswords")
    }()
    private(set) static var hasAutofillScripting = false

    static func install(on controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: world))
        controller.add(shared, contentWorld: world, name: name)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String, let wv = message.webView else { return }
        testHook?(type, body, message.frameInfo, wv)
        // The menu item works even with the offer turned off, since you asked for it.
        let wanted = BrowserPrefs.shared.value.offerPasswords || (openOnNextFocus && type == "focus")
        guard wanted, wv.window?.isKeyWindow == true || PasswordPanel.shared.isFormOpen, !wv.isHiddenOrHasHiddenAncestor else {
            if type == "focus" {
                openOnNextFocus = false
                PasswordPanel.shared.hideSuggestion()
            }
            return
        }
        watchSelection()
        switch type {
        case "focus":
            guard let f = Focus(body, frame: message.frameInfo, webView: wv) else { PasswordPanel.shared.hideSuggestion(); return }
            current = f
            if openOnNextFocus {
                openOnNextFocus = false
                PasswordPanel.shared.openForm(for: f)
            } else {
                PasswordPanel.shared.suggest(for: f)
            }
        case "open":
            if let f = current, f.webView === wv { PasswordPanel.shared.openForm(for: f) }
        case "leave", "typing", "moved", "dismiss":
            if current?.webView === wv { PasswordPanel.shared.hideSuggestion() }
        default:
            break
        }
    }

    /// Switching tabs or spaces takes the panel away with the page it belonged to.
    private func watchSelection() {
        guard selectionWatch == nil, let model = MediaWatch.shared.model else { return }
        selectionWatch = model.$selection.dropFirst().sink { _ in PasswordPanel.shared.hide() }
    }

    func pendingLogin(for f: Focus) -> Pending? {
        guard let p = pending, p.until > Date() else { pending = nil; return nil }
        return f.kind == .password && p.host == f.host ? p : nil
    }

    /// Fills a username and password into the focused field's form. `done` gets whether anything
    /// was filled. A login whose password had nowhere to go waits in memory for the next step.
    func fill(_ f: Focus, username: String, password: String, done: @escaping @MainActor (Bool) -> Void) {
        guard let wv = f.webView else { done(false); return }
        wv.callAsyncJavaScript("return window.__rainPW ? window.__rainPW.fill(field, user, pass, origin) : null",
                               arguments: ["field": f.field, "user": username, "pass": password, "origin": f.origin],
                               in: f.frame, in: Self.world) { result in
            MainActor.assumeIsolated {
                let d = (try? result.get()) as? [String: Any]
                let ok = (d?["ok"] as? Bool) ?? false
                let placedPassword = (d?["pass"] as? Bool) ?? false
                if ok && !placedPassword && !password.isEmpty {
                    self.pending = Pending(host: f.host, username: username, password: password, until: Date().addingTimeInterval(180))
                } else if placedPassword {
                    self.pending = nil
                }
                done(ok)
            }
        }
    }

    func fillPending(_ p: Pending, into f: Focus, done: @escaping @MainActor (Bool) -> Void) {
        fill(f, username: "", password: p.password, done: done)
    }

    /// Fills a code, spreading it over one-digit boxes when the page uses them.
    func fillCode(_ f: Focus, code: String, done: @escaping @MainActor (Bool) -> Void) {
        guard let wv = f.webView else { done(false); return }
        wv.callAsyncJavaScript("return window.__rainPW ? window.__rainPW.fillCode(field, code, origin) : null",
                               arguments: ["field": f.field, "code": code, "origin": f.origin],
                               in: f.frame, in: Self.world) { result in
            MainActor.assumeIsolated { done((((try? result.get()) as? [String: Any])?["ok"] as? Bool) ?? false) }
        }
    }

    /// Edit, then AutoFill Login: the focused login field, or the page's first password field,
    /// opens the form straight away. Returns false when the page has no login fields.
    func fillFromMenu(_ wv: WKWebView, done: @escaping @MainActor (Bool) -> Void) {
        openOnNextFocus = true
        wv.callAsyncJavaScript("return window.__rainPW ? window.__rainPW.reveal() : false", arguments: [:], in: nil, in: Self.world) { result in
            MainActor.assumeIsolated {
                let found = ((try? result.get()) as? Bool) ?? false
                if !found { self.openOnNextFocus = false }
                done(found)
            }
        }
    }

    // MARK: - The page script

    /// Runs in every frame, in Rain's own world. It finds login and code fields when they get
    /// focus and fills them when asked. Fields are referred to by a number only this world knows.
    static let script = """
    (() => {
      if (window.__rainPW) return;
      const post = (m) => { try { window.webkit.messageHandlers.rainPasswords.postMessage(m); } catch (_) {} };
      // The document's own origin. Frames like about:srcdoc inherit the page's, though their URL has
      // none, and sandboxed or data: frames have "null", which Rain never fills.
      const origin = () => self.origin || location.origin;
      const refs = new Map(), ids = new WeakMap();
      let next = 1, current = null;
      const idOf = (el) => { let i = ids.get(el); if (!i) { i = next++; ids.set(el, i); refs.set(i, new WeakRef(el)); } return i; };
      const byID = (i) => { const r = refs.get(i); return r ? r.deref() : null; };
      const ac = (el) => (el.getAttribute('autocomplete') || '').toLowerCase();
      const words = (el) => [el.name, el.id, el.getAttribute('placeholder'), el.getAttribute('aria-label'),
        el.labels ? [...el.labels].map(l => l.textContent).join(' ') : ''].join(' ').toLowerCase();
      const shown = (el) => {
        if (!el.isConnected) return false;
        const r = el.getBoundingClientRect();
        if (r.width < 2 || r.height < 2) return false;
        const s = getComputedStyle(el);
        return s.visibility !== 'hidden' && s.display !== 'none';
      };
      const editable = (el) => !!el && el.tagName === 'INPUT' && !el.disabled && !el.readOnly;
      const texty = (el) => ['text', 'email', 'tel'].includes(el.type);
      const scope = (el) => el.form || el.closest('form, [role=form], [role=dialog]') || document;
      const passwords = (root) => [...root.querySelectorAll('input[type=password]')].filter(p => editable(p) && shown(p));
      const isNew = (p) => /new-password/.test(ac(p));
      const codeWords = /one.?time|\\botp\\b|verification|verify|2fa|two.?factor|\\bmfa\\b|totp|security.?code|auth.*code|passcode|sms.?code|login.?code/;
      const signIn = /sign.?in|log.?in|login|signin/;
      const deepActive = () => {
        let a = document.activeElement;
        while (a && a.shadowRoot && a.shadowRoot.activeElement) a = a.shadowRoot.activeElement;
        return a;
      };
      const splitBoxes = (el) => {
        if (el.maxLength !== 1) return null;
        let p = el.parentElement;
        for (let depth = 0; p && depth < 3; depth++, p = p.parentElement) {
          const all = [...p.querySelectorAll('input')].filter(i => editable(i) && i.maxLength === 1 && shown(i));
          if (all.length >= 4 && all.length <= 8) return all;
        }
        return null;
      };
      const usernameFor = (pw, root) => {
        const all = [...root.querySelectorAll('input')].filter(i => editable(i) && shown(i) && texty(i));
        const tagged = all.find(i => /username|email/.test(ac(i)));
        if (tagged) return tagged;
        let best = null;
        for (const i of all) if (i.compareDocumentPosition(pw) & Node.DOCUMENT_POSITION_FOLLOWING) best = i;
        return best;
      };
      const kindOf = (el) => {
        if (!editable(el) || !shown(el)) return null;
        const a = ac(el);
        if (/one-time-code/.test(a) || splitBoxes(el)) return 'code';
        if (el.type === 'password') {
          if (isNew(el) && passwords(scope(el)).every(isNew)) return null;
          return 'password';
        }
        if (!texty(el) && el.type !== 'number') return null;
        const root = scope(el);
        const pw = passwords(root).filter(p => !isNew(p));
        if (!pw.length && codeWords.test(words(el))) return 'code';
        if (el.type === 'number') return null;
        if (pw.length) return usernameFor(pw[0], root) === el ? 'username' : null;
        if (/username/.test(a)) return 'username';
        // A sign-in step that asks for the username or email first, with the password next.
        if (/email/.test(a) || el.type === 'email' || /user.?name|e-?mail|login|account/.test(words(el))) {
          const text = (document.title + ' ' + (root.textContent || '').slice(0, 2000)).toLowerCase();
          if (signIn.test(text) && !/sign.?up|register|subscribe|newsletter/.test(words(el))) return 'username';
        }
        return null;
      };
      const rectOf = (el) => {
        const r = el.getBoundingClientRect();
        if (window === window.top) return { rect: { x: r.left, y: r.top, w: r.width, h: r.height }, converted: true };
        if (typeof window.convertRectToMainFrameCoordinates === 'function') {
          try {
            const m = window.convertRectToMainFrameCoordinates(r);
            if (m && typeof m.then !== 'function' && 'x' in m) return { rect: { x: m.x, y: m.y, w: m.width, h: m.height }, converted: true };
          } catch (_) {}
        }
        return { rect: { x: r.left, y: r.top, w: r.width, h: r.height }, converted: false };
      };
      const announce = (el) => {
        const kind = kindOf(el);
        if (!kind) { if (current) { current = null; post({ type: 'leave' }); } return; }
        current = el;
        const { rect, converted } = rectOf(el);
        let host = '';
        try { host = new URL(origin()).hostname; } catch (_) {}
        post({ type: 'focus', kind, field: idOf(el), rect, converted, origin: origin(), host, secure: origin().startsWith('https:') });
      };
      const target = (e) => (e.composedPath && e.composedPath()[0]) || e.target;
      document.addEventListener('focusin', (e) => announce(target(e)), true);
      document.addEventListener('focusout', () => setTimeout(() => {
        if (current && !kindOf(deepActive())) { current = null; post({ type: 'leave' }); }
      }, 0), true);
      document.addEventListener('mousedown', (e) => {
        const t = target(e);
        if (t === deepActive() && kindOf(t)) setTimeout(() => announce(t), 0);
      }, true);
      document.addEventListener('keydown', (e) => {
        if (!current || target(e) !== current) return;
        if (e.key === 'Escape') post({ type: 'dismiss' });
        else if (e.key === 'ArrowDown' && !e.metaKey && !e.altKey) post({ type: 'open' });
        else if (e.key.length === 1 || e.key === 'Backspace' || e.key === 'Delete') post({ type: 'typing' });
      }, true);
      window.addEventListener('scroll', () => { if (current) post({ type: 'moved' }); }, { capture: true, passive: true });
      window.addEventListener('pagehide', () => { if (current) { current = null; post({ type: 'leave' }); } });

      const setValue = (el, v) => {
        el.focus({ preventScroll: true });
        Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, v);
        for (const type of ['input', 'change']) {
          let ev;
          try { ev = new Event(type, { bubbles: true, composed: true, trusted: true }); } catch (_) { ev = new Event(type, { bubbles: true }); }
          el.dispatchEvent(ev);
        }
        try { el.autofilled = true; } catch (_) {}
      };
      window.__rainPW = {
        fill(id, user, pass, expected) {
          if (origin() !== expected) return { ok: false, reason: 'origin' };
          const el = byID(id);
          const root = el && el.isConnected ? scope(el) : document;
          const pws = passwords(root).filter(p => !isNew(p));
          const pw = el && el.isConnected && el.type === 'password' && !isNew(el) ? el : (pws[0] || null);
          const un = el && el.isConnected && kindOf(el) === 'username' ? el : (pw ? usernameFor(pw, root) : null);
          let didUser = false, didPass = false;
          if (un && user) { setValue(un, user); didUser = true; }
          if (pw && pass) { setValue(pw, pass); didPass = true; }
          return { ok: didUser || didPass, user: didUser, pass: didPass };
        },
        fillCode(id, code, expected) {
          if (origin() !== expected) return { ok: false, reason: 'origin' };
          const el = byID(id);
          if (!el || !el.isConnected) return { ok: false, reason: 'gone' };
          const boxes = splitBoxes(el), digits = [...code];
          if (boxes && digits.length >= boxes.length) boxes.forEach((b, i) => setValue(b, digits[i]));
          else setValue(el, code);
          return { ok: true };
        },
        reveal() {
          const a = deepActive();
          if (kindOf(a)) { announce(a); return true; }
          const p = passwords(document).find(x => !isNew(x));
          const first = p ? (usernameFor(p, scope(p)) || p) : [...document.querySelectorAll('input')].find(i => kindOf(i));
          if (!first) return false;
          first.focus();
          if (deepActive() === first) { if (current !== first) announce(first); return true; }
          return false;
        },
        kinds() { return [...document.querySelectorAll('input[data-expect]')].map(i => [i.dataset.expect, kindOf(i) || 'none']); }
      };
    })();
    """
}
