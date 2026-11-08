import AppKit
import WebKit

/// The panel under a login or code field.
///
/// It starts as one row, like Safari's AutoFill menu, and never takes keyboard focus from the
/// page. Choosing the row turns it into a small form. Its fields are native, so macOS's own
/// AutoFill works in them: the key in a field opens the Passwords app's list behind Touch ID, and
/// codes from Messages and Mail show under the code field. When a login or code arrives, Rain
/// copies it into the page, clears the fields and closes the panel.
@MainActor
final class PasswordPanel: NSObject {
    static let shared = PasswordPanel()

    private enum Mode { case hidden, suggestion, form }
    private var mode: Mode = .hidden
    private var focus: PasswordAutoFill.Focus?
    private var panel: Panel?
    private weak var parentWindow: NSWindow?
    private var userField: NSTextField?
    private var passField: NSSecureTextField?
    private var codeField: NSTextField?
    private var errorLabel: NSTextField?
    private var watch: Timer?
    private var lastPass = ""
    private var lastCode = ""
    private var observers: [NSObjectProtocol] = []

    var isFormOpen: Bool { mode == .form }
    var isShowingSuggestion: Bool { mode == .suggestion }
    /// The panel's content, for the smoke test's snapshots.
    var contentForTests: NSView? { panel?.contentView }

    final class Panel: NSPanel {
        var takesKey = false
        override var canBecomeKey: Bool { takesKey }
        override var canBecomeMain: Bool { false }
        override func cancelOperation(_ sender: Any?) { PasswordPanel.shared.hide(refocus: true) }
    }

    // MARK: - Showing and hiding

    func suggest(for f: PasswordAutoFill.Focus) {
        if mode == .form, focus?.webView === f.webView, focus?.field == f.field { return }
        if mode == .form { hide(refocus: false) }
        focus = f
        mode = .suggestion
        show(suggestionContent(for: f), near: f, takesKey: false)
    }

    func suggestionContent(for f: PasswordAutoFill.Focus) -> NSView {
        var rows: [PanelRow] = []
        switch f.kind {
        case .code:
            rows.append(PanelRow(symbol: "ellipsis.message", title: "Fill code from Messages or Mail...") { [weak self] in self?.openForm(for: f) })
        case .username, .password:
            // The rows name the site the field belongs to, so a login isn't handed to a lookalike
            // page or to a frame from another site without the site showing first.
            if let p = PasswordAutoFill.shared.pendingLogin(for: f) {
                rows.append(PanelRow(symbol: "key.fill", title: "Fill password for \(p.username) on \(f.host)") { [weak self] in
                    PasswordAutoFill.shared.fillPending(p, into: f) { ok in self?.finish(ok) }
                })
                rows.append(PanelRow(symbol: "key", title: "Other login from Passwords...") { [weak self] in self?.openForm(for: f) })
            } else {
                rows.append(PanelRow(symbol: "key.fill", title: "Fill login for \(f.host) from Passwords...") { [weak self] in self?.openForm(for: f) })
            }
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 5, bottom: 5, right: 5)
        stack.alignment = .leading
        let width = max(250, min(anchor(f).width, 360))
        for r in rows { r.widthAnchor.constraint(equalToConstant: width - 10).isActive = true }
        return stack
    }

    func openForm(for f: PasswordAutoFill.Focus) {
        focus = f
        let content = form(for: f)
        // Set first: making the panel key takes focus from the page's window, and the suggestion
        // closes when that happens.
        mode = .form
        show(content, near: f, takesKey: true)
        lastPass = ""
        lastCode = ""
        panel?.makeFirstResponder(f.kind == .code ? codeField : userField)
        watch?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { _ in MainActor.assumeIsolated { PasswordPanel.shared.tick() } }
        RunLoop.main.add(t, forMode: .common)
        watch = t
    }

    func hideSuggestion() {
        if mode == .suggestion { hide(refocus: false) }
    }

    /// Closes the panel and forgets anything typed or filled into it.
    func hide(refocus: Bool = false) {
        watch?.invalidate()
        watch = nil
        for f in [userField, passField, codeField] { f?.stringValue = "" }
        lastPass = ""
        lastCode = ""
        let wv = focus?.webView
        if let p = panel {
            p.parent?.removeChildWindow(p)
            p.orderOut(nil)
            p.contentView = nil
        }
        userField = nil
        passField = nil
        codeField = nil
        errorLabel = nil
        mode = .hidden
        if refocus, let wv, let win = wv.window {
            win.makeKey()
            win.makeFirstResponder(wv)
        }
    }

    private func show(_ content: NSView, near f: PasswordAutoFill.Focus, takesKey: Bool) {
        guard let wv = f.webView, let win = wv.window else { return }
        let p = panel ?? makePanel()
        panel = p
        p.takesKey = takesKey
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.roundedMask(radius: 10)
        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        p.contentView = effect
        effect.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        p.setFrame(placement(size: size, anchor: anchor(f), screen: win.screen ?? NSScreen.main), display: true)
        if p.parent !== win {
            p.parent?.removeChildWindow(p)
            win.addChildWindow(p, ordered: .above)
        }
        parentWindow = win
        watchParent(win)
        p.orderFront(nil)
        if takesKey { p.makeKey() }
    }

    private func makePanel() -> Panel {
        let p = Panel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 40), styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = true
        p.becomesKeyOnlyIfNeeded = true
        p.animationBehavior = .utilityWindow
        return p
    }

    /// The suggestion goes when the page's window stops being key. The form goes when you click
    /// back into the page's window, but not while the Passwords app's own window has focus.
    private func watchParent(_ win: NSWindow) {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = [
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: win, queue: .main) { _ in
                MainActor.assumeIsolated { PasswordPanel.shared.hideSuggestion() }
            },
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: win, queue: .main) { _ in
                MainActor.assumeIsolated { if PasswordPanel.shared.isFormOpen { PasswordPanel.shared.hide(refocus: false) } }
            },
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: win, queue: .main) { _ in
                MainActor.assumeIsolated { PasswordPanel.shared.hide(refocus: false) }
            },
        ]
    }

    /// The field's rect on screen. A field in a frame whose position Rain can't work out uses the
    /// pointer instead, which is where you just clicked.
    func anchor(_ f: PasswordAutoFill.Focus) -> NSRect {
        guard let wv = f.webView, let win = wv.window else { return .zero }
        guard f.converted else {
            let m = NSEvent.mouseLocation
            return NSRect(x: m.x - 8, y: m.y - 10, width: 16, height: 20)
        }
        let z = wv.pageZoom * wv.magnification
        let inset = wv.obscuredContentInsets
        var r = NSRect(x: f.rect.minX * z + inset.left, y: f.rect.minY * z + inset.top, width: f.rect.width * z, height: f.rect.height * z)
        if !wv.isFlipped { r.origin.y = wv.bounds.height - r.maxY }
        return win.convertToScreen(wv.convert(r, to: nil))
    }

    /// Under the field, or above it when there's no room below, and always on screen.
    func placement(size: NSSize, anchor a: NSRect, screen: NSScreen?) -> NSRect {
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 10_000, height: 10_000)
        var x = a.minX
        var y = a.minY - size.height - 4
        if y < visible.minY + 4 { y = a.maxY + 4 }
        x = min(max(x, visible.minX + 4), visible.maxX - size.width - 4)
        y = min(max(y, visible.minY + 4), visible.maxY - size.height - 4)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    // MARK: - The form

    func form(for f: PasswordAutoFill.Focus) -> NSView {
        let width: CGFloat = 268
        func label(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
            let l = NSTextField(wrappingLabelWithString: s)
            l.font = .systemFont(ofSize: size, weight: weight)
            l.textColor = color
            l.preferredMaxLayoutWidth = width
            l.widthAnchor.constraint(equalToConstant: width).isActive = true
            return l
        }
        let title = label(f.kind == .code ? "Fill a code" : "Fill a login", size: 13, weight: .semibold)
        let host = label("on \(f.host)", size: 11, color: .secondaryLabelColor)
        host.lineBreakMode = .byTruncatingMiddle
        host.maximumNumberOfLines = 1
        var views: [NSView] = [title, host]
        if f.kind == .code {
            let c = NSTextField()
            c.placeholderString = "Code"
            c.contentType = .oneTimeCode
            c.widthAnchor.constraint(equalToConstant: width).isActive = true
            codeField = c
            views.append(c)
            views.append(label("Codes from Messages and Mail show up under the field.", size: 11, color: .secondaryLabelColor))
        } else {
            let u = NSTextField()
            u.placeholderString = "Username or email"
            u.contentType = .username
            u.widthAnchor.constraint(equalToConstant: width).isActive = true
            let p = NSSecureTextField()
            p.placeholderString = "Password"
            p.contentType = .password
            p.widthAnchor.constraint(equalToConstant: width).isActive = true
            userField = u
            passField = p
            views.append(contentsOf: [u, p])
            views.append(label("Click the key in a field and choose Passwords, or right-click a field and choose AutoFill, then Passwords. Touch ID unlocks them.", size: 11, color: .secondaryLabelColor))
        }
        if !f.secure {
            views.append(label("This page isn't secure, so others on the network could see what you send.", size: 11, color: .systemOrange))
        }
        let error = label("", size: 11, color: .systemRed)
        error.isHidden = true
        errorLabel = error
        views.append(error)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelAction))
        cancel.keyEquivalent = "\u{1b}"
        let fill = NSButton(title: "Fill", target: self, action: #selector(submit))
        fill.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, fill])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.widthAnchor.constraint(equalToConstant: width).isActive = true
        views.append(buttons)

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(2, after: title)
        stack.setCustomSpacing(12, after: host)
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        return stack
    }

    @objc private func cancelAction() { hide(refocus: true) }

    /// A login from the Passwords app fills both fields at once while the username field has
    /// focus, so Rain fills the page without waiting for the Fill button. A code pasted or picked
    /// in one go does the same. Typing never triggers it.
    private func tick() {
        guard mode == .form, let f = focus else { return }
        if f.kind == .code {
            let c = codeField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if lastCode.isEmpty && c.count >= 4 { submit() } else { lastCode = c }
        } else {
            let p = passField?.stringValue ?? ""
            let u = userField?.stringValue ?? ""
            if lastPass.isEmpty && !p.isEmpty && !u.isEmpty && !isEditing(passField) { submit() } else { lastPass = p }
        }
    }

    private func isEditing(_ field: NSTextField?) -> Bool {
        guard let field, let editor = panel?.firstResponder as? NSText else { return false }
        return editor.delegate === field
    }

    @objc func submit() {
        guard mode == .form, let f = focus else { return }
        if f.kind == .code {
            let code = (codeField?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty else { NSSound.beep(); return }
            PasswordAutoFill.shared.fillCode(f, code: code) { [weak self] ok in self?.finish(ok) }
        } else {
            let u = userField?.stringValue ?? "", p = passField?.stringValue ?? ""
            guard !u.isEmpty || !p.isEmpty else { NSSound.beep(); return }
            // Keeps the watch from sending it a second time while the page fills.
            lastPass = p
            PasswordAutoFill.shared.fill(f, username: u, password: p) { [weak self] ok in self?.finish(ok) }
        }
    }

    private func finish(_ ok: Bool) {
        if ok {
            hide(refocus: true)
        } else if mode == .form {
            errorLabel?.stringValue = "Rain couldn't find the field on this page anymore. Click into it and try again."
            errorLabel?.isHidden = false
            panel?.contentView?.layoutSubtreeIfNeeded()
        } else {
            hide(refocus: true)
        }
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { r in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }
}

/// One row of the suggestion panel, drawn like a menu item: an icon and a line of text, with the
/// accent colour behind it under the pointer.
final class PanelRow: NSView {
    private let action: () -> Void
    private let icon = NSImageView()
    private let title: NSTextField
    private var hovered = false { didSet { updateLook() } }

    init(symbol: String, title text: String, action: @escaping () -> Void) {
        self.action = action
        title = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingMiddle
        for v in [icon, title] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -9),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(text)
        updateLook()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
    override func accessibilityPerformPress() -> Bool { action(); return true }

    private func updateLook() {
        layer?.backgroundColor = hovered ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        title.textColor = hovered ? .white : .labelColor
        icon.contentTintColor = hovered ? .white : .secondaryLabelColor
    }
}
