import AppKit
import WebKit

/// Fill from Passwords in `--smoketest`: Rain's page script in a real web view, headless. It finds
/// login and code fields, fills them only on the page's own origin, carries a login over to a
/// password step, and the panel's two looks are snapshotted offscreen. The Passwords app itself
/// isn't involved: the logins here are made up and typed in by the test.
@MainActor
enum PasswordSmoke {
    static func check(_ ok: Bool, _ label: String, _ detail: String = "") { SelfTest.check(ok, label, detail) }

    struct Seen {
        let type: String
        let body: [String: Any]
        let frame: WKFrameInfo
        let webView: WKWebView
    }

    /// Runs a script in a frame and world and waits for the answer.
    static func js(_ wv: WKWebView, _ body: String, _ args: [String: Any] = [:], frame: WKFrameInfo? = nil,
                   world: WKContentWorld = .page) -> Any? {
        var out: Any?
        var done = false
        wv.callAsyncJavaScript(body, arguments: args, in: frame, in: world) { r in
            out = try? r.get()
            done = true
        }
        _ = SmokeTest.wait(5) { done }
        return out
    }

    /// Every label's text in a view and the views inside it.
    static func texts(in view: NSView) -> [String] {
        var out: [String] = []
        if let t = view as? NSTextField { out.append(t.stringValue) }
        for v in view.subviews { out += texts(in: v) }
        return out
    }

    static let host = "https://login.example.test"

    static let loginPage = """
    <!doctype html><html><head><title>Sign in</title></head><body style="font: 15px -apple-system; padding: 24px">
    <script>window.seen = []; document.addEventListener('input', e => window.seen.push(e.target.id), true);</script>
    <form id="login"><input id="u" type="email" autocomplete="username" data-expect="username">
      <input id="p" type="password" data-expect="password"><button>Sign in</button></form>
    <form id="plain"><input id="u2" type="text" name="login" data-expect="username"><input id="p2" type="password" name="pass" data-expect="password"></form>
    <form id="signup"><input id="nu" type="text" name="name" data-expect="none"><input id="np" type="password" autocomplete="new-password" data-expect="none"></form>
    <form id="otp"><input id="code" type="text" autocomplete="one-time-code" data-expect="code"></form>
    <div id="boxes"><input id="b1" maxlength="1" data-expect="code"><input id="b2" maxlength="1"><input id="b3" maxlength="1">
      <input id="b4" maxlength="1"><input id="b5" maxlength="1"><input id="b6" maxlength="1"></div>
    <input id="search" type="text" name="q" placeholder="Search" data-expect="none">
    <iframe id="inner" style="width: 400px; height: 120px" srcdoc="<form><input id='fu' type='email' autocomplete='username'><input id='fp' type='password'></form>"></iframe>
    </body></html>
    """

    static func run(snaps: URL) {
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 900),
                           configuration: BrowserModel.makeConfig(store: .nonPersistent()))
        var seen: [Seen] = []
        PasswordAutoFill.shared.testHook = { t, b, f, w in seen.append(Seen(type: t, body: b, frame: f, webView: w)) }
        defer { PasswordAutoFill.shared.testHook = nil }
        func lastFocus(_ kind: String? = nil) -> Seen? {
            seen.last { $0.type == "focus" && (kind == nil || ($0.body["kind"] as? String) == kind) }
        }
        func focus(_ id: String, frame: String? = nil) {
            seen.removeAll()
            let reach = frame.map { "document.getElementById('\($0)').contentDocument" } ?? "document"
            _ = js(wv, "\(reach).getElementById(id).focus(); return true", ["id": id])
            _ = SmokeTest.wait(2) { lastFocus() != nil }
        }
        func value(_ id: String) -> String { (js(wv, "return document.getElementById(id).value", ["id": id]) as? String) ?? "?" }
        func fill(_ s: Seen, _ user: String, _ pass: String, origin: String? = nil) -> Bool {
            var b = s.body
            if let origin { b["origin"] = origin }
            guard let f = PasswordAutoFill.Focus(b, frame: s.frame, webView: s.webView) else { return false }
            var result: Bool?
            PasswordAutoFill.shared.fill(f, username: user, password: pass) { result = $0 }
            _ = SmokeTest.wait(3) { result != nil }
            return result ?? false
        }

        wv.loadHTMLString(loginPage, baseURL: URL(string: host + "/signin")!)
        let ready = SmokeTest.wait(10) { (js(wv, "return !!window.__rainPW", world: PasswordAutoFill.world) as? Bool) == true }
        check(ready, "the Passwords script is in every page")
        guard ready else { return }

        // 1. Which fields count as login and code fields.
        let kinds = (js(wv, "return window.__rainPW.kinds()", world: PasswordAutoFill.world) as? [[String]]) ?? []
        let wrong = kinds.filter { $0.count == 2 && $0[0] != $0[1] }
        check(kinds.count == 9 && wrong.isEmpty,
              "login, username, code and split-code fields are found, and sign-up and search fields aren't", "\(wrong)")

        // 2. Focus on a password field tells Rain where it is.
        focus("p")
        let pf = lastFocus("password")
        let rect = pf?.body["rect"] as? [String: Any]
        check(pf != nil && (pf?.body["host"] as? String) == "login.example.test" && (pf?.body["secure"] as? Bool) == true
              && (pf?.body["converted"] as? Bool) == true && ((rect?["w"] as? NSNumber)?.doubleValue ?? 0) > 10,
              "a focused password field reports its site and position")
        focus("np")
        check(seen.contains { $0.type == "leave" } && lastFocus() == nil, "a sign-up password field offers nothing")

        // 3. Filling a login, with input events the page's own code sees.
        focus("p")
        if let s = lastFocus("password") {
            check(fill(s, "theo@example.test", "correct horse battery") && value("u") == "theo@example.test" && value("p") == "correct horse battery",
                  "a login from Passwords fills the username and password")
            let events = (js(wv, "return window.seen") as? [String]) ?? []
            check(events.contains("u") && events.contains("p"), "the page sees input events, as if typed", "\(events)")
            _ = js(wv, "document.getElementById('u').value = ''; document.getElementById('p').value = ''; return true")
            check(!fill(s, "theo@example.test", "stolen", origin: "https://evil.example.test") && value("p").isEmpty,
                  "a login is never filled into a page from another site")
        } else {
            check(false, "a login from Passwords fills the username and password", "no focus message")
        }

        // 4. A form without autocomplete hints still pairs the username with its password.
        focus("u2")
        if let s = lastFocus("username") {
            check(fill(s, "theo", "pw2") && value("u2") == "theo" && value("p2") == "pw2", "an untagged form still fills both fields")
        } else { check(false, "an untagged form still fills both fields", "no focus message") }

        // 5. Codes, in one field and spread over six boxes.
        focus("code")
        if let s = lastFocus("code"), let f = PasswordAutoFill.Focus(s.body, frame: s.frame, webView: s.webView) {
            var ok: Bool?
            PasswordAutoFill.shared.fillCode(f, code: "482913") { ok = $0 }
            _ = SmokeTest.wait(3) { ok != nil }
            check(ok == true && value("code") == "482913", "a code fills its field")
        } else { check(false, "a code fills its field", "no focus message") }
        focus("b1")
        if let s = lastFocus("code"), let f = PasswordAutoFill.Focus(s.body, frame: s.frame, webView: s.webView) {
            var ok: Bool?
            PasswordAutoFill.shared.fillCode(f, code: "654321") { ok = $0 }
            _ = SmokeTest.wait(3) { ok != nil }
            let boxes = (1...6).map { value("b\($0)") }.joined()
            check(ok == true && boxes == "654321", "a code spreads over one-digit boxes", boxes)
        } else { check(false, "a code spreads over one-digit boxes", "no focus message") }

        // 6. Frames: a same-site frame fills, a frame with no origin of its own is left alone.
        focus("fp", frame: "inner")
        if let s = lastFocus("password") {
            let filled = fill(s, "frame-user", "frame-pass")
            let v = js(wv, "return document.getElementById('inner').contentDocument.getElementById('fp').value") as? String
            check(!s.frame.isMainFrame && filled && v == "frame-pass", "a login form in a frame on the same site fills",
                  "main frame: \(s.frame.isMainFrame), filled: \(filled), value: \(v ?? "nil"), origin: \(s.body["origin"] ?? ""), host: \(s.body["host"] ?? ""), converted: \(s.body["converted"] ?? "")")
        } else { check(false, "a login form in a frame on the same site fills", "no focus message") }
        // A sandboxed or data: frame reports the origin "null", and gets nothing.
        if let s = lastFocus() {
            var b = s.body
            b["origin"] = "null"
            check(PasswordAutoFill.Focus(b, frame: s.frame, webView: s.webView) == nil, "a frame without a real origin never gets a login")
        }

        // 7. A username step, then the password step on the next page, from one pick.
        wv.loadHTMLString("<!doctype html><title>Sign in</title><form><input id='e' type='email' autocomplete='username'><button>Next</button></form>",
                          baseURL: URL(string: host + "/step1")!)
        _ = SmokeTest.wait(10) { (js(wv, "return !!window.__rainPW && !!document.getElementById('e')", world: PasswordAutoFill.world) as? Bool) == true }
        focus("e")
        if let s = lastFocus("username") {
            check(fill(s, "theo@example.test", "two-step secret") && value("e") == "theo@example.test", "a username step fills just the username")
            wv.loadHTMLString("<!doctype html><title>Sign in</title><form><input id='pp' type='password'></form>", baseURL: URL(string: host + "/step2")!)
            _ = SmokeTest.wait(10) { (js(wv, "return !!window.__rainPW && !!document.getElementById('pp')", world: PasswordAutoFill.world) as? Bool) == true }
            focus("pp")
            if let s2 = lastFocus("password"), let f2 = PasswordAutoFill.Focus(s2.body, frame: s2.frame, webView: s2.webView),
               let pending = PasswordAutoFill.shared.pendingLogin(for: f2) {
                var ok: Bool?
                PasswordAutoFill.shared.fillPending(pending, into: f2) { ok = $0 }
                _ = SmokeTest.wait(3) { ok != nil }
                check(pending.username == "theo@example.test" && ok == true && value("pp") == "two-step secret"
                      && PasswordAutoFill.shared.pendingLogin(for: f2) == nil,
                      "the password step offers the same login, then forgets it")
            } else { check(false, "the password step offers the same login, then forgets it", "nothing pending") }
        } else { check(false, "a username step fills just the username", "no focus message") }

        // 8. Edit, then Fill from Passwords finds the login field on a page where nothing has focus.
        wv.loadHTMLString(loginPage, baseURL: URL(string: host + "/again")!)
        _ = SmokeTest.wait(10) { (js(wv, "return !!window.__rainPW && !!document.getElementById('u')", world: PasswordAutoFill.world) as? Bool) == true }
        seen.removeAll()
        var found: Bool?
        PasswordAutoFill.shared.fillFromMenu(wv) { found = $0 }
        _ = SmokeTest.wait(3) { found != nil && lastFocus() != nil }
        check(found == true && (lastFocus()?.body["kind"] as? String) == "username", "the menu item finds the page's login form")

        // 9. A page can focus a field, but it can't fake the ArrowDown that opens the form.
        focus("p")
        let focused = lastFocus("password") != nil
        seen.removeAll()
        _ = js(wv, """
            const el = document.getElementById('p');
            for (const key of ['ArrowDown', 'Escape', 'a']) el.dispatchEvent(new KeyboardEvent('keydown', { key, bubbles: true, composed: true }));
            el.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, composed: true }));
            return true
            """)
        _ = SmokeTest.wait(0.6) { false }
        check(focused && !seen.contains { ["open", "dismiss", "typing", "focus"].contains($0.type) },
              "faked keys and clicks from the page don't open, close or re-offer the Passwords form", seen.map(\.type).joined(separator: " "))

        // 10. The site shows in the suggestion row before anything is filled.
        focus("u")
        if let s = lastFocus(), let f = PasswordAutoFill.Focus(s.body, frame: s.frame, webView: s.webView) {
            let titles = PasswordSmoke.texts(in: PasswordPanel.shared.suggestionContent(for: f))
            check(titles.contains { $0.contains("login.example.test") }, "the suggestion row names the site", titles.joined(separator: " | "))
        } else { check(false, "the suggestion row names the site", "no focus message") }

        snapshots(wv: wv, seen: lastFocus(), snaps: snaps)
        print("      autofill scripting world: \(PasswordAutoFill.hasAutofillScripting ? "yes (macOS 27)" : "no")")
    }

    /// The suggestion row and both forms, light and dark, drawn offscreen.
    static func snapshots(wv: WKWebView, seen: Seen?, snaps: URL) {
        guard let s = seen else { return }
        func render(_ body: [String: Any], form: Bool, dark: Bool, name: String) {
            guard let f = PasswordAutoFill.Focus(body, frame: s.frame, webView: wv) else { return }
            let content = form ? PasswordPanel.shared.form(for: f) : PasswordPanel.shared.suggestionContent(for: f)
            let host = NSView()
            host.wantsLayer = true
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.layer?.backgroundColor = (dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.97, alpha: 1)).cgColor
            content.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: host.leadingAnchor), content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                content.topAnchor.constraint(equalTo: host.topAnchor), content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
            host.layoutSubtreeIfNeeded()
            host.setFrameSize(content.fittingSize)
            let w = SmokeTest.offscreenWindow(host, size: content.fittingSize)
            w.appearance = host.appearance
            SmokeTest.snapshot(host, snaps.appendingPathComponent(name))
            PasswordPanel.shared.hide()
        }
        var insecure = s.body
        insecure["secure"] = false
        var code = s.body
        code["kind"] = "code"
        render(s.body, form: false, dark: false, name: "passwords-1-suggestion-light.png")
        render(s.body, form: false, dark: true, name: "passwords-2-suggestion-dark.png")
        render(insecure, form: true, dark: false, name: "passwords-3-login-form-light.png")
        render(s.body, form: true, dark: true, name: "passwords-4-login-form-dark.png")
        render(code, form: true, dark: true, name: "passwords-5-code-form-dark.png")
    }
}
