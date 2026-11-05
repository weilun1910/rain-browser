import AppKit
import SwiftUI
import WebKit

struct NoteEditorView: View {
    @ObservedObject var doc: NoteDocument
    @EnvironmentObject var model: BrowserModel

    /// Where the note sits, relative to its notes folder.
    var location: String {
        let roots = Settings.shared.value.notesRoots
        guard let root = FileSafety.notesRoot(for: doc.url, roots: roots) else { return doc.url.deletingLastPathComponent().path }
        let rootPath = root.standardizedFileURL.path
        let dir = doc.url.deletingLastPathComponent().standardizedFileURL.path
        let rel = dir.hasPrefix(rootPath) ? String(dir.dropFirst(rootPath.count)) : ""
        let parts = [root.lastPathComponent] + rel.split(separator: "/").map(String.init)
        return parts.joined(separator: "  /  ")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.l) {
                if doc.isReadOnly {
                    Image(systemName: "lock").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(doc.notUTF8 ? "Read only, this file isn't plain UTF-8 text" : "Read only, outside your notes folders")
                        .font(Theme.Font.secondary)
                        .foregroundStyle(.secondary)
                } else {
                    Text(location)
                        .font(Theme.Font.secondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(doc.url.path)
                }
                Spacer()
                IconButton(symbol: "folder", help: "Reveal in Finder", width: 26, height: 24, symbolSize: 12) {
                    NSWorkspace.shared.activateFileViewerSelecting([doc.url])
                }
                Picker("", selection: $doc.showPreview) {
                    Text("Edit").tag(false)
                    Text("Preview").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
                .controlSize(.small)
            }
            .padding(.leading, Theme.Space.xxl)
            .padding(.trailing, Theme.Space.l)
            .frame(height: 40)
            if let change = doc.diskChange {
                DiskChangeBar(doc: doc, change: change)
                    .transition(.opacity)
            }
            Rectangle().fill(Theme.Palette.hairline).frame(height: 1)
            switch doc.state {
            case .loading:
                Color.clear
            case .waitingForICloud:
                Text("Downloading from iCloud...")
                    .font(Theme.Font.row).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let why):
                VStack(spacing: Theme.Space.l) {
                    Text(why).font(Theme.Font.row).foregroundStyle(.secondary)
                    Button("Try again") { doc.load() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                if doc.showPreview {
                    MarkdownPreview(markdown: doc.text, title: doc.title, baseURL: doc.url.deletingLastPathComponent())
                } else {
                    MarkdownTextView(doc: doc)
                }
            }
        }
    }
}

/// A quiet bar for a note that changed on disk while it was open.
struct DiskChangeBar: View {
    @ObservedObject var doc: NoteDocument
    let change: NoteDocument.DiskChange
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        HStack(spacing: Theme.Space.l) {
            Image(systemName: change == .missing ? "questionmark.folder" : "arrow.triangle.2.circlepath")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text(change == .missing ? "This file was moved or deleted on disk. Your text is still here."
                                    : "This file changed on disk. Your edits aren't saved yet.")
                .font(Theme.Font.secondary).foregroundStyle(.secondary)
            Spacer()
            if change == .changed {
                Button("Load disk version") { doc.loadDiskVersion() }
                Button("Keep mine") { doc.keepMine() }
            } else {
                Button("Locate...") {
                    if let t = model.tabs.first(where: { $0.url?.standardizedFileURL.path == doc.url.standardizedFileURL.path }) { model.locateNote(t) }
                }
                Button("Save it back") { doc.keepMine() }
            }
        }
        .buttonStyle(.link)
        .font(.system(size: 12))
        .padding(.horizontal, Theme.Space.xxl)
        .frame(height: 34)
        .background(Theme.Palette.field)
    }
}

/// Shown for a note item whose file is gone.
struct MissingNoteView: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        VStack(spacing: 10) {
            Text("This note's file is missing").font(Theme.Font.display(22)).displayTracking()
            Text(tab.url?.path ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                .frame(maxWidth: 420)
            HStack(spacing: 14) {
                Button("Locate...") { model.locateNote(tab) }
                Button("Close") { model.remove(tab) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Plain Markdown editing in an NSTextView, with light styling for headings, links and code.
struct MarkdownTextView: NSViewRepresentable {
    @ObservedObject var doc: NoteDocument

    final class Coordinator: NSObject, NSTextViewDelegate {
        var doc: NoteDocument
        var lastRevision = -1
        var focusObserver: NSObjectProtocol?
        var frameObserver: NSObjectProtocol?
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
        tv.usesFindBar = true // Cmd-F in a note shows the find bar above the text
        tv.textContainerInset = NSSize(width: ReadingMeasure.minSide, height: 32)
        // Long notes keep a comfortable line length: the text column centres once the pane is wide.
        scroll.contentView.postsFrameChangedNotifications = true
        context.coordinator.frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main) { [weak tv, weak scroll] _ in
            MainActor.assumeIsolated { if let tv, let scroll { ReadingMeasure.apply(tv, width: scroll.contentView.bounds.width) } }
        }
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
        tv.isEditable = !doc.isReadOnly && doc.state == .ready
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if let o = coordinator.focusObserver { NotificationCenter.default.removeObserver(o) }
        if let o = coordinator.frameObserver { NotificationCenter.default.removeObserver(o) }
    }
}

/// A comfortable line length for notes: about 75 characters of 15 pt text, centred in a wide
/// pane, with at least 44 pt of margin when the pane is narrow.
@MainActor
enum ReadingMeasure {
    static let column: CGFloat = 700
    static let minSide: CGFloat = 44

    static func side(for width: CGFloat) -> CGFloat { max(minSide, ((width - column) / 2).rounded()) }

    static func apply(_ tv: NSTextView, width: CGFloat) {
        let s = side(for: width)
        if abs(tv.textContainerInset.width - s) > 0.5 { tv.textContainerInset = NSSize(width: s, height: tv.textContainerInset.height) }
    }
}

enum MarkdownStyler {
    static let bodyFont = NSFont.systemFont(ofSize: 15)
    static let paragraph: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 5
        p.paragraphSpacing = 6
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
                    if u.pathExtension.lowercased() == "md" { model?.openNote(u) } else { NSWorkspace.shared.activateFileViewerSelecting([u]) }
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
