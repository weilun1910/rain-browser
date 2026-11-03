import AppKit
import SwiftUI
import WebKit

struct NoteEditorView: View {
    @ObservedObject var doc: NoteDocument
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if doc.isReadOnly {
                    Image(systemName: "lock").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(doc.projectLabel.map { "Read only, from \($0)" } ?? "Read only")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Notes")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .help(doc.url.lastPathComponent)
                }
                Spacer()
                if doc.isReadOnly {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([doc.url]) }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
                Picker("", selection: $doc.showPreview) {
                    Text(doc.isReadOnly ? "Source" : "Edit").tag(false)
                    Text("Preview").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            Divider().opacity(0.5)
            if doc.showPreview {
                MarkdownPreview(markdown: doc.text, title: doc.title, baseURL: doc.url.deletingLastPathComponent())
            } else {
                MarkdownTextView(doc: doc)
            }
        }
    }
}

/// Plain Markdown editing in an NSTextView, with light styling for headings, links and code.
struct MarkdownTextView: NSViewRepresentable {
    @ObservedObject var doc: NoteDocument

    final class Coordinator: NSObject, NSTextViewDelegate {
        var doc: NoteDocument
        var lastRevision = -1
        var focusObserver: NSObjectProtocol?
        weak var textView: NSTextView?

        init(doc: NoteDocument) { self.doc = doc }

        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            // Restyling mid-composition would break input methods.
            if !tv.hasMarkedText() { MarkdownStyler.style(tv) }
            let s = tv.string
            MainActor.assumeIsolated { doc.userEdited(s) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(doc: doc) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = true
        tv.drawsBackground = false
        tv.font = MarkdownStyler.bodyFont
        tv.textColor = .labelColor
        tv.isEditable = !doc.isReadOnly
        tv.isSelectable = true
        tv.textContainerInset = NSSize(width: 36, height: 28)
        tv.textContainer?.lineFragmentPadding = 0
        tv.defaultParagraphStyle = MarkdownStyler.paragraph
        tv.typingAttributes = MarkdownStyler.baseAttributes
        tv.string = doc.text
        tv.delegate = context.coordinator
        MarkdownStyler.style(tv)
        context.coordinator.textView = tv
        context.coordinator.lastRevision = doc.externalRevision
        context.coordinator.focusObserver = NotificationCenter.default.addObserver(forName: .focusEditor, object: nil, queue: .main) { [weak tv] _ in
            guard let tv else { return }
            tv.window?.makeFirstResponder(tv)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        // Only push text in when it changed outside the editor, so typing isn't disturbed.
        if context.coordinator.lastRevision != doc.externalRevision {
            context.coordinator.lastRevision = doc.externalRevision
            if tv.string != doc.text {
                let sel = tv.selectedRanges
                tv.string = doc.text
                MarkdownStyler.style(tv)
                let len = (tv.string as NSString).length
                tv.selectedRanges = sel.map { r in
                    let range = r.rangeValue
                    return NSValue(range: NSRange(location: min(range.location, len), length: 0))
                }
            }
        }
        tv.isEditable = !doc.isReadOnly
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if let o = coordinator.focusObserver { NotificationCenter.default.removeObserver(o) }
    }
}

enum MarkdownStyler {
    static let bodyFont = NSFont.systemFont(ofSize: 15)
    static let paragraph: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 4
        p.paragraphSpacing = 4
        return p
    }()
    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
    }

    private static let heading = try! NSRegularExpression(pattern: "^(#{1,6})\\s.*$", options: [.anchorsMatchLines])
    private static let link = try! NSRegularExpression(pattern: "\\[[^\\]]+\\]\\([^)]+\\)")
    private static let code = try! NSRegularExpression(pattern: "`[^`\\n]+`")
    private static let fence = try! NSRegularExpression(pattern: "^```.*?^```", options: [.anchorsMatchLines, .dotMatchesLineSeparators])
    private static let bullet = try! NSRegularExpression(pattern: "^\\s*([-*+]|\\d+\\.)\\s", options: [.anchorsMatchLines])

    static func style(_ tv: NSTextView) {
        guard let storage = tv.textStorage else { return }
        let s = storage.string
        let full = NSRange(location: 0, length: (s as NSString).length)
        guard full.length < 400_000 else { return }
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: full)
        for m in heading.matches(in: s, range: full) {
            let level = m.range(at: 1).length
            let size: CGFloat = level == 1 ? 24 : (level == 2 ? 19 : 16)
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .semibold), range: m.range)
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: m.range(at: 1))
        }
        for m in bullet.matches(in: s, range: full) {
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: m.range(at: 1))
        }
        for m in link.matches(in: s, range: full) {
            storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: m.range)
        }
        let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        for m in code.matches(in: s, range: full) {
            storage.addAttribute(.font, value: mono, range: m.range)
        }
        for m in fence.matches(in: s, range: full) {
            storage.addAttribute(.font, value: mono, range: m.range)
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: m.range)
        }
        storage.endEditing()
        tv.typingAttributes = baseAttributes
    }
}

/// Rendered preview. Links open in the browser; links to .md files open in the editor.
struct MarkdownPreview: NSViewRepresentable {
    let markdown: String
    let title: String
    let baseURL: URL
    @EnvironmentObject var model: BrowserModel

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var model: BrowserModel?
        var lastHTML = ""

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard action.navigationType == .linkActivated, let u = action.request.url else {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            MainActor.assumeIsolated {
                if u.isFileURL {
                    if u.pathExtension.lowercased() == "md" { model?.openDocument(u) } else { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                } else if u.scheme == "http" || u.scheme == "https" {
                    model?.newTab(url: u, select: true)
                } else {
                    NSWorkspace.shared.open(u)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = .nonPersistent()
        let wv = WKWebView(frame: .zero, configuration: c)
        wv.navigationDelegate = context.coordinator
        context.coordinator.model = model
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        let html = Markdown.html(markdown, title: title)
        guard html != context.coordinator.lastHTML else { return }
        context.coordinator.lastHTML = html
        wv.loadHTMLString(html, baseURL: baseURL)
    }
}
