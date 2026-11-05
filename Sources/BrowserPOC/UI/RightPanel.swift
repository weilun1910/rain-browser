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

            if resurfacer.cards.isEmpty {
                Text(emptyText)
                    .font(Theme.Font.secondary)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Space.xs)
                    .padding(.top, Theme.Space.xs)
                    .transition(.opacity)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        if !resurfacer.siteCards.isEmpty {
                            SectionLabel(CardSection.sites.title)
                            ForEach(Array(resurfacer.siteCards.enumerated()), id: \.element.id) { i, card in
                                CardView(card: card, showScores: settings.published.showScores)
                                    .transition(Motion.Transitions.card(index: i))
                            }
                        }
                        if !resurfacer.docCards.isEmpty {
                            SectionLabel(CardSection.docs.title)
                                .padding(.top, resurfacer.siteCards.isEmpty ? 0 : Theme.Space.m)
                            ForEach(Array(resurfacer.docCards.enumerated()), id: \.element.id) { i, card in
                                CardView(card: card, showScores: settings.published.showScores)
                                    .transition(Motion.Transitions.card(index: resurfacer.siteCards.count + i))
                            }
                        }
                    }
                    .padding(.bottom, Theme.Space.l)
                }
                .scrollIndicators(.never)
            }
        }
        .padding(.horizontal, Theme.Space.windowMargin)
        // New cards fade and rise one after another. Cards that stay don't move while you type.
        .motion(Motion.insert, value: resurfacer.cards.map { $0.id })
    }

    var emptyText: String {
        if !resurfacer.hasContext { return "Open a page or a note. Things you've seen before that relate to it show up here." }
        return "Nothing related yet."
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
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                RowIcon(symbol: icon)
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
            }
            if !m.passage.isEmpty {
                Text(m.passage)
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
                Text(String(format: "keyword %.2f | meaning %.2f | names %.2f | score %.2f%@",
                            m.keyword, m.semantic, m.entity, m.score, m.penalized ? " | dismissed before" : ""))
                    .font(Theme.Font.mono(10))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: Theme.Space.l) {
                Button("Open") { model.open(card) }
                Button(card.feedback ?? "Add to research") {
                    let msg = model.addToResearch(card)
                    model.resurfacer.setFeedback(msg, for: card)
                }
                .disabled(card.feedback != nil)
                Spacer(minLength: 0)
                IconButton(symbol: "xmark", help: "Dismiss", width: 20, height: 20, symbolSize: 9) {
                    model.resurfacer.dismiss(card)
                }
                .opacity(hovering ? 1 : 0.6)
            }
            .buttonStyle(QuietActionStyle(accent: accent))
            .frame(height: 20)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.l)
        .padding(.bottom, Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard(hovering: hovering)
        .contentShape(Rectangle())
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
