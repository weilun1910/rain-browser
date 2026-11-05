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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Related")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                WindowDragArea()
                NavButton(symbol: "sidebar.right", help: "Hide related panel") {
                    Settings.shared.update { $0.rightPanelOpen = false }
                }
            }
            .frame(height: 30)
            .padding(.top, 4)

            if resurfacer.cards.isEmpty {
                Text(emptyText)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if !resurfacer.siteCards.isEmpty {
                            SectionLabel(CardSection.sites.title)
                            ForEach(resurfacer.siteCards) { card in
                                CardView(card: card, showScores: settings.published.showScores)
                            }
                        }
                        if !resurfacer.docCards.isEmpty {
                            SectionLabel(CardSection.docs.title)
                                .padding(.top, resurfacer.siteCards.isEmpty ? 0 : 6)
                            ForEach(resurfacer.docCards) { card in
                                CardView(card: card, showScores: settings.published.showScores)
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.never)
            }
            LocalGraphSlot(resurfacer: resurfacer)
                .padding(.bottom, 8)
        }
        .padding(.horizontal, 10)
        .transaction { $0.animation = nil }
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
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.leading, 2)
    }
}

struct CardView: View {
    let card: Card
    let showScores: Bool
    @EnvironmentObject var model: BrowserModel
    @State private var hovering = false

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
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.doc.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    Text(label)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            if !m.passage.isEmpty {
                Text(m.passage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(card.reason)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if showScores {
                Text(String(format: "keyword %.2f | meaning %.2f | names %.2f | score %.2f%@",
                            m.keyword, m.semantic, m.entity, m.score, m.penalized ? " | dismissed before" : ""))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 12) {
                Button("Open") { model.open(card) }
                Button(card.feedback ?? "Add to research") {
                    let msg = model.addToResearch(card)
                    if msg.hasPrefix("Added") { GraphRecorder.shared.researchAdded(addedKey: card.match.doc.key, model: model) }
                    model.resurfacer.setFeedback(msg, for: card)
                }
                .disabled(card.feedback != nil)
                Spacer()
                Button { model.resurfacer.dismiss(card) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                }
                .help("Dismiss")
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(hovering ? Color.accentColor : Color.secondary)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .textBackgroundColor).opacity(hovering ? 0.95 : 0.75)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
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
