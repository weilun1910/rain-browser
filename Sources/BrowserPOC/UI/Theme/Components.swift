import AppKit
import SwiftUI

// Small building blocks other views use instead of styling themselves.

// MARK: Environment

private struct SpaceAccentKey: EnvironmentKey {
    static let defaultValue: Color = Theme.Palette.accent(nil)
}
private struct SpaceTintHexKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The current space's colour, toned for small marks: rings, progress, the selected command row.
    var spaceAccent: Color {
        get { self[SpaceAccentKey.self] }
        set { self[SpaceAccentKey.self] = newValue }
    }
    /// The current space's colour as stored, for views that blend it themselves.
    var spaceTintHex: String? {
        get { self[SpaceTintHexKey.self] }
        set { self[SpaceTintHexKey.self] = newValue }
    }
}

extension View {
    /// Hands the space's colour to everything inside. MainView sets it once from the current space.
    func spaceTint(_ hex: String?) -> some View {
        environment(\.spaceAccent, Theme.Palette.accent(hex)).environment(\.spaceTintHex, hex)
    }
}

// MARK: Surfaces

struct ContentCard: ViewModifier {
    var focused = false
    var accent: Color?
    @Environment(\.spaceAccent) private var spaceAccent
    func body(content: Content) -> some View {
        let shape = Theme.Radius.shape(Theme.Radius.card)
        return content
            .background(Theme.Palette.card)
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(focused ? (accent ?? spaceAccent).opacity(0.65) : Theme.Palette.hairline,
                                   lineWidth: focused ? 1.5 : 0.5)
                    .motion(Motion.hover, value: focused, fadeOnly: true)
                    .allowsHitTesting(false)
            )
            .background(shape.fill(Theme.Palette.card).themeShadow(.card))
    }
}

struct SidebarRowBackground: ViewModifier {
    let selected: Bool
    let hovering: Bool
    var pressed = false
    func body(content: Content) -> some View {
        content
            .background(
                Theme.Radius.shape(Theme.Radius.row)
                    .fill(selected ? Theme.Palette.rowSelected
                          : (pressed ? Theme.Palette.rowPressed : (hovering ? Theme.Palette.rowHover : .clear)))
                    .themeShadow(selected ? .row : .mark)
            )
            .motion(Motion.hover, value: hovering, fadeOnly: true)
            .motion(Motion.hover, value: selected, fadeOnly: true)
    }
}

struct PanelCard: ViewModifier {
    let hovering: Bool
    func body(content: Content) -> some View {
        let shape = Theme.Radius.shape(Theme.Radius.card)
        return content
            .background(shape.fill(hovering ? Theme.Palette.raisedHover : Theme.Palette.raised).themeShadow(.panelCard))
            .overlay(shape.strokeBorder(Theme.Palette.hairline, lineWidth: 0.5))
            .motion(Motion.hover, value: hovering, fadeOnly: true)
    }
}

struct FloatingSheet: ViewModifier {
    var radius: CGFloat = Theme.Radius.sheet
    func body(content: Content) -> some View {
        let shape = Theme.Radius.shape(radius)
        return content
            .background(shape.fill(Theme.Palette.sheet).themeShadow(.sheet))
            .overlay(shape.strokeBorder(Theme.Palette.hairline, lineWidth: 0.5))
    }
}

extension View {
    /// The rounded card a page or note sits on. `focused` draws a quiet ring in the space's accent.
    func contentCard(focused: Bool = false, accent: Color? = nil) -> some View {
        modifier(ContentCard(focused: focused, accent: accent))
    }
    /// Background for a sidebar row: a near-white chip when selected, a faint fill on hover.
    func sidebarRow(selected: Bool, hovering: Bool, pressed: Bool = false) -> some View {
        modifier(SidebarRowBackground(selected: selected, hovering: hovering, pressed: pressed))
    }
    /// A neutral card in the right panel.
    func panelCard(hovering: Bool = false) -> some View { modifier(PanelCard(hovering: hovering)) }
    /// A sheet that floats over everything: the command bar, the first run panel.
    func floatingSheet(radius: CGFloat = Theme.Radius.sheet) -> some View { modifier(FloatingSheet(radius: radius)) }
}

// MARK: Buttons

/// Icon buttons in the chrome: back, forward, reload, panel toggles, small plus buttons.
/// A faint rounded fill on hover and a slight press, no border.
struct IconButtonStyle: ButtonStyle {
    var width: CGFloat = 28
    var height: CGFloat = 26
    var symbolSize: CGFloat = 13
    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, width: width, height: height, symbolSize: symbolSize)
    }
}

private struct IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let width: CGFloat
    let height: CGFloat
    let symbolSize: CGFloat
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .font(.system(size: symbolSize, weight: .medium))
            .frame(width: width, height: height)
            .foregroundStyle(enabled ? (hovering ? .primary : .secondary) : .quaternary)
            .background(
                Theme.Radius.shape(Theme.Radius.button)
                    .fill(configuration.isPressed ? Theme.Palette.rowPressed : (hovering && enabled ? Theme.Palette.rowHover : .clear))
            )
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed && !Motion.reduceMotion ? 0.94 : 1)
            .onHover { hovering = $0 }
            .motion(Motion.hover, value: hovering, fadeOnly: true)
            .motion(Motion.press, value: configuration.isPressed)
    }
}

/// A full-width action row in the sidebar, like New tab: quiet text, a faint fill on hover.
struct SidebarActionRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { SidebarActionRowBody(configuration: configuration) }
}

private struct SidebarActionRowBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false
    var body: some View {
        configuration.label
            .font(Theme.Font.row)
            .foregroundStyle(hovering ? .primary : .secondary)
            .padding(.horizontal, Theme.Space.rowInset)
            .frame(height: Theme.Space.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .sidebarRow(selected: false, hovering: hovering, pressed: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

/// A small text action, like Open or Add to research on a card.
struct QuietActionStyle: ButtonStyle {
    var accent: Color = .accentColor
    func makeBody(configuration: Configuration) -> some View { QuietActionBody(configuration: configuration, accent: accent) }
}

private struct QuietActionBody: View {
    let configuration: ButtonStyleConfiguration
    let accent: Color
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        configuration.label
            .font(Theme.Font.action)
            .foregroundStyle(enabled ? (hovering ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary)) : AnyShapeStyle(.tertiary))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .motion(Motion.hover, value: hovering, fadeOnly: true)
    }
}

/// An icon button with the chrome's look.
struct IconButton: View {
    let symbol: String
    let help: String
    var width: CGFloat = 28
    var height: CGFloat = 26
    var symbolSize: CGFloat = 13
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(IconButtonStyle(width: width, height: height, symbolSize: symbolSize))
            .help(help)
    }
}

// MARK: Labels

/// The quiet header above a sidebar or panel section. Its buttons, like New folder, show when
/// you hover the header, the way Zen keeps the sidebar clear until you reach for something.
struct SectionHeader<Trailing: View>: View {
    let title: String
    var highlighted = false
    /// Keep the trailing buttons visible all the time.
    var alwaysShowTrailing = false
    @ViewBuilder var trailing: () -> Trailing
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            trailing()
                .opacity(hovering || highlighted || alwaysShowTrailing ? 1 : 0)
                .motion(Motion.hover, value: hovering, fadeOnly: true)
        }
        .padding(.leading, Theme.Space.rowInset)
        .padding(.trailing, 2)
        .frame(height: 24)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .background(Theme.Radius.shape(Theme.Radius.button).fill(highlighted ? Theme.Palette.rowHover : .clear))
        .motion(Motion.hover, value: highlighted, fadeOnly: true)
    }
}

/// A hairline between groups of rows, inset to the row text.
struct SectionDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.Palette.hairline)
            .frame(height: 1)
            .padding(.horizontal, Theme.Space.rowInset)
            .padding(.vertical, Theme.Space.s)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, highlighted: Bool = false) {
        self.init(title: title, highlighted: highlighted) { EmptyView() }
    }
}

/// The small icon at the start of a sidebar row.
struct RowIcon: View {
    let symbol: String
    var tint: Color? = nil
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12))
            .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
            .frame(width: Theme.Space.rowIcon, height: Theme.Space.rowIcon)
    }
}

// MARK: Background and progress

/// The window frame: neutral grey with the space's colour washed over the sidebar side,
/// fading toward the trailing edge. It crossfades when the space changes and dims when the
/// window isn't key.
struct SpaceTintBackground: View {
    let hex: String?
    var sidebarWidth: CGFloat = Theme.Space.sidebarWidth
    /// Renders and tests set this so an offscreen window looks active.
    nonisolated(unsafe) static var forceActive = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        GeometryReader { g in
            let active = Self.forceActive || activeState == .key || activeState == .active
            let edge = min(0.95, max(0.05, sidebarWidth / max(g.size.width, 1)))
            let tint = Theme.Palette.sidebarColor(hex, active: active)
            ZStack {
                Theme.Palette.frame
                // Full strength under the sidebar, holding past its edge, then easing toward neutral.
                LinearGradient(stops: [
                    .init(color: tint, location: 0),
                    .init(color: tint.opacity(0.92), location: edge),
                    .init(color: tint.opacity(0.55), location: min(1, edge + 0.25)),
                    .init(color: tint.opacity(Theme.Palette.tintTrailingShare), location: 1),
                ], startPoint: .leading, endPoint: .trailing)
                .id((hex ?? "") + (active ? "" : "-inactive"))
                .transition(.opacity)
                GrainOverlay()
            }
            .motion(Motion.spaceSwitch, value: hex, fadeOnly: true)
            .motion(Motion.hover, value: active, fadeOnly: true)
        }
        .ignoresSafeArea()
    }
}

/// The thin load progress line along the top of a page.
struct TintedProgressLine: View {
    let progress: Double
    let visible: Bool
    var accent: Color?
    @Environment(\.spaceAccent) private var spaceAccent
    var body: some View {
        GeometryReader { g in
            Capsule()
                .fill((accent ?? spaceAccent).opacity(0.85))
                .frame(width: max(8, g.size.width * min(1, max(0, progress))), height: 2)
                .opacity(visible ? 1 : 0)
                .motion(Motion.progress, value: progress)
                .motion(Motion.progress, value: visible, fadeOnly: true)
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }
}
