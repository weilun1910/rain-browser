import AppKit
import SwiftUI
import WebKit

// The Related shelf: cards float as small pills along the bottom of the page or note, and hovering
// one opens what the right panel's card shows. Values live in ShelfStyle, state and rules in
// RelatedShelfState. See notes/plans/2026-11-05-related-shelf.md.

extension View {
    /// Floats the shelf over the bottom of the focused pane. `frame` is that pane in this view's space.
    func relatedShelf(frame: CGRect) -> some View { modifier(RelatedShelfHost(frame: frame)) }
}

struct RelatedShelfHost: ViewModifier {
    let frame: CGRect
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var prefs = RelatedPrefs.shared

    func body(content: Content) -> some View {
        let shelf = prefs.mode == .shelf
        return content
            .environment(\.relatedShelfClearance, shelf && !prefs.value.shelfHidden ? ShelfStyle.clearance : 0)
            .overlay(alignment: .topLeading) {
                if shelf {
                    RelatedShelfLayer(resurfacer: model.resurfacer, size: frame.size)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                        // Moving to another pane of a split glides; resizing the window doesn't.
                        .animation(ShelfStyle.motion(ShelfStyle.shelf), value: model.currentTab?.id)
                }
            }
    }
}

/// Where the pills and the graph button sit, in the layer's space, for anchoring the popover.
struct ShelfAnchorsKey: PreferenceKey {
    static let defaultValue: [ShelfTarget: CGRect] = [:]
    static func reduce(value: inout [ShelfTarget: CGRect], nextValue: () -> [ShelfTarget: CGRect]) { value.merge(nextValue()) { $1 } }
}

struct RelatedShelfLayer: View {
    @ObservedObject var resurfacer: Resurfacer
    let size: CGSize
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var prefs = RelatedPrefs.shared
    @ObservedObject var state = ShelfState.shared
    @ObservedObject var models = ModelStore.shared
    @ObservedObject var settings = Settings.shared
    @State private var anchors: [ShelfTarget: CGRect] = [:]
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Namespace private var glass

    var progress: Double? { state.progressOverride ?? models.overallProgress }

    /// On glass the pills hold their own against the page, so the fade behind them goes. The solid
    /// pills of the Reduce Transparency fallback keep it.
    var usesFade: Bool { Theme.GlassStyle.isSolid(reduceTransparency) }

    var presence: ShelfLayout.Presence {
        ShelfLayout.presence(.init(mode: prefs.mode, hidden: prefs.value.shelfHidden, hasCards: !resurfacer.cards.isEmpty,
                                   downloading: progress != nil, typing: state.typing, peekOpen: model.peek != nil,
                                   firstRunDone: settings.published.firstRunDone))
    }

    /// The page keeps its inset under Peek and while typing, so it doesn't reflow back and forth.
    var insetsPage: Bool {
        prefs.mode == .shelf && !prefs.value.shelfHidden && !resurfacer.cards.isEmpty && settings.published.firstRunDone
    }

    var body: some View {
        let p = presence
        let entries = ShelfLayout.entries(sites: resurfacer.siteCards, docs: resurfacer.docCards, progress: progress)
        let covers = ShelfLayout.coversPage(p, hasCards: !resurfacer.cards.isEmpty)
        ZStack(alignment: .bottomLeading) {
            if let img = state.backdrop {
                Image(nsImage: img).resizable().frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: ShelfStyle.cardRadius, style: .continuous))
                    .allowsHitTesting(false)
            }
            if usesFade {
                ShelfFade()
                    .frame(width: size.width, height: ShelfStyle.fadeHeight)
                    .opacity(covers ? 1 : 0)
                    .allowsHitTesting(false)
            }
            if p != .gone {
                ShelfRow(entries: entries, resurfacer: resurfacer)
                    .padding(.horizontal, ShelfStyle.margin - ShelfRow.inner)
                    .padding(.bottom, ShelfStyle.margin - ShelfRow.inner)
                    .frame(width: size.width, alignment: .leading)
                    .offset(y: p == .sunk && !ShelfStyle.reduceMotion ? ShelfStyle.pillHeight + ShelfStyle.margin + 8 : 0)
                    .opacity(p == .sunk ? 0 : 1)
                    .allowsHitTesting(p == .shown)
                    .transition(ShelfStyle.reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 12)))
            }
            // The popover has a container of its own, so it keeps one glass as it glides from
            // pill to pill. The pills' container sits inside the row's scroll view, so the row's
            // clipping and edge fade apply to their glass too.
            GlassEffectContainer(spacing: Theme.GlassStyle.containerSpacing) {
                if p == .shown, let t = state.open, let a = anchors[t] {
                    ShelfPopover(target: t, anchor: a, container: size, resurfacer: resurfacer, progress: progress, glass: glass)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .bottomLeading)
        }
        .frame(width: size.width, height: size.height, alignment: .bottomLeading)
        .coordinateSpace(name: "shelf")
        .onPreferenceChange(ShelfAnchorsKey.self) { anchors = $0 }
        .animation(ShelfStyle.motion(ShelfStyle.shelf), value: p)
        .onChange(of: InsetKey(tab: model.currentTab?.id, on: insetsPage), initial: true) { applyInset() }
        .onChange(of: resurfacer.context?.key) { state.closeNow() }
        .onChange(of: p) { if p != .shown && !state.pinned { state.closeNow() } }
        .onDisappear { ShelfInsets.clear() }
    }

    struct InsetKey: Equatable { let tab: UUID?; let on: Bool }

    func applyInset() {
        let tab = model.currentTab
        let wv = tab?.kind == .web ? tab?.webView : nil
        ShelfInsets.apply(wv, bottom: insetsPage ? ShelfStyle.clearance : 0)
    }
}

/// The gentle floor behind the pills: toward black in dark mode, toward the light frame in light mode.
struct ShelfFade: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let s = scheme == .dark ? ShelfStyle.fadeStrength.dark : ShelfStyle.fadeStrength.light
        let c = ShelfStyle.fadeColor
        let r = ShelfStyle.cardRadius
        // Eased stops, so the fade has no visible top edge.
        LinearGradient(stops: [
            .init(color: c.opacity(0), location: 0),
            .init(color: c.opacity(s * 0.10), location: 0.3),
            .init(color: c.opacity(s * 0.38), location: 0.6),
            .init(color: c.opacity(s * 0.75), location: 0.85),
            .init(color: c.opacity(s), location: 1),
        ], startPoint: .top, endPoint: .bottom)
        .clipShape(UnevenRoundedRectangle(cornerRadii: .init(topLeading: 0, bottomLeading: r, bottomTrailing: r, topTrailing: 0), style: .continuous))
    }
}

// MARK: - The row

struct ShelfRow: View {
    let entries: [ShelfEntry]
    @ObservedObject var resurfacer: Resurfacer
    @ObservedObject var state = ShelfState.shared
    @EnvironmentObject var model: BrowserModel
    @State private var position = ScrollPosition(edge: .leading)
    @State private var geo = Geo()
    @State private var offsets: [String: CGFloat] = [:]
    @State private var globalFrame: CGRect = .zero
    @State private var wheel: Any?
    @FocusState private var focused: ShelfTarget?

    /// Room inside the scroll view for shadows and the hover lift.
    static let inner: CGFloat = 10

    struct Geo: Equatable { var x: CGFloat = 0; var content: CGFloat = 0; var container: CGFloat = 0 }

    var contentWidth: CGFloat {
        let widths = entries.map { ShelfMetrics.width($0) }
        return widths.reduce(0, +) + ShelfStyle.pillGap * CGFloat(max(0, widths.count - 1)) + Self.inner * 2
    }

    var canLeft: Bool { geo.x > 1 }
    var canRight: Bool { geo.x < geo.content - geo.container - 1 }

    var body: some View {
        HStack(spacing: ShelfStyle.pillGap) {
            ScrollView(.horizontal) {
                GlassEffectContainer(spacing: Theme.GlassStyle.containerSpacing) {
                HStack(spacing: ShelfStyle.pillGap) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                        entry(e, index: i)
                            .background(GeometryReader { g in
                                Color.clear.preference(key: ShelfOffsetsKey.self, value: [e.id: g.frame(in: .named("shelfContent")).minX])
                            })
                            .transition(.asymmetric(
                                insertion: ShelfStyle.reduceMotion ? .opacity.animation(ShelfStyle.reducedFade)
                                    : .opacity.combined(with: .offset(y: 6)).combined(with: .scale(scale: 0.96, anchor: .bottom))
                                        .animation(.spring(duration: 0.34, bounce: 0.08).delay(Double(min(i, 8)) * ShelfStyle.stagger)),
                                // Pills leave at once, so a replaced row never overlaps the new one.
                                removal: .identity))
                    }
                }
                }
                .padding(Self.inner)
                .coordinateSpace(name: "shelfContent")
                .scrollTargetLayout()
                .onPreferenceChange(ShelfOffsetsKey.self) { offsets = $0 }
                .animation(ShelfStyle.motion(.spring(duration: 0.3, bounce: 0)), value: entries.map(\.id))
            }
            .scrollIndicators(.never)
            .scrollTargetBehavior(.viewAligned(limitBehavior: .never))
            .scrollPosition($position)
            .onScrollGeometryChange(for: Geo.self) { g in
                Geo(x: g.contentOffset.x, content: g.contentSize.width, container: g.containerSize.width)
            } action: { old, new in
                geo = new
                // Scrolling moves the pills out from under the popover, so it closes.
                if abs(new.x - old.x) > 3, !state.pinned { state.closeNow() }
            }
            .mask(edgeMask)
            // Hugs the pills, so the rest of the bottom edge still belongs to the page.
            .frame(maxWidth: contentWidth)
            .frame(height: ShelfStyle.pillHeight + Self.inner * 2)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { globalFrame = $0 }
            if ShelfGraph.isAvailable {
                ShelfGraphButton()
            }
            Spacer(minLength: 0)
        }
        .onChange(of: focused) { state.focus(focused) }
        .onChange(of: state.revealRequest) { reveal(state.revealRequest) }
        .onAppear { installWheel() }
        .onDisappear { if let w = wheel { NSEvent.removeMonitor(w) }; wheel = nil }
    }

    @ViewBuilder func entry(_ e: ShelfEntry, index: Int) -> some View {
        switch e {
        case .card(let c):
            ShelfPill(card: c, width: ShelfMetrics.width(e))
                .focusable()
                .focusEffectDisabled()
                .focused($focused, equals: .card(c.id))
                .overlay {
                    if focused == .card(c.id) {
                        RoundedRectangle(cornerRadius: ShelfStyle.pillRadius, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5)
                            .allowsHitTesting(false)
                    }
                }
                .onKeyPress(.return) { model.open(c); return .handled }
        case .divider:
            Rectangle().fill(ShelfStyle.divider)
                .frame(width: 1, height: ShelfStyle.dividerHeight)
                .padding(.horizontal, ShelfStyle.dividerGap)
                .frame(width: ShelfMetrics.width(e))
        case .progress(let p):
            ShelfProgressPill(progress: p, width: ShelfMetrics.width(e))
        }
    }

    /// Fades the row out at an edge with more to scroll to.
    var edgeMask: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: canLeft ? ShelfStyle.edgeFade : 0)
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: canRight ? ShelfStyle.edgeFade : 0)
        }
        .animation(ShelfStyle.hover, value: canLeft)
        .animation(ShelfStyle.hover, value: canRight)
    }

    /// A mouse wheel turns into one pill per notch. Trackpads scroll natively and snap.
    func installWheel() {
        guard wheel == nil else { return }
        wheel = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
            MainActor.assumeIsolated { handleWheel(e) } ? nil : e
        }
    }

    /// Scrolls just far enough that the pill for `t` sits inside the row, clear of the edge fade.
    func reveal(_ t: ShelfTarget?) {
        guard case .card(let id)? = t, let e = entries.first(where: { $0.card?.id == id }),
              let minX = offsets[e.id], geo.content > geo.container + 1 else { return }
        let maxX = geo.content - geo.container
        let end = minX + ShelfMetrics.width(e) + ShelfStyle.edgeFade + Self.inner
        let x = min(max(0, end - geo.container), maxX)
        guard x > geo.x else { return }
        withAnimation(ShelfStyle.motion(.easeOut(duration: 0.2))) { position.scrollTo(x: x) }
    }

    func handleWheel(_ e: NSEvent) -> Bool {
        guard !e.hasPreciseScrollingDeltas, abs(e.scrollingDeltaY) > abs(e.scrollingDeltaX),
              geo.content > geo.container + 1, let view = e.window?.contentView else { return false }
        var p = view.convert(e.locationInWindow, from: nil)
        if !view.isFlipped { p.y = view.bounds.height - p.y }
        guard globalFrame.contains(p) else { return false }
        let stops = offsets.values.map { $0 - Self.inner }.sorted()
        let maxX = geo.content - geo.container
        let forward = e.scrollingDeltaY < 0
        let target = forward ? (stops.first { $0 > geo.x + 4 } ?? maxX) : (stops.last { $0 < geo.x - 4 } ?? 0)
        withAnimation(ShelfStyle.motion(.easeOut(duration: 0.2))) { position.scrollTo(x: min(max(0, target), maxX)) }
        return true
    }
}

struct ShelfOffsetsKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) { value.merge(nextValue()) { $1 } }
}

/// Pill widths, measured from the title so the row knows its own width before it draws.
@MainActor
enum ShelfMetrics {
    static let titleFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let captionFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    static func textWidth(_ s: String, _ font: NSFont) -> CGFloat {
        ceil(NSAttributedString(string: s, attributes: [.font: font]).size().width)
    }

    static func width(_ e: ShelfEntry) -> CGFloat {
        let pad = ShelfStyle.pillPadding * 2 + ShelfStyle.pillIcon + ShelfStyle.pillIconGap
        switch e {
        case .card(let c):
            let t = textWidth(ShelfText.title(c), titleFont)
            return min(ShelfStyle.pillMaxWidth, max(ShelfStyle.pillMinWidth, pad + t + 1))
        case .divider: return 1 + ShelfStyle.dividerGap * 2
        case .progress(let p): return pad + textWidth(ShelfText.progressShort(p), captionFont) + 1
        }
    }
}

/// Words the shelf shows.
enum ShelfText {
    static func title(_ c: Card) -> String {
        let t = c.match.doc.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? Snippet.prettyURL(c.match.doc.url) : t
    }

    static func progressShort(_ p: Double) -> String { "Models \(Int(p * 100))%" }

    /// Plain text from a Markdown passage: no heading marks, emphasis, checkboxes or link syntax.
    static func plain(_ s: String) -> String {
        var t = s
        let patterns: [(String, String)] = [
            ("(?m)^\\s{0,3}#{1,6}\\s+", ""),
            ("(?m)^\\s*[-*+]\\s+\\[[ xX]\\]\\s+", ""),
            ("(?m)^\\s*[-*+]\\s+", ""),
            ("(?m)^\\s*>\\s?", ""),
            ("\\[\\[([^\\]|]+)(\\|[^\\]]+)?\\]\\]", "$1"),
            ("\\[([^\\]]+)\\]\\([^)]+\\)", "$1"),
            ("(\\*\\*|__)(.+?)\\1", "$2"),
            ("\\*\\*|__", ""),
            ("`([^`]+)`", "$1"),
            ("\\s*#{1,6}\\s+", " "),
            ("\\s*\\n\\s*", " "),
            ("\\s{2,}", " "),
        ]
        for (p, r) in patterns { t = t.replacingOccurrences(of: p, with: r, options: .regularExpression) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// What a card shows next to its title: the site, or where the note or doc lives.
@MainActor
enum ShelfSource {
    static func symbol(_ m: Match) -> String {
        switch m.doc.source {
        case .web, .chrome:
            if m.section == .docs { return "doc.richtext" }
            return m.doc.source == .web ? "globe" : "clock.arrow.circlepath"
        case .note, .markdown: return "note.text"
        case .notion, .gdocs: return "doc.richtext"
        case .granola: return "person.2.wave.2"
        }
    }

    static func isPage(_ m: Match) -> Bool { [.web, .chrome, .notion, .gdocs].contains(m.doc.source) }

    static func label(_ m: Match, model: BrowserModel) -> String {
        switch m.doc.source {
        case .web, .chrome:
            let host = Snippet.prettyURL(m.doc.url).split(separator: "/").first.map(String.init) ?? ""
            if let folder = model.folderName(forURL: m.doc.url) { return "\(host)  |  \(folder)" }
            return host
        case .note, .markdown: return m.doc.project ?? "Notes"
        case .notion: return "Notion"
        case .gdocs: return "Google Docs"
        case .granola: return "Granola meeting"
        }
    }
}

// MARK: - Pills

/// A pill's surface: Liquid Glass that answers the pointer, with a faint fill on the glass while
/// it's hovered or open. Under Reduce Transparency, the solid pill with its two-layer shadow.
struct PillSurface: ViewModifier {
    let hovering: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: ShelfStyle.pillRadius, style: .continuous)
        return Group {
            if Theme.GlassStyle.isSolid(reduceTransparency) {
                content
                    .background(shape.fill(hovering ? ShelfStyle.pillHover : ShelfStyle.pillFill)
                        .shelfShadow(ShelfStyle.pillShadow(dark: scheme == .dark, hovering: hovering)))
                    .overlay(shape.strokeBorder(ShelfStyle.hairline, lineWidth: 0.5).allowsHitTesting(false))
            } else {
                content.glassControl(radius: ShelfStyle.pillRadius, active: hovering)
            }
        }
        .contentShape(shape)
        .offset(y: hovering && !ShelfStyle.reduceMotion ? -1 : 0)
        .animation(ShelfStyle.hover, value: hovering)
    }
}

struct ShelfPill: View {
    let card: Card
    let width: CGFloat
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var state = ShelfState.shared
    @State private var hovering = false

    var target: ShelfTarget { .card(card.id) }
    var m: Match { card.match }

    var body: some View {
        HStack(spacing: ShelfStyle.pillIconGap) {
            SourceIcon(url: m.doc.url, isPage: ShelfSource.isPage(m), symbol: ShelfSource.symbol(m), size: ShelfStyle.pillIcon)
            Text(ShelfText.title(card))
                .font(ShelfStyle.pillTitle)
                .foregroundStyle(hovering || state.open == target ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, ShelfStyle.pillPadding)
        .frame(width: width, height: ShelfStyle.pillHeight, alignment: .leading)
        .modifier(PillSurface(hovering: hovering || state.open == target))
        .background(GeometryReader { g in Color.clear.preference(key: ShelfAnchorsKey.self, value: [target: g.frame(in: .named("shelf"))]) })
        .onHover { h in
            hovering = h
            if h { state.enter(target) } else { state.leave(target) }
        }
        .onTapGesture { state.closeNow(); model.open(card) }
        .contextMenu { ShelfCardMenu(card: card) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ShelfText.title(card))
        .accessibilityHint(card.reason)
        .accessibilityAddTraits(.isButton)
    }
}

struct ShelfCardMenu: View {
    let card: Card
    @EnvironmentObject var model: BrowserModel
    var m: Match { card.match }
    var body: some View {
        Button("Open") { model.open(card) }
        Button(card.feedback ?? "Add to research") {
            let msg = model.addToResearch(card)
            model.resurfacer.setFeedback(msg, for: card)
        }
        .disabled(card.feedback != nil)
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
        Button("Dismiss") { ShelfState.shared.closeNow(); model.resurfacer.dismiss(card) }
        Divider()
        Button("Show Related as a Sidebar") { RelatedPrefs.shared.setMode(.sidebar) }
    }
}

/// The model download, as a quiet pill with a thin ring.
struct ShelfProgressPill: View {
    let progress: Double
    let width: CGFloat
    @ObservedObject var state = ShelfState.shared
    @State private var hovering = false

    var body: some View {
        HStack(spacing: ShelfStyle.pillIconGap) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 1.5)
                Circle().trim(from: 0, to: max(0.02, progress)).stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: ShelfStyle.pillIcon - 2, height: ShelfStyle.pillIcon - 2)
            .frame(width: ShelfStyle.pillIcon)
            Text(ShelfText.progressShort(progress))
                .font(ShelfStyle.pillCaption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, ShelfStyle.pillPadding)
        .frame(width: width, height: ShelfStyle.pillHeight, alignment: .leading)
        .modifier(PillSurface(hovering: hovering))
        .background(GeometryReader { g in Color.clear.preference(key: ShelfAnchorsKey.self, value: [.progress: g.frame(in: .named("shelf"))]) })
        .onHover { h in
            hovering = h
            if h { state.enter(.progress) } else { state.leave(.progress) }
        }
    }
}

/// Opens the local graph above the shelf.
struct ShelfGraphButton: View {
    @ObservedObject var state = ShelfState.shared
    @State private var hovering = false

    var body: some View {
        Button { state.toggleGraph() } label: {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(hovering || state.open == .graph ? .primary : .secondary)
                .frame(width: ShelfStyle.pillHeight, height: ShelfStyle.pillHeight)
                .modifier(PillSurface(hovering: hovering || state.open == .graph))
        }
        .buttonStyle(.plain)
        .help("Local graph")
        .onHover { hovering = $0 }
        .background(GeometryReader { g in Color.clear.preference(key: ShelfAnchorsKey.self, value: [.graph: g.frame(in: .named("shelf"))]) })
    }
}

// MARK: - The popover

struct ShelfPopover: View {
    let target: ShelfTarget
    let anchor: CGRect
    let container: CGSize
    @ObservedObject var resurfacer: Resurfacer
    let progress: Double?
    let glass: Namespace.ID
    @ObservedObject var state = ShelfState.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var width: CGFloat { target == .graph ? ShelfStyle.graphPopoverWidth : ShelfStyle.popoverWidth }

    var x: CGFloat {
        let inset = ShelfStyle.margin
        return min(max(inset, anchor.midX - width / 2), max(inset, container.width - width - inset))
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ShelfStyle.popoverRadius, style: .continuous)
        let grow = UnitPoint(x: min(1, max(0, (anchor.midX - x) / width)), y: 1)
        ZStack(alignment: .bottomLeading) {
            content
                .id(target)
                .transition(.opacity)
        }
        .frame(width: width, alignment: .leading)
        .clipShape(shape)
        .modifier(ShelfPopoverSurface(solid: Theme.GlassStyle.isSolid(reduceTransparency), dark: scheme == .dark, glass: glass))
        .contentShape(shape)
        .onHover { inside in if inside { state.enterPopover() } else { state.leavePopover() } }
        .offset(x: x, y: -(container.height - anchor.minY) - ShelfStyle.popoverGap)
        .transition(ShelfStyle.reduceMotion ? .opacity
            : .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: grow)).combined(with: .offset(y: 6)),
                          removal: .opacity.combined(with: .scale(scale: 0.98, anchor: grow))))
    }

    @ViewBuilder var content: some View {
        switch target {
        case .card(let id):
            if let c = resurfacer.cards.first(where: { $0.id == id }) { ShelfCardDetail(card: c) }
        case .progress:
            VStack(alignment: .leading, spacing: 6) {
                Text("Getting on-device models ready, \(Int((progress ?? 0) * 100))%")
                    .font(ShelfStyle.popTitle)
                Text("Until they're ready, Related uses Apple's built-in embedding and keyword scoring. Settings has the details, under Models.")
                    .font(ShelfStyle.popPassage)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(ShelfStyle.popoverPadding)
        case .graph:
            if let make = ShelfGraph.provider {
                make(resurfacer)
                    .padding(.horizontal, ShelfStyle.popoverPadding - 4)
                    .padding(.top, ShelfStyle.popoverPadding - 6)
                    .padding(.bottom, ShelfStyle.popoverPadding - 10)
                    .frame(width: ShelfStyle.graphPopoverWidth)
            }
        }
    }
}

/// The popover's surface: one Liquid Glass panel with a stable identity, so moving between pills
/// slides the same glass rather than making a new one. Solid under Reduce Transparency.
struct ShelfPopoverSurface: ViewModifier {
    let solid: Bool
    let dark: Bool
    let glass: Namespace.ID
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: ShelfStyle.popoverRadius, style: .continuous)
        if solid {
            content
                .background(shape.fill(ShelfStyle.popoverFill).shelfShadow(ShelfStyle.popoverShadow(dark: dark)))
                .overlay(shape.strokeBorder(ShelfStyle.hairline, lineWidth: 0.5).allowsHitTesting(false))
        } else {
            content
                .glassPanel(radius: ShelfStyle.popoverRadius)
                .glassEffectID("shelf-popover", in: glass)
                .glassEffectTransition(.materialize)
        }
    }
}

/// What the right panel's card shows, in the popover above a pill.
struct ShelfCardDetail: View {
    let card: Card
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var settings = Settings.shared
    var m: Match { card.match }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 9) {
                SourceIcon(url: m.doc.url, isPage: ShelfSource.isPage(m), symbol: ShelfSource.symbol(m), size: 16)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ShelfText.title(card))
                        .font(ShelfStyle.popTitle)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(ShelfSource.label(m, model: model))
                        .font(ShelfStyle.popMeta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            let passage = ShelfText.plain(m.passage)
            if !passage.isEmpty {
                Text(passage)
                    .font(ShelfStyle.popPassage)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 8) {
                Capsule().fill(ShelfStyle.reasonRule).frame(width: 2)
                Text(card.reason)
                    .font(ShelfStyle.popReason)
                    .foregroundStyle(.secondary)
                    .lineSpacing(1.5)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
            if settings.published.showScores {
                Text(String(format: "keyword %.2f | meaning %.2f | names %.2f | score %.2f%@%@",
                            m.keyword, m.semantic, m.entity, m.score,
                            m.rerank.map { String(format: " | reranker %.2f", $0) } ?? "",
                            m.penalized ? " | dismissed before" : ""))
                    .font(ShelfStyle.popScores)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 14) {
                ShelfAction(title: "Open") { ShelfState.shared.closeNow(); model.open(card) }
                ShelfAction(title: card.feedback ?? "Add to research") {
                    let msg = model.addToResearch(card)
                    model.resurfacer.setFeedback(msg, for: card)
                }
                .disabled(card.feedback != nil)
                Spacer()
                ShelfAction(symbol: "xmark", title: "Dismiss") {
                    ShelfState.shared.closeNow()
                    model.resurfacer.dismiss(card)
                }
            }
            .padding(.top, 1)
        }
        .padding(ShelfStyle.popoverPadding)
    }
}

/// A quiet text action that brightens on hover.
struct ShelfAction: View {
    var symbol: String?
    let title: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)).frame(width: 16, height: 16) }
                else { Text(title).font(ShelfStyle.popAction) }
            }
            .foregroundStyle(enabled ? (hovering ? Color.accentColor : Color.secondary) : Color.secondary.opacity(0.6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(symbol == nil ? "" : title)
        .onHover { hovering = $0 }
        .animation(ShelfStyle.hover, value: hovering)
    }
}

// MARK: - Controls elsewhere

/// The sidebar's Related button: shows or hides Related in whichever mode is on.
struct RelatedToggleButton: View {
    @ObservedObject var prefs = RelatedPrefs.shared
    @ObservedObject var gate = RelatedGate.shared
    var help: String {
        let base = prefs.mode == .shelf ? "Show or hide Related (Shift-Cmd-R)" : "Related panel (Shift-Cmd-R)"
        guard let p = gate.pause, p.isPower else { return base }
        return base + ". " + p.short + "."
    }
    var body: some View {
        NavButton(symbol: prefs.mode == .shelf ? "rectangle.bottomthird.inset.filled" : "sidebar.right", help: help) {
            RelatedPrefs.shared.toggleVisible()
        }
    }
}

/// Settings, under General: Related as a shelf or a sidebar, and when it runs.
struct RelatedLayoutSection: View {
    @ObservedObject var prefs = RelatedPrefs.shared
    @ObservedObject var gate = RelatedGate.shared
    var body: some View {
        Section {
            Picker("Show Related as", selection: Binding(get: { prefs.mode }, set: { RelatedPrefs.shared.setMode($0) })) {
                ForEach(RelatedMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Run Related", selection: Binding(get: { prefs.value.power }, set: { p in RelatedPrefs.shared.update { $0.power = p } })) {
                ForEach(RelatedPower.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if let p = gate.pause, p.isPower, prefs.value.power == .pluggedIn {
                Text(p.short + ".")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Related")
        } footer: {
            Text("The shelf floats small cards along the bottom of the page. Hover one to see why it's related. The sidebar shows full cards in a panel on the right. Ctrl-Cmd-R switches between them.\n\nRelated runs AI models on your Mac for each page you stay on, which uses a lot of battery. By default it only runs when your Mac is plugged in.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
