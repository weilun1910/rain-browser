import AppKit
import SwiftUI

/// Every visual value the Related shelf uses, in one place. Where the design system has a token
/// (`Theme` and `Motion`, in `UI/Theme/`), the value points at it, so the shelf follows the chrome.
/// The rest are the shelf's own.
enum ShelfStyle {
    // MARK: Sizes

    /// A pill's height. Thin enough that the shelf barely covers the page.
    static let pillHeight: CGFloat = 30
    /// The sidebar row radius (`Theme.Radius.row`), so pills read as precise rather than bubbly.
    static let pillRadius: CGFloat = Theme.Radius.row
    static let pillPadding: CGFloat = 10            // between `Theme.Space.m` and `.l`
    static let pillIcon: CGFloat = 14
    static let pillIconGap: CGFloat = 7
    static let pillMaxWidth: CGFloat = 220
    static let pillMinWidth: CGFloat = 92
    static let pillGap: CGFloat = Theme.Space.s
    /// The hairline between Sites and Notes / Docs.
    static let dividerHeight: CGFloat = 14
    static let dividerGap: CGFloat = 4
    /// Between the shelf and the card's edges.
    static let margin: CGFloat = 10
    /// The content card's corner.
    static let cardRadius: CGFloat = Theme.Radius.card
    /// How tall the fade behind the shelf is.
    static let fadeHeight: CGFloat = 72
    /// The row fades out over this much at an edge with more to scroll to.
    static let edgeFade: CGFloat = 18
    /// How much of the page's bottom the shelf covers, told to WebKit and to notes.
    static var clearance: CGFloat { pillHeight + margin + 6 }
    /// Toasts sit this much higher while the shelf shows.
    static var toastLift: CGFloat { pillHeight + margin }

    static let popoverWidth: CGFloat = 330
    static let popoverRadius: CGFloat = Theme.Radius.popover
    static let popoverPadding: CGFloat = 14
    /// Between the pill and the popover above it.
    static let popoverGap: CGFloat = 8
    /// The local graph's popover. Its height comes from the graph slot itself.
    static let graphPopoverWidth: CGFloat = 340

    // MARK: Type (`Theme.Font`)

    static let pillTitle = Font.system(size: 12, weight: .medium)
    static let pillCaption = Theme.Font.caption.monospacedDigit()
    static let popTitle = Theme.Font.cardTitle
    static let popMeta = Theme.Font.caption
    static let popPassage = Theme.Font.secondary
    static let popReason = Theme.Font.caption
    static let popAction = Theme.Font.action
    static let popScores = Theme.Font.mono(10)

    // MARK: Colours, light then dark

    static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { a in a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light })
    }

    /// Pills sit on the sheet colour, a touch see-through.
    static let pillFill = dynamic(Theme.Palette.sheetLight.ns.withAlphaComponent(0.94), Theme.Palette.sheetDark.ns.withAlphaComponent(0.94))
    static let pillHover = dynamic(NSColor(white: 1, alpha: 1), NSColor(white: 0.205, alpha: 0.98))
    static let hairline = Theme.Palette.hairline
    static let popoverFill = Theme.Palette.sheet
    /// The line between Sites and Notes / Docs. A mid grey, so it shows over light and dark pages.
    static let divider = Color.secondary.opacity(0.45)
    /// The fade: toward black in dark mode, toward the light frame grey (`frameLight`, #EDEDED) in light mode.
    static let fadeColor = dynamic(Theme.Palette.frameLight.ns, NSColor(white: 0, alpha: 1))
    static let fadeStrength = (light: 0.75, dark: 0.5)
    /// The rule beside the reason line, like the right panel card's.
    static let reasonRule = Color.accentColor.opacity(0.55)

    // MARK: Shadows (`Theme.Shadow`, two layers: contact then lift)

    struct ShadowLayer { let opacity: Double; let radius: CGFloat; let y: CGFloat }
    static func pillShadow(dark: Bool, hovering: Bool) -> [ShadowLayer] {
        let k = dark ? 2.2 : 1.0
        return [ShadowLayer(opacity: 0.08 * k, radius: 0.5, y: 0.5),
                ShadowLayer(opacity: (hovering ? 0.13 : 0.08) * min(k, 1.6), radius: hovering ? 9 : 6, y: hovering ? 3 : 2)]
    }
    /// The design system's popover shadow, for anything that floats over the page.
    static func popoverShadow(dark: Bool) -> [ShadowLayer] {
        Theme.Shadow.popover.layers(dark: dark).map { ShadowLayer(opacity: $0.opacity, radius: $0.radius, y: $0.y) }
    }

    // MARK: Motion (`Motion`)

    /// Tests set this to check both paths. Nil follows the system setting. It's the chrome's own
    /// switch, so the shelf and the rest of the app never disagree.
    static var forceReduce: Bool? {
        get { Motion.forceReduce }
        set { Motion.forceReduce = newValue }
    }
    static var reduceMotion: Bool { Motion.reduceMotion }

    /// How long the pointer rests on a pill before its popover opens.
    static let openDelay: TimeInterval = 0.3
    /// How long after the pointer leaves the pill and the popover before it closes.
    static let closeDelay: TimeInterval = 0.2
    /// A re-hover this soon after closing opens at once.
    static let warmWindow: TimeInterval = 0.5
    /// The shelf comes back this long after the last keystroke in a note.
    static let typingPause: TimeInterval = 1.4
    /// Pills arriving one after another, the same step as the Related cards.
    static let stagger: TimeInterval = Motion.Timing.cardStagger

    /// The popover growing out of its pill: gentle, a touch of settle.
    static let popIn = Animation.spring(duration: 0.32, bounce: 0.1)
    static let popOut = Animation.easeOut(duration: 0.14)
    /// The popover gliding to a neighbouring pill.
    static let glide = Animation.spring(duration: 0.3, bounce: 0)
    /// The shelf rising in, sinking while you type, and moving to another pane.
    static let shelf = Animation.spring(duration: 0.36, bounce: 0.06)
    /// A hovered pill brightening and lifting.
    static let hover = Motion.hover
    static let reducedFade = Motion.reducedFade

    /// `a`, or a short fade under Reduce Motion.
    static func motion(_ a: Animation) -> Animation { reduceMotion ? reducedFade : a }
}

extension View {
    /// Two-layer shadow from `ShelfStyle`.
    func shelfShadow(_ layers: [ShelfStyle.ShadowLayer]) -> some View {
        self
            .shadow(color: .black.opacity(layers[0].opacity), radius: layers[0].radius, y: layers[0].y)
            .shadow(color: .black.opacity(layers[1].opacity), radius: layers[1].radius, y: layers[1].y)
    }
}
