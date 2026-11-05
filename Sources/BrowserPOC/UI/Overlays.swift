import AppKit
import SwiftUI

/// Peek: the page floats over the current one, which dims and settles back a little, like Zen's
/// Glance. Expand, Split and Close sit at the top right.
struct PeekOverlay: View {
    let peek: PeekState
    @EnvironmentObject var model: BrowserModel
    @State private var shown = false

    var body: some View {
        GeometryReader { g in
            ZStack {
                Theme.Palette.scrim.opacity(shown ? 1.6 : 0)
                    .contentShape(Rectangle())
                    .onTapGesture { model.closePeek() }
                VStack(spacing: Theme.Space.s) {
                    HStack(spacing: Theme.Space.s) {
                        PeekTitle(tab: peek.tab)
                        Spacer()
                        HStack(spacing: 0) {
                            PeekButton(symbol: "rectangle.split.2x1", help: "Open in split view") { model.splitPeek() }
                            PeekButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Open as a tab (Cmd-O)") { model.expandPeek() }
                            PeekButton(symbol: "xmark", help: "Close (Esc)") { model.closePeek() }
                        }
                        .padding(.horizontal, 2)
                        .floatingSurface(radius: Theme.Radius.row)
                    }
                    .padding(.horizontal, Theme.Space.xs)
                    WebArea(tab: peek.tab)
                        .paneCard()
                        .themeShadow(.popover)
                }
                .frame(width: g.size.width * 0.84, height: g.size.height * 0.9)
                .scaleEffect(shown || Motion.reduceMotion ? 1 : 0.96)
                .opacity(shown ? 1 : 0)
            }
        }
        .onAppear { Motion.run(Motion.peek, fadeOnly: true) { shown = true } }
    }
}

struct PeekTitle: View {
    @ObservedObject var tab: Tab
    var body: some View {
        HStack(spacing: Theme.Space.s) {
            ItemIcon(tab: tab, size: 14)
            Text(tab.displayTitle).font(Theme.Font.rowEmphasis).lineLimit(1).foregroundStyle(.primary)
            if let h = tab.url?.host { Text(h).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: 26)
        .floatingSurface(radius: Theme.Radius.row)
    }
}

struct PeekButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        IconButton(symbol: symbol, help: help, width: 28, height: 24, symbolSize: 11, action: action)
    }
}

/// Find in page, at the top right of the focused pane.
struct FindBar: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            FindField(text: Binding(get: { model.find.query }, set: { model.setFindQuery($0) }), focusToken: model.find.focusToken,
                      onNext: { model.findNext(backwards: $0) }, onClose: { model.closeFind() })
                .frame(width: 180, height: 20)
            Text(countText).font(Theme.Font.caption.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 54, alignment: .trailing)
            SmallIconButton(symbol: "chevron.up", help: "Previous (Shift-Cmd-G)") { model.findNext(backwards: true) }
            SmallIconButton(symbol: "chevron.down", help: "Next (Cmd-G)") { model.findNext() }
            SmallIconButton(symbol: "xmark", help: "Done (Esc)") { model.closeFind() }
        }
        .padding(.leading, Theme.Space.l - 2)
        .padding(.trailing, Theme.Space.xs)
        .frame(height: 36)
        .popoverSurface(radius: Theme.Radius.card)
        .appearEffect(scale: 0.98, y: -4, animation: Motion.barIn)
    }

    var countText: String {
        guard !model.find.query.isEmpty, let n = model.find.matches else { return "" }
        return n == 0 ? "No matches" : "\(model.find.index) of \(n)"
    }
}

struct FindField: NSViewRepresentable {
    @Binding var text: String
    let focusToken: Int
    let onNext: (Bool) -> Void
    let onClose: () -> Void

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FindField
        var lastToken = -1
        init(_ p: FindField) { parent = p }
        func controlTextDidChange(_ n: Notification) { if let f = n.object as? NSTextField { parent.text = f.stringValue } }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onNext(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false); return true
            case #selector(NSResponder.cancelOperation(_:)): parent.onClose(); return true
            default: return false
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: 13)
        f.placeholderString = "Find in page"
        f.delegate = context.coordinator
        f.stringValue = text
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text { f.stringValue = text }
        if context.coordinator.lastToken != focusToken {
            context.coordinator.lastToken = focusToken
            DispatchQueue.main.async { f.window?.makeFirstResponder(f); f.currentEditor()?.selectAll(nil) }
        }
    }
}

/// A short message at the bottom of the content area, sometimes with Undo.
struct ToastView: View {
    let toast: ToastState
    @EnvironmentObject var model: BrowserModel

    @Environment(\.spaceAccent) private var accent

    var body: some View {
        HStack(spacing: Theme.Space.l) {
            Text(toast.message).font(Theme.Font.secondary)
            if let a = toast.actionTitle {
                Button(a) { model.runToastAction() }
                    .buttonStyle(QuietActionStyle(accent: accent))
                    .foregroundStyle(accent)
            }
        }
        .padding(.horizontal, Theme.Space.l + 2)
        .frame(height: 34)
        .floatingSurface(radius: Theme.Radius.card)
    }
}

/// Ctrl-Tab: recent items while Ctrl is held. Release Ctrl to go there.
struct SwitcherOverlay: View {
    let state: SwitcherState
    @EnvironmentObject var model: BrowserModel
    @Environment(\.spaceAccent) private var accent
    @Namespace private var selection

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            ForEach(Array(state.items.enumerated()), id: \.offset) { i, s in
                HStack(spacing: Theme.Space.l) {
                    switcherIcon(s)
                    Text(model.title(for: s)).font(Theme.Font.row).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.Space.m + 2)
                .frame(height: 32)
                // The same gliding, space-tinted highlight as the command bar.
                .background {
                    if i == state.index {
                        Theme.Radius.shape(Theme.Radius.row).fill(accent.opacity(0.16))
                            .matchedGeometryEffect(id: "switcher", in: selection)
                    }
                }
            }
        }
        .motion(Motion.selection, value: state.index)
        .padding(Theme.Space.m)
        .frame(width: 380)
        .floatingSheet()
        .appearEffect(scale: 0.97, y: 6, animation: Motion.barIn)
    }

    @ViewBuilder func switcherIcon(_ s: Selection) -> some View {
        switch s {
        case .tab(let id): ItemIcon(tab: model.tab(id), size: 16)
        case .split: Image(systemName: "rectangle.split.2x1").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
        }
    }
}
