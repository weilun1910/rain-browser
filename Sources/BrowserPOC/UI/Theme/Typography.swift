import AppKit
import SwiftUI

extension Theme {
    /// Type. The chrome is SF Pro, the system face: it's what macOS controls and Safari's web text
    /// use, it has optical sizes for 11 to 13 pt, and a browser's chrome should recede behind the
    /// page. Display moments, where the app speaks to you (onboarding, import, the empty start page),
    /// use New York, Apple's serif, at large sizes only. Monospace is for raw data only.
    enum Font {
        /// Section labels, metadata, counts. Sentence case, never uppercase.
        static let label = SwiftUI.Font.system(size: 11, weight: .medium)
        /// Small secondary text: hosts, reasons, captions.
        static let caption = SwiftUI.Font.system(size: 11)
        /// Secondary body text: passages, explanations.
        static let secondary = SwiftUI.Font.system(size: 12)
        /// Rows in the sidebar and most UI text.
        static let row = SwiftUI.Font.system(size: 13)
        static let rowEmphasis = SwiftUI.Font.system(size: 13, weight: .medium)
        /// The current space's name at the top of the sidebar.
        static let spaceTitle = SwiftUI.Font.system(size: 12, weight: .semibold)
        /// Titles on right panel cards.
        static let cardTitle = SwiftUI.Font.system(size: 13, weight: .semibold)
        /// Small action labels, like Open on a card.
        static let action = SwiftUI.Font.system(size: 11, weight: .medium)
        /// Section titles inside panes, like an error heading.
        static let heading = SwiftUI.Font.system(size: 15, weight: .semibold)
        /// The command bar's field.
        static let fieldSize: CGFloat = 20
        static let field = SwiftUI.Font.system(size: fieldSize)
        static let fieldNS = NSFont.systemFont(ofSize: fieldSize, weight: .regular)

        /// New York at display sizes.
        static func display(_ size: CGFloat = 26, weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
            .system(size: size, weight: weight, design: .serif)
        }
        /// Monospace, for raw data like scores and domain lists.
        static func mono(_ size: CGFloat = 11) -> SwiftUI.Font { .system(size: size, design: .monospaced) }
    }
}

extension View {
    /// Tightens display type the way large serif headings want.
    func displayTracking() -> some View { tracking(-0.2) }
}
