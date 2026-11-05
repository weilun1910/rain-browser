import SwiftUI

// Small visual pieces of the sidebar, kept apart so the look can change without touching behaviour.
// The open state of a folder is `Folder.isExpanded` (see `BrowserModel.setFolder(_:open:)`).
// The drawing lives in the design system: `FolderGlyph` and `FolderReveal` in UI/Theme/Glyphs.swift.

/// The timing for folders opening and closing: the theme's folder spring, or a short fade with
/// Reduce Motion on.
enum FolderMotion {
    static var toggle: Animation { Motion.animation(Motion.expand, fadeOnly: true) ?? Motion.reducedFade }
}

extension View {
    /// How a folder's children appear and go: they slide out from under the folder row like a
    /// drawer and fade, and with Reduce Motion they only fade.
    func folderReveal() -> some View {
        self.transition(Motion.Transitions.folderContents)
    }

    /// The ring on the row the keyboard is on, after Cmd-.
    func sidebarCursor(_ on: Bool) -> some View {
        modifier(SidebarCursor(on: on))
    }
}

private struct SidebarCursor: ViewModifier {
    let on: Bool
    @Environment(\.spaceAccent) private var accent
    func body(content: Content) -> some View {
        content.overlay {
            if on {
                Theme.Radius.shape(Theme.Radius.row)
                    .strokeBorder(accent.opacity(0.7), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .motion(Motion.hover, value: on, fadeOnly: true)
    }
}
