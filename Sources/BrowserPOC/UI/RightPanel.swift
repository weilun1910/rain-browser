import AppKit
import SwiftUI

struct RightPanel: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        RightPanelContent(resurfacer: model.resurfacer)
    }
}

struct RightPanelContent: View {
    @ObservedObject var resurfacer: Resurfacer
    @ObservedObject var settings = Settings.shared
    @ObservedObject var gate = RelatedGate.shared
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: 0) {
                Text("Related")
                    .font(Theme.Font.rowEmphasis)
                    .foregroundStyle(.secondary)
                    .padding(.leading, Theme.Space.xs)
                WindowDragArea()
                NavButton(symbol: "sidebar.right", help: "Hide related panel") {
                    Settings.shared.update { $0.rightPanelOpen = false }
                }
            }
            // Lines up with the sidebar's top row.
            .frame(height: Theme.Space.titleBarHeight - Theme.Space.windowMargin)
            .padding(.top, Theme.Space.windowMargin)
            ModelProgressLine()

            if resurfacer.cards.isEmpty {
                // A quiet, centred note instead of a sentence stuck in the corner.
                VStack(spacing: Theme.Space.s) {
                    Text(emptyTitle)
                        .font(Theme.Font.rowEmphasis)
                        .foregroundStyle(.secondary)
                    Text(emptyText)
                        .font(Theme.Font.secondary)
                        .foregroundStyle(.secondary)
                        .opacity(0.85)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 220)
                .frame(maxWidth: .infinity)
                .padding(.top, 120)
                .transition(.opacity)
                Spacer()
            } else {
                ScrollView {
                    // Keyed by what's open, so a new page or note brings a fresh list instead of
                    // cards sliding past each other. New cards fade and rise one after another.
                    // Cards that stay don't move while you type.
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        if !resurfacer.siteCards.isEmpty {
                            SectionLabel(CardSection.sites.title)
                            ForEach(Array(resurfacer.siteCards.enumerated()), id: \.element.id) { i, card in
                                CardView(card: card, showScores: settings.published.showScores)
                                    .cardAppear(index: i)
                            }
                        }
                        if !resurfacer.docCards.isEmpty {
                            SectionLabel(CardSection.docs.title)
                                .padding(.top, resurfacer.siteCards.isEmpty ? 0 : Theme.Space.m)
                            ForEach(Array(resurfacer.docCards.enumerated()), id: \.element.id) { i, card in
                                CardView(card: card, showScores: settings.published.showScores)
                                    .cardAppear(index: resurfacer.siteCards.count + i)
                            }
                        }
                    }
                    .padding(.bottom, Theme.Space.l)
                    .id(resurfacer.context?.key ?? "")
                }
                .scrollIndicators(.never)
            }
            LocalGraphSlot(resurfacer: resurfacer)
                .padding(.bottom, 8)
        }
        .padding(.horizontal, Theme.Space.windowMargin)
    }

    var powerPause: RelatedPause? { gate.pause.flatMap { $0.isPower ? $0 : nil } }

    var emptyTitle: String {
        if let p = powerPause { return p.title }
        return resurfacer.hasContext ? "Nothing related yet" : "Nothing open"
    }

    var emptyText: String {
        if let p = powerPause { return p.detail }
        if !resurfacer.hasContext { return "Open a page or a note. Things you've seen before that relate to it show up here." }
        return "Cards show up when something you've seen before matches what's open."
    }
}

/// Plain text from a Markdown passage, for previews: no heading marks, emphasis, checkboxes or
/// link syntax, so a card reads as prose.
enum PlainText {
    static func fromMarkdown(_ s: String) -> String {
        var t = s
        let patterns: [(String, String)] = [
            ("(?m)^\\s{0,3}#{1,6}\\s+", ""),              // headings
            ("(?m)^\\s*[-*+]\\s+\\[[ xX]\\]\\s+", ""),    // task boxes
            ("(?m)^\\s*[-*+]\\s+", ""),                   // bullets
            ("(?m)^\\s*>\\s?", ""),                       // quotes
            ("\\[\\[([^\\]|]+)(\\|[^\\]]+)?\\]\\]", "$1"),  // wiki links
            ("\\[([^\\]]+)\\]\\([^)]+\\)", "$1"),          // links
            ("(\\*\\*|__)(.+?)\\1", "$2"),                 // bold
            ("(?<![\\w*])\\*(?!\\s)(.+?)(?<!\\s)\\*(?![\\w*])", "$1"), // italics
            ("\\*\\*|__", ""),                             // emphasis cut off by the passage's edges
            ("`([^`]+)`", "$1"),                           // code
            ("\\s*#{1,6}\\s+", " "),                       // heading marks inside a joined passage
            ("\\s{2,}", " "),
        ]
        for (p, r) in patterns {
            t = t.replacingOccurrences(of: p, with: r, options: .regularExpression)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(Theme.Font.label)
            .foregroundStyle(.secondary)
            .padding(.leading, Theme.Space.xs)
    }
}

struct CardView: View {
    let card: Card
    let showScores: Bool
    @EnvironmentObject var model: BrowserModel
    @State private var hovering = false
    @Environment(\.spaceAccent) private var accent

    var m: Match { card.match }

    var icon: String {
        switch m.doc.source {
        case .web, .chrome:
            if m.section == .docs { return "doc.richtext" }
            return m.doc.source == .web ? "globe" : "clock.arrow.circlepath"
        case .note, .markdown: return "note.text"
        case .notion, .gdocs: return "doc.richtext"
        case .granola: return "person.2.wave.2"
        }
    }

    var label: String {
        switch m.doc.source {
        case .web, .chrome:
            let host = Snippet.prettyURL(m.doc.url).split(separator: "/").first.map(String.init) ?? ""
            if let folder = model.folderName(forURL: m.doc.url) { return "\(host)  |  \(folder)" }
            return host
        case .note, .markdown:
            return m.doc.project ?? "Notes"
        case .notion: return "Notion"
        case .gdocs: return "Google Docs"
        case .granola: return "Granola meeting"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                // Pages, Notion and Google Docs show the site's icon. Notes and meetings keep their symbols.
                SourceIcon(url: m.doc.url, isPage: [.web, .chrome, .notion, .gdocs].contains(m.doc.source), symbol: icon, size: 16)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(m.doc.title)
                        .font(Theme.Font.cardTitle)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(label)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                // Leaves room for the actions that appear on hover.
                Spacer(minLength: 44)
            }
            let passage = PlainText.fromMarkdown(m.passage)
            if !passage.isEmpty {
                Text(passage)
                    .font(Theme.Font.secondary)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .lineLimit(2)
            }
            // The reason, set off by a thin rule in the space's colour.
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Capsule().fill(accent.opacity(0.55)).frame(width: 2)
                Text(card.reason)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineSpacing(1.5)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
            if showScores {
                Text(String(format: "keyword %.2f | meaning %.2f | names %.2f | score %.2f%@%@",
                            m.keyword, m.semantic, m.entity, m.score,
                            m.rerank.map { String(format: " | reranker %.2f", $0) } ?? "",
                            m.penalized ? " | dismissed before" : ""))
                    .font(Theme.Font.mono(10))
                    .foregroundStyle(.secondary)
            }
            if let feedback = card.feedback {
                Label(feedback, systemImage: "checkmark")
                    .font(Theme.Font.caption)
                    .foregroundStyle(accent)
                    .transition(.opacity)
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Actions show on hover, top right, so a column of cards stays calm. Arc does the same.
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 2) {
                IconButton(symbol: "plus", help: card.feedback ?? "Add to research", width: 22, height: 22, symbolSize: 10) {
                    let msg = model.addToResearch(card)
                    if msg.hasPrefix("Added") { GraphRecorder.shared.researchAdded(addedKey: card.match.doc.key, model: model) }
                    model.resurfacer.setFeedback(msg, for: card)
                }
                .disabled(card.feedback != nil)
                IconButton(symbol: "arrow.up.right", help: "Open", width: 22, height: 22, symbolSize: 10) { model.open(card) }
                IconButton(symbol: "xmark", help: "Dismiss", width: 22, height: 22, symbolSize: 9) {
                    model.resurfacer.dismiss(card)
                }
            }
            .padding(Theme.Space.s)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .motion(Motion.hover, value: hovering, fadeOnly: true)
        }
        .panelCard(hovering: hovering)
        .contentShape(Rectangle())
        .motion(Motion.hover, value: card.feedback, fadeOnly: true)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { model.open(card) }
        .contextMenu {
            Button("Open") { model.open(card) }
            if m.doc.source == .markdown || m.doc.source == .note, let u = URL(string: m.doc.url) {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) }
            }
            Button("Copy link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(m.doc.url, forType: .string)
            }
            if m.doc.source == .web || m.doc.source == .chrome {
                if m.section == .sites {
                    Button("Move to Notes / Docs") { model.resurfacer.move(card, to: .docs) }
                } else {
                    Button("Move to Sites") { model.resurfacer.move(card, to: .sites) }
                }
            }
            Divider()
            Button("Dismiss") { model.resurfacer.dismiss(card) }
        }
    }
}
