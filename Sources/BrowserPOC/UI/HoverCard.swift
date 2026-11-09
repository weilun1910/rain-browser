import SwiftUI

// A small card with a tab's name and site, beside an icon whose name isn't on screen: the icon
// column's tabs, folders and spaces, Essentials in their box, and pinned tabs in the tab bar.
// It follows Chrome's tab hover card (notes/research/2026-11-06-icon-mode-toolbar-hover-menu.md):
// 300 ms the first time, then it slides from icon to icon at once while the pointer runs down
// the column, and comes back at once within 300 ms of going. Its top lines up with the icon's,
// up to two lines of title and the site under them. It's drawn over the whole window, so it
// never goes under the page, and it never takes a click.

/// What the card shows, and where.
struct HoverCardItem: Equatable {
    var id: AnyHashable
    var title: String
    var detail: String?
    /// The icon, in the window's coordinates.
    var frame: CGRect
    /// The card sits outside this: the icon itself, or the Essentials box it's in, so the card
    /// doesn't cover the tiles beside it.
    var bounds: CGRect
    var side: Edge
}

@MainActor
final class HoverCards: ObservableObject {
    static let shared = HoverCards()

    @Published private(set) var item: HoverCardItem?
    /// Offscreen shots have no pointer to rest, so they turn this on and read the card each
    /// icon would show, at the place it would show it.
    var recorded: [AnyHashable: HoverCardItem]?
    private var pending: DispatchWorkItem?
    private var pendingID: AnyHashable?
    private var lastHidden = Date.distantPast

    /// The pointer rests this long on the first icon before its card shows, Chrome's minimum.
    static let delay: TimeInterval = 0.3
    /// Once a card has gone, another icon within this long shows its card at once, as in Chrome.
    static let warm: TimeInterval = 0.3
    /// Leaving an icon waits this long before the card goes, so moving to the next icon swaps
    /// the card rather than closing and opening it.
    static let linger: TimeInterval = 0.08
    static let slide = Animation.easeOut(duration: 0.2)
    static let fadeIn = Animation.easeOut(duration: 0.2)
    static let fadeOut = Animation.easeIn(duration: 0.15)

    func enter(_ i: HoverCardItem) {
        cancel()
        if item != nil {
            // Slides to the next icon, as Chrome's does over 200 ms.
            Motion.run(Self.slide) { item = i }
            return
        }
        if Date().timeIntervalSince(lastHidden) < Self.warm {
            Motion.run(Self.fadeIn, fadeOnly: true) { item = i }
            return
        }
        schedule(i.id, after: Self.delay) { [weak self] in Motion.run(Self.fadeIn, fadeOnly: true) { self?.item = i } }
    }

    func leave(_ id: AnyHashable) {
        if pendingID == id { cancel() }
        guard item?.id == id else { return }
        schedule(id, after: Self.linger) { [weak self] in self?.hide() }
    }

    /// The icon was clicked, dragged or went away.
    func hide() {
        cancel()
        guard item != nil else { return }
        lastHidden = Date()
        Motion.run(Self.fadeOut, fadeOnly: true) { item = nil }
    }

    private func cancel() {
        pending?.cancel()
        pending = nil
        pendingID = nil
    }

    private func schedule(_ id: AnyHashable, after: TimeInterval, _ body: @escaping @MainActor () -> Void) {
        let w = DispatchWorkItem { MainActor.assumeIsolated { body() } }
        pending = w
        pendingID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: w)
    }
}

private struct HoverCardSideKey: EnvironmentKey { static let defaultValue: Edge? = nil }
private struct HoverCardBoundsKey: EnvironmentKey { static let defaultValue: CGRect? = nil }

extension EnvironmentValues {
    /// Which side of an icon its card goes on, or nil where icons have their titles beside them
    /// and keep a plain tooltip.
    var hoverCardSide: Edge? {
        get { self[HoverCardSideKey.self] }
        set { self[HoverCardSideKey.self] = newValue }
    }
    /// A box the card sits outside of, set by the Essentials box for its tiles.
    var hoverCardBounds: CGRect? {
        get { self[HoverCardBoundsKey.self] }
        set { self[HoverCardBoundsKey.self] = newValue }
    }
}

private struct HoverCardSource: ViewModifier {
    let id: AnyHashable
    let title: String
    let detail: String?
    @Environment(\.hoverCardSide) private var side
    @Environment(\.hoverCardBounds) private var bounds
    /// Where the icon is. Kept in a plain box, so scrolling the column doesn't redraw every icon
    /// each frame just to remember it.
    @State private var place = Place()

    final class Place { var frame: CGRect = .zero }

    private func item(_ side: Edge) -> HoverCardItem {
        HoverCardItem(id: id, title: title, detail: detail, frame: place.frame, bounds: bounds ?? place.frame, side: side)
    }

    func body(content: Content) -> some View {
        if let side {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { f in
                    place.frame = f
                    if HoverCards.shared.recorded != nil { HoverCards.shared.recorded?[id] = item(side) }
                }
                .onHover { inside in
                    let cards = HoverCards.shared
                    if inside {
                        cards.enter(item(side))
                    } else {
                        cards.leave(id)
                    }
                }
                .onChange(of: bounds) { _, _ in
                    if HoverCards.shared.recorded != nil { HoverCards.shared.recorded?[id] = item(side) }
                }
                .onDisappear { HoverCards.shared.leave(id) }
                .accessibilityLabel(title)
        } else {
            content.help(detail.map { "\(title)\n\($0)" } ?? title)
        }
    }
}

extension View {
    /// Shows `title` and `detail` in a card beside this icon on hover, where the layout asks for
    /// cards, and as a tooltip anywhere else.
    /// With `enabled` off it leaves the view alone, for rows that show their titles.
    @ViewBuilder
    func hoverCard(id: AnyHashable, title: String, detail: String? = nil, enabled: Bool = true) -> some View {
        if enabled { modifier(HoverCardSource(id: id, title: title, detail: detail)) } else { self }
    }

    func hoverCard(_ tab: Tab) -> some View {
        hoverCard(id: tab.id, title: tab.displayTitle, detail: tab.hoverDetail)
    }
}

extension Tab {
    /// The line under a tab's name on its hover card: the site, as Chrome shows it.
    var hoverDetail: String? {
        if isNote { return "Note" }
        guard isWeb, let url, let host = url.host() else { return nil }
        // The demo's Google Docs, Notion and Granola pages say which app they stand in for.
        if url.scheme == DemoScheme.scheme { return DemoContent.sourceLabel(host) }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// The card, over everything in the window.
struct HoverCardLayer: View {
    @ObservedObject private var cards = HoverCards.shared

    static let gap: CGFloat = 6
    /// Chrome's card is 256 pt wide. This one hugs shorter titles.
    static let maxWidth: CGFloat = 256
    /// Room the card is laid out in. It hugs its text inside this.
    private static let room = CGSize(width: maxWidth, height: 80)

    var body: some View {
        GeometryReader { g in
            if let i = cards.item {
                let o = g.frame(in: .global).origin
                let f = i.frame.offsetBy(dx: -o.x, dy: -o.y)
                let b = i.bounds.offsetBy(dx: -o.x, dy: -o.y)
                let w = Self.room.width, h = Self.room.height
                switch i.side {
                // Beside the icon with their tops lined up, like Chrome's card beside a vertical tab.
                case .trailing:
                    card(i).frame(width: w, height: h, alignment: .topLeading)
                        .position(x: b.maxX + Self.gap + w / 2, y: f.minY + h / 2)
                        .transition(appear(x: -4, y: 0))
                case .leading:
                    card(i).frame(width: w, height: h, alignment: .topTrailing)
                        .position(x: b.minX - Self.gap - w / 2, y: f.minY + h / 2)
                        .transition(appear(x: 4, y: 0))
                case .bottom, .top:
                    card(i).frame(width: w, height: h, alignment: .topLeading)
                        .position(x: max(Theme.Space.windowMargin, f.minX - 4) + w / 2, y: b.maxY + Self.gap / 2 + h / 2)
                        .transition(appear(x: 0, y: -4))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func card(_ i: HoverCardItem) -> some View {
        let shape = Theme.Radius.shape(Theme.Radius.row)
        return VStack(alignment: .leading, spacing: 1) {
            Text(i.title)
                .font(Theme.Font.row)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let d = i.detail {
                Text(d)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Theme.Space.m + 2)
        .padding(.vertical, Theme.Space.s + 1)
        .background(shape.fill(Theme.Palette.sheet))
        .overlay(shape.strokeBorder(Theme.Palette.hairline, lineWidth: 0.5))
        .themeShadow(.popover)
    }

    private func appear(x: CGFloat, y: CGFloat) -> AnyTransition {
        if Motion.suppressed { return .identity }
        if Motion.reduceMotion { return .opacity }
        return .opacity.combined(with: .offset(x: x, y: y))
    }
}
