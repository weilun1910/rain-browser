import SwiftUI

// Small visual pieces of the sidebar, kept apart so the look can change without touching behaviour.
// The open state of a folder is `Folder.isExpanded` (see `BrowserModel.setFolder(_:open:)`).

/// The timing for folders opening and closing.
enum FolderMotion {
    static let toggle: Animation = .easeInOut(duration: 0.2)
}

/// A folder's disclosure chevron and icon. The chevron turns as the folder opens.
struct FolderGlyph: View {
    let isOpen: Bool
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .foregroundStyle(.tertiary)
                .frame(width: 10)
            Image(systemName: isOpen ? "folder" : "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

extension View {
    /// How a folder's children appear and go: they slide down from the folder row and fade.
    func folderReveal() -> some View {
        self.transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                    removal: .move(edge: .top).combined(with: .opacity)))
    }

    /// The ring on the row the keyboard is on, after Cmd-.
    func sidebarCursor(_ on: Bool) -> some View {
        self.overlay {
            if on {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
    }
}
