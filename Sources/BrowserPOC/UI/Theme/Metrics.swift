import AppKit
import SwiftUI

extension Theme {
    /// Spacing. One margin, 8, separates the window, sidebar and content, the way Zen does.
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 6
        static let m: CGFloat = 8
        static let l: CGFloat = 12
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 20
        static let x3: CGFloat = 24
        static let x4: CGFloat = 32

        /// Between the window edge and the content card, and between the card and its neighbours.
        static let windowMargin: CGFloat = 8
        /// The sidebar's width, including its own inner padding.
        static let sidebarWidth: CGFloat = 248
        /// The right panel's width.
        static let panelWidth: CGFloat = 300
        /// Horizontal padding inside the sidebar and the right panel.
        static let sidebarInset: CGFloat = 10
        /// The top row of the sidebar, matching the title bar so its buttons line up with the traffic lights.
        static let titleBarHeight: CGFloat = 40
        /// Leaves room for the traffic lights at the start of the sidebar's top row.
        static let trafficLightsWidth: CGFloat = 76
        /// Sidebar rows: tabs, notes, folders, splits.
        static let rowHeight: CGFloat = 30
        static let rowGap: CGFloat = 2
        /// Leading inset of a row's icon and of a section label, so both line up.
        static let rowInset: CGFloat = 8
        /// The icon column in a row.
        static let rowIcon: CGFloat = 16
    }

    /// Corner radii. All corners are continuous (squircle) curves.
    enum Radius {
        static let xs: CGFloat = 4
        static let button: CGFloat = 6
        static let row: CGFloat = 8
        /// The content card. Inside the 16 pt window corner and the 8 pt margin it reads as concentric.
        static let card: CGFloat = 10
        static let sheet: CGFloat = 14
        static let window: CGFloat = 16

        static func shape(_ r: CGFloat) -> RoundedRectangle { RoundedRectangle(cornerRadius: r, style: .continuous) }
    }

    /// Shadows. Two layers each: a tight contact shadow for the edge and a soft one for lift.
    enum Shadow {
        case card, row, panelCard, sheet, mark

        struct Layer { let opacity: Double; let radius: CGFloat; let y: CGFloat }

        func layers(dark: Bool) -> [Layer] {
            let k = dark ? 2.2 : 1.0
            switch self {
            case .card: return [Layer(opacity: 0.06 * k, radius: 0.5, y: 0.5), Layer(opacity: 0.06 * k, radius: 8, y: 2)]
            case .row: return [Layer(opacity: 0.06 * k, radius: 0.5, y: 0.5), Layer(opacity: 0.04 * k, radius: 2, y: 1)]
            case .panelCard: return [Layer(opacity: 0.035 * k, radius: 0.5, y: 0.5), Layer(opacity: 0.04 * k, radius: 6, y: 2)]
            case .sheet: return [Layer(opacity: 0.10 * k, radius: 1, y: 0.5), Layer(opacity: 0.22 * min(k, 1.6), radius: 40, y: 18)]
            case .mark: return [Layer(opacity: 0.0, radius: 0, y: 0)]
            }
        }
    }
}

struct ThemeShadow: ViewModifier {
    let kind: Theme.Shadow
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let l = kind.layers(dark: scheme == .dark)
        return content
            .shadow(color: .black.opacity(l[0].opacity), radius: l[0].radius, y: l[0].y)
            .shadow(color: .black.opacity(l.count > 1 ? l[1].opacity : 0), radius: l.count > 1 ? l[1].radius : 0, y: l.count > 1 ? l[1].y : 0)
    }
}

extension View {
    func themeShadow(_ kind: Theme.Shadow) -> some View { modifier(ThemeShadow(kind: kind)) }
}
