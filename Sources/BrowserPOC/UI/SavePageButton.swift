import AppKit
import SwiftUI

// Saving a page: Cmd-Shift-S, or the save icon at the end of the address field, opens the folder
// popup to pick where it goes, like choosing where to save a download. When the page is already
// saved the icon is filled in, and clicking it shows where, with Move and Remove.

extension BrowserModel {
    /// Cmd-Shift-S and the save icon.
    func saveCurrentPage(from anchor: String? = nil) {
        guard let t = currentTab, t.isWeb || t.isApp, t.url != nil || t.webView?.url != nil else {
            toast("Open a page to save it")
            return
        }
        FolderPopup.shared.open(self, from: anchor, mode: .save(t.id))
    }
}

/// The save icon at the end of the address field.
struct SavePageButton: View {
    @ObservedObject var tab: Tab
    var size: CGFloat = 20
    @EnvironmentObject var model: BrowserModel
    @ObservedObject private var saved = SavedPages.shared
    @State private var showing = false
    @Environment(\.spaceAccent) private var accent

    var body: some View {
        let _ = saved.version
        let files = model.savedFiles(for: tab)
        IconButton(symbol: files.isEmpty ? "bookmark" : "bookmark.fill",
                   help: files.isEmpty ? "Save Page to Folder (Shift-Cmd-S)" : "Saved. Click to see where.",
                   width: size, height: size, symbolSize: 10) {
            if files.isEmpty { model.saveCurrentPage(from: "address-save") } else { showing.toggle() }
        }
        .foregroundStyle(files.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(accent))
        .folderPopupAnchor("address-save")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            SavedPlaces(files: files, close: { showing = false })
                .frame(width: 300)
                .padding(12)
        }
    }
}

/// Where a page is saved, with Move and Remove for each place.
struct SavedPlaces: View {
    let files: [URL]
    let close: () -> Void
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(files.count == 1 ? "Saved in" : "Saved in \(files.count) places").font(Theme.Font.label).foregroundStyle(.secondary)
            ForEach(files, id: \.self) { f in
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        close()
                        FolderPopup.shared.open(model, at: f.deletingLastPathComponent())
                        FolderPopup.shared.selection = f.path
                    } label: {
                        HStack(spacing: 8) {
                            FolderGlyph(isOpen: false, size: 15, ground: Theme.Palette.sheet)
                            Text(model.displayPath(f.deletingLastPathComponent())).font(Theme.Font.row).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show it in Folders")
                    HStack(spacing: 8) {
                        Button("Move...") {
                            close()
                            FolderPopup.shared.open(model, at: f.deletingLastPathComponent(), mode: .move([f]))
                        }
                        Button("Remove") {
                            close()
                            model.removeSavedPage(f)
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}
